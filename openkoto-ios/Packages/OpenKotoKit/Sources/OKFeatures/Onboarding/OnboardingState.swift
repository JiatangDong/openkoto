#if os(iOS)
import Foundation
import Observation
import OKModels

/// 首启引导的全部可变状态。
/// 必须由 RootTabView 以 `@State` 持有（在 `.id(interfaceLanguage)` 边界之外）：
/// 语言步切界面语言会触发整棵子树重建，步骤进度、已输入的 Key、测试结果
/// 全靠本对象存活；步骤视图内不放任何需要跨重建保留的本地 `@State`。
@MainActor
@Observable
final class OnboardingState {
    /// `appLanguage` 必须是第一步：欢迎语本身也要用用户看得懂的语言写，
    /// 而系统语言不在 en/zh/ja 里时（韩语、法语…）整页会退回英文。
    /// 先让用户挑一次界面语言，后面所有文案才有意义。
    enum Step: Int, CaseIterable {
        case appLanguage, welcome, language, theme, model, reminder, done

        static var first: Step { .appLanguage }
    }

    enum TestState: Equatable {
        case idle, testing, success, failure(String)
    }

    var step: Step = .first
    /// 步骤切换方向，驱动 push 转场的进出边。
    private(set) var movingForward = true

    /// 截图/UI 测试用（同 RootTabView 的 -startTab*）：
    /// `-onboardingStep welcome|language|theme|model|reminder|done` 启动直达指定步骤；
    /// `-onboardingProvider <ProviderID.rawValue>` 预选精选 Provider（配合 model 步截图）。
    init() {
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "-onboardingStep"), idx + 1 < args.count {
            switch args[idx + 1] {
            case "appLanguage": step = .appLanguage
            case "welcome": step = .welcome
            case "language": step = .language
            case "theme": step = .theme
            case "model": step = .model
            case "reminder": step = .reminder
            case "done": step = .done
            default: break
            }
        }
        if let idx = args.firstIndex(of: "-onboardingProvider"), idx + 1 < args.count,
           let id = ProviderID(rawValue: args[idx + 1]),
           let provider = OnboardingProvider.curated.first(where: { $0.id == id }) {
            select(provider)
        }
    }

    // MARK: 模型步草稿

    var selectedProviderID: ProviderID?
    var modelName = ""
    var apiKeyInput = ""
    /// 仅 OpenAI 兼容需要：用户自带服务商的 Base URL。
    var baseURLInput = ""
    var testState: TestState = .idle
    /// 已保存过的配置 id：回退再前进时更新同一条，避免重复建配置。
    var savedConfigID: UUID?
    var modelStepSkipped = false
    /// 最近一次预填的推荐模型：仅当用户未手改时，切换 Provider 才覆盖模型名。
    var lastPrefilledModel = ""

    var selectedProvider: OnboardingProvider? {
        guard let id = selectedProviderID else { return nil }
        return OnboardingProvider.curated.first { $0.id == id }
    }

    func select(_ provider: OnboardingProvider) {
        selectedProviderID = provider.id
        if modelName.isEmpty || modelName == lastPrefilledModel {
            modelName = provider.recommendedModel
        }
        lastPrefilledModel = provider.recommendedModel
        testState = .idle
    }

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        movingForward = true
        step = next
    }

    func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        movingForward = false
        step = previous
    }

    /// 从设置页重看引导时回到第一步。模型步的草稿一并清掉——
    /// 上次填的 Key 早已存进 Keychain，留着只会让人以为要重填一遍。
    func reset() {
        step = .first
        movingForward = true
        selectedProviderID = nil
        modelName = ""
        apiKeyInput = ""
        baseURLInput = ""
        testState = .idle
        savedConfigID = nil
        modelStepSkipped = false
        lastPrefilledModel = ""
    }
}
#endif
