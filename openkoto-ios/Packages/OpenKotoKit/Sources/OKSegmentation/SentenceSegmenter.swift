import Foundation

/// 切分结果草稿（尚未持久化，无 ID/文章归属）。
public struct SegmentDraft: Sendable, Equatable {
    public var text: String
    public var isNewParagraph: Bool

    public init(text: String, isNewParagraph: Bool) {
        self.text = text
        self.isNewParagraph = isNewParagraph
    }
}

public protocol SegmentationStrategy: Sendable {
    func segment(_ text: String) -> [SegmentDraft]
}

/// 句子切分器。
///
/// 1:1 移植桌面算法 `textlingo-desktop/src-tauri/src/commands.rs`
/// （`create_segments_from_content` / `split_into_sentences` / `is_abbreviation`，L64-200）。
/// 语义须与 Rust 逐条对齐——二期跨端同步后，同一篇文章在 iOS/桌面/Web 重切必须产出
/// 相同句子边界，否则翻译/精讲会错位（设计文档 §5）。
/// 对齐由 `Tests/OKSegmentationTests/Fixtures/segmentation_golden.json`（与 Rust 共享）保证。
///
/// **实现要点：全程在 `Unicode.Scalar` 上迭代**，对齐 Rust 的 `Vec<char>`（标量）语义。
/// 不能用 `[Character]`（字素簇）——例如 CRLF `"\r\n"` 在 Swift 中是单个 Character，会导致
/// `split(separator: "\n")` 无法切分段落，与 Rust 按 `\n` 标量切分产生漂移。
/// 同理 `is_alphabetic`/`is_uppercase` 对应 Unicode 属性 `properties.isAlphabetic`/`.isUppercase`。
public struct SentenceSegmenter: SegmentationStrategy {
    public init() {}

    public func segment(_ text: String) -> [SegmentDraft] {
        var drafts: [SegmentDraft] = []
        for paragraph in Self.splitParagraphs(text) {
            let sentences = Self.splitIntoSentences(paragraph)
            // 段落首句 is_new_paragraph = true（对齐 Rust `sentence_index == 0`）。
            for (index, sentence) in sentences.enumerated() {
                let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                drafts.append(SegmentDraft(text: trimmed, isNewParagraph: index == 0))
            }
        }
        return drafts
    }

    /// 按 `\n` 标量切段落，trim 后丢弃空行
    /// （对齐 Rust `content.split('\n').map(trim).filter(!empty)`）。
    /// 用 whitespacesAndNewlines 以匹配 Rust `str::trim()`（含 \r、\t 与 Unicode 空白）。
    static func splitParagraphs(_ text: String) -> [String] {
        var paragraphs: [String] = []
        var current = String.UnicodeScalarView()

        func flush() {
            let trimmed = String(current).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { paragraphs.append(trimmed) }
            current = String.UnicodeScalarView()
        }

        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                flush()
            } else {
                current.append(scalar)
            }
        }
        flush()
        return paragraphs
    }

    /// 将段落拆成句子，保留句末标点（对齐 `split_into_sentences`）。
    static func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)

        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            current.append(c)

            let isSentenceEnd = c == "。"
                || c == "？"
                || c == "！"
                || (c == "." && !isAbbreviation(scalars, i))
                || c == "?"
                || c == "!"

            if isSentenceEnd {
                // 句末符后紧跟闭引号/右括号则一并归入本句（如 ... said."）。
                if i + 1 < scalars.count {
                    let next = scalars[i + 1]
                    if next == "\""            // U+0022 直双引号
                        || next == "\u{201D}"  // ” 右双引号
                        || next == "'"         // U+0027 直单引号
                        || next == "\u{2019}"  // ’ 右单引号
                        || next == ")"         // U+0029 右括号
                        || next == "）"         // U+FF09 全角右括号
                    {
                        i += 1
                        current.append(next)
                    }
                }

                let trimmed = String(current).trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = String.UnicodeScalarView()
            }

            i += 1
        }

        // 处理无句末符结尾的剩余内容。
        let trailing = String(current).trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty { sentences.append(trailing) }

        // 整段没有分割成功（未找到分隔符）时返回整段。
        let whole = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if sentences.isEmpty && !whole.isEmpty {
            sentences.append(whole)
        }

        return sentences
    }

    /// 常见英文缩写词表（小写，对齐 Rust `abbreviations`）。
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "jr", "sr", "vs", "etc",
        "inc", "ltd", "no", "st", "ave", "rd",
    ]

    /// 判断某个 `.` 是否属于缩写（对齐 `is_abbreviation`）。
    static func isAbbreviation(_ scalars: [Unicode.Scalar], _ pos: Int) -> Bool {
        // 句点后紧跟字母 → 可能是缩写（如 U.S.A）。
        if pos + 1 < scalars.count && scalars[pos + 1].properties.isAlphabetic {
            return true
        }

        // 向前收集单词。
        var wordScalars: [Unicode.Scalar] = []
        var j = pos - 1
        while j >= 0 && scalars[j].properties.isAlphabetic {
            wordScalars.append(scalars[j])
            j -= 1
        }
        let word = String(String.UnicodeScalarView(wordScalars.reversed()))

        if abbreviations.contains(word.lowercased()) {
            return true
        }

        // 单个大写字母后跟句点通常是缩写（如 A. B. C.）。
        if wordScalars.count == 1, wordScalars[0].properties.isUppercase {
            return true
        }

        return false
    }
}
