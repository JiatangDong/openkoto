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

    private func makeTransport() -> LiveChatTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return LiveChatTransport(session: URLSession(configuration: config))
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
        await #expect(throws: AIClientError.unauthorized) {
            try await makeTransport().complete(
                ChatRequest(purpose: .connectionTest, systemPrompt: "", userMessage: "ping"),
                config: ModelConfig(name: "o", apiProvider: .openai, model: "gpt-4o"),
                apiKey: "k")
        }
    }

    @Test func mapsRateLimited() async throws {
        StubURLProtocol.respond(status: 429, json: "{}")
        defer { StubURLProtocol.reset() }
        await #expect(throws: AIClientError.rateLimited) {
            try await makeTransport().complete(
                ChatRequest(purpose: .connectionTest, systemPrompt: "", userMessage: "ping"),
                config: ModelConfig(name: "o", apiProvider: .openai, model: "gpt-4o"),
                apiKey: "k")
        }
    }

    @Test func mapsServerError() async throws {
        StubURLProtocol.respond(status: 503, json: "{}")
        defer { StubURLProtocol.reset() }
        await #expect(throws: AIClientError.serverError(status: 503)) {
            try await makeTransport().complete(
                ChatRequest(purpose: .connectionTest, systemPrompt: "", userMessage: "ping"),
                config: ModelConfig(name: "o", apiProvider: .openai, model: "gpt-4o"),
                apiKey: "k")
        }
    }
}

/// 简易 URLProtocol stub：拦截请求返回预设状态码与响应体。
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var payload = Data()

    static func respond(status: Int, json: String) {
        self.status = status
        self.payload = Data(json.utf8)
    }
    static func reset() {
        status = 200
        payload = Data()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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
