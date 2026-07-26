import Foundation
import OKBooks
import OKModels
import OKPersistence
import OKTestSupport
import Testing

@testable import OKFeatures

/// 复习卡片上的「出处」。
///
/// 卡片只存了 articleID / segmentID，句子本身要现查。这条链路有三种退化情形
/// （没有出处、句子被重新切分过、来源是书要拼书名），每一种都必须给出确定的结果——
/// 复习流是用户每天都会走的路，出处那一块闪一下或者显示成空白都很刺眼。
@MainActor
@Suite struct ReviewSourceTests {
    private func makeStore() throws -> (ContentStore, ContentRepository) {
        let repository = try ContentRepository(database: AppDatabase.inMemory())
        let suiteName = "ReviewSourceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (ContentStore(repository: repository, defaults: defaults), repository)
    }

    private func makeArticle(_ repository: ContentRepository) async throws
        -> (Article, ArticleSegment)
    {
        let article = Article(title: "ある記事", content: "私は日本語を勉強しています。")
        let segment = ArticleSegment(
            articleId: article.id, order: 0, text: "私は日本語を勉強しています。")
        try await repository.insertArticle(article, segments: [segment])
        return (article, segment)
    }

    // MARK: - 正常情形

    @Test func resolvesTheLabelAndTheSentence() async throws {
        let (store, repository) = try makeStore()
        let (article, segment) = try await makeArticle(repository)
        await store.load()
        store.toggleFavorite(
            VocabularyItem(word: "勉強", meaning: "学习"), source: article, segmentID: segment.id)

        let favorite = try #require(store.favorites.first { $0.word == "勉強" })
        let source = try #require(await store.resolveSource(for: favorite))
        #expect(source.label == "ある記事")
        #expect(source.sentence == "私は日本語を勉強しています。")
        #expect(source.jump.articleID == article.id)
        #expect(source.jump.segmentID == segment.id)
    }

    /// 刚在阅读器里收藏完就去复习是最常见的路径，这时句子已在内存里，不该再查库。
    @Test func readsFromMemoryWhenTheArticleIsOpen() async throws {
        let (store, repository) = try makeStore()
        let (article, segment) = try await makeArticle(repository)
        await store.load()
        await store.openArticle(article.id)
        store.toggleFavorite(
            VocabularyItem(word: "勉強", meaning: "学习"), source: article, segmentID: segment.id)

        let favorite = try #require(store.favorites.first { $0.word == "勉強" })
        let source = try #require(await store.resolveSource(for: favorite))
        #expect(source.sentence == "私は日本語を勉強しています。")
    }

    // MARK: - 退化情形

    /// 手工新建的卡从来就没有来源，出处那一块要整个不出现——
    /// 给一个点了没反应的入口比不给更糟。
    @Test func aCardWithoutASourceResolvesToNil() async throws {
        let (store, _) = try makeStore()
        await store.load()
        #expect(
            store.addManualWord(word: "犬", meaning: "狗", reading: nil, usage: nil, example: nil))

        let favorite = try #require(store.favorites.first { $0.word == "犬" })
        #expect(await store.resolveSource(for: favorite) == nil)
    }

    /// 句子查不到时**只降级掉句子**，来源名和跳转都得留着。
    ///
    /// 章节被重新切分后 segment 全换新 UUID（重导入同一本书就会发生），
    /// 老卡片的 `sourceSegmentId` 就指向一个不存在的行了。这时仍然能跳回那篇文章，
    /// 只是落在开头——比整块消失有用得多。
    @Test func aStaleSegmentDegradesToLabelOnly() async throws {
        let (store, repository) = try makeStore()
        let (article, _) = try await makeArticle(repository)
        await store.load()
        store.toggleFavorite(
            VocabularyItem(word: "勉強", meaning: "学习"), source: article, segmentID: UUID())

        let favorite = try #require(store.favorites.first { $0.word == "勉強" })
        let source = try #require(await store.resolveSource(for: favorite))
        #expect(source.label == "ある記事")
        #expect(source.sentence == nil)
        #expect(source.jump.articleID == article.id)
    }

    /// 同一张卡翻面两次只查一次库。
    ///
    /// 绕过 store 直接删库来验证：第二次还拿得到句子，就说明走的是缓存。
    /// 复习一轮几十张卡，每张翻面都查一次是没必要的。
    @Test func theSentenceIsCachedForTheSession() async throws {
        let (store, repository) = try makeStore()
        let (article, segment) = try await makeArticle(repository)
        await store.load()

        #expect(await store.sourceSentence(segmentID: segment.id) == "私は日本語を勉強しています。")
        try await repository.deleteArticle(id: article.id)
        #expect(await store.sourceSentence(segmentID: segment.id) == "私は日本語を勉強しています。")
    }

    /// 查不到的那次也要记进缓存，否则每次翻面都为同一张必然落空的卡再查一次库。
    @Test func aMissTooIsCached() async throws {
        let (store, _) = try makeStore()
        await store.load()
        let ghost = UUID()

        #expect(await store.sourceSentence(segmentID: ghost) == nil)
        #expect(store.sourceSentenceCache.index(forKey: ghost) != nil)
    }
}

/// 书里收藏的词，出处要写成「书名 · 章名」。
///
/// 只显示章标题的话，同一本书里的几十张卡出处全长一样（都是「第三章」这种），
/// 等于没显示。
@MainActor
@Suite struct ReviewSourceInBookTests {
    private func makeStore() throws -> (ContentStore, URL) {
        let database = try AppDatabase.inMemory()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("okreview-books-\(UUID().uuidString)")
        let storage = BookStorage(root: root)
        try storage.prepare()
        let suiteName = "ReviewSourceInBookTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        return (
            ContentStore(
                repository: ContentRepository(database: database),
                bookRepository: BookRepository(database: database),
                bookStorage: storage,
                defaults: defaults),
            root
        )
    }

    @Test func theLabelCombinesTheBookAndTheChapter() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.load()

        var builder = EPUBBuilder()
        builder.addChapter("OEBPS/ch1.xhtml", title: "第一章", body: "<p>最初の文です。</p>")
        builder.addChapter(
            "OEBPS/ch2.xhtml", title: "第二章", body: "<p>私は日本語を勉強しています。</p>")
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("okreview-src-\(UUID().uuidString).epub")
        try builder.epubData().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let book = try #require(await store.importBook(from: url))

        // 章节 Article 不在 articles 列表里，得从章节目录拿。
        let chapter = try #require(store.chapterSummaries(of: book.id).first { $0.index == 1 })
        await store.openArticle(chapter.articleId)
        let article = try #require(store.chapterArticle(id: chapter.articleId))
        let segment = try #require(
            store.segments(for: chapter.articleId).first { $0.text.contains("勉強") })

        store.toggleFavorite(
            VocabularyItem(word: "勉強", meaning: "学习"), source: article, segmentID: segment.id)
        let favorite = try #require(store.favorites.first { $0.word == "勉強" })

        let source = try #require(await store.resolveSource(for: favorite))
        #expect(source.label == "\(book.title) · 第二章")
        #expect(source.sentence?.contains("勉強") == true)
    }
}
