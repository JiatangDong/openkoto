import Foundation
import Testing

@testable import OKSegmentation

/// 语言无关分词的黄金用例。
///
/// 这组测试锁死的是"词表能不能用"：它此前想复用注音器，但注音器只认日中，
/// 对英语等语种返回整句一个 run —— 词表会只有一项。
@Suite struct WordTokenizerTests {
    private func words(_ text: String, _ locale: String? = nil) -> [String] {
        WordTokenizer.tokenize(text, locale: locale).map(\.text)
    }

    // MARK: - 不变式：range 必须能定位回原文

    /// 每个 token 的标量区间切出来必须等于它自己的文本。这是词表能高亮原句的前提。
    @Test(arguments: [
        "Although thorough, it wasn't enough.",
        "L'homme qu'il a vu n'était pas là.",
        "これは日本語の字幕です。",
        "银行行长说这首歌的长度不够。",
        "한국어를 공부하고 있습니다.",
        "Mixed 混在 text テキスト 123.",
    ])
    func rangesLocateBackIntoSource(_ text: String) {
        let scalars = Array(text.unicodeScalars)
        for token in WordTokenizer.tokenize(text) {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[token.range])
            #expect(String(view) == token.text)
        }
    }

    /// token 必须按出现顺序、互不重叠。
    @Test func tokensAreOrderedAndDisjoint() {
        let tokens = WordTokenizer.tokenize("これは日本語の字幕です。")
        for (previous, next) in zip(tokens, tokens.dropFirst()) {
            #expect(previous.range.upperBound <= next.range.lowerBound)
        }
    }

    // MARK: - 各语种的切分质量

    /// 法语的 elision 不能被切开——`L'homme` 是一个词，切成 `L` + `homme` 就查不了了。
    @Test func keepsFrenchElisionIntact() {
        let result = words("L'homme qu'il a vu n'était pas là.", "fr_FR")
        #expect(result.contains("L'homme"))
        #expect(result.contains("qu'il"))
        #expect(result.contains("n'était"))
    }

    /// 德语复合词保持完整（查词要查整个词）。
    @Test func keepsGermanCompoundIntact() {
        #expect(
            words("Die Geschwindigkeitsbegrenzung gilt.", "de_DE")
                .contains("Geschwindigkeitsbegrenzung"))
    }

    @Test func keepsEnglishContractionIntact() {
        #expect(words("it wasn't enough", "en_US").contains("wasn't"))
    }

    /// 无空格文字按词切，不是按字切。
    @Test func splitsCJKIntoWords() {
        #expect(words("これは日本語の字幕です。", "ja_JP").contains("字幕"))
        let chinese = words("银行行长说这首歌的长度不够。", "zh_CN")
        #expect(chinese.contains("银行"))
        #expect(chinese.contains("长度"))
    }

    @Test func splitsKoreanBySpaces() {
        #expect(words("한국어를 공부하고 있습니다.", "ko_KR").contains("공부하고"))
    }

    /// **不传 locale 也要准**——语种判不出来时不必降级，这是方案能成立的关键。
    @Test func worksWithoutLocaleHint() {
        #expect(words("L'homme qu'il a vu").contains("L'homme"))
        #expect(words("これは日本語の字幕です。").contains("字幕"))
        #expect(words("한국어를 공부하고 있습니다.").contains("공부하고"))
    }

    // MARK: - 候选过滤

    /// 词表里不该出现标点、空白、纯数字——点了也没有释义可给。
    @Test func lookupCandidatesDropNoise() {
        let candidates = WordTokenizer.lookupCandidates("これは、日本語です。123 ABC")
            .map(\.text)
        #expect(!candidates.contains("、"))
        #expect(!candidates.contains("。"))
        #expect(!candidates.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }))
        #expect(!candidates.contains("123"))
        #expect(candidates.contains("ABC"))
        #expect(candidates.contains("日本"))
    }

    @Test func classifiesIndividualTokens() {
        #expect(WordTokenizer.isWorthLookingUp("字幕"))
        #expect(WordTokenizer.isWorthLookingUp("thorough"))
        #expect(!WordTokenizer.isWorthLookingUp("。"))
        #expect(!WordTokenizer.isWorthLookingUp("  "))
        #expect(!WordTokenizer.isWorthLookingUp("42"))
        #expect(!WordTokenizer.isWorthLookingUp("１２３"))
    }

    @Test func handlesEmptyInput() {
        #expect(WordTokenizer.tokenize("").isEmpty)
        #expect(WordTokenizer.lookupCandidates("   ").isEmpty)
    }
}
