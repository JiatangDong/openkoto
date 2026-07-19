import Foundation

/// 共享字符串资源入口（en/zh/ja，String Catalog）。
/// 用法：`L("library.title")` 或 `Text("library.title", bundle: L10n.bundle)`。
public enum L10n {
    public static let bundle = Bundle.module

    /// 界面语言覆盖（nil = 跟随系统）。设置页切换后由 RootTabView 用 `.id` 触发视图树重建。
    /// `nonisolated(unsafe)`：仅在设置/启动时从主线程写一次，读多写少，无需锁。
    nonisolated(unsafe) private static var overrideBundle: Bundle?

    /// 设置界面语言覆盖。`code` 为 `.lproj` 目录名（en / zh-Hans / ja）；传 nil 恢复跟随系统。
    public static func setOverrideLanguage(_ code: String?) {
        guard let code,
              let path = bundle.path(forResource: code, ofType: "lproj"),
              let localized = Bundle(path: path)
        else {
            overrideBundle = nil
            return
        }
        overrideBundle = localized
    }

    static var activeBundle: Bundle { overrideBundle ?? bundle }
}

public func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: L10n.activeBundle)
}
