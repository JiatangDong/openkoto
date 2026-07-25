import Foundation
import Testing
import OKModels
import OKPersistence

@testable import OKFeatures

/// 句子按需加载的行为测试。
///
/// 启动不再预载任何句子——一本 50 万字小说约 1.5 万句，全量入内存撑不住。
/// 但"不载入正文"不能牺牲书库列表上的进度徽章，两者的分工由这组用例钉死。
@MainActor
@Suite struct ContentStoreLazyLoadTests {
    private func makeStore() throws -> (ContentStore, ContentRepository, UserDefaults) {
        let repository = try ContentRepository(database: AppDatabase.inMemory())
        let suiteName = "ContentStoreLazyLoadTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (ContentStore(repository: repository, defaults: defaults), repository, defaults)
    }

    @Test func segmentsAreNotLoadedUntilArticleOpens() async throws {
        let (store, _, _) = try makeStore()
        await store.load()
        let article = try #require(store.articles.first)

        #expect(store.segments(for: article.id).isEmpty)
        // 正文没进内存，进度徽章仍要正确——它走启动时查好的计数。
        #expect(store.progress(for: article.id) == (explained: 2, total: 9))

        await store.openArticle(article.id)
        #expect(store.segments(for: article.id).count == 9)
        #expect(store.progress(for: article.id) == (explained: 2, total: 9))
    }

    /// 超出上限的最久未用文章从内存卸载，但计数留下，徽章不受影响。
    @Test func evictsLeastRecentlyUsedArticlesBeyondLimit() async throws {
        let (store, _, _) = try makeStore()
        await store.load()

        var ids: [UUID] = []
        for index in 0..<(ContentStore.loadedArticleLimit + 1) {
            store.importArticle(title: "文章\(index)", content: "一句目。二句目。")
            ids.append(try #require(store.articles.first).id)
        }

        #expect(store.segments(for: ids[0]).isEmpty)
        #expect(store.segments(for: ids.last!).count == 2)
        #expect(store.progress(for: ids[0]) == (explained: 0, total: 2))
    }

    /// 被卸载后重新打开要能从库里读回来。
    @Test func evictedArticleReloadsOnReopen() async throws {
        let (store, _, _) = try makeStore()
        await store.load()

        var ids: [UUID] = []
        for index in 0..<(ContentStore.loadedArticleLimit + 1) {
            store.importArticle(title: "文章\(index)", content: "一句目。二句目。")
            ids.append(try #require(store.articles.first).id)
        }
        await store.flushPersistence()
        #expect(store.segments(for: ids[0]).isEmpty)

        await store.openArticle(ids[0])
        #expect(store.segments(for: ids[0]).map(\.text) == ["一句目。", "二句目。"])
    }

    /// 章节首开时的延迟切分：库里没有句子就调注入的切分器，并落库。
    @Test func lazySegmenterFillsSegmentsOnFirstOpen() async throws {
        let (store, repository, defaults) = try makeStore()
        await store.load()

        // 直接写一篇没有句子的文章，模拟"导入书籍时不切分"。
        let article = Article(title: "第一章", content: "一句目。二句目。")
        try await repository.insertArticle(article, segments: [])

        var segmenterCalls = 0
        store.lazySegmenter = { article in
            segmenterCalls += 1
            return ["一句目。", "二句目。"].enumerated().map { index, text in
                ArticleSegment(articleId: article.id, order: index, text: text)
            }
        }

        await store.openArticle(article.id)
        #expect(segmenterCalls == 1)
        #expect(store.segments(for: article.id).map(\.text) == ["一句目。", "二句目。"])

        // 落库后重启：不该再切一次。
        await store.flushPersistence()
        let restarted = ContentStore(repository: repository, defaults: defaults)
        restarted.lazySegmenter = { _ in
            Issue.record("已落库的章节不应再次切分")
            return []
        }
        await restarted.load()
        await restarted.openArticle(article.id)
        #expect(restarted.segments(for: article.id).count == 2)
    }

    /// 精讲写回时计数要同步递增，否则文章被卸载后徽章会倒退。
    @Test func explanationCountSurvivesEviction() async throws {
        let (store, _, _) = try makeStore()
        await store.load()
        store.explanationProvider = { text in
            GeneratedExplanation(
                explanation: SegmentExplanation(translation: "译:\(text)", explanation: "讲解"),
                meta: ExplanationMeta(
                    targetLanguage: "zh-CN", providerId: "moonshot", modelId: "kimi-k3",
                    promptVersion: "explain-v1", generatedAt: .now, sourceTextHash: "hash"))
        }
        store.importArticle(title: "新文章", content: "一句目。二句目。")
        let articleID = try #require(store.articles.first).id
        let segmentID = try #require(store.segments(for: articleID).first).id

        await store.generateExplanation(articleID: articleID, segmentID: segmentID)
        #expect(store.progress(for: articleID) == (explained: 1, total: 2))

        // 挤掉它，再看徽章。
        for index in 0..<ContentStore.loadedArticleLimit {
            store.importArticle(title: "占位\(index)", content: "甲。乙。")
        }
        #expect(store.segments(for: articleID).isEmpty)
        #expect(store.progress(for: articleID) == (explained: 1, total: 2))
    }
}
