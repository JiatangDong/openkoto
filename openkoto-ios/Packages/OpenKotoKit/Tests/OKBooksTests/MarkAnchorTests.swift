import Foundation
import OKModels
import Testing

@testable import OKBooks

/// 书签重锚。核心要求：句序可以漂，标记不能丢。
@Suite struct MarkAnchorTests {
    private let bookID = UUID()
    private let articleID = UUID()

    private func segments(_ texts: [String]) -> [ArticleSegment] {
        texts.enumerated().map { index, text in
            ArticleSegment(articleId: articleID, order: index, text: text)
        }
    }

    private func mark(
        order: Int? = nil, text: String? = nil, fraction: Double? = nil,
        kind: BookMark.Kind = .highlight
    ) -> BookMark {
        BookMark(
            bookId: bookID, chapterIndex: 0, kind: kind,
            segmentOrder: order, scrollFraction: fraction, selectedText: text)
    }

    @Test func usesSegmentOrderWhenTextStillMatches() {
        let list = segments(["吾輩は猫である。", "名前はまだ無い。"])
        let resolution = MarkAnchor.resolve(mark(order: 1, text: "名前はまだ無い。"), in: list)
        #expect(resolution.segmentOrder == 1)
        #expect(resolution.range == 0..<8)
        #expect(resolution.isApproximate == false)
    }

    /// 重新切分后句序变了：靠保存的原文全章找回来。
    @Test func reanchorsByTextAfterResegmentation() {
        let list = segments(["新增的开头句。", "吾輩は猫である。", "名前はまだ無い。"])
        // 标记建立时"名前はまだ無い。"在第 1 句，重切后跑到了第 2 句。
        let resolution = MarkAnchor.resolve(mark(order: 1, text: "名前はまだ無い。"), in: list)
        #expect(resolution.segmentOrder == 2)
        #expect(resolution.isApproximate == false)
    }

    @Test func findsPartialTextInsideSentence() {
        let list = segments(["吾輩は猫である。"])
        let resolution = MarkAnchor.resolve(mark(order: 0, text: "猫である"), in: list)
        #expect(resolution.segmentOrder == 0)
        #expect(resolution.range == 3..<7)
    }

    /// 原文彻底找不到（书换了版本）：按比例落到大概位置，并标成近似。
    @Test func fallsBackToFractionAndFlagsApproximate() {
        let list = segments(["一。", "二。", "三。", "四。"])
        let resolution = MarkAnchor.resolve(
            mark(order: 99, text: "这段文字已经不存在了", fraction: 0.5), in: list)
        #expect(resolution.segmentOrder == 2)
        #expect(resolution.isApproximate)
    }

    /// 连比例都没有：夹到合法句序，仍然不丢标记。
    @Test func clampsOutOfRangeOrderWithoutFraction() {
        let list = segments(["一。", "二。"])
        let resolution = MarkAnchor.resolve(mark(order: 99, text: "找不到的文字"), in: list)
        #expect(resolution.segmentOrder == 1)
        #expect(resolution.isApproximate)
    }

    @Test func returnsNilForEmptyChapter() {
        let resolution = MarkAnchor.resolve(mark(order: 0, text: "任意"), in: [])
        #expect(resolution.segmentOrder == nil)
        #expect(resolution.isApproximate)
    }

    /// 原版模式建的标记只有 locator + 原文，切到原生模式要补上句序与比例。
    @Test func fillsCrossModeAnchors() {
        let list = segments(["吾輩は猫である。", "名前はまだ無い。"])
        var original = BookMark(
            bookId: bookID, chapterIndex: 0, kind: .highlight,
            locator: "OEBPS/ch1.xhtml#/2/4:0-/2/4:8", selectedText: "名前はまだ無い。")
        original.segmentOrder = nil
        original.scrollFraction = nil

        let filled = MarkAnchor.filledCrossModeAnchors(
            original, segments: list, segmentCount: list.count)
        #expect(filled.segmentOrder == 1)
        #expect(filled.charStart == 0)
        #expect(filled.charEnd == 8)
        #expect(filled.scrollFraction == 0.5)
        // 原版锚点保持不动。
        #expect(filled.locator == original.locator)
    }

    @Test func doesNotOverwriteExistingAnchors() {
        let list = segments(["一。", "二。"])
        let existing = BookMark(
            bookId: bookID, chapterIndex: 0, kind: .bookmark,
            segmentOrder: 0, charStart: 1, charEnd: 2, scrollFraction: 0.9,
            selectedText: "二。")
        let filled = MarkAnchor.filledCrossModeAnchors(
            existing, segments: list, segmentCount: list.count)
        #expect(filled.segmentOrder == 0)
        #expect(filled.charStart == 1)
        #expect(filled.scrollFraction == 0.9)
    }
}
