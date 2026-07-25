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
    /// nil = 没有固定官网（OpenAI 兼容由用户自带服务商），此时不显示跳转入口。
    let keyConsoleURL: URL?
    /// 可选的补充提示文案 key（如“有免费额度”），nil = 只显示通用三步指引。
    let noteKey: String?

    var capability: ProviderCapability { .capability(for: id) }

    /// 需要用户自填 Base URL（OpenAI 兼容）——引导文案与表单都要相应变形。
    var needsBaseURL: Bool { capability.requiresCustomBaseURL }

    static let curated: [OnboardingProvider] = [
        // deepseek-chat/reasoner 于 2026-07-24 废弃，V4 Flash 是官方后继。
        .init(id: .deepseek, recommendedModel: "deepseek-v4-flash",
              keyConsoleURL: URL(string: "https://platform.deepseek.com/api_keys")!,
              noteKey: nil),
        // K3 2026-07-16 发布，api.moonshot.ai 官方模型 ID。
        .init(id: .kimi, recommendedModel: "kimi-k3",
              keyConsoleURL: URL(string: "https://platform.moonshot.ai/console/api-keys")!,
              noteKey: nil),
        // 中国版走 api.moonshot.cn：模型 ID 与国际版一致，但账号/Key 各自独立。
        .init(id: .moonshot, recommendedModel: "kimi-k3",
              keyConsoleURL: URL(string: "https://platform.moonshot.cn/console/api-keys")!,
              noteKey: "onboarding.provider.note.moonshot"),
        .init(id: .openai, recommendedModel: "gpt-5.4-mini",
              keyConsoleURL: URL(string: "https://platform.openai.com/api-keys")!,
              noteKey: nil),
        // 滚动别名：Google 升级 Flash 时 App 无需发版即可跟随。
        .init(id: .google, recommendedModel: "gemini-flash-latest",
              keyConsoleURL: URL(string: "https://aistudio.google.com/apikey")!,
              noteKey: "onboarding.provider.note.google"),
        // 无日期别名：跟随 Anthropic 的滚动指针，避免固定快照过期。
        .init(id: .anthropic, recommendedModel: "claude-haiku-4-5",
              keyConsoleURL: URL(string: "https://console.anthropic.com/settings/keys")!,
              noteKey: nil),
        .init(id: .openrouter, recommendedModel: "openrouter/auto",
              keyConsoleURL: URL(string: "https://openrouter.ai/keys")!,
              noteKey: "onboarding.provider.note.openrouter"),
        // 兜底项：任何提供 /v1/chat/completions 的服务商（自建、代理、上表没列的）
        // 都从这里进，所以不预填模型名——模型 ID 只有用户自己知道。
        .init(id: .openAICompatible, recommendedModel: "",
              keyConsoleURL: nil,
              noteKey: "onboarding.provider.note.openaiCompatible"),
    ]
}
