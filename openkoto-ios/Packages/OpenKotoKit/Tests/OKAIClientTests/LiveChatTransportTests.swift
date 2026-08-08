import Foundation
import Testing
@testable import OKAIClient
import OKModels

/// Transport 契约测试：URL 拼接、认证头、请求体、状态码映射逐条对齐桌面 ai_service.rs。
/// 串行执行以避免并行测试争用 StubURLProtocol 的静态 responder。
@Suite(.serialized) struct LiveChatTransportTests {

    // MARK: - URL 解析（对齐 get_api_url）

    @Test func resolvesCustomBaseURLAppendingChatCompletions() {
        let config = ModelConfig(name: "x", apiProvider: .openAICompatible, model: "m",
                                 baseURL: URL(string: "https://host.example/v1"))
        #expect(LiveChatTransport.resolveURL(config: config)?.absoluteString
                == "https://host.example/v1/chat/completions")
    }

    @Test func resolvesCustomBaseURLLeavesExistingSuffix() {
        let config = ModelConfig(name: "x", apiProvider: .openAICompatible, model: "m",
                                 baseURL: URL(string: "https://host.example/v1/chat/completions/"))
        #expect(LiveChatTransport.resolveURL(config: config)?.absoluteString
                == "https://host.example/v1/chat/completions")
    }

    @Test func resolvesGeminiURLStrippingModelsPrefix() {
        let config = ModelConfig(name: "g", apiProvider: .google, model: "models/gemini-2.0-flash")
        #expect(LiveChatTransport.resolveURL(config: config)?.absoluteString
                == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent")
    }

    @Test func resolvesProviderDefaults() {
        func url(_ p: ProviderID, _ model: String = "m") -> String? {
            LiveChatTransport.resolveURL(config: ModelConfig(name: "n", apiProvider: p, model: model))?
                .absoluteString
        }
        #expect(url(.anthropic) == "https://api.anthropic.com/v1/messages")
        #expect(url(.moonshot) == "https://api.moonshot.cn/v1/chat/completions")
        #expect(url(.kimi) == "https://api.moonshot.ai/v1/chat/completions")
        #expect(url(.deepseek) == "https://api.deepseek.com/v1/chat/completions")
        #expect(url(.ollama) == "http://localhost:11434/v1/chat/completions")
        // openai-compatible 未配 baseURL 时兜底 OpenAI（对齐 Rust）
        #expect(url(.openAICompatible) == "https://api.openai.com/v1/chat/completions")
    }

    // MARK: - 请求头与请求体

    private func body(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    @Test func openAIRequestHasBearerAuthAndMessages() throws {
        let config = ModelConfig(name: "o", apiProvider: .openai, model: "gpt-4o")
        let req = try LiveChatTransport.buildURLRequest(
            ChatRequest(purpose: .explain, systemPrompt: "SYS", userMessage: "Analyze this: hi"),
            config: config, apiKey: "sk-123")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-123")
        let b = body(req)
        #expect(b["model"] as? String == "gpt-4o")
        let messages = b["messages"] as? [[String: Any]]
        #expect(messages?.first?["role"] as? String == "system")
        #expect(messages?.first?["content"] as? String == "SYS")
        #expect(messages?.last?["content"] as? String == "Analyze this: hi")
    }

    @Test func localProviderOmitsAuthWhenKeyEmpty() throws {
        let config = ModelConfig(name: "l", apiProvider: .ollama, model: "qwen",
                                 baseURL: URL(string: "http://localhost:11434/v1"))
        let req = try LiveChatTransport.buildURLRequest(
            ChatRequest(purpose: .explain, systemPrompt: "s", userMessage: "u"),
            config: config, apiKey: "")
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func anthropicRequestHasKeyAndVersionHeaders() throws {
        let config = ModelConfig(name: "a", apiProvider: .anthropic, model: "claude-3-5-sonnet")
        let req = try LiveChatTransport.buildURLRequest(
            ChatRequest(purpose: .explain, systemPrompt: "SYS", userMessage: "Analyze this: hi"),
            config: config, apiKey: "key-abc")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "key-abc")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let b = body(req)
        #expect(b["system"] as? String == "SYS")
        #expect(b["max_tokens"] as? Int == 8192)
        let messages = b["messages"] as? [[String: Any]]
        #expect(messages?.count == 1)
        #expect(messages?.first?["role"] as? String == "user")
    }

    @Test func geminiMergesSystemAndUserIntoSinglePart() throws {
        let config = ModelConfig(name: "g", apiProvider: .google, model: "gemini-2.0-flash")
        let req = try LiveChatTransport.buildURLRequest(
            ChatRequest(purpose: .explain, systemPrompt: "SYS", userMessage: "Analyze this: hi"),
            config: config, apiKey: "gkey")
        #expect(req.value(forHTTPHeaderField: "X-goog-api-key") == "gkey")
        let contents = body(req)["contents"] as? [[String: Any]]
        let parts = contents?.first?["parts"] as? [[String: Any]]
        #expect(parts?.first?["text"] as? String == "SYS\n\nAnalyze this: hi")
    }

    @Test func moonshotForcesTemperatureOne() throws {
        let config = ModelConfig(name: "m", apiProvider: .moonshot, model: "kimi-k2")
        let req = try LiveChatTransport.buildURLRequest(
            ChatRequest(purpose: .explain, systemPrompt: "s", userMessage: "u", temperature: 0.3),
            config: config, apiKey: "k")
        #expect((body(req)["temperature"] as? NSNumber)?.doubleValue == 1.0)
    }

    // MARK: - 端到端（URLProtocol stub）

    fileprivate func makeTransport() -> LiveChatTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        // 重试延迟归零：429 重试用例不该拖慢回路。
        return LiveChatTransport(
            session: URLSession(configuration: config), rateLimitRetryDelay: 0)
    }

    @Test func completeReturnsOpenAIContent() async throws {
        StubURLProtocol.respond(status: 200, json: """
        {"choices": [{"message": {"content": "hello world"}}]}
        """)
        defer { StubURLProtocol.reset() }
        let content = try await makeTransport().complete(
            ChatRequest(purpose: .connectionTest, systemPrompt: "", userMessage: "ping"),
            config: ModelConfig(name: "o", apiProvider: .openai, model: "gpt-4o"),
            apiKey: "k")
        #expect(content == "hello world")
    }

    @Test func mapsUnauthorized() async throws {
        StubURLProtocol.respond(status: 401, json: "{\"error\": \"bad key\"}")
        defer { StubURLProtocol.reset() }
        await #expect {
            try await makeTransport().complete(
                ChatRequest(purpose: .connectionTest, systemPrompt: "", userMessage: "ping"),
                config: ModelConfig(name: "o", apiProvider: .openai, model: "gpt-4o"),
                apiKey: "k")
        } throws: { error in
            (error as? AIRequestFailure)?.error == .unauthorized
        }
    }

    @Test func mapsRateLimited() async throws {
        StubURLProtocol.respond(status: 429, json: "{}")
        defer { StubURLProtocol.reset() }
        await #expect {
            try await makeTransport().complete(
                ChatRequest(purpose: .connectionTest, systemPrompt: "", userMessage: "ping"),
                config: ModelConfig(name: "o", apiProvider: .openai, model: "gpt-4o"),
                apiKey: "k")
        } throws: { error in
            (error as? AIRequestFailure)?.error == .rateLimited
        }
    }

    @Test func mapsServerError() async throws {
        StubURLProtocol.respond(status: 503, json: "{}")
        defer { StubURLProtocol.reset() }
        await #expect {
            try await makeTransport().complete(
                ChatRequest(purpose: .connectionTest, systemPrompt: "", userMessage: "ping"),
                config: ModelConfig(name: "o", apiProvider: .openai, model: "gpt-4o"),
                apiKey: "k")
        } throws: { error in
            (error as? AIRequestFailure)?.error == .serverError(status: 503)
        }
    }

    // MARK: - 诊断快照（「复制诊断信息」的数据源）

    /// HTTP 失败的现场必须带够定位信息：状态码、响应体、端点、带没带 Key。
    /// 用户报告"全都失败了"时，这份快照是区分额度到期/模型失效/Key 丢失的唯一依据。
    @Test func httpFailureCarriesDiagnostics() async throws {
        StubURLProtocol.respond(status: 401, json: "{\"error\": \"bad key\"}")
        defer { StubURLProtocol.reset() }
        do {
            _ = try await makeTransport().complete(
                ChatRequest(purpose: .explain, systemPrompt: "", userMessage: "hi"),
                config: ModelConfig(name: "o", apiProvider: .openai, model: "gpt-4o"),
                apiKey: "sk-secret")
            Issue.record("应当抛错")
        } catch let failure as AIRequestFailure {
            let d = failure.diagnostics
            #expect(failure.error == .unauthorized)
            #expect(d.httpStatus == 401)
            #expect(d.responseBodyExcerpt?.contains("bad key") == true)
            #expect(d.providerID == "openai")
            #expect(d.providerName == "OpenAI")
            #expect(d.model == "gpt-4o")
            #expect(d.endpoint == "https://api.openai.com/v1/chat/completions")
            #expect(d.apiKeyAttached)
            #expect(d.purpose == "explain")
            #expect(d.errorKind == "unauthorized")
        }
    }

    /// "网络不可用"盖住了一整族错误：-1005 连接被重置与 -1009 真断网是两回事，
    /// 快照必须保留 URLError 原始码与名字。
    @Test func urlErrorCarriesRawCodeAndName() async throws {
        StubURLProtocol.respondError(.networkConnectionLost)
        defer { StubURLProtocol.reset() }
        do {
            _ = try await makeTransport().complete(
                ChatRequest(purpose: .explain, systemPrompt: "", userMessage: "hi"),
                config: ModelConfig(name: "o", apiProvider: .deepseek, model: "deepseek-chat"),
                apiKey: "k")
            Issue.record("应当抛错")
        } catch let failure as AIRequestFailure {
            let d = failure.diagnostics
            #expect(failure.error == .networkUnreachable)
            #expect(d.urlErrorCode == URLError.Code.networkConnectionLost.rawValue)
            #expect(d.urlErrorName == "networkConnectionLost")
            #expect(d.httpStatus == nil)
        }
    }

    /// 没带 Key 的裸请求必然 401——`apiKeyAttached == false` 是 Keychain 读出失败的证据。
    @Test func missingKeyIsRecordedInDiagnostics() async throws {
        StubURLProtocol.respond(status: 401, json: "{\"error\": \"missing auth\"}")
        defer { StubURLProtocol.reset() }
        do {
            _ = try await makeTransport().complete(
                ChatRequest(purpose: .explain, systemPrompt: "", userMessage: "hi"),
                config: ModelConfig(name: "o", apiProvider: .openai, model: "gpt-4o"),
                apiKey: nil)
            Issue.record("应当抛错")
        } catch let failure as AIRequestFailure {
            #expect(failure.error == .unauthorized)
            #expect(!failure.diagnostics.apiKeyAttached)
        }
    }

    /// 响应体偶尔会回显请求内容——诊断报告要发给开发者，Key 必须剔除。
    @Test func diagnosticsRedactAPIKeyEchoedInBody() async throws {
        StubURLProtocol.respond(status: 400, json: "{\"error\": \"bad request for key sk-secret\"}")
        defer { StubURLProtocol.reset() }
        do {
            _ = try await makeTransport().complete(
                ChatRequest(purpose: .explain, systemPrompt: "", userMessage: "hi"),
                config: ModelConfig(name: "o", apiProvider: .openai, model: "gpt-4o"),
                apiKey: "sk-secret")
            Issue.record("应当抛错")
        } catch let failure as AIRequestFailure {
            #expect(failure.diagnostics.responseBodyExcerpt?.contains("sk-secret") == false)
            #expect(failure.diagnostics.responseBodyExcerpt?.contains("<redacted>") == true)
        }
    }
}

/// 简易 URLProtocol stub：拦截请求返回预设状态码与响应体，或直接以 URLError 失败。
/// `respondSequence` 支持按请求顺序脚本化多个响应（测降级重发）；
/// 每个请求的 body 记录在 `capturedBodies`，可断言重发时参数确实变了。
final class StubURLProtocol: URLProtocol {
    enum Step {
        case http(status: Int, json: String)
        case error(URLError.Code)
    }

    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var payload = Data()
    nonisolated(unsafe) private static var failure: URLError?
    /// 逐个消费的响应脚本；耗尽后回落到上面的静态响应。
    nonisolated(unsafe) private static var script: [Step] = []
    nonisolated(unsafe) private(set) static var capturedBodies: [String] = []

    static func respond(status: Int, json: String) {
        self.status = status
        self.payload = Data(json.utf8)
    }
    static func respondError(_ code: URLError.Code) {
        failure = URLError(code)
    }
    static func respondSequence(_ steps: [Step]) {
        script = steps
    }
    static func reset() {
        status = 200
        payload = Data()
        failure = nil
        script = []
        capturedBodies = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedBodies.append(Self.bodyString(of: request))

        let step: Step
        if Self.script.isEmpty {
            if let failure = Self.failure {
                step = .error(failure.code)
            } else {
                step = .http(status: Self.status, json: String(decoding: Self.payload, as: UTF8.self))
            }
        } else {
            step = Self.script.removeFirst()
        }

        switch step {
        case .error(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .http(let status, let json):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    /// URLSession 会把 httpBody 转成 stream，URLProtocol 里只能从 stream 读回。
    private static func bodyString(of request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// 输出上限（`maxOutputTokens`）在各 provider 上真的落进请求体。
///
/// 这组测试存在的理由：它曾经**只有 anthropic 分支生效**，OpenAI 兼容与 Gemini 的请求体
/// 里根本没有对应字段，传进来的上限被静默丢弃——"测试连接"因此是一次不设限的完整生成。
/// 这类 bug 不会有任何报错，没有断言就一定会再次回归。
@Suite(.serialized) struct TokenLimitTests {
    private func body(
        provider: ProviderID, model: String = "m", maxOutputTokens: Int? = 300
    ) throws -> [String: Any] {
        let request = ChatRequest(
            purpose: .explain, systemPrompt: "sys", userMessage: "user",
            temperature: 0.3, maxOutputTokens: maxOutputTokens, timeout: 30)
        let config = ModelConfig(
            name: "n", apiProvider: provider, model: model,
            baseURL: URL(string: "https://host.example/v1"))
        let urlRequest = try LiveChatTransport.buildURLRequest(
            request, config: config, apiKey: "k",
            tokenParameter: LiveChatTransport.tokenParameter(for: model))
        let data = try #require(urlRequest.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func openAICompatibleSendsMaxTokens() throws {
        let json = try body(provider: .deepseek, model: "deepseek-chat")
        #expect(json["max_tokens"] as? Int == 300)
        #expect(json["max_completion_tokens"] == nil)
    }

    /// o 系与 gpt-5 拒绝 `max_tokens`（400 而不是忽略），必须换参数名。
    @Test func newerOpenAIModelsSendMaxCompletionTokens() throws {
        for model in ["o1", "o1-mini", "o3-pro", "gpt-5", "gpt-5.2-turbo"] {
            let json = try body(provider: .openai, model: model)
            #expect(json["max_completion_tokens"] as? Int == 300, "\(model)")
            #expect(json["max_tokens"] == nil, "\(model)")
        }
    }

    /// OpenRouter 之类会带 `openai/` 前缀，判定要取最后一段。
    @Test func routesByLastPathComponentOfModelID() {
        #expect(LiveChatTransport.tokenParameter(for: "openai/o1-preview") == .maxCompletionTokens)
        #expect(LiveChatTransport.tokenParameter(for: "openai/gpt-4o") == .maxTokens)
        #expect(LiveChatTransport.tokenParameter(for: "GPT-5-mini") == .maxCompletionTokens)
        // 不能把 o1/o3 之外碰巧以 o 开头的模型误判
        #expect(LiveChatTransport.tokenParameter(for: "openchat-3.5") == .maxTokens)
        #expect(LiveChatTransport.tokenParameter(for: "o1x-experimental") == .maxTokens)
    }

    @Test func geminiSendsMaxOutputTokens() throws {
        let json = try body(provider: .google, model: "gemini-2.0-flash")
        let config = try #require(json["generationConfig"] as? [String: Any])
        #expect(config["maxOutputTokens"] as? Int == 300)
    }

    @Test func anthropicStillSendsMaxTokens() throws {
        #expect(try body(provider: .anthropic, model: "claude-x")["max_tokens"] as? Int == 300)
    }

    /// 不设上限时字段要整个省略，不能塞 null。
    @Test func omitsFieldWhenNoLimitRequested() throws {
        let json = try body(provider: .deepseek, maxOutputTokens: nil)
        #expect(json["max_tokens"] == nil)
        #expect(json["max_completion_tokens"] == nil)
    }
}

/// 用户报告"接了 OpenAI / Gemini 就全部失败"的根因回归测试。
///
/// 三组真实报文（都来自各家线上 API 的实际响应形态）：
/// 1. gpt-5 / o 系推理模型拒绝自定义 temperature（400，每次必失败）；
/// 2. Gemini 2.5 默认"思考"，思考 token 计入 maxOutputTokens——
///    查词(300)/测试连接(16) 的小上限必然 MAX_TOKENS 且响应没有 parts；
/// 3. 安全拦截（Gemini blockReason / OpenAI refusal）返回 200 但没有正文。
/// 另有间歇性失败的两大来源：429 限流、-1005 连接复用断裂，均应重试一次。
///
/// 挂在 `LiveChatTransportTests` 的 extension 里而不是独立 @Suite：
/// StubURLProtocol 的 responder 是全局静态，两个各自 .serialized 的 suite
/// 仍会彼此并行，脚本会串台。
extension LiveChatTransportTests {
    private static let okOpenAI = #"{"choices": [{"message": {"content": "译文"}, "finish_reason": "stop"}]}"#
    private static let okGemini = """
    {"candidates":[{"content":{"parts":[{"text":"译文"}],"role":"model"},"finishReason":"STOP"}]}
    """

    // MARK: - temperature（OpenAI 推理模型 400 必失败）

    /// gpt-5 / o 系只接受默认 temperature，显式传 0.3 直接 400。
    /// 已知模型**第一发就不该带** temperature，而不是靠失败后重发。
    @Test func reasoningModelsOmitTemperatureProactively() throws {
        for model in ["gpt-5", "gpt-5-mini", "o1", "o3-pro", "o4-mini", "openai/o3"] {
            let req = try LiveChatTransport.buildURLRequest(
                ChatRequest(purpose: .translate, systemPrompt: "s", userMessage: "u", temperature: 0.3),
                config: ModelConfig(name: "o", apiProvider: .openai, model: model),
                apiKey: "k")
            let body = (try? JSONSerialization.jsonObject(
                with: req.httpBody ?? Data())) as? [String: Any] ?? [:]
            #expect(body["temperature"] == nil, "\(model)")
        }
        // 非推理模型照旧带 temperature（gpt-5-chat 系是普通 chat 模型）。
        for model in ["gpt-4o", "gpt-5-chat-latest", "deepseek-chat"] {
            let req = try LiveChatTransport.buildURLRequest(
                ChatRequest(purpose: .translate, systemPrompt: "s", userMessage: "u", temperature: 0.3),
                config: ModelConfig(name: "o", apiProvider: .openai, model: model),
                apiKey: "k")
            let body = (try? JSONSerialization.jsonObject(
                with: req.httpBody ?? Data())) as? [String: Any] ?? [:]
            #expect((body["temperature"] as? NSNumber)?.doubleValue == 0.3, "\(model)")
        }
    }

    /// 中转站/自建端点背后的推理模型判不出来，只能靠 400 报错兜底：
    /// 去掉 temperature 重发一次。
    @Test func dropsTemperatureAfter400AndSucceeds() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.respondSequence([
            .http(status: 400, json: #"{"error":{"message":"Unsupported value: 'temperature' does not support 0.3 with this model. Only the default (1) value is supported.","type":"invalid_request_error","param":"temperature","code":"unsupported_value"}}"#),
            .http(status: 200, json: Self.okOpenAI),
        ])
        defer { StubURLProtocol.reset() }
        let content = try await makeTransport().complete(
            ChatRequest(purpose: .translate, systemPrompt: "s", userMessage: "u", temperature: 0.3),
            config: ModelConfig(name: "relay", apiProvider: .openAICompatible, model: "my-relay-model",
                                baseURL: URL(string: "https://relay.example/v1")),
            apiKey: "k")
        #expect(content == "译文")
        #expect(StubURLProtocol.capturedBodies.count == 2)
        #expect(StubURLProtocol.capturedBodies[0].contains("temperature"))
        #expect(!StubURLProtocol.capturedBodies[1].contains("temperature"))
    }

    // MARK: - 输出上限被思考/推理吃光（200 但没有正文）

    /// Gemini 2.5 思考 token 计入 maxOutputTokens：小上限必然 MAX_TOKENS 且无 parts。
    /// 应去掉上限重发一次，而不是报"响应异常"。
    @Test func geminiThinkingExhaustedBudgetRetriesWithoutCap() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.respondSequence([
            .http(status: 200, json: """
            {"candidates":[{"content":{"role":"model"},"finishReason":"MAX_TOKENS","index":0}],\
            "usageMetadata":{"promptTokenCount":42,"totalTokenCount":341,"thoughtsTokenCount":299},\
            "modelVersion":"gemini-2.5-flash"}
            """),
            .http(status: 200, json: Self.okGemini),
        ])
        defer { StubURLProtocol.reset() }
        let content = try await makeTransport().complete(
            ChatRequest(purpose: .wordGloss, systemPrompt: "s", userMessage: "u",
                        temperature: 0.2, maxOutputTokens: 300),
            config: ModelConfig(name: "g", apiProvider: .google, model: "gemini-2.5-flash"),
            apiKey: "k")
        #expect(content == "译文")
        #expect(StubURLProtocol.capturedBodies.count == 2)
        #expect(StubURLProtocol.capturedBodies[0].contains("maxOutputTokens"))
        #expect(!StubURLProtocol.capturedBodies[1].contains("maxOutputTokens"))
    }

    /// gpt-5 推理 token 也计入 max_completion_tokens：小上限返回 200 + 空 content +
    /// finish_reason=length。同样去掉上限重发。
    @Test func openAIEmptyContentWithLengthRetriesWithoutCap() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.respondSequence([
            .http(status: 200, json: """
            {"choices":[{"index":0,"message":{"role":"assistant","content":""},\
            "finish_reason":"length"}],\
            "usage":{"completion_tokens":300,"completion_tokens_details":{"reasoning_tokens":300}}}
            """),
            .http(status: 200, json: Self.okOpenAI),
        ])
        defer { StubURLProtocol.reset() }
        let content = try await makeTransport().complete(
            ChatRequest(purpose: .wordGloss, systemPrompt: "s", userMessage: "u",
                        temperature: 0.2, maxOutputTokens: 300),
            config: ModelConfig(name: "o", apiProvider: .openai, model: "gpt-5-mini"),
            apiKey: "k")
        #expect(content == "译文")
        #expect(StubURLProtocol.capturedBodies.count == 2)
        #expect(!StubURLProtocol.capturedBodies[1].contains("max_completion_tokens"))
    }

    /// 没设上限却仍 MAX_TOKENS（模型自身上限）——没法重发，如实报错并保留响应体。
    @Test func geminiMaxTokensWithoutCapIsTerminal() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.respond(status: 200, json: """
        {"candidates":[{"content":{"role":"model"},"finishReason":"MAX_TOKENS"}]}
        """)
        defer { StubURLProtocol.reset() }
        do {
            _ = try await makeTransport().complete(
                ChatRequest(purpose: .translate, systemPrompt: "s", userMessage: "u"),
                config: ModelConfig(name: "g", apiProvider: .google, model: "gemini-2.5-flash"),
                apiKey: "k")
            Issue.record("应当抛错")
        } catch let failure as AIRequestFailure {
            guard case .malformedResponse = failure.error else {
                Issue.record("应分类为 malformedResponse，实际 \(failure.error)")
                return
            }
            #expect(failure.diagnostics.responseBodyExcerpt?.contains("MAX_TOKENS") == true)
            #expect(StubURLProtocol.capturedBodies.count == 1)
        }
    }

    // MARK: - 安全拦截（200 但没有内容）

    @Test func geminiPromptBlockIsContentBlocked() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.respond(status: 200, json: """
        {"promptFeedback":{"blockReason":"SAFETY","safetyRatings":\
        [{"category":"HARM_CATEGORY_DANGEROUS_CONTENT","probability":"HIGH"}]}}
        """)
        defer { StubURLProtocol.reset() }
        await #expect {
            try await makeTransport().complete(
                ChatRequest(purpose: .translate, systemPrompt: "s", userMessage: "u"),
                config: ModelConfig(name: "g", apiProvider: .google, model: "gemini-2.5-flash"),
                apiKey: "k")
        } throws: { error in
            (error as? AIRequestFailure)?.error == .contentBlocked
        }
    }

    @Test func geminiCandidateSafetyFinishIsContentBlocked() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.respond(status: 200, json: """
        {"candidates":[{"finishReason":"SAFETY","index":0,"safetyRatings":\
        [{"category":"HARM_CATEGORY_SEXUALLY_EXPLICIT","probability":"MEDIUM"}]}]}
        """)
        defer { StubURLProtocol.reset() }
        await #expect {
            try await makeTransport().complete(
                ChatRequest(purpose: .translate, systemPrompt: "s", userMessage: "u"),
                config: ModelConfig(name: "g", apiProvider: .google, model: "gemini-2.5-flash"),
                apiKey: "k")
        } throws: { error in
            (error as? AIRequestFailure)?.error == .contentBlocked
        }
    }

    /// OpenAI 的拒答走 content: null + refusal 字段——不能因 content 非 String 就整包解码失败。
    @Test func openAIRefusalIsContentBlocked() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.respond(status: 200, json: """
        {"choices":[{"index":0,"message":{"role":"assistant","content":null,\
        "refusal":"I can't help with that."},"finish_reason":"stop"}]}
        """)
        defer { StubURLProtocol.reset() }
        await #expect {
            try await makeTransport().complete(
                ChatRequest(purpose: .translate, systemPrompt: "s", userMessage: "u"),
                config: ModelConfig(name: "o", apiProvider: .openai, model: "gpt-4o"),
                apiKey: "k")
        } throws: { error in
            (error as? AIRequestFailure)?.error == .contentBlocked
        }
    }

    // MARK: - 间歇性失败（限流 / 连接复用断裂）

    /// 真限流（非余额耗尽）等一下重试一次就能过——批量任务的"半数失败"多来自这里。
    @Test func rateLimit429RetriesOnceThenSucceeds() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.respondSequence([
            .http(status: 429, json: #"{"error":{"message":"Rate limit reached"}}"#),
            .http(status: 200, json: Self.okOpenAI),
        ])
        defer { StubURLProtocol.reset() }
        let content = try await makeTransport().complete(
            ChatRequest(purpose: .translate, systemPrompt: "s", userMessage: "u"),
            config: ModelConfig(name: "o", apiProvider: .openai, model: "gpt-4o"),
            apiKey: "k")
        #expect(content == "译文")
        #expect(StubURLProtocol.capturedBodies.count == 2)
    }

    /// 余额耗尽伪装成 429——重试多少次都不会好，一次都不该试。
    @Test func insufficientQuota429DoesNotRetry() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.respond(status: 429, json:
            #"{"error":{"message":"You exceeded your current quota","type":"insufficient_quota","code":"insufficient_quota"}}"#)
        defer { StubURLProtocol.reset() }
        do {
            _ = try await makeTransport().complete(
                ChatRequest(purpose: .translate, systemPrompt: "s", userMessage: "u"),
                config: ModelConfig(name: "o", apiProvider: .openai, model: "gpt-4o"),
                apiKey: "k")
            Issue.record("应当抛错")
        } catch let failure as AIRequestFailure {
            #expect(failure.error == .insufficientBalance)
            #expect(StubURLProtocol.capturedBodies.count == 1)
        }
    }

    /// -1005：iOS 复用了服务端已单方面关闭的连接，重发一次即可（iOS 网络栈经典问题）。
    @Test func connectionLostRetriesOnce() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.respondSequence([
            .error(.networkConnectionLost),
            .http(status: 200, json: Self.okOpenAI),
        ])
        defer { StubURLProtocol.reset() }
        let content = try await makeTransport().complete(
            ChatRequest(purpose: .translate, systemPrompt: "s", userMessage: "u"),
            config: ModelConfig(name: "o", apiProvider: .openai, model: "gpt-4o"),
            apiKey: "k")
        #expect(content == "译文")
        #expect(StubURLProtocol.capturedBodies.count == 2)
    }
}

/// 余额不足必须与限流分开——前者重试多少次都不会好。
@Suite struct ErrorClassificationTests {
    @Test func deepSeekPaymentRequiredIsBalance() {
        #expect(LiveChatTransport.classify(status: 402, body: "") == .insufficientBalance)
    }

    /// OpenAI 的额度耗尽走 429，与真限流同码，只能靠 body 区分。
    @Test func openAIInsufficientQuotaIsBalanceNotRateLimit() {
        let body = #"{"error":{"code":"insufficient_quota","message":"You exceeded your current quota"}}"#
        #expect(LiveChatTransport.classify(status: 429, body: body) == .insufficientBalance)
        #expect(LiveChatTransport.classify(status: 429, body: #"{"error":{"code":"rate_limit_exceeded"}}"#)
            == .rateLimited)
    }

    @Test func anthropicLowCreditIsBalance() {
        let body = #"{"error":{"message":"Your credit balance is too low to access the API"}}"#
        #expect(LiveChatTransport.classify(status: 400, body: body) == .insufficientBalance)
    }

    @Test func keepsExistingMappings() {
        #expect(LiveChatTransport.classify(status: 401, body: "") == .unauthorized)
        #expect(LiveChatTransport.classify(status: 403, body: "") == .unauthorized)
        #expect(LiveChatTransport.classify(status: 500, body: "") == .serverError(status: 500))
    }

    /// 超时与断网要分开：行动不同（重试/换模型 vs 检查网络）。
    @Test func timeoutIsNotNetworkUnreachable() {
        #expect(LiveChatTransport.mapURLError(URLError(.timedOut)) == .timeout)
        #expect(LiveChatTransport.mapURLError(URLError(.notConnectedToInternet))
            == .networkUnreachable)
    }

    /// 余额不足不该被自动重试，限流与超时应该。
    @Test func retryabilityMatchesUserAction() {
        #expect(!AIClientError.insufficientBalance.isRetryable)
        #expect(AIClientError.rateLimited.isRetryable)
        #expect(AIClientError.timeout.isRetryable)
    }

    @Test func detectsTokenParameterComplaintForDowngradeRetry() {
        let body = #"{"error":{"message":"Unsupported parameter: 'max_tokens' is not supported"}}"#
        #expect(LiveChatTransport.mentionsTokenParameter(body))
        #expect(!LiveChatTransport.mentionsTokenParameter(#"{"error":{"message":"bad request"}}"#))
    }
}
