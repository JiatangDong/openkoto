import Foundation
import OKLocalization

/// 语言选项的唯一来源：设置页与首启引导共用，避免两份列表漂移。
enum LanguageOptions {
    /// 界面语言选项：code → 以该语言自身书写的名字（本地惯例，不本地化）。
    /// code 为 `.lproj` 目录名，与 `app.interfaceLanguage` 存储值一致。
    static let interface: [(code: String, name: String)] = [
        ("en", "English"), ("zh-Hans", "简体中文"), ("ja", "日本語"),
    ]

    /// 讲解语言选项（`learning.targetLanguage` 存储值，直接喂 AI prompt）。
    static let target = [
        "zh-CN", "zh-TW", "en", "ja", "ko", "es", "fr", "de", "ru", "ar",
    ]

    /// 讲解语言的显示名：中文两项用中性的“简体/繁体中文”（避免系统按地区命名引起争议），
    /// 其余语言用系统按界面语言本地化的纯语言名（无地区）。
    static func targetDisplayName(_ code: String, locale: Locale) -> String {
        switch code {
        case "zh-CN": return L("lang.simplifiedChinese")
        case "zh-TW": return L("lang.traditionalChinese")
        default: return locale.localizedString(forIdentifier: code) ?? code
        }
    }
}
