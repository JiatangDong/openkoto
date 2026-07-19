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
        let urlRequest = try Self.buildURLRequest(request, config: config, apiKey: apiKey)

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
        try Self.validate(status: http.statusCode)

        return try Self.parseContent(
            data: data,
            kind: ProviderCapability.capability(for: config.apiProvider).kind,
            requestID: request.requestID
        )
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

    static func buildURLRequest(
        _ request: ChatRequest, config: ModelConfig, apiKey: String?
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
                temperature: temperature
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
                generationConfig: .init(temperature: temperature)
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

    static func validate(status: Int) throws {
        switch status {
        case 200...299: return
        case 401, 403: throw AIClientError.unauthorized
        case 429: throw AIClientError.rateLimited
        case 500...599: throw AIClientError.serverError(status: status)
        default: throw AIClientError.serverError(status: status)
        }
    }

    static func mapURLError(_ error: URLError) -> AIClientError {
        switch error.code {
        case .cancelled:
            return .cancelled
        case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
             .networkConnectionLost, .timedOut, .dnsLookupFailed:
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
    struct GenerationConfig: Encodable { let temperature: Double }
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
