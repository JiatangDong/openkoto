import Foundation

/// 一个词在句子中的位置。
public struct WordToken: Sendable, Equatable, Hashable {
    public var text: String
    /// 在原句中的 **Unicode 标量**区间（与 `SentenceLocator`、`MarkAnchor` 的偏移语义一致）。
    public var range: Range<Int>

    public init(text: String, range: Range<Int>) {
        self.text = text
        self.range = range
    }
}

/// 语言无关的分词。
///
/// **为什么不复用 `LocalReadingAnnotator`**：那个是**注音器**，只认日语和中文
/// （`ReadingLanguage` 没有别的 case），对其它语种直接返回整句一个 run。
/// 拿它做词表，英语文章会只有一项。分词能力（`CFStringTokenizer`）本身是语言无关的，
/// 只是被注音 provider 的 guard 挡住了——这里把它剥出来。
///
/// 实测覆盖（`kCFStringTokenizerUnitWordBoundary`）：
/// - 法语 elision `L'homme` / `qu'il` / `n'était` 不会被切开
/// - 德语复合词 `Geschwindigkeitsbegrenzung` 保持完整
/// - 英语缩写 `wasn't` 完整
/// - 日中泰按词切，韩语按空格切（助词黏着，查词可用）
/// - **不传 locale 也一样准**，所以语种判不出来时不必降级
public enum WordTokenizer {
    /// 切词。`locale` 是 BCP-47 提示，可为 nil。
    public static func tokenize(_ text: String, locale: String? = nil) -> [WordToken] {
        guard !text.isEmpty else { return [] }
        let scalars = Array(text.unicodeScalars)
        let cfText = text as CFString
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault, cfText,
            CFRangeMake(0, CFStringGetLength(cfText)),
            kCFStringTokenizerUnitWordBoundary,
            locale.map { Locale(identifier: $0) as CFLocale })

        var result: [WordToken] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let cfRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard
                let stringRange = Range(
                    NSRange(location: cfRange.location, length: cfRange.length), in: text)
            else { continue }
            // CFStringTokenizer 的 range 是 UTF-16 的，这里换算成标量偏移
            let start = text.unicodeScalars.distance(
                from: text.unicodeScalars.startIndex, to: stringRange.lowerBound)
            let end = text.unicodeScalars.distance(
                from: text.unicodeScalars.startIndex, to: stringRange.upperBound)
            guard start < end, end <= scalars.count else { continue }
            result.append(WordToken(text: String(text[stringRange]), range: start..<end))
        }
        return result
    }

    /// 只保留"值得查"的词：去掉纯标点、纯空白、纯数字。
    ///
    /// 词表上出现「。」「、」「 」这种可点条目纯属噪声，而且点了也没有释义可给。
    public static func lookupCandidates(_ text: String, locale: String? = nil) -> [WordToken] {
        tokenize(text, locale: locale).filter { isWorthLookingUp($0.text) }
    }

    static func isWorthLookingUp(_ word: String) -> Bool {
        var hasMeaningfulScalar = false
        for scalar in word.unicodeScalars {
            if scalar.properties.isWhitespace { continue }
            if CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar)
            {
                continue
            }
            // 纯数字（含全角数字）不值得查
            if CharacterSet.decimalDigits.contains(scalar) { continue }
            hasMeaningfulScalar = true
            break
        }
        return hasMeaningfulScalar
    }
}
