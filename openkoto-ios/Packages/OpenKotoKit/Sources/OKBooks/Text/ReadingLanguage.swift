import Foundation

/// 离线注音支持的语种。
///
/// 只列**系统能离线给出真实读音**的语言。iOS 的 `CFStringTokenizer` 转写对日语/中文
/// 恰好就是读音（假名 / 拼音），但对韩语、俄语等只是**字形转写**——
/// `한국말 → hangugmal`（实际读 hangungmal），拿它当发音会教错人，因此不在此列。
/// 后续要加的转写型语种（俄/希腊/印地）与韩语音韵规则引擎各自是独立的 case + provider。
public enum ReadingLanguage: Sendable, Equatable {
    case japanese
    case chinese
    /// 无法可靠判定，或该语种无离线读音能力。一律不标注——宁可不显示，不可显示错的。
    case unsupported
}

/// 语种判定。**判错是灾难性的**：中文喂 ja locale 会得到日语音读
/// （`银行行长 → 银行()行(こう)长说()`），所以策略必须保守。
///
/// 判定应在**篇级**做一次（整篇/整章的文本），不要逐句判——
/// 日语文章里可能有整句只有汉字（「日本語」），逐句判会漏。
public enum ReadingLanguageDetector {
    /// - Parameters:
    ///   - text: 用于判定的样本（整篇内容或其前若干字）。
    ///   - hint: 调用方已知的 BCP-47 语言码（书籍取 `Book.language`，
    ///           文章由 `NLLanguageRecognizer` 检测）。`OKBooks` 不引入
    ///           NaturalLanguage，检测留在调用方。
    public static func detect(text: String, hint: String? = nil) -> ReadingLanguage {
        // 假名是日语的确凿证据，优先于任何 hint（带日文正文的书 hint 可能填错）。
        if containsKana(text) { return .japanese }

        if let hint = normalize(hint) {
            if hint.hasPrefix("ja") { return .japanese }
            if hint.hasPrefix("zh") || hint.hasPrefix("cmn") || hint.hasPrefix("yue") {
                return .chinese
            }
            // 明确是别的语种：即便满屏汉字（日语汉字文）也不猜。
            return .unsupported
        }

        // 只有汉字且无 hint：中日无法区分，不猜。
        return .unsupported
    }

    private static func normalize(_ hint: String?) -> String? {
        guard let hint = hint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !hint.isEmpty
        else { return nil }
        return hint
    }

    /// 平假名 U+3040–309F / 片假名 U+30A0–30FF（含长音符 U+30FC）。
    static func containsKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { isKana($0) }
    }

    static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(scalar.value)
    }

    /// CJK 统一汉字（含扩展 A 与兼容汉字），用于判断 token 是否需要注音。
    static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: true
        default: false
        }
    }

    static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { isHan($0) }
    }
}
