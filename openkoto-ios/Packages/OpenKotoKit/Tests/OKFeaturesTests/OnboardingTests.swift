import Foundation
import Testing
import OKModels
import OKAIClient
@testable import OKFeatures

@Suite struct OnboardingGateTests {
    /// 每个用例独立的 UserDefaults 域，避免污染 standard。
    private func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "OnboardingGateTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func freshInstallStaysIncomplete() {
        let defaults = makeDefaults(#function)
        OnboardingGate.migrateIfNeeded(defaults: defaults)
        #expect(!defaults.bool(forKey: OnboardingGate.completedKey))
    }

    @Test func existingConfigsMarkCompleted() throws {
        let defaults = makeDefaults(#function)
        let configs = [ModelConfig(name: "Test", apiProvider: .deepseek, model: "deepseek-v4-flash", isDefault: true)]
        defaults.set(try JSONEncoder().encode(configs), forKey: "ai.modelConfigs.v1")
        OnboardingGate.migrateIfNeeded(defaults: defaults)
        #expect(defaults.bool(forKey: OnboardingGate.completedKey))
    }

    @Test func emptyConfigListStaysIncomplete() throws {
        let defaults = makeDefaults(#function)
        defaults.set(try JSONEncoder().encode([ModelConfig]()), forKey: "ai.modelConfigs.v1")
        OnboardingGate.migrateIfNeeded(defaults: defaults)
        #expect(!defaults.bool(forKey: OnboardingGate.completedKey))
    }

    @Test func corruptConfigDataStaysIncomplete() {
        let defaults = makeDefaults(#function)
        defaults.set(Data("not json".utf8), forKey: "ai.modelConfigs.v1")
        OnboardingGate.migrateIfNeeded(defaults: defaults)
        #expect(!defaults.bool(forKey: OnboardingGate.completedKey))
    }

    @Test func completedFlagIsIdempotent() {
        let defaults = makeDefaults(#function)
        defaults.set(true, forKey: OnboardingGate.completedKey)
        OnboardingGate.migrateIfNeeded(defaults: defaults)
        #expect(defaults.bool(forKey: OnboardingGate.completedKey))
    }
}

@Suite struct OnboardingProviderTests {
    @Test func curatedListExcludesLocalProviders() {
        for provider in OnboardingProvider.curated {
            #expect(!provider.capability.isLocalProvider, "\(provider.id) 是本地 Provider，不应进精选")
        }
    }

    @Test func curatedListHasNoDuplicates() {
        let ids = OnboardingProvider.curated.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    /// 除"自带服务商"外，每一项都必须能开箱即用：预填模型 + https 取 Key 入口。
    @Test func everyFixedProviderHasModelAndSecureConsoleURL() {
        for provider in OnboardingProvider.curated where !provider.needsBaseURL {
            #expect(!provider.recommendedModel.isEmpty)
            #expect(provider.keyConsoleURL?.scheme == "https", "\(provider.id) 的取 Key 链接必须是 https")
        }
    }

    /// 引导只在 `needsBaseURL` 时收集 Base URL，其余一律存 `baseURL: nil`——
    /// 那就要求 Provider 自带默认端点或是 gemini（transport 按 model 动态拼 URL）。
    /// 此不变量被破坏会导致请求无处可发。
    @Test func everyCuratedProviderResolvesToAnEndpoint() {
        for provider in OnboardingProvider.curated {
            let cap = provider.capability
            if cap.requiresCustomBaseURL {
                // 需要自填地址的项，引导表单必须认得出来并把输入框显示出来。
                #expect(provider.needsBaseURL)
                #expect(!cap.isLocalProvider, "\(provider.id) 是局域网 Provider，不应进精选")
            } else {
                #expect(cap.defaultEndpoint != nil || cap.kind == .gemini,
                        "\(provider.id) 无默认端点且非 gemini，baseURL: nil 不安全")
            }
        }
    }

    /// 自带服务商（OpenAI 兼容）：模型 ID 与地址都只有用户知道，不能预填。
    @Test func openAICompatibleIsCuratedAndPrefillsNothing() throws {
        let compat = try #require(
            OnboardingProvider.curated.first { $0.id == .openAICompatible })
        #expect(compat.needsBaseURL)
        #expect(compat.recommendedModel.isEmpty)
        #expect(compat.keyConsoleURL == nil)
    }

    /// gemini transport 会剥 `models/` 前缀；推荐模型不应带着它存进配置。
    @Test func geminiModelHasNoModelsPrefix() {
        let google = OnboardingProvider.curated.first { $0.id == .google }
        #expect(google != nil)
        #expect(google?.recommendedModel.hasPrefix("models/") == false)
    }
}

#if os(iOS)
/// 引导步骤顺序与重看引导的状态复位。
@MainActor
@Suite struct OnboardingStepFlowTests {
    /// 选语言必须是第一步：欢迎语本身也得用用户看得懂的语言写，
    /// 系统语言不在 en/zh/ja 里时整页会退回英文。
    @Test func languagePickIsTheFirstStep() {
        #expect(OnboardingState.Step.first == .appLanguage)
        #expect(OnboardingState.Step.allCases.first == .appLanguage)
        #expect(OnboardingState().step == .appLanguage)
    }

    @Test func advanceReachesWelcomeAfterLanguage() {
        let state = OnboardingState()
        state.advance()
        #expect(state.step == .welcome)
        state.goBack()
        #expect(state.step == .appLanguage)
        // 第一步没有上一步可回
        state.goBack()
        #expect(state.step == .appLanguage)
    }

    /// 从设置页重看引导：回到第一步，且模型步草稿清空
    /// （Key 早已进 Keychain，留着草稿会让人以为要重填）。
    @Test func resetReturnsToFirstStepAndClearsDraft() {
        let state = OnboardingState()
        state.step = .done
        state.apiKeyInput = "sk-secret"
        state.modelName = "gpt-x"
        state.savedConfigID = UUID()
        state.modelStepSkipped = true

        state.reset()

        #expect(state.step == .appLanguage)
        #expect(state.apiKeyInput.isEmpty)
        #expect(state.modelName.isEmpty)
        #expect(state.savedConfigID == nil)
        #expect(!state.modelStepSkipped)
    }
}
#endif
