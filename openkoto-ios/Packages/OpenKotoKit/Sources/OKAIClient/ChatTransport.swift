import Foundation
import OKModels

// 多 Provider LLM 客户端，1:1 对齐桌面 `textlingo-desktop/src-tauri/src/ai_service.rs`
// 的 URL 拼接、认证头与模型特例（设计文档 §4.1-4.2）。
// 一期结构化任务（精讲/批翻）全部走 complete，非流式。

public struct ChatRequest: Sendable {
    public enum Purpose: String, Sendable {
        case connectionTest
        case translate
        case explain
    }

    public var purpose: Purpose
    public var systemPrompt: String
    public var userMessage: String
    public var temperature: Double
    public var maxOutputTokens: Int?
    public var timeout: TimeInterval
    public var requestID: UUID

    public init(
        purpose: Purpose,
        systemPrompt: String,
        userMessage: String,
        temperature: Double = 0.3,
        maxOutputTokens: Int? = nil,
        timeout: TimeInterval = 120,
        requestID: UUID = UUID()
    ) {
        self.purpose = purpose
        self.systemPrompt = systemPrompt
        self.userMessage = userMessage
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.timeout = timeout
        self.requestID = requestID
    }
}

/// 统一错误分类（设计文档 §4.1）。
/// 只有安全、幂等的请求允许指数退避重试；401/403、解析错误和取消不自动重试。
public enum AIClientError: Error, Sendable, Equatable {
    case notConfigured           // 尚未配置可用模型（应用层）
    case networkUnreachable
    case unauthorized            // 401 / 403
    case rateLimited             // 429
    case serverError(status: Int)
    case malformedResponse(requestID: UUID)
    case contentBlocked
    case cancelled

    /// 是否适合自动重试（安全幂等）。
    public var isRetryable: Bool {
        switch self {
        case .networkUnreachable, .rateLimited, .serverError:
            return true
        case .notConfigured, .unauthorized, .malformedResponse, .contentBlocked, .cancelled:
            return false
        }
    }
}

public protocol ChatTransport: Sendable {
    func complete(_ request: ChatRequest, config: ModelConfig, apiKey: String?) async throws -> String
    // M3+：流式接口仅服务未来普通文本 UI，不进入一期关键路径
    // func stream(...) async throws -> AsyncThrowingStream<ChatDelta, Error>
}

/// Provider 的协议形态——桌面 `ai_service.rs` 实际只有三种（设计文档 §4.1）。
public enum ProviderKind: Sendable {
    case openAICompatible   // /chat/completions，Bearer 认证
    case anthropic          // /v1/messages，x-api-key + anthropic-version
    case gemini             // :generateContent，X-goog-api-key
}

/// Provider 能力表：UI（设置页）与 transport 共用，避免两套 switch 漂移（设计文档 §6.6）。
/// URL 默认值、认证方式、模型特例逐条对齐 `ai_service.rs`。
public struct ProviderCapability: Sendable {
    public let id: ProviderID
    public let displayName: String
    public let kind: ProviderKind
    /// 默认完整端点（openai 系为 /chat/completions，anthropic 为 /v1/messages）；
    /// gemini 依 model 动态拼接、openai-compatible 必须由用户提供 baseURL，故为 nil。
    public let defaultEndpoint: URL?
    /// openai-compatible / ollama / lmstudio 必填自定义 Base URL
    public let requiresCustomBaseURL: Bool
    /// 本地 Provider（Ollama/LM Studio）允许空 Key，且需要局域网 HTTP 安全警告
    public let isLocalProvider: Bool
    /// 本地 Provider 允许空 Key（对齐 Rust：api_key 为空时不加 Authorization 头）
    public let allowsEmptyKey: Bool
    /// Moonshot 系特例：temperature 强制 1.0（对齐 `make_request`）
    public let forcesTemperatureOne: Bool
    /// 隐私政策入口（设置页“内容会离开设备”披露用）
    public let privacyPolicyURL: URL?

    init(
        id: ProviderID,
        displayName: String,
        kind: ProviderKind,
        defaultEndpoint: String?,
        requiresCustomBaseURL: Bool = false,
        isLocalProvider: Bool = false,
        forcesTemperatureOne: Bool = false,
        privacyPolicyURL: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.defaultEndpoint = defaultEndpoint.flatMap(URL.init(string:))
        self.requiresCustomBaseURL = requiresCustomBaseURL
        self.isLocalProvider = isLocalProvider
        self.allowsEmptyKey = isLocalProvider
        self.forcesTemperatureOne = forcesTemperatureOne
        self.privacyPolicyURL = privacyPolicyURL.flatMap(URL.init(string:))
    }

    public static let all: [ProviderCapability] = [
        .init(id: .openai, displayName: "OpenAI", kind: .openAICompatible,
              defaultEndpoint: "https://api.openai.com/v1/chat/completions",
              privacyPolicyURL: "https://openai.com/policies/privacy-policy"),
        .init(id: .deepseek, displayName: "DeepSeek", kind: .openAICompatible,
              defaultEndpoint: "https://api.deepseek.com/v1/chat/completions",
              privacyPolicyURL: "https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html"),
        .init(id: .openrouter, displayName: "OpenRouter", kind: .openAICompatible,
              defaultEndpoint: "https://openrouter.ai/api/v1/chat/completions",
              privacyPolicyURL: "https://openrouter.ai/privacy"),
        .init(id: .siliconflow, displayName: "SiliconFlow", kind: .openAICompatible,
              defaultEndpoint: "https://api.siliconflow.cn/v1/chat/completions",
              privacyPolicyURL: "https://siliconflow.cn/zh-cn/privacy-policy"),
        .init(id: .ai302, displayName: "302.AI", kind: .openAICompatible,
              defaultEndpoint: "https://api.302.ai/v1/chat/completions",
              privacyPolicyURL: "https://302.ai/privacy/"),
        .init(id: .google, displayName: "Google Gemini", kind: .gemini,
              defaultEndpoint: nil,
              privacyPolicyURL: "https://ai.google.dev/gemini-api/terms"),
        .init(id: .anthropic, displayName: "Anthropic", kind: .anthropic,
              defaultEndpoint: "https://api.anthropic.com/v1/messages",
              privacyPolicyURL: "https://www.anthropic.com/legal/privacy"),
        .init(id: .moonshot, displayName: "Moonshot (Kimi 国内)", kind: .openAICompatible,
              defaultEndpoint: "https://api.moonshot.cn/v1/chat/completions",
              forcesTemperatureOne: true,
              privacyPolicyURL: "https://platform.moonshot.cn/docs/agreement/privacy"),
        .init(id: .kimi, displayName: "Kimi (Global)", kind: .openAICompatible,
              defaultEndpoint: "https://api.moonshot.ai/v1/chat/completions",
              forcesTemperatureOne: true,
              privacyPolicyURL: "https://platform.moonshot.ai/docs/agreement/privacy"),
        .init(id: .ollama, displayName: "Ollama", kind: .openAICompatible,
              defaultEndpoint: "http://localhost:11434/v1/chat/completions",
              requiresCustomBaseURL: true, isLocalProvider: true),
        .init(id: .lmstudio, displayName: "LM Studio", kind: .openAICompatible,
              defaultEndpoint: "http://localhost:1234/v1/chat/completions",
              requiresCustomBaseURL: true, isLocalProvider: true),
        .init(id: .openAICompatible, displayName: "OpenAI Compatible", kind: .openAICompatible,
              defaultEndpoint: nil, requiresCustomBaseURL: true),
    ]

    public static func capability(for id: ProviderID) -> ProviderCapability {
        all.first { $0.id == id } ?? all[0]
    }
}
