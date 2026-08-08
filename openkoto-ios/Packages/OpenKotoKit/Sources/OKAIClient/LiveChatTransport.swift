import Foundation
import OKModels

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 生产用 ChatTransport：非流式 `complete`，逐条对齐桌面 `ai_service.rs`
/// 的三种协议形态（OpenAI-compatible / Anthropic / Google Gemini）。
///
/// URL 拼接、认证头、请求体与响应字段解析均镜像 Rust 侧
/// `get_api_url` / `make_request` / `make_anthropic_request` / `make_google_request`。
/// 通过注入 `URLSession`（可用 URLProtocol stub）做契约测试（设计文档 §9.1 AI 契约层）。
public struct LiveChatTransport: ChatTransport {
    private let session: URLSession
    /// 429（真限流，非余额耗尽）重试前的等待秒数；响应带 Retry-After 时优先用它。
    /// 测试注入 0 以保持毫秒级回路。
    private let rateLimitRetryDelay: TimeInterval

    public init(session: URLSession = .shared, rateLimitRetryDelay: TimeInterval = 2) {
        self.session = session
        self.rateLimitRetryDelay = rateLimitRetryDelay
    }

    public func complete(
        _ request: ChatRequest, config: ModelConfig, apiKey: String?
    ) async throws -> String {
        let started = Date()
        // 每类降级只允许一次，标志位单向翻转，循环必然终止（最多 5 发）。
        var effectiveRequest = request
        var tokenParameter = Self.tokenParameter(for: config.model)
        var includeTemperature = true
        var didSwapTokenParameter = false
        var didDropTemperature = false
        var didDropOutputCap = false
        var didRetryTransient = false

        while true {
            do {
                return try await send(
                    effectiveRequest, config: config, apiKey: apiKey,
                    tokenParameter: tokenParameter, includeTemperature: includeTemperature)
            } catch let failure as HTTPFailure {
                // OpenAI 的 o 系与 gpt-5 只收 max_completion_tokens，其余模型只收 max_tokens，
                // 发错是 400 而不是被忽略。model id 判不准时（OpenRouter 代理、自建兼容端点）
                // 靠这次降级重发兜底，换另一个参数名再试一次。
                if failure.status == 400, effectiveRequest.maxOutputTokens != nil,
                    !didSwapTokenParameter, Self.mentionsTokenParameter(failure.body)
                {
                    didSwapTokenParameter = true
                    tokenParameter = tokenParameter.alternative
                    continue
                }
                // 推理模型只接受默认 temperature（已知的 gpt-5/o 系在构造时就不带；
                // 中转站背后的模型判不出来），400 点名 temperature 时去掉它重发。
                if failure.status == 400, includeTemperature, !didDropTemperature,
                    Self.mentionsTemperature(failure.body)
                {
                    didDropTemperature = true
                    includeTemperature = false
                    continue
                }
                // 真限流（非余额耗尽）等一下重试一次就能过——批量任务的
                // 间歇性大面积失败多来自这里。余额耗尽伪装的 429 一次都不试。
                if failure.status == 429, !didRetryTransient,
                    !Self.isInsufficientBalance(status: failure.status, body: failure.body)
                {
                    didRetryTransient = true
                    do {
                        try await Task.sleep(
                            for: .seconds(min(failure.retryAfter ?? rateLimitRetryDelay, 15)))
                    } catch {
                        throw Self.diagnosed(
                            AIClientError.cancelled, request: effectiveRequest, config: config,
                            apiKey: apiKey, started: started)
                    }
                    continue
                }
                throw Self.diagnosed(
                    failure, request: effectiveRequest, config: config, apiKey: apiKey,
                    started: started)
            } catch let exhausted as OutputBudgetExhausted {
                // 思考/推理 token 也计入输出上限（Gemini 2.5、gpt-5）：查词/测试连接的
                // 小上限会被思考吃光，返回 200 但没有正文。去掉上限重发——
                // 宁可这一次多花些 token，也不能给用户一句"响应异常"。
                if effectiveRequest.maxOutputTokens != nil, !didDropOutputCap {
                    didDropOutputCap = true
                    effectiveRequest.maxOutputTokens = nil
                    continue
                }
                throw Self.diagnosed(
                    exhausted, request: effectiveRequest, config: config, apiKey: apiKey,
                    started: started)
            } catch let urlError as URLError
                where urlError.code == .networkConnectionLost && !didRetryTransient
            {
                // -1005：复用了服务端已单方面关闭的连接（iOS 网络栈经典问题），
                // 原样重发一次即可，不算真正的网络故障。
                didRetryTransient = true
                continue
            } catch {
                throw Self.diagnosed(
                    error, request: effectiveRequest, config: config, apiKey: apiKey,
                    started: started)
            }
        }
    }

    private func send(
        _ request: ChatRequest, config: ModelConfig, apiKey: String?,
        tokenParameter: TokenParameter, includeTemperature: Bool
    ) async throws -> String {
        let urlRequest = try Self.buildURLRequest(
            request, config: config, apiKey: apiKey, tokenParameter: tokenParameter,
            includeTemperature: includeTemperature)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch is CancellationError {
            throw AIClientError.cancelled
        }
        // URLError 不在这里分类：原始码（-1005 连接被重置 vs -1009 断网…）是
        // 排查"网络不可用"的关键线索，原样抛给 complete 的 diagnosed() 统一处理。

        guard let http = response as? HTTPURLResponse else {
            throw AIClientError.malformedResponse(requestID: request.requestID)
        }
        guard (200...299).contains(http.statusCode) else {
            // 失败响应的 body 是"余额不足 vs 限流"的唯一信息来源，必须留到分类那一步
            throw HTTPFailure(
                status: http.statusCode, body: String(decoding: data, as: UTF8.self),
                retryAfter: http.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(TimeInterval.init))
        }

        do {
            return try Self.parseContent(
                data: data,
                kind: ProviderCapability.capability(for: config.apiProvider).kind,
                requestID: request.requestID
            )
        } catch let error as AIClientError {
            // 模型回了 200 但内容对不上 schema——响应体是"模型到底回了什么"的唯一线索。
            throw ParseFailure(clientError: error, body: String(decoding: data, as: UTF8.self))
        }
    }

    /// 非 2xx 的原始信息。带着 body 一路传到分类那一步。
    private struct HTTPFailure: Error {
        let status: Int
        let body: String
        /// 429 响应的 Retry-After 秒数（若服务端给了）。
        let retryAfter: TimeInterval?
    }

    /// 2xx 但解析失败的原始信息：错误分类 + 响应体摘录。
    private struct ParseFailure: Error {
        let clientError: AIClientError
        let body: String
    }

    /// 200 但输出被 token 上限吃光：思考/推理 token 也计入上限（Gemini 2.5 / gpt-5），
    /// 上限太小时正文为空。complete 捕获后去掉上限重发一次。
    private struct OutputBudgetExhausted: Error {
        let body: String
    }

    // MARK: - URL 解析（对齐 get_api_url）

    static func resolveURL(config: ModelConfig) -> URL? {
        let capability = ProviderCapability.capability(for: config.apiProvider)

        // 1. 自定义 baseURL 优先（对齐 Rust：无条件先用 base_url）。
        //    末尾去斜杠；已含 /chat/completions 则原样，否则补 /chat/completions。
        if let base = config.baseURL {
            var trimmed = base.absoluteString
            while trimmed.hasSuffix("/") { trimmed.removeLast() }
            if trimmed.hasSuffix("/chat/completions") {
                return URL(string: trimmed)
            }
            return URL(string: trimmed + "/chat/completions")
        }

        // 2. Gemini 依 model 动态拼接，并 strip "models/" 前缀。
        if capability.kind == .gemini {
            let model = config.model.hasPrefix("models/")
                ? String(config.model.dropFirst("models/".count))
                : config.model
            return URL(string:
                "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")
        }

        // 3. 已知 Provider 默认端点；4. 兜底 OpenAI（对齐 openai-compatible 未配 baseURL 的兜底）。
        return capability.defaultEndpoint
            ?? URL(string: "https://api.openai.com/v1/chat/completions")
    }

    // MARK: - 请求构造

    /// OpenAI 兼容端点上"输出上限"的参数名。同一个 provider 下不同模型不一样，
    /// 所以按 **model id** 判而不是按 provider 判。
    enum TokenParameter: Sendable, Equatable {
        case maxTokens
        case maxCompletionTokens

        var alternative: TokenParameter {
            self == .maxTokens ? .maxCompletionTokens : .maxTokens
        }
    }

    /// OpenRouter 之类会带 `openai/` 前缀，判模型家族取最后一段。
    private static func canonicalModelName(_ model: String) -> String {
        model.lowercased().split(separator: "/").last.map(String.init) ?? model.lowercased()
    }

    /// o 系（o1/o3/o4）与 gpt-5 系只收 `max_completion_tokens`，其余收 `max_tokens`。
    static func tokenParameter(for model: String) -> TokenParameter {
        let name = canonicalModelName(model)
        if name.hasPrefix("gpt-5") { return .maxCompletionTokens }
        for family in ["o1", "o3", "o4"] where name == family || name.hasPrefix("\(family)-") {
            return .maxCompletionTokens
        }
        return .maxTokens
    }

    /// gpt-5 与 o 系**推理模型**只接受默认 temperature(1)，显式传其他值直接 400——
    /// 这是"接了 OpenAI 之后全部失败"的根因，已知家族第一发就不能带。
    /// gpt-5-chat 系是普通 chat 模型，不在此列。
    static func modelRejectsCustomTemperature(_ model: String) -> Bool {
        let name = canonicalModelName(model)
        if name.hasPrefix("gpt-5-chat") { return false }
        if name.hasPrefix("gpt-5") { return true }
        for family in ["o1", "o3", "o4"] where name == family || name.hasPrefix("\(family)-") {
            return true
        }
        return false
    }

    /// 400 的报错是否指向输出上限参数——是的话换个名字重发还有救。
    static func mentionsTokenParameter(_ body: String) -> Bool {
        let lowered = body.lowercased()
        return lowered.contains("max_tokens") || lowered.contains("max_completion_tokens")
    }

    /// 400 的报错是否点名 temperature——是的话去掉它重发还有救（中转站背后的推理模型）。
    static func mentionsTemperature(_ body: String) -> Bool {
        body.lowercased().contains("temperature")
    }

    static func buildURLRequest(
        _ request: ChatRequest, config: ModelConfig, apiKey: String?,
        tokenParameter: TokenParameter = .maxTokens,
        includeTemperature: Bool = true
    ) throws -> URLRequest {
        guard let url = resolveURL(config: config) else {
            throw AIClientError.malformedResponse(requestID: request.requestID)
        }
        let capability = ProviderCapability.capability(for: config.apiProvider)
        let key = apiKey ?? ""

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = request.timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Moonshot 特例：temperature 强制 1.0（对齐 make_request）。
        // gpt-5/o 系推理模型只接受默认值，字段整个不发（未知模型靠 complete 的 400 兜底）。
        let temperature: Double? =
            capability.forcesTemperatureOne
            ? 1.0
            : (includeTemperature && !Self.modelRejectsCustomTemperature(config.model))
                ? request.temperature : nil

        switch capability.kind {
        case .openAICompatible:
            // 空 Key 时不加 Authorization（本地服务可能不需要）。
            if !key.isEmpty {
                urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            let body = OpenAIBody(
                model: config.model,
                messages: [
                    .init(role: "system", content: request.systemPrompt),
                    .init(role: "user", content: request.userMessage),
                ],
                temperature: temperature,
                max_tokens: tokenParameter == .maxTokens ? request.maxOutputTokens : nil,
                max_completion_tokens: tokenParameter == .maxCompletionTokens
                    ? request.maxOutputTokens : nil
            )
            urlRequest.httpBody = try JSONEncoder().encode(body)

        case .anthropic:
            urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
            urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let body = AnthropicBody(
                model: config.model,
                max_tokens: request.maxOutputTokens ?? 8192,
                messages: [.init(role: "user", content: request.userMessage)],
                temperature: temperature,
                system: request.systemPrompt.isEmpty ? nil : request.systemPrompt
            )
            urlRequest.httpBody = try JSONEncoder().encode(body)

        case .gemini:
            urlRequest.setValue(key, forHTTPHeaderField: "X-goog-api-key")
            // 对齐 Rust：Gemini 无 system 角色，把 system + user 合并进单个 user part。
            let text = request.systemPrompt.isEmpty
                ? request.userMessage
                : "\(request.systemPrompt)\n\n\(request.userMessage)"
            let body = GeminiBody(
                contents: [.init(role: "user", parts: [.init(text: text)])],
                generationConfig: .init(
                    temperature: temperature, maxOutputTokens: request.maxOutputTokens)
            )
            urlRequest.httpBody = try JSONEncoder().encode(body)
        }

        return urlRequest
    }

    // MARK: - 响应解析（对齐三种 Provider 的取值路径）

    /// 内容之外还要看 finish reason：200 而没有正文的三种情形必须分开——
    /// 安全拦截（→ `.contentBlocked`，重试无用）、输出上限被思考/推理 token 吃光
    /// （→ `OutputBudgetExhausted`，去掉上限重发有救）、其余才是真的响应异常。
    static func parseContent(data: Data, kind: ProviderKind, requestID: UUID) throws -> String {
        let decoder = JSONDecoder()
        switch kind {
        case .openAICompatible:
            guard let r = try? decoder.decode(OpenAIResponse.self, from: data),
                let choice = r.choices.first
            else { throw AIClientError.malformedResponse(requestID: requestID) }
            if let content = choice.message?.content, !content.isEmpty { return content }
            // 拒答走 content: null + refusal 字段；内容过滤走 finish_reason。
            if choice.message?.refusal != nil || choice.finishReason == "content_filter" {
                throw AIClientError.contentBlocked
            }
            if choice.finishReason == "length" {
                throw OutputBudgetExhausted(body: String(decoding: data, as: UTF8.self))
            }
            throw AIClientError.malformedResponse(requestID: requestID)

        case .anthropic:
            guard let r = try? decoder.decode(AnthropicResponse.self, from: data) else {
                throw AIClientError.malformedResponse(requestID: requestID)
            }
            // 只取 text block（扩展思考等其他 block 类型没有 text 字段）。
            let text = r.content.compactMap(\.text).joined()
            if !text.isEmpty { return text }
            if r.stopReason == "refusal" { throw AIClientError.contentBlocked }
            if r.stopReason == "max_tokens" {
                throw OutputBudgetExhausted(body: String(decoding: data, as: UTF8.self))
            }
            throw AIClientError.malformedResponse(requestID: requestID)

        case .gemini:
            guard let r = try? decoder.decode(GeminiResponse.self, from: data) else {
                throw AIClientError.malformedResponse(requestID: requestID)
            }
            let candidate = r.candidates?.first
            if let parts = candidate?.content?.parts {
                let text = parts.compactMap(\.text).joined()
                if !text.isEmpty { return text }
            }
            // prompt 级拦截连 candidates 都没有；candidate 级拦截没有 content。
            if r.promptFeedback?.blockReason != nil {
                throw AIClientError.contentBlocked
            }
            if let finish = candidate?.finishReason,
                ["SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII",
                 "IMAGE_SAFETY"].contains(finish)
            {
                throw AIClientError.contentBlocked
            }
            if candidate?.finishReason == "MAX_TOKENS" {
                throw OutputBudgetExhausted(body: String(decoding: data, as: UTF8.self))
            }
            throw AIClientError.malformedResponse(requestID: requestID)
        }
    }

    // MARK: - 错误映射

    /// 把状态码 + 响应体分类成用户能据以行动的错误。
    ///
    /// **只看状态码是不够的**：OpenAI 的余额耗尽走 429，与真正的限流同码。
    /// 把它显示成"限流，请稍后重试"会让用户去重试一个永远不会好的状态。
    /// 各家的判据（都来自各自的错误响应体）：
    /// - DeepSeek：`402`
    /// - OpenAI 系：`429` + `error.code == "insufficient_quota"`
    /// - Anthropic：`400` + 文案含 "credit balance is too low"
    static func classify(status: Int, body: String) -> AIClientError {
        if isInsufficientBalance(status: status, body: body) { return .insufficientBalance }
        switch status {
        case 401, 403: return .unauthorized
        case 429: return .rateLimited
        default: return .serverError(status: status)
        }
    }

    static func isInsufficientBalance(status: Int, body: String) -> Bool {
        if status == 402 { return true }
        let lowered = body.lowercased()
        let markers = [
            "insufficient_quota", "insufficient quota", "insufficient balance",
            "credit balance is too low", "exceeded your current quota",
            "billing_hard_limit_reached",
        ]
        guard markers.contains(where: lowered.contains) else { return false }
        // 只在明确的失败码上认，避免把正文里恰好提到这些词的成功响应误判
        return status == 400 || status == 402 || status == 429
    }

    static func mapURLError(_ error: URLError) -> AIClientError {
        switch error.code {
        case .cancelled:
            return .cancelled
        // 超时与断网要分开：前者"可重试或换个更快的模型"，后者"检查网络"，
        // 用户据此采取的行动完全不同。
        case .timedOut:
            return .timeout
        case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
            .networkConnectionLost, .dnsLookupFailed:
            return .networkUnreachable
        default:
            return .networkUnreachable
        }
    }

    /// 把 transport 内的任何错误归一成 `AIRequestFailure`：分类 + 现场快照。
    ///
    /// "网络不可用"这一句话盖住了一整族错误（断网、连接被重置、TLS 失败、DNS 污染……），
    /// 用户报告里唯一能区分它们的就是这里留下的 URLError 原始码与响应体摘录。
    /// 脱敏红线：API Key 只走请求头，快照天然不含；响应体若恰好回显 Key 会被剔除。
    static func diagnosed(
        _ error: Error, request: ChatRequest, config: ModelConfig, apiKey: String?,
        started: Date
    ) -> AIRequestFailure {
        if let failure = error as? AIRequestFailure { return failure }

        let classified: AIClientError
        var httpStatus: Int?
        var bodyExcerpt: String?
        var urlErrorCode: Int?
        var urlErrorName: String?
        var urlErrorMessage: String?

        switch error {
        case let failure as HTTPFailure:
            classified = classify(status: failure.status, body: failure.body)
            httpStatus = failure.status
            bodyExcerpt = failure.body
        case let failure as ParseFailure:
            classified = failure.clientError
            bodyExcerpt = failure.body
        case let exhausted as OutputBudgetExhausted:
            // 走到这说明没有上限可去（重发兜底已在 complete 做过/做不了）。
            classified = .malformedResponse(requestID: request.requestID)
            bodyExcerpt = exhausted.body
        case let urlError as URLError:
            classified = mapURLError(urlError)
            urlErrorCode = urlError.errorCode
            urlErrorName = urlErrorCodeName(urlError.code)
            urlErrorMessage = urlError.localizedDescription
        case let clientError as AIClientError:
            classified = clientError
        default:
            classified = .malformedResponse(requestID: request.requestID)
        }

        // 短串会把正文里碰巧相同的字符全部错杀（如 key="k" 时 "token"→"to<redacted>en"），
        // 真实 Key 不会短于 8；短于它的输入本就不是有效凭据，不值得为此毁掉报文。
        if let key = apiKey, key.count >= 8, let excerpt = bodyExcerpt, excerpt.contains(key) {
            bodyExcerpt = excerpt.replacingOccurrences(of: key, with: "<redacted>")
        }

        let diagnostics = AIFailureDiagnostics(
            timestamp: started,
            duration: Date().timeIntervalSince(started),
            purpose: request.purpose.rawValue,
            requestID: request.requestID,
            providerID: config.apiProvider.rawValue,
            providerName: ProviderCapability.capability(for: config.apiProvider).displayName,
            model: config.model,
            endpoint: resolveURL(config: config)?.absoluteString ?? "<invalid URL>",
            apiKeyAttached: !(apiKey ?? "").isEmpty,
            errorKind: String(describing: classified),
            httpStatus: httpStatus,
            responseBodyExcerpt: bodyExcerpt.map { String($0.prefix(2000)) },
            urlErrorCode: urlErrorCode,
            urlErrorName: urlErrorName,
            urlErrorMessage: urlErrorMessage
        )
        return AIRequestFailure(error: classified, diagnostics: diagnostics)
    }

    /// URLError.Code 没有可读名，而数字本身（-1005）对排查毫无帮助，名字才有。
    static func urlErrorCodeName(_ code: URLError.Code) -> String {
        switch code {
        case .timedOut: return "timedOut"
        case .cannotFindHost: return "cannotFindHost"
        case .cannotConnectToHost: return "cannotConnectToHost"
        case .networkConnectionLost: return "networkConnectionLost"
        case .dnsLookupFailed: return "dnsLookupFailed"
        case .notConnectedToInternet: return "notConnectedToInternet"
        case .secureConnectionFailed: return "secureConnectionFailed"
        case .serverCertificateHasBadDate: return "serverCertificateHasBadDate"
        case .serverCertificateUntrusted: return "serverCertificateUntrusted"
        case .serverCertificateHasUnknownRoot: return "serverCertificateHasUnknownRoot"
        case .serverCertificateNotYetValid: return "serverCertificateNotYetValid"
        case .clientCertificateRejected: return "clientCertificateRejected"
        case .cannotLoadFromNetwork: return "cannotLoadFromNetwork"
        case .internationalRoamingOff: return "internationalRoamingOff"
        case .callIsActive: return "callIsActive"
        case .dataNotAllowed: return "dataNotAllowed"
        case .appTransportSecurityRequiresSecureConnection:
            return "appTransportSecurityRequiresSecureConnection"
        case .badServerResponse: return "badServerResponse"
        case .cancelled: return "cancelled"
        default: return "code \(code.rawValue)"
        }
    }
}

// MARK: - 请求体（Encodable；nil 可选字段由合成编码器 encodeIfPresent 省略）

private struct OpenAIMessage: Encodable {
    let role: String
    let content: String
}

private struct OpenAIBody: Encodable {
    let model: String
    let messages: [OpenAIMessage]
    /// nil = 不发该字段（gpt-5/o 系推理模型只接受默认值，显式传直接 400）。
    let temperature: Double?
    /// 两者互斥且都可为 nil（合成编码器会 encodeIfPresent 省略）——
    /// 由 `LiveChatTransport.tokenParameter(for:)` 按 model id 二选一。
    let max_tokens: Int?
    let max_completion_tokens: Int?
}

private struct AnthropicBody: Encodable {
    let model: String
    let max_tokens: Int
    let messages: [OpenAIMessage]
    let temperature: Double?
    let system: String?
}

private struct GeminiBody: Encodable {
    struct Part: Encodable { let text: String }
    struct Content: Encodable { let role: String; let parts: [Part] }
    struct GenerationConfig: Encodable {
        let temperature: Double?
        let maxOutputTokens: Int?
    }
    let contents: [Content]
    let generationConfig: GenerationConfig
}

// MARK: - 响应体
//
// 可缺字段一律 Optional：content/parts 在安全拦截与上限吃光时整个缺失，
// 不能因此让整包 decode 失败（那会把"可判别的失败"降级成"响应异常"）。

private struct OpenAIResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
            let refusal: String?
        }
        let message: Message?
        let finishReason: String?
        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }
    let choices: [Choice]
}

private struct AnthropicResponse: Decodable {
    struct Block: Decodable { let text: String? }
    let content: [Block]
    let stopReason: String?
    enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
    }
}

private struct GeminiResponse: Decodable {
    struct PromptFeedback: Decodable { let blockReason: String? }
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable { let text: String? }
            let parts: [Part]?
        }
        let content: Content?
        let finishReason: String?
    }
    let candidates: [Candidate]?
    let promptFeedback: PromptFeedback?
}
