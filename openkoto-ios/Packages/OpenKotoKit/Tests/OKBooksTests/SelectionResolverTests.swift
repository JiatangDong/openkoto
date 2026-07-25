import Foundation
import OKModels
import Testing

@testable import OKBooks

/// 原版模式划词 → 句子的映射。
/// 这是"原版模式仍然能学习"的关键：映射失败就只剩翻页器了。
@Suite struct SelectionResolverTests {
    private let articleID = UUID()

    private func segments(_ texts: [String]) -> [ArticleSegment] {
        texts.enumerated().map { index, text in
            ArticleSegment(articleId: articleID, order: index, text: text)
        }
    }

    @Test func matchesWholeSentence() throws {
        let list = segments(["吾輩は猫である。", "名前はまだ無い。"])
        let match = try #require(SelectionResolver.resolve(selection: "名前はまだ無い。", in: list))
        #expect(match.segmentID == list[1].id)
        #expect(match.order == 1)
        #expect(match.range == 0..<8)
    }

    @Test func matchesPartialSelectionInsideSentence() throws {
        let list = segments(["吾輩は猫である。", "名前はまだ無い。"])
        let match = try #require(SelectionResolver.resolve(selection: "猫である", in: list))
        #expect(match.segmentID == list[0].id)
        #expect(match.range == 3..<7)
    }

    /// WebView 的选区会带上排版换行和 NBSP，归一化后才对得上。
    @Test func normalizesWhitespaceAndInvisibles() throws {
        let list = segments(["I am a cat. As yet I have no name."])
        let selection = "As yet\n   I have\u{00A0}no name."
        let match = try #require(SelectionResolver.resolve(selection: selection, in: list))
        #expect(match.segmentID == list[0].id)
    }

    /// 跨句选择：取被覆盖最多的那一句——用户点"精讲"时讲整句最有用。
    @Test func picksLongestCoveredSentenceForCrossSentenceSelection() throws {
        let list = segments(["短句。", "这是一个明显更长的句子内容。"])
        let selection = "短句。这是一个明显更长的句子内容。"
        let match = try #require(SelectionResolver.resolve(selection: selection, in: list))
        #expect(match.segmentID == list[1].id)
        // 跨句时不给句内区间。
        #expect(match.range == nil)
    }

    @Test func returnsNilWhenNothingMatches() {
        let list = segments(["吾輩は猫である。"])
        #expect(SelectionResolver.resolve(selection: "完全无关的文字", in: list) == nil)
        #expect(SelectionResolver.resolve(selection: "", in: list) == nil)
        #expect(SelectionResolver.resolve(selection: "   \n  ", in: list) == nil)
        #expect(SelectionResolver.resolve(selection: "任意", in: []) == nil)
    }

    /// 重复出现的短词落在第一处即可——精讲的是句子，不是词的具体位置。
    @Test func resolvesRepeatedShortSelectionDeterministically() throws {
        let list = segments(["猫がいる。", "猫は寝ている。"])
        let match = try #require(SelectionResolver.resolve(selection: "猫", in: list))
        #expect(match.order == 0)
    }
}
