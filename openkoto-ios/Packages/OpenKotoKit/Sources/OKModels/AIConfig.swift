import Foundation

/// Provider 标识，镜像桌面 ModelConfig.api_provider 的取值
/// （textlingo-desktop/src-tauri/src/ai_service.rs）。
public enum ProviderID: String, Codable, Sendable, CaseIterable {
    case openai
    case deepseek
    case openrouter
    case siliconflow
    case ai302 = "302ai"
    case google
    case anthropic
    case moonshot
    case kimi
    case ollama
    case lmstudio
    case openAICompatible = "openai-compatible"
}

/// 模型配置。API Key 不在此结构中——只存 Keychain（设计文档 §3.3 / §4.5）。
public struct ModelConfig: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var apiProvider: ProviderID
    public var model: String
    public var baseURL: URL?
    public var isDefault: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        apiProvider: ProviderID,
        model: String,
        baseURL: URL? = nil,
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.apiProvider = apiProvider
        self.model = model
        self.baseURL = baseURL
        self.isDefault = isDefault
    }
}

/// Share Extension → 主 App 的导入任务信封（设计文档 §6.3）。
/// 扩展只向 App Group inbox 原子写入本结构，不访问主库。
public struct ImportEnvelope: Codable, Identifiable, Sendable {
    public enum Payload: Codable, Sendable {
        case plainText(String)
        case url(String, title: String?, text: String?)
    }

    public var id: UUID
    public var schemaVersion: Int
    public var payload: Payload
    public var sourceApp: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = 1,
        payload: Payload,
        sourceApp: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.payload = payload
        self.sourceApp = sourceApp
        self.createdAt = createdAt
    }
}
