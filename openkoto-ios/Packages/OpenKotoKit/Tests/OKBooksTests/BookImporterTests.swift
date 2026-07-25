import Foundation
import OKModels
import OKTestSupport
import Testing

@testable import OKBooks

@Suite struct BookImporterTests {
    /// 每个用例一个独立的书籍根目录，用完删掉。
    private func withImporter<T>(
        minBookChars: Int = 200, _ body: (BookImporter, BookStorage) throws -> T
    ) throws -> T {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("okbooks-import-\(UUID().uuidString)")
        let storage = BookStorage(root: root)
        try storage.prepare()
        defer { try? FileManager.default.removeItem(at: root) }
        var options = ChapterSplitter.Options()
        options.minBookChars = minBookChars
        return try body(BookImporter(storage: storage, splitterOptions: options), storage)
    }

    private func writeTemp(_ data: Data, extension ext: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("okbooks-src-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return url
    }

    // MARK: - EPUB

    @Test func importsEPUBIntoChaptersWithMetadata() throws {
        try withImporter { importer, storage in
            let url = try writeTemp(EPUBBuilder.japaneseNovel().epubData(), extension: "epub")
            defer { try? FileManager.default.removeItem(at: url) }

            let result = try #require(try importer.importBook(from: url))
            #expect(result.book.title == "テスト書籍")
            #expect(result.book.author == "夏目漱石")
            #expect(result.book.language == "ja")
            #expect(result.book.format == .epub)
            // 这个样例书全文只有几十个字，会被判成"几乎没有正文"；
            // 模式判定本身由 fullLengthNovelDefaultsToNativeMode 等用例覆盖。
            #expect(result.chapters.map(\.title) == ["第一章", "第二章", "第三章"])
            #expect(result.chapters[0].plainText == "第一章\n吾輩は猫である。名前はまだ無い。")
            #expect(result.book.totalChars == result.chapters.reduce(0) { $0 + $1.charCount })

            // 原始文件落在书籍目录里，原版模式和注音重建都要靠它。
            let source = storage.directory(for: result.book.id)
                .appendingPathComponent(try #require(result.chapters[0].sourceHref))
            #expect(FileManager.default.fileExists(atPath: source.path))
        }
    }

    /// DRM 必须明确报错，不能像桌面端那样"导入成功"后正文变占位符。
    @Test func rejectsDRMProtectedEPUB() throws {
        try withImporter { importer, storage in
            var builder = EPUBBuilder.japaneseNovel()
            builder.encryption = .drm
            let url = try writeTemp(builder.epubData(), extension: "epub")
            defer { try? FileManager.default.removeItem(at: url) }

            #expect(throws: BookImporter.Failure.drmProtected) {
                try importer.importBook(from: url)
            }
            // 失败不留垃圾。
            #expect(try FileManager.default.contentsOfDirectory(
                atPath: storage.root.path).allSatisfy { $0 == ".staging" })
        }
    }

    @Test func rejectsCorruptArchive() throws {
        try withImporter { importer, _ in
            let url = try writeTemp(Data(repeating: 0x41, count: 4096), extension: "epub")
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(throws: BookImporter.Failure.self) { try importer.importBook(from: url) }
        }
    }

    /// 固定版式（纯图漫画）抽不出正文，只能给原版模式。
    @Test func marksFixedLayoutBookAsOriginalOnly() throws {
        try withImporter { importer, _ in
            var builder = EPUBBuilder()
            builder.renditionLayout = "pre-paginated"
            for index in 1...4 {
                builder.addChapter(
                    "OEBPS/p\(index).xhtml", title: "P\(index)",
                    body: "<div><img src=\"p\(index).jpg\"/></div>", prePaginated: true)
            }
            let url = try writeTemp(builder.epubData(), extension: "epub")
            defer { try? FileManager.default.removeItem(at: url) }

            let result = try #require(try importer.importBook(from: url))
            #expect(result.book.originalOnly)
            #expect(result.book.defaultMode == .original)
        }
    }

    /// 正常长度的小说默认原生模式。
    @Test func fullLengthNovelDefaultsToNativeMode() throws {
        try withImporter { importer, _ in
            var builder = EPUBBuilder()
            let body = (0..<40)
                .map { "<p>第\($0)段の本文がここに続きます。名前はまだ無い。</p>" }
                .joined()
            for index in 1...3 {
                builder.addChapter("OEBPS/ch\(index).xhtml", title: "第\(index)章", body: body)
            }
            let url = try writeTemp(builder.epubData(), extension: "epub")
            defer { try? FileManager.default.removeItem(at: url) }

            let result = try #require(try importer.importBook(from: url))
            #expect(result.book.defaultMode == .native)
            #expect(result.book.originalOnly == false)
        }
    }

    /// 短篇/绘本字少，但正文是真的——只改默认模式，不能锁死原生模式。
    @Test func shortButRealTextIsNotLockedToOriginal() {
        let short = (0..<5).map {
            BookImporter.Chapter(
                title: "\($0)", plainText: String(repeating: "字", count: 60), sourceHref: nil)
        }
        let quality = BookImporter.assessQuality(chapters: short, isFixedLayout: false)
        #expect(quality.originalOnly == false)
        #expect(quality.defaultMode == .original)
    }

    /// 整本几乎没有字 = 纯图漫画，这才锁死原生模式。
    @Test func imageOnlyBookIsOriginalOnly() {
        let empty = (0..<20).map {
            BookImporter.Chapter(title: "P\($0)", plainText: "", sourceHref: nil)
        }
        #expect(
            BookImporter.assessQuality(chapters: empty, isFixedLayout: false)
                == .init(defaultMode: .original, originalOnly: true))
    }

    @Test func qualityAssessmentPicksModeFromChapterLength() {
        let novel = (0..<10).map {
            BookImporter.Chapter(
                title: "第\($0)章", plainText: String(repeating: "文", count: 3_000),
                sourceHref: nil)
        }
        #expect(
            BookImporter.assessQuality(chapters: novel, isFixedLayout: false)
                == .init(defaultMode: .native, originalOnly: false))

        // 正文极少：默认原版，但仍允许切回原生。
        let sparse = (0..<10).map {
            BookImporter.Chapter(
                title: "\($0)", plainText: String(repeating: "字", count: 100), sourceHref: nil)
        }
        #expect(
            BookImporter.assessQuality(chapters: sparse, isFixedLayout: false)
                == .init(defaultMode: .original, originalOnly: false))
    }

    // MARK: - TXT

    @Test func importsChineseNovelTXTIntoChapters() throws {
        try withImporter { importer, storage in
            let body = (0..<30)
                .map { "这是第\($0)段正文，写了一些足够长的句子来凑够字数。再补一句。" }
                .joined(separator: "\n")
            let text = ["第一章 开端", body, "第二章 发展", body, "第三章 结局", body]
                .joined(separator: "\n")
            let url = try writeTemp(Data(text.utf8), extension: "txt")
            defer { try? FileManager.default.removeItem(at: url) }

            let result = try #require(try importer.importBook(from: url))
            #expect(result.book.format == .txt)
            #expect(result.chapters.map(\.title) == ["第一章 开端", "第二章 发展", "第三章 结局"])
            #expect(result.chapters[0].plainText.hasPrefix("第一章 开端"))

            // 每章的原始切片都落了盘。
            for chapter in result.chapters {
                let href = try #require(chapter.sourceHref)
                let url = storage.directory(for: result.book.id).appendingPathComponent(href)
                #expect(FileManager.default.fileExists(atPath: url.path))
            }
        }
    }

    /// 太短的文本不建书，交回普通文章路径。
    @Test func returnsNilForShortText() throws {
        try withImporter(minBookChars: 20_000) { importer, storage in
            let url = try writeTemp(Data("第一章\n很短。".utf8), extension: "txt")
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(try importer.importBook(from: url) == nil)
            // 不留目录。
            let entries = try FileManager.default.contentsOfDirectory(atPath: storage.root.path)
            #expect(entries.allSatisfy { $0 == ".staging" })
        }
    }

    /// 青空文庫：剥页眉页脚、按章切、注音进 RubyText。
    @Test func importsAozoraTXTWithRuby() throws {
        try withImporter { importer, storage in
            let body = (0..<30)
                .map { "｜吾輩《わがはい》は猫である。第\($0)段の本文が続きます。名前はまだ無い。" }
                .joined(separator: "\n")
            let text = """
                吾輩は猫である
                夏目漱石

                -------------------------------------------------------
                【テキスト中に現れる記号について】
                《》：ルビ
                -------------------------------------------------------

                第一章
                \(body)

                第二章
                \(body)

                底本：「吾輩は猫である」岩波文庫、岩波書店
                """
            // Shift_JIS 编码——青空文庫的实际分发格式。
            let url = try writeTemp(try #require(text.data(using: .shiftJIS)), extension: "txt")
            defer { try? FileManager.default.removeItem(at: url) }

            let result = try #require(try importer.importBook(from: url))
            #expect(result.book.language == "ja")
            #expect(result.chapters.map(\.title) == ["吾輩は猫である", "第一章", "第二章"])
            // 纯文本里注音标记已剥离。
            #expect(result.chapters[1].plainText.contains("《") == false)
            #expect(result.chapters[1].plainText.contains("吾輩は猫である。"))
            // 页脚书志信息不进正文。
            #expect(result.chapters.allSatisfy { !$0.plainText.contains("底本：") })

            // 原始切片保留了注音标记，供首开切分时重建读音。
            let href = try #require(result.chapters[1].sourceHref)
            let raw = try String(
                contentsOf: storage.directory(for: result.book.id).appendingPathComponent(href),
                encoding: .utf8)
            #expect(raw.contains("｜吾輩《わがはい》"))
        }
    }

    // MARK: - 与切分器联动

    /// 首开章节的延迟切分：读原始文件拿注音。
    @Test func chapterSegmenterFillsReadingFromSourceFile() throws {
        try withImporter { importer, storage in
            let url = try writeTemp(EPUBBuilder.japaneseNovel().epubData(), extension: "epub")
            defer { try? FileManager.default.removeItem(at: url) }
            let result = try #require(try importer.importBook(from: url))

            let chapter = result.chapters[0]
            let source = storage.directory(for: result.book.id)
                .appendingPathComponent(try #require(chapter.sourceHref))
            let articleID = UUID()
            let segments = ChapterSegmenter().segments(
                articleID: articleID, plainTextFallback: chapter.plainText,
                sourceFile: source, format: .epub)

            #expect(segments.map(\.text) == ["第一章", "吾輩は猫である。", "名前はまだ無い。"])
            #expect(segments[1].readingText == "わがはいは猫である。")
            #expect(segments[0].isNewParagraph)
        }
    }

    /// 原始文件丢失（换机恢复后 Books/ 没回来）：丢注音，但书还能读。
    @Test func chapterSegmenterFallsBackWhenSourceMissing() {
        let articleID = UUID()
        let segments = ChapterSegmenter().segments(
            articleID: articleID,
            plainTextFallback: "第一章\n吾輩は猫である。名前はまだ無い。",
            sourceFile: URL(fileURLWithPath: "/nonexistent/ch1.xhtml"),
            format: .epub)
        #expect(segments.map(\.text) == ["第一章", "吾輩は猫である。", "名前はまだ無い。"])
        #expect(segments.allSatisfy { $0.readingText == nil })
    }

    // MARK: - 存储

    @Test func storageCommitsAtomicallyAndSweepsOrphans() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("okbooks-storage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookStorage(root: root)
        try storage.prepare()

        let keep = UUID()
        let staging = try storage.stagingDirectory(for: keep)
        try Data("x".utf8).write(to: staging.appendingPathComponent("a.txt"))
        try storage.commit(staging: staging, to: keep)
        #expect(FileManager.default.fileExists(
            atPath: storage.directory(for: keep).appendingPathComponent("a.txt").path))

        // 孤儿目录 + staging 残留都要清掉，已知的书保留。
        let orphan = UUID()
        try FileManager.default.createDirectory(
            at: storage.directory(for: orphan), withIntermediateDirectories: true)
        _ = try storage.stagingDirectory(for: UUID())

        try storage.sweepOrphans(knownIDs: [keep])
        #expect(FileManager.default.fileExists(atPath: storage.directory(for: keep).path))
        #expect(FileManager.default.fileExists(atPath: storage.directory(for: orphan).path) == false)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".staging").path) == false)
    }

    @Test func removeDeletesBookDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("okbooks-remove-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookStorage(root: root)
        try storage.prepare()

        let id = UUID()
        let staging = try storage.stagingDirectory(for: id)
        try Data("x".utf8).write(to: staging.appendingPathComponent("a.txt"))
        try storage.commit(staging: staging, to: id)

        try storage.remove(id: id)
        #expect(FileManager.default.fileExists(atPath: storage.directory(for: id).path) == false)
    }
}
