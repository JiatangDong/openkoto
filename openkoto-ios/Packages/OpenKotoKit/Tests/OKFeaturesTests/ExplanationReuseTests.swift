import Foundation
import OKAIClient
import OKModels
import OKPersistence
import Testing

@testable import OKFeatures

/// 精讲复用。这条路径的价值全在**省下的 API 调用**，所以测试直接断言调用次数。
@MainActor
@Suite struct ExplanationReuseTests {
    private func makeStore() throws -> (ContentStore, ContentRepository, UserDefaults) {
        let repository = try ContentRepository(database: AppDatabase.inMemory())
        let suite = "ReuseTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set("zh-CN", forKey: "learning.targetLanguage")
        return (ContentStore(repository: repository, defaults: defaults), repository, defaults)
    }

    private func provider(_ counter: RequestCounter) -> (String) async throws
        -> GeneratedExplanation
    {
        { text in
            await counter.increment()
            return GeneratedExplanation(
                explanation: SegmentExplanation(translation: "译:\(text)", explanation: "讲解"),
                meta: ExplanationMeta(
                    targetLanguage: "zh-CN", providerId: "p", modelId: "m",
                    promptVersion: PromptLibrary.segmentExplainVersion,
                    generatedAt: .now, sourceTextHash: SourceTextHash.of(text)))
        }
    }

    /// 同一句原文在另一篇文章里出现，不该再付一次钱。
    @Test func sameSentenceInAnotherArticleCostsNothing() async throws {
        let (store, _, _) = try makeStore()
        await store.load()
        let counter = RequestCounter()
        store.explanationProvider = provider(counter)

        store.importArticle(title: "A", content: "これは同じ文です。")
        let first = try #require(store.articles.first { $0.title == "A" })
        let firstSegment = store.segments(for: first.id)[0].id
        #expect(await store.generateExplanation(articleID: first.id, segmentID: firstSegment))
        await store.flushPersistence()
        #expect(await counter.value == 1)

        store.importArticle(title: "B", content: "これは同じ文です。")
        let second = try #require(store.articles.first { $0.title == "B" })
        let secondSegment = store.segments(for: second.id)[0].id
        #expect(await store.generateExplanation(articleID: second.id, segmentID: secondSegment))

        // 第二次是复用，没有新的 API 调用
        #expect(await counter.value == 1)
        #expect(store.segments(for: second.id)[0].explanation?.translation == "译:これは同じ文です。")
    }

    /// 首尾空白不同的同一句话也该命中（哈希做了 trim + NFKC）。
    @Test func normalizationMakesWhitespaceVariantsMatch() async throws {
        let (store, _, _) = try makeStore()
        await store.load()
        let counter = RequestCounter()
        store.explanationProvider = provider(counter)

        store.importArticle(title: "A", content: "テスト文です。")
        let a = try #require(store.articles.first { $0.title == "A" })
        _ = await store.generateExplanation(
            articleID: a.id, segmentID: store.segments(for: a.id)[0].id)
        await store.flushPersistence()

        // 复用查询用的是归一化后的哈希
        let reused = await store.reusableExplanation(for: "  テスト文です。  ")
        #expect(reused?.translation == "译:テスト文です。")
        #expect(await counter.value == 1)
    }

    /// **大小写不能撞哈希**——"Turkey" 与 "turkey" 是两个意思，复用会给出错误的讲解。
    @Test func caseDifferenceIsNotReused() async throws {
        #expect(SourceTextHash.of("Turkey is a country.") != SourceTextHash.of("turkey is a bird."))
        #expect(SourceTextHash.of("The Sie form.") != SourceTextHash.of("The sie form."))
        // 但首尾空白与全角半角要归一
        #expect(SourceTextHash.of(" same ") == SourceTextHash.of("same"))
    }

    /// 讲解语言换了之后，旧结果不能复用。
    @Test func doesNotReuseAcrossTargetLanguages() async throws {
        let (store, _, defaults) = try makeStore()
        await store.load()
        let counter = RequestCounter()
        store.explanationProvider = provider(counter)

        store.importArticle(title: "A", content: "これは同じ文です。")
        let a = try #require(store.articles.first { $0.title == "A" })
        _ = await store.generateExplanation(
            articleID: a.id, segmentID: store.segments(for: a.id)[0].id)
        await store.flushPersistence()

        defaults.set("en", forKey: "learning.targetLanguage")
        #expect(await store.reusableExplanation(for: "これは同じ文です。") == nil)
    }

    /// 打开一篇全是已精讲原文的新文章时，整篇批量回填、零 API 调用。
    ///
    /// 这是复用威力最大的场景：重新导入一本读过的书。
    @Test func backfillsWholeArticleOnOpenWithZeroCalls() async throws {
        let (store, repository, defaults) = try makeStore()
        await store.load()
        let counter = RequestCounter()
        store.explanationProvider = provider(counter)

        // 先精讲三句
        store.importArticle(title: "原文章", content: "一句目。二句目。三句目。")
        let original = try #require(store.articles.first { $0.title == "原文章" })
        for segment in store.segments(for: original.id) {
            _ = await store.generateExplanation(articleID: original.id, segmentID: segment.id)
        }
        await store.flushPersistence()
        #expect(await counter.value == 3)

        // 模拟"重新导入"：同样的正文，全新的 segment UUID
        let restarted = ContentStore(repository: repository, defaults: defaults)
        await restarted.load()
        restarted.explanationProvider = provider(counter)
        restarted.importArticle(title: "重新导入", content: "一句目。二句目。三句目。")
        let reimported = try #require(restarted.articles.first { $0.title == "重新导入" })
        await restarted.openArticle(reimported.id)

        let segments = restarted.segments(for: reimported.id)
        #expect(segments.count == 3)
        #expect(segments.allSatisfy { $0.explanation != nil })
        // 一次新调用都没有
        #expect(await counter.value == 3)
    }

    /// 复用失败时必须照常调 AI——省钱的优化不能挡住主路径。
    @Test func fallsBackToProviderWhenNothingToReuse() async throws {
        let (store, _, _) = try makeStore()
        await store.load()
        let counter = RequestCounter()
        store.explanationProvider = provider(counter)

        store.importArticle(title: "A", content: "全新的一句话。")
        let a = try #require(store.articles.first { $0.title == "A" })
        #expect(
            await store.generateExplanation(
                articleID: a.id, segmentID: store.segments(for: a.id)[0].id))
        #expect(await counter.value == 1)
    }
}

private actor RequestCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
