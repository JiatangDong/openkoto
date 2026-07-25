import Foundation
import OKModels
import OKTestSupport
import Testing

@testable import OKBooks

/// 大部头的时间与规模门槛。
///
/// 断言刻意留得很宽（只挡住数量级退化），精确数字打印出来供人看——
/// 在不同机器上跑同一套阈值必然变成 flaky 测试。
@Suite struct LargeBookPerformanceTests {
    /// 约 50 万字的中文小说，120 章。
    private func makeNovelText(chapters: Int = 120, paragraphsPerChapter: Int = 62) -> String {
        let paragraph =
            "他站在窗前望着远处的山影，心里想着那些早已模糊的往事，"
            + "风从半开的窗子里灌进来，把桌上的纸吹得沙沙作响。"  // ~52 字
        var lines: [String] = []
        for chapter in 1...chapters {
            lines.append("第\(chapter)章")
            for index in 0..<paragraphsPerChapter {
                lines.append("\(paragraph)这是第\(index)段。")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func withStorage<T>(_ body: (BookStorage) throws -> T) throws -> T {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("okbooks-perf-\(UUID().uuidString)")
        let storage = BookStorage(root: root)
        try storage.prepare()
        defer { try? FileManager.default.removeItem(at: root) }
        return try body(storage)
    }

    @Test func importsHalfMillionCharacterNovelQuickly() throws {
        let text = makeNovelText()
        #expect(text.count > 400_000)

        try withStorage { storage in
            let importer = BookImporter(storage: storage)
            let started = Date()
            let result = try #require(try importer.importText(text, title: "长篇测试"))
            let elapsed = Date().timeIntervalSince(started)

            print(
                "[perf] 导入 \(text.count) 字 / \(result.chapters.count) 章："
                    + String(format: "%.2fs", elapsed))
            #expect(result.chapters.count == 120)
            #expect(result.book.totalChars > 400_000)
            // 导入**不切句**，所以这里只有解码 + 分章 + 落盘的成本。
            #expect(elapsed < 10)
        }
    }

    /// 首开单章的切分成本——这是用户翻到新章时真正等待的那一下。
    @Test func segmentsSingleChapterFast() throws {
        let text = makeNovelText(chapters: 2)
        try withStorage { storage in
            // 只造 2 章，字数不到"成书"门槛，测试里显式调低。
            var options = ChapterSplitter.Options()
            options.minBookChars = 1_000
            let importer = BookImporter(storage: storage, splitterOptions: options)
            let result = try #require(try importer.importText(text, title: "长篇测试"))
            let chapter = result.chapters[0]
            let source = storage.directory(for: result.book.id)
                .appendingPathComponent(try #require(chapter.sourceHref))

            let started = Date()
            let segments = ChapterSegmenter().segments(
                articleID: UUID(), plainTextFallback: chapter.plainText,
                sourceFile: source, format: .txt)
            let elapsed = Date().timeIntervalSince(started)

            print("[perf] 单章切分 \(chapter.charCount) 字 → \(segments.count) 句："
                + String(format: "%.3fs", elapsed))
            #expect(segments.count > 50)
            #expect(elapsed < 2)
        }
    }

    /// 一本书解出来的句子规模——用来说明"为什么不能在导入时全切"。
    @Test func wholeNovelWouldProduceTensOfThousandsOfSentences() throws {
        let text = makeNovelText(chapters: 10)
        try withStorage { storage in
            var options = ChapterSplitter.Options()
            options.minBookChars = 1_000
            let importer = BookImporter(storage: storage, splitterOptions: options)
            let result = try #require(try importer.importText(text, title: "长篇测试"))
            let segmenter = ChapterSegmenter()
            let perChapter = result.chapters.map { chapter in
                segmenter.segments(
                    articleID: UUID(), plainTextFallback: chapter.plainText,
                    sourceFile: nil, format: .txt
                ).count
            }
            let total = perChapter.reduce(0, +)
            print("[perf] 10 章共 \(total) 句，整本 120 章约 \(total * 12) 句")
            // 这个量级正是懒切分与 LRU 卸载存在的理由。
            #expect(total * 12 > 10_000)
        }
    }

    @Test func importsLargeEPUBQuickly() throws {
        var builder = EPUBBuilder()
        let body = (0..<60)
            .map { "<p>第\($0)段の本文がここに続きます。名前はまだ無い。長い小説の一部です。</p>" }
            .joined()
        for index in 1...100 {
            builder.addChapter("OEBPS/ch\(index).xhtml", title: "第\(index)章", body: body)
        }
        let data = builder.epubData()

        try withStorage { storage in
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("perf-\(UUID().uuidString).epub")
            try data.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            let started = Date()
            let result = try BookImporter(storage: storage)
                .importEPUB(from: url, fallbackTitle: "perf")
            let elapsed = Date().timeIntervalSince(started)

            print(
                "[perf] EPUB 解压+解析 \(data.count / 1024)KB / \(result.chapters.count) 章："
                    + String(format: "%.2fs", elapsed))
            #expect(result.chapters.count == 100)
            #expect(elapsed < 10)
        }
    }
}
