import CoreText
import Foundation
import Testing

@testable import OKDesignSystem

/// CoreText 振假名排版的度量契约。
///
/// 这些断言存在的理由：TextKit/UILabel 也能*画*出 ruby，但**高度算不对**
/// （多行会上下相撞、注音溢出边框）。下面第一条就是区分两者的判据——
/// 若哪天有人把实现换回 UILabel，它会立刻挂。
@Suite struct RubyTypesetterTests {
    private let fontSize: CGFloat = 24

    private func attributed(_ runs: [RubyRun]) -> NSAttributedString {
        RubyTypesetter.attributed(
            runs: runs,
            font: RubyTypesetter.systemFont(ofSize: fontSize),
            color: CGColor(gray: 0, alpha: 1),
            rubyColor: CGColor(gray: 0.5, alpha: 1))
    }

    /// 注音会把行的 ascent 抬高，抬高量约等于 字号 × sizeFactor。
    @Test func rubyIncreasesLineAscent() {
        let plain = RubyTypesetter.layout(attributed([RubyRun(text: "漢字です")]), maxWidth: nil)
        let ruby = RubyTypesetter.layout(
            attributed([RubyRun(text: "漢字", reading: "かんじ"), RubyRun(text: "です")]),
            maxWidth: nil)

        #expect(ruby.size.height > plain.size.height)
        let grew = ruby.size.height - plain.size.height
        #expect(abs(grew - fontSize * RubyTypesetter.sizeFactor) <= 2)
    }

    /// 注音比基文宽时，CoreText 会撑宽基文——这是纯 SwiftUI 逐词方案做不到的，
    /// 也是注音不会压到相邻字上的根本保证。
    @Test func wideReadingWidensBaseText() {
        let plain = RubyTypesetter.layout(attributed([RubyRun(text: "私")]), maxWidth: nil)
        let ruby = RubyTypesetter.layout(
            attributed([RubyRun(text: "私", reading: "わたくし")]), maxWidth: nil)
        #expect(ruby.size.width > plain.size.width)
    }

    /// 窄注音不撑宽。
    @Test func narrowReadingDoesNotWidenBaseText() {
        let plain = RubyTypesetter.layout(attributed([RubyRun(text: "薔薇")]), maxWidth: nil)
        let ruby = RubyTypesetter.layout(
            attributed([RubyRun(text: "薔薇", reading: "ばら")]), maxWidth: nil)
        #expect(abs(ruby.size.width - plain.size.width) <= 1)
    }

    /// 折行后**每一行**都必须保留注音高度，否则第二行的注音会撞到第一行的正文上。
    ///
    /// 这正是 TextKit/UILabel 挂掉的地方：它按基础字号 × 行数算高度，
    /// 于是每行高度等于无注音的行高。这里断言的是「明显高于无注音行高」。
    @Test func wrappingKeepsRubyHeightOnEveryLine() {
        let runs = (0..<8).flatMap { _ in
            [RubyRun(text: "漢字", reading: "かんじ"), RubyRun(text: "です")]
        }
        let single = RubyTypesetter.layout(attributed(runs), maxWidth: nil)
        let wrapped = RubyTypesetter.layout(attributed(runs), maxWidth: single.size.width / 3)
        let plainLineHeight = RubyTypesetter.layout(
            attributed([RubyRun(text: "漢字です")]), maxWidth: nil
        ).size.height

        #expect(wrapped.lines.count >= 3)
        #expect(wrapped.size.width <= single.size.width / 3 + 1)

        let wrappedLineHeight = wrapped.size.height / CGFloat(wrapped.lines.count)
        #expect(wrappedLineHeight >= plainLineHeight * 1.25)
    }

    /// 不限宽时返回的是内容自然宽度，不是提议宽度——`FlowLayout` 靠它决定要不要限宽重问。
    @Test func unboundedLayoutReturnsNaturalWidth() {
        let layout = RubyTypesetter.layout(attributed([RubyRun(text: "短い")]), maxWidth: nil)
        #expect(layout.size.width > 0)
        #expect(layout.size.width < 200)
        #expect(layout.lines.count == 1)
    }

    /// 极窄宽度不能死循环（CTTypesetterSuggestLineBreak 会返回 0）。
    @Test func absurdlyNarrowWidthTerminates() {
        let layout = RubyTypesetter.layout(
            attributed([RubyRun(text: "漢字", reading: "かんじ")]), maxWidth: 1)
        #expect(layout.lines.count == 2)
    }

    @Test func emptyRunsProduceEmptyLayout() {
        let layout = RubyTypesetter.layout(attributed([]), maxWidth: 100)
        #expect(layout.size == .zero)
        #expect(layout.lines.isEmpty)
    }
}
