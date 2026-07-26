import Foundation
import OKModels
import OKPersistence
import Testing

@testable import OKFeatures

/// 从搜索结果跳到具体一句。
///
/// 全文索引建在 `article.content` 上，而阅读器定位靠的是 `segment.order`——
/// 这中间的换算是整条链路唯一会"搜到了却跳错地方"的环节，所以单独钉住。
@MainActor
@Suite struct SearchNavigationTests {
    private func makeStore() throws -> (ContentStore, ContentRepository) {
        let repository = try ContentRepository(database: AppDatabase.inMemory())
        let suiteName = "SearchNavigationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (ContentStore(repository: repository, defaults: defaults), repository)
    }

    private func insert(
        _ repository: ContentRepository, title: String, sentences: [String]
    ) async throws -> Article {
        let article = Article(title: title, content: sentences.joined())
        let segments = sentences.enumerated().map {
            ArticleSegment(articleId: article.id, order: $0.offset, text: $0.element)
        }
        try await repository.insertArticle(article, segments: segments)
        return article
    }

    // MARK: - 定位

    @Test func locatesTheSentenceContainingTheQuery() async throws {
        let (store, repository) = try makeStore()
        let article = try await insert(
            repository, title: "T",
            sentences: ["最初の文です。", "私は日本語を勉強しています。", "最後の文です。"])
        await store.load()

        #expect(await store.locateSegmentOrder(articleID: article.id, matching: "日本語") == 1)
    }

    /// 多次出现时落在**第一次**出现的地方——这是用户对"跳过去"的默认预期。
    @Test func locatesTheFirstOccurrence() async throws {
        let (store, repository) = try makeStore()
        let article = try await insert(
            repository, title: "T",
            sentences: ["犬がいます。", "猫がいます。", "また猫がいます。"])
        await store.load()

        #expect(await store.locateSegmentOrder(articleID: article.id, matching: "猫") == 1)
    }

    /// 书籍章节导入时不写 segment，定位必须自己触发懒切分，否则永远返回 nil——
    /// 而书恰恰是最需要全文搜索的那类内容。
    @Test func triggersLazySegmentationBeforeLocating() async throws {
        let (store, repository) = try makeStore()
        let article = Article(
            title: "章", content: "最初の文です。私は日本語を勉強しています。最後の文です。")
        try await repository.insertArticle(article, segments: [])
        await store.load()
        store.lazySegmenter = { article in
            article.content.split(separator: "。", omittingEmptySubsequences: true)
                .enumerated()
                .map {
                    ArticleSegment(
                        articleId: article.id, order: $0.offset, text: $0.element + "。")
                }
        }
        #expect(store.segments(for: article.id).isEmpty)

        let order = await store.locateSegmentOrder(articleID: article.id, matching: "日本語")
        #expect(order == 1)
        #expect(!store.segments(for: article.id).isEmpty)
    }

    /// 查不到就返回 nil，让调用方退化成"从头打开"，而不是随便给个 0 号句装作找到了。
    @Test func returnsNilWhenTheQueryIsAbsent() async throws {
        let (store, repository) = try makeStore()
        let article = try await insert(repository, title: "T", sentences: ["犬がいます。"])
        await store.load()

        #expect(await store.locateSegmentOrder(articleID: article.id, matching: "猫") == nil)
        #expect(await store.locateSegmentOrder(articleID: article.id, matching: "  ") == nil)
    }

    // MARK: - 来源归属（决定跳进哪个阅读器）

    @Test func plainArticleResolvesToArticleContainer() async throws {
        let (store, repository) = try makeStore()
        let article = try await insert(repository, title: "T", sentences: ["犬がいます。"])
        await store.load()

        guard case .article(let resolved) = store.container(forArticle: article.id) else {
            Issue.record("应归为普通文章")
            return
        }
        #expect(resolved.id == article.id)
    }

    @Test func unknownArticleDoesNotCrash() async throws {
        let (store, _) = try makeStore()
        await store.load()
        guard case .unknown = store.container(forArticle: UUID()) else {
            Issue.record("不存在的文章应归为 unknown")
            return
        }
    }

    // MARK: - 索引进度

    /// 进度为 0 时 UI 不该显示"正在建立索引"——新库本来就没有待办。
    @Test func freshDatabaseHasNothingPending() async throws {
        let (store, _) = try makeStore()
        await store.load()
        #expect(store.pendingIndexCount == 0)
    }
}

/// 生词卡的出处。
///
/// v5 加的 `source_segment_id` 是「回到原句」的全部依据——收藏时没记下来，
/// 之后再也补不回去（句子会被重新切分，UUID 全换）。
@MainActor
@Suite struct FavoriteSourceTests {
    private func makeStore() throws -> (ContentStore, ContentRepository) {
        let repository = try ContentRepository(database: AppDatabase.inMemory())
        let suiteName = "FavoriteSourceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (ContentStore(repository: repository, defaults: defaults), repository)
    }

    private func makeArticle(_ repository: ContentRepository) async throws
        -> (Article, ArticleSegment)
    {
        let article = Article(title: "T", content: "私は日本語を勉強しています。")
        let segment = ArticleSegment(
            articleId: article.id, order: 0, text: "私は日本語を勉強しています。")
        try await repository.insertArticle(article, segments: [segment])
        return (article, segment)
    }

    @Test func favoritingFromASentenceRecordsIt() async throws {
        let (store, repository) = try makeStore()
        let (article, segment) = try await makeArticle(repository)
        await store.load()

        store.toggleFavorite(
            VocabularyItem(word: "勉強", meaning: "学习"), source: article, segmentID: segment.id)

        let favorite = try #require(store.favorites.first { $0.word == "勉強" })
        #expect(favorite.sourceArticleId == article.id)
        #expect(favorite.sourceSegmentId == segment.id)
    }

    /// 出处要落库，不能只活在内存里——重启后「回到原句」还得能用。
    @Test func theSourcePersists() async throws {
        let (store, repository) = try makeStore()
        let (article, segment) = try await makeArticle(repository)
        await store.load()
        store.toggleFavorite(
            VocabularyItem(word: "勉強", meaning: "学习"), source: article, segmentID: segment.id)
        await store.flushPersistence()

        let restarted = ContentStore(
            repository: repository,
            defaults: UserDefaults(suiteName: "FavoriteSourceTests-restart-\(UUID().uuidString)")!)
        await restarted.load()
        let favorite = try #require(restarted.favorites.first { $0.word == "勉強" })
        #expect(favorite.sourceSegmentId == segment.id)
    }

    /// 划词建卡此前完全丢来源：卡片上既没有出处也回不去原句。
    @Test func manualWordCanCarryItsSource() async throws {
        let (store, repository) = try makeStore()
        let (article, segment) = try await makeArticle(repository)
        await store.load()

        #expect(
            store.addManualWord(
                word: "日本語", meaning: "日语", reading: nil, usage: nil, example: nil,
                source: article, segmentID: segment.id))

        let favorite = try #require(store.favorites.first { $0.word == "日本語" })
        #expect(favorite.sourceArticleId == article.id)
        #expect(favorite.sourceArticleTitle == article.title)
        #expect(favorite.sourceSegmentId == segment.id)
    }

    /// 生词本里手工新建的卡没有出处，「回到原句」按钮就不该出现。
    @Test func manualWordWithoutSourceStaysEmpty() async throws {
        let (store, _) = try makeStore()
        await store.load()

        #expect(
            store.addManualWord(
                word: "犬", meaning: "狗", reading: nil, usage: nil, example: nil))

        let favorite = try #require(store.favorites.first { $0.word == "犬" })
        #expect(favorite.sourceArticleId == nil)
        #expect(favorite.sourceSegmentId == nil)
    }
}
