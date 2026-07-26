#if os(iOS)
import CryptoKit
import Foundation
import Observation
import OKModels
import OKAIClient

/// 应用级配置仓库（设计文档 §3.3 / §6.6）：
/// - `ModelConfig` 列表（不含 api_key）持久化到 UserDefaults；
/// - API Key 只经 `KeychainStore` 存取，删除配置时同步删除 Key（避免孤儿）；
/// - 目标语言复用 `learning.targetLanguage`（与设置页 @AppStorage 同一 key）；
/// - 提供 `explain`（组合 ExplanationService）与 `testConnection` 给 UI 调用。
@MainActor
@Observable
public final class AppConfigStore {
    public private(set) var configs: [ModelConfig]

    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let explanationService: ExplanationService

    private static let configsKey = "ai.modelConfigs.v1"
    private static let targetLanguageKey = "learning.targetLanguage"

    public init(
        keychain: KeychainStore = KeychainStore(),
        defaults: UserDefaults = .standard,
        explanationService: ExplanationService = ExplanationService()
    ) {
        self.keychain = keychain
        self.defaults = defaults
        self.explanationService = explanationService
        if let data = defaults.data(forKey: Self.configsKey),
           let saved = try? JSONDecoder().decode([ModelConfig].self, from: data) {
            configs = saved
        } else {
            configs = []
        }
    }

    // MARK: - 查询

    /// 当前生效模型：显式默认优先，否则取第一个。
    public var activeConfig: ModelConfig? {
        configs.first(where: \.isDefault) ?? configs.first
    }

    public var hasUsableModel: Bool { activeConfig != nil }

    public func apiKey(for id: UUID) -> String? { keychain.key(for: id) }
    public func hasKey(for id: UUID) -> Bool { keychain.hasKey(for: id) }

    public var targetLanguage: String {
        defaults.string(forKey: Self.targetLanguageKey) ?? "zh-CN"
    }

    // MARK: - CRUD

    /// 新增或更新一个模型配置。`apiKey` 传 nil 表示不改动已存 Key，传空串表示清除。
    public func addOrUpdate(_ config: ModelConfig, apiKey: String?) {
        var updated = config
        // 首个配置或显式默认时，保证唯一默认。
        if updated.isDefault || configs.isEmpty {
            updated.isDefault = true
            for i in configs.indices where configs[i].id != updated.id {
                configs[i].isDefault = false
            }
        }
        if let idx = configs.firstIndex(where: { $0.id == updated.id }) {
            configs[idx] = updated
        } else {
            configs.append(updated)
        }
        if let apiKey {
            keychain.setKey(apiKey, for: updated.id)
        }
        ensureSingleDefault()
        persist()
    }

    public func delete(_ id: UUID) {
        configs.removeAll { $0.id == id }
        keychain.deleteKey(for: id)   // 删除配置必须同步删除 Key，避免孤儿
        ensureSingleDefault()
        persist()
    }

    public func setDefault(_ id: UUID) {
        for i in configs.indices {
            configs[i].isDefault = (configs[i].id == id)
        }
        persist()
    }

    private func ensureSingleDefault() {
        guard !configs.isEmpty else { return }
        if !configs.contains(where: \.isDefault) {
            configs[0].isDefault = true
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(configs) {
            defaults.set(data, forKey: Self.configsKey)
        }
    }

    // MARK: - AI 调用

    /// 用当前生效模型对一句原文做翻译+精讲。未配置模型抛 `.notConfigured`。
    /// 返回值附带溯源元数据，随精讲一起写入 `explanation_json`（设计文档 §3.2）。
    public func explain(text: String) async throws -> GeneratedExplanation {
        guard let config = activeConfig else { throw AIClientError.notConfigured }
        let explanation = try await explanationService.explain(
            text: text,
            targetLanguage: targetLanguage,
            config: config,
            apiKey: apiKey(for: config.id)
        )
        let meta = ExplanationMeta(
            targetLanguage: targetLanguage,
            providerId: config.apiProvider.rawValue,
            modelId: config.model,
            promptVersion: PromptLibrary.segmentExplainVersion,
            generatedAt: .now,
            sourceTextHash: SourceTextHash.of(text)
        )
        return GeneratedExplanation(explanation: explanation, meta: meta)
    }

    /// 查一个词在所在句子里的意思。比整句精讲便宜一个数量级。
    ///
    /// 与精讲共用同一个 `activeConfig`：省钱靠的是 schema 与输出都极短，
    /// 与模型选型无关，所以不值得为它引入第二个模型配置（多一个 picker、
    /// 多一个可能失败的 Key、以及"为什么查词失败但精讲正常"这种新困惑）。
    public func gloss(word: String, sentence: String) async throws -> VocabularyItem {
        guard let config = activeConfig else { throw AIClientError.notConfigured }
        return try await explanationService.gloss(
            word: word, sentence: sentence, targetLanguage: targetLanguage,
            config: config, apiKey: apiKey(for: config.id))
    }

    /// 用当前生效模型对一句原文只做翻译（快翻/全文翻译）。未配置模型抛 `.notConfigured`。
    public func translate(text: String) async throws -> String {
        guard let config = activeConfig else { throw AIClientError.notConfigured }
        return try await explanationService.translate(
            text: text,
            targetLanguage: targetLanguage,
            config: config,
            apiKey: apiKey(for: config.id)
        )
    }

    /// 测试某个配置能否连通（设置页“测试连接”）。
    public func testConnection(_ config: ModelConfig, apiKey: String?) async throws {
        try await explanationService.testConnection(config: config, apiKey: apiKey)
    }
}
#endif
