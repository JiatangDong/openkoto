import Foundation

/// 把相邻 token 拼成连续文本时，中间该不该加空格。
///
/// 这件事必须做对，否则整条管线的输入就是错的：中日文加了空格会让切分器多切、
/// 让正文难看；拉丁文不加空格会把 `Helloworldhowareyou` 喂给切分器和 LLM。
/// 桌面端 `segment_words_into_cues` 就是靠「整篇出现任意一个 CJK 字符」一次性判定
/// 全篇 joiner（`subtitle_extraction.rs:891-894`），混合语言下必然出错。
/// 这里改成**逐边界判定**，只看接缝两侧的那一个字符。
public enum TokenJoiner {
    public static func joiner(after previous: String, before next: String) -> String {
        guard let left = previous.unicodeScalars.last else { return "" }
        guard let right = next.unicodeScalars.first else { return "" }

        // 已有空白就别再加，避免双空格（端上转写的 token 常自带前导空格）
        if isWhitespace(left) || isWhitespace(right) { return "" }
        // 后置标点贴左、前置标点贴右
        if isClosingPunctuation(right) || isOpeningPunctuation(left) { return "" }
        // 接缝任一侧属于不使用空格的文字系统
        if isSpacelessScript(left) || isSpacelessScript(right) { return "" }
        return " "
    }

    /// 顺序拼接一串 token，并逐边界决定分隔符。
    public static func join(_ texts: [String]) -> String {
        var result = ""
        for text in texts {
            result += joiner(after: result, before: text) + text
        }
        return result
    }

    // MARK: - 字符分类

    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace
    }

    /// 不使用空格分词的文字系统。
    ///
    /// ⚠️ **韩文（Hangul AC00–D7AF）不在此列——韩语是用空格的。**
    /// 这是最容易写错的一条：CJK 三个字母连着念，就容易把韩文一起塞进来。
    /// 桌面端把 `sub-lang` 写死成 en,zh-Hans,zh-Hant 导致日韩根本下不到字幕，
    /// 别在算法层再犯一次日韩不分。
    static func isSpacelessScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,  // CJK 标点
            0x3040...0x309F,  // 平假名
            0x30A0...0x30FF,  // 片假名
            0x3400...0x4DBF,  // CJK 扩展 A
            0x4E00...0x9FFF,  // CJK 统一汉字
            0xF900...0xFAFF,  // CJK 兼容汉字
            0xFF00...0xFFEF,  // 全角/半角（含半角片假名）
            0x0E00...0x0E7F,  // 泰文
            0x0E80...0x0EFF,  // 老挝文
            0x1780...0x17FF,  // 高棉文
            0x1000...0x109F,  // 缅甸文
            0x20000...0x2FA1F:  // CJK 扩展 B 及以后
            true
        default: false
        }
    }

    /// 贴在前一个词右侧的标点（句末、逗号、右括号、右引号…）。
    private static func isClosingPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        ".,!?;:%…、。！？，；：）〕］｝〉》」』】”’)]}>".unicodeScalars.contains(scalar)
    }

    /// 贴在后一个词左侧的标点（左括号、左引号…）。
    private static func isOpeningPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        "（〔［｛〈《「『【“‘([{<".unicodeScalars.contains(scalar)
    }
}
