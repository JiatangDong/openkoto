import Foundation
import Testing
@testable import OKAIClient

/// 导入素材 AI 清洗的纯逻辑测试（分批 / 预览截断 / 按行号装配）。
/// 联网那一段不测——这里要守住的是"留下来的行必须与原文逐字一致"。
@Suite struct WebContentCleanerTests {

    // MARK: - 送审预览

    @Test func shortLineIsTrimmedNotTruncated() {
        #expect(WebContentCleaner.linePreview("  首页 登录 注册  ") == "首页 登录 注册")
    }

    @Test func longLineIsTruncatedWithRealLength() {
        let long = String(repeating: "あ", count: WebContentCleaner.previewChars + 50)
        let preview = WebContentCleaner.linePreview(long)
        #expect(preview.hasSuffix("(len=\(WebContentCleaner.previewChars + 50))"))
        // 截断只影响送审文本；原文不参与，故装配时行内容不受影响。
        #expect(preview.count < long.count)
    }

    // MARK: - 分批

    @Test func splitsByLineBudget() {
        let candidates = (0..<(WebContentCleaner.batchLines * 2 + 5)).map {
            (index: $0, preview: "line")
        }
        let batches = WebContentCleaner.splitBatches(candidates)
        #expect(batches.count == 3)
        #expect(batches.allSatisfy { $0.count <= WebContentCleaner.batchLines })
        // 不能丢行：行号丢了就等于那一行永远没被审过。
        #expect(batches.flatMap { $0 }.map(\.index) == candidates.map(\.index))
    }

    @Test func splitsByCharBudget() {
        let long = String(repeating: "x", count: WebContentCleaner.previewChars)
        let candidates = (0..<(WebContentCleaner.batchLines / 2)).map {
            (index: $0, preview: long)
        }
        let batches = WebContentCleaner.splitBatches(candidates)
        #expect(batches.count > 1)
        for batch in batches {
            let chars = batch.reduce(0) { $0 + $1.preview.count + 8 }
            #expect(chars <= WebContentCleaner.batchChars + WebContentCleaner.previewChars + 8)
        }
    }

    @Test func emptyInputProducesNoBatches() {
        #expect(WebContentCleaner.splitBatches([]).isEmpty)
    }

    // MARK: - 装配

    @Test func keepsSurvivingLinesVerbatim() throws {
        let content = """
            首页 登录 注册
            春はあけぼの。やうやう白くなりゆく山ぎは。
            广告：立即订阅
            すこしあかりて、紫だちたる雲のほそくたなびきたる。
            """
        let result = try WebContentCleaner.assemble(
            content: content, dropping: [0, 2], suggestedTitle: nil, fallbackTitle: "枕草子",
            partial: false)

        #expect(result.content == """
            春はあけぼの。やうやう白くなりゆく山ぎは。
            すこしあかりて、紫だちたる雲のほそくたなびきたる。
            """)
        #expect(result.removedLines == 2)
        #expect(result.keptLines == 2)
        #expect(result.title == "枕草子")
    }

    @Test func modelTitleWinsOverFetchedTitle() throws {
        let content = String(repeating: "正文一行。\n", count: 5)
        let result = try WebContentCleaner.assemble(
            content: content, dropping: [], suggestedTitle: "  干净标题  ",
            fallbackTitle: "网页原标题 - 某站", partial: false)
        #expect(result.title == "干净标题")
    }

    @Test func blankModelTitleFallsBackToFetchedTitle() throws {
        let content = String(repeating: "正文一行。\n", count: 5)
        let result = try WebContentCleaner.assemble(
            content: content, dropping: [], suggestedTitle: "   ",
            fallbackTitle: "网页原标题", partial: false)
        #expect(result.title == "网页原标题")
    }

    @Test func collapsesBlankRunsLeftBehindByRemovedBlocks() throws {
        let content = "正文第一段，够长了。\n\n导航\n推荐\n\n正文第二段，也够长。"
        let result = try WebContentCleaner.assemble(
            content: content, dropping: [2, 3], suggestedTitle: nil, fallbackTitle: nil,
            partial: false)
        #expect(result.content == "正文第一段，够长了。\n\n正文第二段，也够长。")
    }

    /// CRLF 网页必须照样按行切开。Swift 里 `"\r\n"` 是**一个** Character，
    /// `split(separator: "\n")` 一刀都切不下去——整篇会变成一行，清洗直接失效。
    @Test func splitsCRLFDocumentIntoLines() {
        let lines = WebContentCleaner.splitLines("一\r\n二\r\n\r\n三")
        #expect(lines == ["一", "二", "", "三"])
    }

    @Test func splitsLoneCarriageReturnsToo() {
        #expect(WebContentCleaner.splitLines("一\r二\n三") == ["一", "二", "三"])
    }

    /// 装配也走同一套切分，行号才对得上；行尾统一归一化成 \n（与桌面一致）。
    @Test func assemblesCRLFContentByLineNumber() throws {
        let content = "正文第一段，够长了。\r\n\r\n导航\r\n推荐\r\n\r\n正文第二段，也够长。"
        let result = try WebContentCleaner.assemble(
            content: content, dropping: [2, 3], suggestedTitle: nil, fallbackTitle: nil,
            partial: false)
        #expect(result.content == "正文第一段，够长了。\n\n正文第二段，也够长。")
        #expect(result.removedLines == 2)
    }

    /// 模型删过头时必须报错，让调用方退回原文——静默交出一篇空文章最糟。
    @Test func rejectsOverAggressiveCleaning() {
        let content = "第一行正文内容。\n第二行正文内容。"
        #expect(throws: WebContentCleaner.CleanError.tooShort) {
            try WebContentCleaner.assemble(
                content: content, dropping: [0, 1], suggestedTitle: nil, fallbackTitle: nil,
                partial: false)
        }
    }

    /// 越界行号是模型幻觉出来的，忽略即可，不能连累整批。
    @Test func ignoresOutOfRangeDropIndices() throws {
        let content = "正文第一行，长度足够留下来。\n正文第二行，会被删掉。"
        let result = try WebContentCleaner.assemble(
            content: content, dropping: [99, 1], suggestedTitle: nil, fallbackTitle: nil,
            partial: false)
        #expect(result.content == "正文第一行，长度足够留下来。")
        #expect(result.removedLines == 1)
    }
}
