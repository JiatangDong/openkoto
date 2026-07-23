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

    @Test func everyEntryHasModelAndSecureConsoleURL() {
        for provider in OnboardingProvider.curated {
            #expect(!provider.recommendedModel.isEmpty)
            #expect(provider.keyConsoleURL.scheme == "https")
        }
    }

    /// 引导保存的配置一律 `baseURL: nil`，前提是 Provider 有默认端点或是 gemini
    /// （gemini 由 transport 按 model 动态拼 URL）。此不变量被破坏会导致请求无处可发。
    @Test func nilBaseURLIsSafeForEveryCuratedProvider() {
        for provider in OnboardingProvider.curated {
            let cap = provider.capability
            #expect(cap.defaultEndpoint != nil || cap.kind == .gemini,
                    "\(provider.id) 无默认端点且非 gemini，baseURL: nil 不安全")
            #expect(!cap.requiresCustomBaseURL, "\(provider.id) 要求自定义 Base URL，不应进精选")
        }
    }

    /// gemini transport 会剥 `models/` 前缀；推荐模型不应带着它存进配置。
    @Test func geminiModelHasNoModelsPrefix() {
        let google = OnboardingProvider.curated.first { $0.id == .google }
        #expect(google != nil)
        #expect(google?.recommendedModel.hasPrefix("models/") == false)
    }
}
