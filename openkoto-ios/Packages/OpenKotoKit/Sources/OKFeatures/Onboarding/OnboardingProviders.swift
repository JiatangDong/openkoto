import Foundation
import OKModels
import OKAIClient

/// 首启引导的精选 Provider：能力表之上的产品级推荐（推荐模型 + 取 Key 入口）。
/// 与 `ProviderCapability`（传输层能力）分开维护：取 Key 链接、模型推荐、
/// 精选范围都是产品决策，且随市场变化而更新——集中在这一张表里改。
/// 不含本地 Provider（Ollama/LM Studio 在 iOS 上需连局域网电脑，对新手不友好，
/// 进阶用户可去设置页配置完整 12 家）。
struct OnboardingProvider: Identifiable {
    let id: ProviderID
    /// 预填的推荐模型（用户可改）。最后核实：2026-07。
    let recommendedModel: String
    /// 该 Provider 的 API Key 控制台（引导文案“前往官网获取”跳这里）。
    let keyConsoleURL: URL
    /// 可选的补充提示文案 key（如“有免费额度”），nil = 只显示通用三步指引。
    let noteKey: String?

    var capability: ProviderCapability { .capability(for: id) }

    static let curated: [OnboardingProvider] = [
        // deepseek-chat/reasoner 于 2026-07-24 废弃，V4 Flash 是官方后继。
        .init(id: .deepseek, recommendedModel: "deepseek-v4-flash",
              keyConsoleURL: URL(string: "https://platform.deepseek.com/api_keys")!,
              noteKey: nil),
        // K3 2026-07-16 发布，api.moonshot.ai 官方模型 ID。
        .init(id: .kimi, recommendedModel: "kimi-k3",
              keyConsoleURL: URL(string: "https://platform.moonshot.ai/console/api-keys")!,
              noteKey: nil),
        .init(id: .siliconflow, recommendedModel: "deepseek-ai/DeepSeek-V4-Flash",
              keyConsoleURL: URL(string: "https://cloud.siliconflow.cn/account/ak")!,
              noteKey: nil),
        .init(id: .openai, recommendedModel: "gpt-5.4-mini",
              keyConsoleURL: URL(string: "https://platform.openai.com/api-keys")!,
              noteKey: nil),
        // 滚动别名：Google 升级 Flash 时 App 无需发版即可跟随。
        .init(id: .google, recommendedModel: "gemini-flash-latest",
              keyConsoleURL: URL(string: "https://aistudio.google.com/apikey")!,
              noteKey: "onboarding.provider.note.google"),
        .init(id: .openrouter, recommendedModel: "openrouter/auto",
              keyConsoleURL: URL(string: "https://openrouter.ai/keys")!,
              noteKey: "onboarding.provider.note.openrouter"),
    ]
}
