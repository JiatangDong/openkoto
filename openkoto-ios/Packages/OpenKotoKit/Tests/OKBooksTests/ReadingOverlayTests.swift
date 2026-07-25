import Foundation
import OKModels
import Testing

@testable import OKBooks

/// 读音叠加：高置信来源盖低置信来源，且**任何情况下都不能改写正文**。
@Suite struct ReadingOverlayTests {
    private func rendered(_ runs: [ReadingRun]) -> String {
        runs.map { run in run.reading.map { "\(run.text)(\($0))" } ?? run.text }.joined()
    }

    private let base = [
        ReadingRun(text: "仰向", reading: "あおぐむき"),  // 离线注音器的已知错误
        ReadingRun(text: "に"),
        ReadingRun(text: "寝", reading: "ね"),
        ReadingRun(text: "た"),
    ]

    @Test func overridesWrongOfflineReading() {
        let fixed = ReadingOverlay.apply(
            [.init(start: 0, length: 2, reading: "あおむけ")], to: base)
        #expect(rendered(fixed) == "仰向(あおむけ)に寝(ね)た")
        #expect(fixed.plainText == "仰向に寝た")
    }

    /// 覆盖段与底层 run 交叠（只盖了半个词）时，剩下那半截必须**丢掉读音**——
    /// 半个词配整串读音是错的。
    @Test func dropsReadingOfPartiallyCoveredRun() {
        let overlaid = ReadingOverlay.apply(
            [.init(start: 1, length: 2, reading: "むけに")], to: base)
        #expect(overlaid.plainText == "仰向に寝た")
        #expect(rendered(overlaid) == "仰向に(むけに)寝(ね)た")
    }

    /// 重叠的覆盖段只认第一个（同起点取长的），不能产出两份读音。
    @Test func discardsOverlappingSpans() {
        let overlaid = ReadingOverlay.apply(
            [
                .init(start: 0, length: 1, reading: "あお"),
                .init(start: 0, length: 2, reading: "あおむけ"),
                .init(start: 1, length: 2, reading: "むけに"),
            ], to: base)
        #expect(rendered(overlaid) == "仰向(あおむけ)に寝(ね)た")
    }

    @Test func ignoresOutOfRangeSpans() {
        let overlaid = ReadingOverlay.apply(
            [.init(start: 99, length: 3, reading: "x"), .init(start: 3, length: 99, reading: "ねた")],
            to: base)
        #expect(overlaid.plainText == "仰向に寝た")
    }

    @Test func emptySpansLeaveBaseUntouched() {
        #expect(ReadingOverlay.apply([], to: base) == base)
    }

    /// 从带读音的 runs 反向提取 span（原书 ruby 走这条路）。
    @Test func extractsSpansFromRuns() {
        let spans = ReadingOverlay.spans(of: base)
        #expect(spans == [.init(start: 0, length: 2, reading: "あおぐむき"),
                          .init(start: 3, length: 1, reading: "ね")])
    }

    /// 未注音的底层（英语等语种判不出来时）也能被生词读音盖上。
    @Test func annotatesPlainBaseFromVocabularyOnly() {
        let plain = [ReadingRun(text: "Although thorough")]
        let overlaid = ReadingOverlay.apply(
            [.init(start: 9, length: 8, reading: "ˈθʌrə")], to: plain)
        #expect(rendered(overlaid) == "Although thorough(ˈθʌrə)")
    }
}

/// 生词表定位：AI 只给词形不给位置，得自己找回原句。
@Suite struct VocabularyReadingMatcherTests {
    private func spans(_ entries: [(String, String)], _ text: String) -> [ReadingOverlay.Span] {
        VocabularyReadingMatcher.spans(
            for: entries.map { .init(word: $0.0, reading: $0.1) }, in: text)
    }

    @Test func matchesWordsInOrder() {
        let result = spans([("声", "こえ"), ("夜", "よる")], "夜に君の声が")
        #expect(result == [.init(start: 0, length: 1, reading: "よる"),
                           .init(start: 4, length: 1, reading: "こえ")])
    }

    /// 同起点取更长的词：「行长」不能被「行」抢走。
    @Test func prefersLongerWordAtSameStart() {
        let result = spans([("行", "xíng"), ("行长", "hángzhǎng")], "行长说")
        #expect(result == [.init(start: 0, length: 2, reading: "hángzhǎng")])
    }

    /// 每个词条只用一次：同一个词第二次出现不再标注。
    @Test func usesEachEntryOnce() {
        let result = spans([("夜", "よる")], "夜に夜を")
        #expect(result.count == 1)
        #expect(result[0].start == 0)
    }

    /// AI 常给词典形而原文是活用形，找不到就静默丢弃，不能瞎标。
    @Test func silentlyDropsUnmatchedEntries() {
        #expect(spans([("駆ける", "かける")], "駆けた").isEmpty)
    }

    @Test func skipsEmptyOrIdenticalEntries() {
        #expect(spans([("", "よる"), ("夜", ""), ("夜", "夜")], "夜に").isEmpty)
    }
}
