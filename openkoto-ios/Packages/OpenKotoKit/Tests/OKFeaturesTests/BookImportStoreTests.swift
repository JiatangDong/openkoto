import Foundation
import OKBooks
import OKModels
import OKPersistence
import OKTestSupport
import Testing

@testable import OKFeatures

/// ContentStore 的书籍接线：导入 → 重启仍在 → 首开章节才切句 → 删书清干净。
@MainActor
@Suite struct BookImportStoreTests {
    private struct Harness {
        var store: ContentStore
        var content: ContentRepository
        var books: BookRepository
        var storage: BookStorage
        var defaults: UserDefaults
        var root: URL
    }

    private func makeHarness() throws -> Harness {
        let database = try AppDatabase.inMemory()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("okfeatures-books-\(UUID().uuidString)")
        let storage = BookStorage(root: root)
        try storage.prepare()
        let suiteName = "BookImportStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let content = ContentRepository(database: database)
        let books = BookRepository(database: database)
        return Harness(
            store: ContentStore(
                repository: content, bookRepository: books, bookStorage: storage,
                defaults: defaults),
            content: content, books: books, storage: storage, defaults: defaults, root: root)
    }

    private func writeEPUB(_ builder: EPUBBuilder) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("okfeatures-src-\(UUID().uuidString).epub")
        try builder.epubData().write(to: url)
        return url
    }

    private func makeNovel() -> EPUBBuilder {
        var builder = EPUBBuilder()
        let body = (0..<20)
            .map { "<p>第\($0)段の本文です。名前はまだ無い。</p>" }
            .joined()
        builder.addChapter(
            "OEBPS/ch1.xhtml", title: "第一章",
            body: "<p><ruby>吾輩<rt>わがはい</rt></ruby>は猫である。</p>" + body)
        builder.addChapter("OEBPS/ch2.xhtml", title: "第二章", body: body)
        return builder
    }

    // MARK: - 导入

    @Test func importedBookSurvivesRestartAndStaysOutOfArticleList() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        await harness.store.load()

        let url = try writeEPUB(makeNovel())
        defer { try? FileManager.default.removeItem(at: url) }
        let book = try #require(await harness.store.importBook(from: url))
        await harness.store.flushPersistence()

        #expect(harness.store.books.map(\.id) == [book.id])
        #expect(harness.store.chapterSummaries(of: book.id).map(\.title) == ["第一章", "第二章"])
        // 章节是 article 行，但不能混进书库顶层列表。
        #expect(harness.store.articles.contains { $0.title == "第一章" } == false)

        let restarted = ContentStore(
            repository: harness.content, bookRepository: harness.books,
            bookStorage: harness.storage, defaults: harness.defaults)
        await restarted.load()
        #expect(restarted.books.map(\.title) == [book.title])
        #expect(restarted.chapterSummaries(of: book.id).count == 2)
    }

    /// 导入不切句——一本长篇会切出上万句，卡住导入也撑爆内存。
    @Test func importDoesNotSegmentChapters() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        await harness.store.load()

        let url = try writeEPUB(makeNovel())
        defer { try? FileManager.default.removeItem(at: url) }
        let book = try #require(await harness.store.importBook(from: url))
        await harness.store.flushPersistence()

        for chapter in harness.store.chapterSummaries(of: book.id) {
            #expect(chapter.isSegmented == false)
            #expect(try await harness.content.loadSegments(articleID: chapter.articleId).isEmpty)
        }
    }

    /// 首次打开章节才切句，并把注音一起带出来；结果落库，重开不再切。
    @Test func openingChapterSegmentsLazilyWithRubyAndPersists() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        await harness.store.load()

        let url = try writeEPUB(makeNovel())
        defer { try? FileManager.default.removeItem(at: url) }
        let book = try #require(await harness.store.importBook(from: url))
        await harness.store.flushPersistence()

        let first = try #require(harness.store.chapterSummaries(of: book.id).first)
        await harness.store.openArticle(first.articleId)
        await harness.store.flushPersistence()

        let segments = harness.store.segments(for: first.articleId)
        #expect(segments.isEmpty == false)
        #expect(segments.first?.text == "吾輩は猫である。")
        // EPUB 的 <ruby> 读音进了注音行。
        #expect(segments.first?.readingText == "わがはいは猫である。")

        // 已落库：重启后直接读得到，不再触发切分。
        let restarted = ContentStore(
            repository: harness.content, bookRepository: harness.books,
            bookStorage: harness.storage, defaults: harness.defaults)
        await restarted.load()
        await restarted.openArticle(first.articleId)
        #expect(restarted.segments(for: first.articleId).count == segments.count)
        #expect(try #require(await harness.books.chapter(articleID: first.articleId)).isSegmented)
    }

    /// 原书自带的振假名要盖过离线注音——作者标的才是权威。
    ///
    /// 用「私」做判据：离线注音器读成 わたくし，书里标的是 わたし。
    /// 读到 わたし 才说明 run 边界真的从原始文件里还原回来了（切句时它被压平丢过一次）。
    @Test func bookOwnRubyOverridesOfflineReading() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        await harness.store.load()

        var builder = EPUBBuilder()
        builder.addChapter(
            "OEBPS/ch1.xhtml", title: "第一章",
            body: "<p><ruby>私<rt>わたし</rt></ruby>は本を読む。</p>")
        let url = try writeEPUB(builder)
        defer { try? FileManager.default.removeItem(at: url) }

        let book = try #require(await harness.store.importBook(from: url))
        await harness.store.flushPersistence()
        let first = try #require(harness.store.chapterSummaries(of: book.id).first)
        await harness.store.openArticle(first.articleId)

        let segmentID = try #require(harness.store.segments(for: first.articleId).first).id
        let runs = try #require(harness.store.readingRuns(for: first.articleId)[segmentID])

        #expect(runs.contains { $0.text == "私" && $0.reading == "わたし" })
        #expect(!runs.contains { $0.reading == "わたくし" })
        // 未被作者标注的词仍由离线注音器补上，覆盖不该有空洞
        #expect(runs.contains { $0.text == "本" && $0.reading == "ほん" })
        #expect(runs.plainText == "私は本を読む。")
    }

    /// 精讲写在章节这一行上，生词照常收藏——书籍与文章共用同一条学习管线。
    @Test func chapterParticipatesInExplanationPipeline() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        await harness.store.load()
        harness.store.explanationProvider = { text in
            GeneratedExplanation(
                explanation: SegmentExplanation(translation: "译:\(text)", explanation: "讲解"),
                meta: ExplanationMeta(
                    targetLanguage: "zh-CN", providerId: "moonshot", modelId: "kimi-k3",
                    promptVersion: "explain-v1", generatedAt: .now, sourceTextHash: "hash"))
        }

        let url = try writeEPUB(makeNovel())
        defer { try? FileManager.default.removeItem(at: url) }
        let book = try #require(await harness.store.importBook(from: url))
        let first = try #require(harness.store.chapterSummaries(of: book.id).first)
        await harness.store.openArticle(first.articleId)

        let segmentID = try #require(harness.store.segments(for: first.articleId).first).id
        let ok = await harness.store.generateExplanation(
            articleID: first.articleId, segmentID: segmentID)
        #expect(ok)
        #expect(harness.store.progress(for: first.articleId).explained == 1)

        await harness.store.flushPersistence()
        let reloaded = try await harness.content.loadSegments(articleID: first.articleId)
        #expect(reloaded.first?.explanation?.translation == "译:吾輩は猫である。")
    }

    // MARK: - 删除

    @Test func deleteBookRemovesChaptersProgressAndFiles() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        await harness.store.load()

        let url = try writeEPUB(makeNovel())
        defer { try? FileManager.default.removeItem(at: url) }
        let book = try #require(await harness.store.importBook(from: url))
        let first = try #require(harness.store.chapterSummaries(of: book.id).first)
        await harness.store.openArticle(first.articleId)
        harness.store.saveBookProgress(
            BookProgress(bookId: book.id, chapterIndex: 1, segmentOrder: 3))
        await harness.store.flushPersistence()
        #expect(FileManager.default.fileExists(
            atPath: harness.storage.directory(for: book.id).path))

        harness.store.deleteBook(book.id)
        await harness.store.flushPersistence()

        #expect(harness.store.books.isEmpty)
        #expect(harness.store.chapterSummaries(of: book.id).isEmpty)
        #expect(harness.store.progress(ofBook: book.id) == nil)
        #expect(harness.store.segments(for: first.articleId).isEmpty)
        // 磁盘目录一并清掉，不留孤儿。
        #expect(FileManager.default.fileExists(
            atPath: harness.storage.directory(for: book.id).path) == false)
        #expect(try await harness.books.loadBooks().isEmpty)
        #expect(try await harness.content.loadSegments(articleID: first.articleId).isEmpty)
    }

    // MARK: - 阅读位置

    @Test func bookProgressPersistsAcrossRestart() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        await harness.store.load()

        let url = try writeEPUB(makeNovel())
        defer { try? FileManager.default.removeItem(at: url) }
        let book = try #require(await harness.store.importBook(from: url))

        harness.store.saveBookProgress(
            BookProgress(
                bookId: book.id, chapterIndex: 1, segmentOrder: 7, scrollFraction: 0.35,
                mode: .native))
        await harness.store.flushPersistence()

        let restarted = ContentStore(
            repository: harness.content, bookRepository: harness.books,
            bookStorage: harness.storage, defaults: harness.defaults)
        await restarted.load()
        let progress = try #require(restarted.progress(ofBook: book.id))
        #expect(progress.chapterIndex == 1)
        #expect(progress.segmentOrder == 7)
        #expect(progress.scrollFraction == 0.35)
    }

    /// 太短的文本不建书，走回普通文章路径。
    @Test func shortTextDoesNotBecomeBook() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        await harness.store.load()

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("short-\(UUID().uuidString).txt")
        try Data("第一章\n很短的内容。".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try await harness.store.importBook(from: url) == nil)
        #expect(harness.store.books.isEmpty)
    }
}
