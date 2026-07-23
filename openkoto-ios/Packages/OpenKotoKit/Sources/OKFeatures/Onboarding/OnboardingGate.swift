import Foundation
import OKModels

/// 首启引导门控（设计文档 §6.2“首启无 ModelConfig 时展示配置引导”）。
/// 不包 `#if os(iOS)`：纯逻辑，macOS 下 `swift test` 可测。
enum OnboardingGate {
    static let completedKey = "app.onboarding.completed"
    /// 与 `AppConfigStore.configsKey` 同一 key：迁移判断只读不写，避免引依赖。
    private static let configsKey = "ai.modelConfigs.v1"

    /// App 启动时调用一次：老用户（升级前已有模型配置）直接视为已完成引导。
    /// 必须一次性判定而非实时看 configs 是否为空——否则用户在模型步保存配置的
    /// 瞬间向导会被弹掉。
    static func migrateIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: completedKey) else { return }
        if let data = defaults.data(forKey: configsKey),
           let configs = try? JSONDecoder().decode([ModelConfig].self, from: data),
           !configs.isEmpty {
            defaults.set(true, forKey: completedKey)
        }
    }
}
