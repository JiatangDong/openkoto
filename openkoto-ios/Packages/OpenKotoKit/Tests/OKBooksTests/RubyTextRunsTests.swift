import Foundation
import OKModels
import Testing

@testable import OKBooks

/// 原书自带振假名的 run 还原：切句之后仍能说清「哪几个字对应哪个读音」。
///
/// `readingLines` 把它压平成一整行字符串（阅读页的整句注音行用），
/// `runs(forSentencesIn:)` 保留边界（词级 ruby 用）。两者必须描述同一件事。
@Suite struct RubyTextRunsTests {
    private func rendered(_ runs: [ReadingRun]?) -> String {
        (runs ?? []).map { run in run.reading.map { "\(run.text)(\($0))" } ?? run.text }.joined()
    }

    @Test func restoresRunBoundariesFromAozora() {
        let ruby = AozoraParser.parse("｜吾輩《わがはい》は猫である。名前はまだ｜無《な》い。")
        let sentences = ["吾輩は猫である。", "名前はまだ無い。"]
        let runs = ruby.runs(forSentencesIn: sentences)

        #expect(rendered(runs[0]) == "吾輩(わがはい)は猫である。")
        #expect(rendered(runs[1]) == "名前はまだ無(な)い。")
        // 正文一个字都不能改
        for (index, sentence) in sentences.enumerated() {
            #expect((runs[index] ?? []).plainText == sentence)
        }
    }

    @Test func restoresRunBoundariesFromEPUBRuby() {
        let ruby = XHTMLTextExtractor.extract(
            xhtml: "<p><ruby>漢字<rt>かんじ</rt></ruby>を読む。</p>")
        let runs = ruby.runs(forSentencesIn: ["漢字を読む。"])
        #expect(rendered(runs[0]) == "漢字(かんじ)を読む。")
    }

    /// 没有任何注音的句子返回 nil——与 `readingLines` 的约定一致，
    /// 调用方据此判断"这一句没有原书读音"，好退回离线注音。
    @Test func returnsNilForSentencesWithoutRuby() {
        let ruby = AozoraParser.parse("｜吾輩《わがはい》は猫である。名前はまだ無い。")
        let runs = ruby.runs(forSentencesIn: ["吾輩は猫である。", "名前はまだ無い。"])
        #expect(runs[0] != nil)
        #expect(runs[1] == nil)
    }

    @Test func returnsAllNilWhenTextHasNoRubyAtAll() {
        let runs = RubyText(plainText: "普通の文章です。").runs(forSentencesIn: ["普通の文章です。"])
        #expect(runs == [nil])
    }

    /// 与压平版本描述的是同一件事：把 runs 里的读音替换进去应等于 readingLines。
    @Test func agreesWithFlattenedReadingLines() {
        let ruby = AozoraParser.parse("｜吾輩《わがはい》は｜猫《ねこ》である。")
        let sentences = ["吾輩は猫である。"]
        let flattened = ruby.readingLines(forSentencesIn: sentences)[0]
        let recomposed = (ruby.runs(forSentencesIn: sentences)[0] ?? [])
            .map { $0.reading ?? $0.text }.joined()
        #expect(flattened == recomposed)
    }
}
