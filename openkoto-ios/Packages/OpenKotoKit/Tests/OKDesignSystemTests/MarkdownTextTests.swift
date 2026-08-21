import Foundation
import Testing
@testable import OKDesignSystem

/// 精讲 Markdown 的块级切分。AI 会照 prompt 要求吐 `**粗体**`、`- 列表`、`### 小标题`，
/// 以前这些原样显示在界面上。
@Suite struct MarkdownTextTests {

    @Test func parsesBoldParagraph() {
        #expect(MarkdownBlock.parse("这里是**重点**内容") == [.paragraph("这里是**重点**内容")])
    }

    @Test func blankLineSplitsParagraphs() {
        let blocks = MarkdownBlock.parse("第一段\n\n第二段")
        #expect(blocks == [.paragraph("第一段"), .paragraph("第二段")])
    }

    @Test func softNewlinesStayInsideOneParagraph() {
        let blocks = MarkdownBlock.parse("第一行\n第二行")
        #expect(blocks == [.paragraph("第一行\n第二行")])
    }

    @Test func parsesHeadings() {
        let blocks = MarkdownBlock.parse("# 一级\n### 三级")
        #expect(blocks == [.heading(level: 1, text: "一级"), .heading(level: 3, text: "三级")])
    }

    /// "#东京" 是话题标签，不是标题 —— ATX 标题的 # 后必须有空格。
    @Test func hashWithoutSpaceIsNotHeading() {
        #expect(MarkdownBlock.parse("#东京 の朝") == [.paragraph("#东京 の朝")])
    }

    @Test func parsesBulletList() {
        let blocks = MarkdownBlock.parse("- 第一点\n* 第二点\n+ 第三点")
        #expect(blocks == [
            .listItem(marker: "•", text: "第一点", depth: 0),
            .listItem(marker: "•", text: "第二点", depth: 0),
            .listItem(marker: "•", text: "第三点", depth: 0),
        ])
    }

    @Test func parsesOrderedListAndKeepsNumber() {
        let blocks = MarkdownBlock.parse("1. 先这样\n2) 再那样")
        #expect(blocks == [
            .listItem(marker: "1.", text: "先这样", depth: 0),
            .listItem(marker: "2.", text: "再那样", depth: 0),
        ])
    }

    @Test func indentedListItemGetsDepth() {
        let blocks = MarkdownBlock.parse("- 外层\n    - 内层")
        #expect(blocks == [
            .listItem(marker: "•", text: "外层", depth: 0),
            .listItem(marker: "•", text: "内层", depth: 2),
        ])
    }

    /// 分隔线判定必须排在列表之前，否则 "---" 会变成一个空的列表项。
    @Test func dashRuleIsDividerNotListItem() {
        #expect(MarkdownBlock.parse("上\n\n---\n\n下")
            == [.paragraph("上"), .divider, .paragraph("下")])
    }

    @Test func parsesQuote() {
        #expect(MarkdownBlock.parse("> 引用一句") == [.quote("引用一句")])
    }

    @Test func parsesFencedCode() {
        let blocks = MarkdownBlock.parse("说明：\n```\nlet a = 1\n```\n完")
        #expect(blocks == [.paragraph("说明："), .code("let a = 1"), .paragraph("完")])
    }

    /// 模型偶尔忘了闭合围栏——剩下的内容不能被整段吞掉。
    @Test func unclosedFenceStillYieldsCode() {
        let blocks = MarkdownBlock.parse("```\nlet a = 1")
        #expect(blocks == [.code("let a = 1")])
    }

    @Test func emptyInputYieldsNoBlocks() {
        #expect(MarkdownBlock.parse("").isEmpty)
        #expect(MarkdownBlock.parse("\n\n  \n").isEmpty)
    }

    // MARK: - 行内

    @Test func inlineBoldIsStrippedFromRenderedText() {
        let attributed = MarkdownInline.attributed("这里是**重点**内容")
        // 渲染后不该还留着星号；粗体走 attribute，不走字面量。
        #expect(String(attributed.characters) == "这里是重点内容")
    }

    @Test func inlineCodeAndItalicAreParsed() {
        #expect(String(MarkdownInline.attributed("用 `let` 声明").characters) == "用 let 声明")
        #expect(String(MarkdownInline.attributed("*轻声*说").characters) == "轻声说")
    }

    /// 半个链接不该让整段消失。
    @Test func malformedMarkdownFallsBackToPlainText() {
        let broken = "看这里 [标题](http://"
        #expect(!String(MarkdownInline.attributed(broken).characters).isEmpty)
    }
}
