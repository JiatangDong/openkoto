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

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func complete(
        _ request: ChatRequest, config: ModelConfig, apiKey: String?
    ) async throws -> String {
        let parameter = Self.tokenParameter(for: config.model)
        do {
            return try await send(
                request, config: config, apiKey: apiKey, tokenParameter: parameter)
        } catch let failure as HTTPFailure {
            // OpenAI 的 o 系与 gpt-5 只收 max_completion_tokens，其余模型只收 max_tokens，
            // 发错是 400 而不是被忽略。model id 判不准时（OpenRouter 代理、自建兼容端点）
            // 靠这次降级重发兜底，换另一个参数名再试一次。
            if failure.status == 400, request.maxOutputTokens != nil,
                Self.mentionsTokenParameter(failure.body)
            {
                return try await send(
                    request, config: config, apiKey: apiKey,
                    tokenParameter: parameter.alternative)
            }
            throw Self.classify(status: failure.status, body: failure.body)
        }
    }

    private func send(
        _ request: ChatRequest, config: ModelConfig, apiKey: String?,
        tokenParameter: TokenParameter
    ) async throws -> String {
        let urlRequest = try Self.buildURLRequest(
            request, config: config, apiKey: apiKey, tokenParameter: tokenParameter)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch is CancellationError {
            throw AIClientError.cancelled
        } catch let error as URLError {
            throw Self.mapURLError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AIClientError.malformedResponse(requestID: request.requestID)
        }
        guard (200...299).contains(http.statusCode) else {
            // 失败响应的 body 是"余额不足 vs 限流"的唯一信息来源，必须留到分类那一步
            throw HTTPFailure(
                status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }

        return try Self.parseContent(
            data: data,
            kind: ProviderCapability.capability(for: config.apiProvider).kind,
            requestID: request.requestID
        )
    }

    /// 非 2xx 的原始信息。带着 body 一路传到分类那一步。
    private struct HTTPFailure: Error {
        let status: Int
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

    /// o 系（o1/o3/o4）与 gpt-5 系只收 `max_completion_tokens`，其余收 `max_tokens`。
    /// OpenRouter 之类会带 `openai/` 前缀，取最后一段判。
    static func tokenParameter(for model: String) -> TokenParameter {
        let name = model.lowercased().split(separator: "/").last.map(String.init)
            ?? model.lowercased()
        if name.hasPrefix("gpt-5") { return .maxCompletionTokens }
        for family in ["o1", "o3", "o4"] where name == family || name.hasPrefix("\(family)-") {
            return .maxCompletionTokens
        }
        return .maxTokens
    }

    /// 400 的报错是否指向输出上限参数——是的话换个名字重发还有救。
    static func mentionsTokenParameter(_ body: String) -> Bool {
        let lowered = body.lowercased()
        return lowered.contains("max_tokens") || lowered.contains("max_completion_tokens")
    }

    static func buildURLRequest(
        _ request: ChatRequest, config: ModelConfig, apiKey: String?,
        tokenParameter: TokenParameter = .maxTokens
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
        let temperature = capability.forcesTemperatureOne ? 1.0 : request.temperature

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

    static func parseContent(data: Data, kind: ProviderKind, requestID: UUID) throws -> String {
        let decoder = JSONDecoder()
        do {
            switch kind {
            case .openAICompatible:
                let r = try decoder.decode(OpenAIResponse.self, from: data)
                guard let content = r.choices.first?.message.content else {
                    throw AIClientError.malformedResponse(requestID: requestID)
                }
                return content
            case .anthropic:
                let r = try decoder.decode(AnthropicResponse.self, from: data)
                guard let text = r.content.first?.text else {
                    throw AIClientError.malformedResponse(requestID: requestID)
                }
                return text
            case .gemini:
                let r = try decoder.decode(GeminiResponse.self, from: data)
                guard let text = r.candidates.first?.content.parts.first?.text else {
                    throw AIClientError.malformedResponse(requestID: requestID)
                }
                return text
            }
        } catch let error as AIClientError {
            throw error
        } catch {
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
}

// MARK: - 请求体（Encodable；nil 可选字段由合成编码器 encodeIfPresent 省略）

private struct OpenAIMessage: Encodable {
    let role: String
    let content: String
}

private struct OpenAIBody: Encodable {
    let model: String
    let messages: [OpenAIMessage]
    let temperature: Double
    /// 两者互斥且都可为 nil（合成编码器会 encodeIfPresent 省略）——
    /// 由 `LiveChatTransport.tokenParameter(for:)` 按 model id 二选一。
    let max_tokens: Int?
    let max_completion_tokens: Int?
}

private struct AnthropicBody: Encodable {
    let model: String
    let max_tokens: Int
    let messages: [OpenAIMessage]
    let temperature: Double
    let system: String?
}

private struct GeminiBody: Encodable {
    struct Part: Encodable { let text: String }
    struct Content: Encodable { let role: String; let parts: [Part] }
    struct GenerationConfig: Encodable {
        let temperature: Double
        let maxOutputTokens: Int?
    }
    let contents: [Content]
    let generationConfig: GenerationConfig
}

// MARK: - 响应体

private struct OpenAIResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }
    let choices: [Choice]
}

private struct AnthropicResponse: Decodable {
    struct Block: Decodable { let text: String }
    let content: [Block]
}

private struct GeminiResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable { let text: String }
            let parts: [Part]
        }
        let content: Content
    }
    let candidates: [Candidate]
}
