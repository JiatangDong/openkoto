import Foundation
import Testing

@testable import OKBooks

@Suite struct ChapterSplitterTests {
    private func body(_ marker: String, paragraphs: Int = 30) -> String {
        (0..<paragraphs)
            .map { "\(marker)的第\($0)段正文，写了一些无关紧要但足够长的句子来凑字数。这里再补一句。" }
            .joined(separator: "\n")
    }

    private func novel(headings: [String], paragraphs: Int = 30) -> String {
        headings.map { "\($0)\n\(body($0, paragraphs: paragraphs))" }.joined(separator: "\n")
    }

    /// 分章逻辑本身与"多长才算一本书"无关，测试里把门槛调低，
    /// 免得每个用例都要堆两万字。门槛本身另有专门用例覆盖。
    private var lowThreshold: ChapterSplitter.Options {
        var options = ChapterSplitter.Options()
        options.minBookChars = 200
        return options
    }

    // MARK: - 标题识别

    @Test(arguments: [
        "第一章", "第1章", "第十二回", "第３話", "第二卷", "序章", "楔子", "尾声",
        "Chapter 1", "CHAPTER IV", "Ch. 3", "プロローグ", "第一章 风起", "終章",
    ])
    func recognizesHeadings(line: String) {
        #expect(ChapterSplitter.isHeading(line))
    }

    /// 关键的假阳性：正文里提到章节名不能被当成标题。
    @Test(arguments: [
        "他翻开书，第三章说的是关于猫的事情，读起来颇为有趣，于是他继续读了下去。",
        "这一段里出现了 Chapter 1 这样的字样但它其实是正文的一部分而且很长很长。",
        "",
        "    ",
        "第章",
        "序幕拉开之后的故事非常漫长，这一行明显不是标题因为它实在太长了。",
    ])
    func rejectsNonHeadings(line: String) {
        #expect(ChapterSplitter.isHeading(line) == false)
    }

    // MARK: - 分章

    @Test func splitsChineseNovelByChapterHeadings() {
        let text = novel(headings: ["第一章 开端", "第二章 发展", "第三章 结局"])
        let chapters = ChapterSplitter.split(text, options: lowThreshold)
        #expect(chapters.map(\.title) == ["第一章 开端", "第二章 发展", "第三章 结局"])
        // 每章正文以自己的标题行开头，内容不串。
        #expect(chapters[1].rawText.hasPrefix("第二章 发展"))
        #expect(chapters[1].rawText.contains("第二章 发展的第0段"))
        #expect(chapters[1].rawText.contains("第三章") == false)
    }

    @Test func splitsJapaneseNovelByEpisodeHeadings() {
        let text = novel(headings: ["第一話", "第二話", "第三話"])
        #expect(
            ChapterSplitter.split(text, options: lowThreshold).map(\.title)
                == ["第一話", "第二話", "第三話"])
    }

    @Test func splitsEnglishNovelByChapterHeadings() {
        let text = novel(headings: ["Chapter 1", "Chapter 2", "Chapter 3"])
        #expect(
            ChapterSplitter.split(text, options: lowThreshold).map(\.title)
                == ["Chapter 1", "Chapter 2", "Chapter 3"])
    }

    /// 第一个标题之前的书名/作者信息要单独成章，不能丢。
    @Test func keepsPrefaceBeforeFirstHeading() {
        let text = "《测试小说》\n作者：某人\n\n" + novel(headings: ["第一章", "第二章"])
        let chapters = ChapterSplitter.split(text, options: lowThreshold)
        #expect(chapters.count == 3)
        #expect(chapters[0].title == "《测试小说》")
        #expect(chapters[0].rawText.contains("作者：某人"))
        #expect(chapters[1].title == "第一章")
    }

    // MARK: - 兜底

    /// 只有一处标题（不到 minHeadings）时不算分章成功，退回分块。
    @Test func chunksWhenTooFewHeadings() {
        let text = "第一章\n" + body("只有一个标题", paragraphs: 400)
        let chapters = ChapterSplitter.split(text, options: lowThreshold)
        #expect(chapters.count > 1)
    }

    /// 没有任何标题的长文本也必须能读——按块切，标题取块首行。
    @Test func chunksNovelWithoutHeadings() {
        let text = body("无标题", paragraphs: 400)
        let chapters = ChapterSplitter.split(text, options: lowThreshold)
        #expect(chapters.count > 1)
        #expect(chapters.allSatisfy { !$0.title.isEmpty })
        // 不丢字：各块拼回去应覆盖全文长度（分隔符差异忽略）。
        let total = chapters.map(\.rawText.count).reduce(0, +)
        #expect(total >= text.count - chapters.count)
    }

    /// 只匹配到"序"和"后记"这类零星标题、导致某章巨大时，应整体退回分块。
    @Test func fallsBackToChunkingWhenChapterTooLarge() {
        let huge = body("超长", paragraphs: 3_000)
        let text = "序\n\(huge)\n后记\n结束语"
        let chapters = ChapterSplitter.split(text)
        #expect(chapters.count > 2)
        #expect(chapters.allSatisfy { $0.rawText.count <= 60_000 })
    }

    @Test func returnsEmptyForShortText() {
        #expect(ChapterSplitter.split("第一章\n很短的内容。").isEmpty)
        #expect(ChapterSplitter.split("").isEmpty)
    }

    @Test func honorsCustomMinimumBookSize() {
        var options = ChapterSplitter.Options()
        options.minBookChars = 10
        let chapters = ChapterSplitter.split("第一章\n甲乙丙丁戊己庚辛\n第二章\n壬癸", options: options)
        #expect(chapters.map(\.title) == ["第一章", "第二章"])
    }

    @Test func truncatesLongDerivedTitles() {
        let line = String(repeating: "长", count: 50)
        #expect(ChapterSplitter.title(from: line).count == 31)
        #expect(ChapterSplitter.title(from: line).hasSuffix("…"))
    }
}
