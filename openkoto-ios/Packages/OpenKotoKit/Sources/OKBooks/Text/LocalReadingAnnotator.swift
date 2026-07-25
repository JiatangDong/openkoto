import Foundation
import OKModels

/// 离线注音器：把一句话切成带读音的 run 序列，供阅读页做词级注音（ruby）。
///
/// 全部依赖 iOS/macOS 系统自带的 `CFStringTokenizer` —— **不联网、不调 AI、不带词典**：
/// - 分词器同时给出每个词在原文中的 range，注音的对齐位置是白送的；
/// - 日语：`kCFStringTokenizerAttributeLatinTranscription` 返回的是 **wapuro（输入法式）罗马字**
///   （`toukyou` 而非 `tōkyō`、`ha` 而非 `wa`），所以回转假名是正字法无损的：
///   東京→とうきょう、大阪→おおさか（おう/おお 分得对）、を→wo→を；
/// - 中文：转写即带调拼音，且分词器带词典能分辨多音字上下文
///   （银行 yínháng / 行长 hángzhǎng / 长度 chángdù）。
///
/// 已知误差约 10%，集中在高频词的读音频次选择（日本語→日本(にっぽん)+語(ご)、私→わたくし）。
/// 精讲过的句子由上层用 AI 数据覆盖修正。
///
/// 语种必须由调用方在**篇级**判定后传入（见 `ReadingLanguageDetector`）——
/// 判错的代价是整篇读音全错，不是少标几个词。
public struct LocalReadingAnnotator: Sendable {
    public init() {}

    /// 给一句话注音。语种不支持时原样返回单个无注音 run。
    public func annotate(_ text: String, language: ReadingLanguage) -> [ReadingRun] {
        guard !text.isEmpty else { return [] }
        guard let provider = Self.provider(for: language) else { return [ReadingRun(text: text)] }

        let cfText = text as CFString
        let fullRange = CFRangeMake(0, CFStringGetLength(cfText))
        let locale = Locale(identifier: provider.localeIdentifier) as CFLocale
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault, cfText, fullRange, kCFStringTokenizerUnitWordBoundary, locale)

        var runs: [ReadingRun] = []
        var cursor = text.startIndex

        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard
                let range = Range(
                    NSRange(location: tokenRange.location, length: tokenRange.length), in: text),
                range.lowerBound >= cursor
            else { continue }

            // 词之间的空白/标点分词器不返回，按 range 间隙补回来，保证拼接 == 原文。
            if cursor < range.lowerBound {
                runs.append(ReadingRun(text: String(text[cursor..<range.lowerBound])))
            }
            let transcription = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String
            runs.append(
                contentsOf: provider.runs(
                    forToken: String(text[range]), transcription: transcription))
            cursor = range.upperBound
        }

        if cursor < text.endIndex {
            runs.append(ReadingRun(text: String(text[cursor...])))
        }
        return runs.mergingUnannotated()
    }

    private static func provider(for language: ReadingLanguage) -> ReadingProvider? {
        switch language {
        case .japanese: JapaneseReadingProvider()
        case .chinese: ChineseReadingProvider()
        case .unsupported: nil
        }
    }
}

// MARK: - Provider

/// 一个语种的注音策略。加一门语言 = 加一个 provider + 一组 golden 测试，渲染层不动。
protocol ReadingProvider: Sendable {
    var localeIdentifier: String { get }
    /// 把一个词切成 run。返回多个 run 是为了日语送假名（`駆ける` → `駆`(か) + `ける`）。
    func runs(forToken token: String, transcription: String?) -> [ReadingRun]
}

/// 日语：wapuro 罗马字 → 平假名，再把送假名从注音范围里剥出去。
struct JapaneseReadingProvider: ReadingProvider {
    let localeIdentifier = "ja_JP"

    func runs(forToken token: String, transcription: String?) -> [ReadingRun] {
        guard ReadingLanguageDetector.containsHan(token),
            let romaji = transcription,
            let kana = Self.hiragana(from: romaji),
            kana != token
        else { return [ReadingRun(text: token)] }
        return Self.splittingOkurigana(token: token, reading: kana)
    }

    /// 罗马字 → 平假名。转换不完整（残留拉丁字母等）说明系统没认出这个词，
    /// 此时返回 nil 不注音——宁可不显示，不可显示错的。
    static func hiragana(from romaji: String) -> String? {
        let buffer = NSMutableString(string: romaji)
        guard CFStringTransform(buffer as CFMutableString, nil, kCFStringTransformLatinHiragana, false)
        else { return nil }
        let kana = buffer as String
        guard !kana.isEmpty,
            kana.unicodeScalars.allSatisfy({ ReadingLanguageDetector.isKana($0) })
        else { return nil }
        return kana
    }

    /// 送假名裁剪：`駆ける/かける` → `駆`(か) + `ける`，`聞こえる/きこえる` → `聞`(き) + `こえる`。
    /// 只在**原文那一侧是假名**且与读音同音时才剥离，所以纯汉字词（東京）不受影响。
    /// 比较用片假名折叠成平假名后进行（`消しゴム/けしごむ` 的 `ゴ` 与 `ご` 视为同音）。
    static func splittingOkurigana(token: String, reading: String) -> [ReadingRun] {
        var base = Array(token)
        var kana = Array(reading)

        var suffix: [Character] = []
        while let last = base.last, let readingLast = kana.last,
            isKana(last), fold(last) == fold(readingLast)
        {
            suffix.insert(last, at: 0)
            base.removeLast()
            kana.removeLast()
        }

        var prefix: [Character] = []
        while let first = base.first, let readingFirst = kana.first,
            isKana(first), fold(first) == fold(readingFirst)
        {
            prefix.append(first)
            base.removeFirst()
            kana.removeFirst()
        }

        // 剥没了（或读音被剥空）说明这个词本来就不需要注音。
        guard !base.isEmpty, !kana.isEmpty else { return [ReadingRun(text: token)] }

        var runs: [ReadingRun] = []
        if !prefix.isEmpty { runs.append(ReadingRun(text: String(prefix))) }
        runs.append(ReadingRun(text: String(base), reading: String(kana)))
        if !suffix.isEmpty { runs.append(ReadingRun(text: String(suffix))) }
        return runs
    }

    private static func isKana(_ character: Character) -> Bool {
        !character.unicodeScalars.isEmpty
            && character.unicodeScalars.allSatisfy { ReadingLanguageDetector.isKana($0) }
    }

    /// 片假名折叠成平假名，只为比较用。
    private static func fold(_ character: Character) -> Character {
        guard let scalar = character.unicodeScalars.first,
            (0x30A1...0x30F6).contains(scalar.value),
            let folded = Unicode.Scalar(scalar.value - 0x60)
        else { return character }
        return Character(folded)
    }
}

/// 中文：转写即带调拼音，分词器自带词典，多音字按上下文选音。
struct ChineseReadingProvider: ReadingProvider {
    let localeIdentifier = "zh_CN"

    func runs(forToken token: String, transcription: String?) -> [ReadingRun] {
        guard ReadingLanguageDetector.containsHan(token),
            let pinyin = transcription?.trimmingCharacters(in: .whitespaces),
            !pinyin.isEmpty, pinyin != token, Self.looksLikePinyin(pinyin)
        else { return [ReadingRun(text: token)] }
        return [ReadingRun(text: token, reading: pinyin)]
    }

    /// 只接受拉丁字母（含声调符号）与分隔符。转写里若残留汉字/假名，说明没转成功。
    static func looksLikePinyin(_ text: String) -> Bool {
        guard !ReadingLanguageDetector.containsHan(text),
            !ReadingLanguageDetector.containsKana(text)
        else { return false }
        let separators = CharacterSet(charactersIn: " '·-")
        var hasLetter = false
        for scalar in text.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                hasLetter = true
            } else if !separators.contains(scalar) {
                return false
            }
        }
        return hasLetter
    }
}
