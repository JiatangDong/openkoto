import Foundation
import OKBooks
import OKModels
import OKPersistence
import OKTestSupport
import Testing

@testable import OKFeatures

/// 在书里搜索并跳到那一句——整条链路最容易"搜到了却跳错地方"的一段。
///
/// 书籍是全文搜索最该服务的对象（一本 50 万字的小说才需要搜），
/// 也恰恰是最容易漏的：导入时**不写 segment**，索引只能建在 `article.content` 上，
/// 而跳转要的是 `segment.order`，中间还隔着一次懒切分和一层章号。
@MainActor
@Suite struct SearchInBookTests {
    private struct Harness {
        var store: ContentStore
        var root: URL
    }

    private func makeHarness() throws -> Harness {
        let database = try AppDatabase.inMemory()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("oksearch-books-\(UUID().uuidString)")
        let storage = BookStorage(root: root)
        try storage.prepare()
        let suiteName = "SearchInBookTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        return Harness(
            store: ContentStore(
                repository: ContentRepository(database: database),
                bookRepository: BookRepository(database: database),
                bookStorage: storage,
                searchIndexer: SearchIndexer(database: database),
                defaults: defaults),
            root: root)
    }

    /// 第二章第三句藏着要找的词，前后都是干扰段落。
    private func makeNovel() -> EPUBBuilder {
        var builder = EPUBBuilder()
        let filler = (0..<10).map { "<p>第\($0)段の本文です。</p>" }.joined()
        builder.addChapter("OEBPS/ch1.xhtml", title: "第一章", body: filler)
        builder.addChapter(
            "OEBPS/ch2.xhtml", title: "第二章",
            body: "<p>最初の文です。二番目の文です。ここに探し物があります。</p>" + filler)
        return builder
    }

    private func importNovel(_ store: ContentStore) async throws -> Book {
        let builder = makeNovel()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("oksearch-src-\(UUID().uuidString).epub")
        try builder.epubData().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try #require(await store.importBook(from: url))
    }

    @Test func findsAndLocatesASentenceInsideABook() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        await harness.store.load()
        let book = try await importNovel(harness.store)
        await harness.store.flushPersistence()

        // 导入不写 segment；索引建在 article.content 上，所以此刻就该搜得到。
        let hits = await harness.store.search("探し物")
        #expect(hits.count == 1)
        let hit = try #require(hits.first)

        // 落到正确的书与正确的章
        guard case .book(let resolved, let chapterIndex) =
            harness.store.container(forArticle: hit.articleID)
        else {
            Issue.record("书里的命中应归为 .book")
            return
        }
        #expect(resolved.id == book.id)
        #expect(chapterIndex == 1)

        // 落到正确的句：懒切分由定位自己触发
        let order = try #require(
            await harness.store.locateSegmentOrder(articleID: hit.articleID, matching: "探し物"))
        let segments = harness.store.segments(for: hit.articleID)
        #expect(segments[order].text.contains("探し物"))
    }

    /// 删掉书之后不能还搜得到它的章节——章节是 article 行，
    /// 删书要一路清到 FTS。
    @Test func deletingTheBookRemovesItsChaptersFromSearch() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        await harness.store.load()
        let book = try await importNovel(harness.store)
        await harness.store.flushPersistence()
        #expect(await !harness.store.search("探し物").isEmpty)

        harness.store.deleteBook(book.id)
        await harness.store.flushPersistence()

        #expect(await harness.store.search("探し物").isEmpty)
    }
}
