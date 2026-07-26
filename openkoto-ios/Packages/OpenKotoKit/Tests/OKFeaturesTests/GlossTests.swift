import Foundation
import OKAIClient
import OKModels
import OKPersistence
import Testing

@testable import OKFeatures

/// 单词查询。这条路径存在的全部意义是**便宜**——所以缓存与去重是它的核心契约，
/// 不是优化。
@MainActor
@Suite struct GlossTests {
    private func makeStore() throws -> ContentStore {
        let repository = try ContentRepository(database: AppDatabase.inMemory())
        let suite = "GlossTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return ContentStore(repository: repository, defaults: defaults)
    }

    private func item(_ word: String) -> VocabularyItem {
        VocabularyItem(word: word, meaning: "释义:\(word)", reading: "よみ")
    }

    // MARK: - 分词（不花钱、不需要先精讲）

    @Test func splitsSentenceIntoLookupCandidates() throws {
        let store = try makeStore()
        let words = store.lookupCandidates(in: "これは日本語の字幕です。").map(\.text)
        #expect(words.contains("字幕"))
        #expect(!words.contains("。"))
    }

    // MARK: - 缓存（核心契约）

    /// 同一个词查第二次不能再发请求。用户读得越多，重复词越多，这是复利。
    @Test func secondLookupOfSameWordCostsNothing() async throws {
        let store = try makeStore()
        let counter = RequestCounter()
        store.glossProvider = { word, _ in
            await counter.increment()
            return self.item(word)
        }

        let first = await store.gloss(word: "字幕", in: "これは日本語の字幕です。")
        let second = await store.gloss(word: "字幕", in: "別の文にも字幕がある。")
        #expect(first?.meaning == "释义:字幕")
        #expect(second?.meaning == "释义:字幕")
        #expect(await counter.value == 1)
    }

    /// 大小写/首尾空白不同的同一个词也该命中缓存。
    @Test func cacheKeyIsNormalized() async throws {
        let store = try makeStore()
        let counter = RequestCounter()
        store.glossProvider = { word, _ in
            await counter.increment()
            return self.item(word)
        }

        _ = await store.gloss(word: "Thorough", in: "s")
        _ = await store.gloss(word: " thorough ", in: "s")
        #expect(await counter.value == 1)
    }

    /// 精讲已经给过的词不该再花钱查一次——那些词已经付过费了。
    @Test func reusesVocabularyFromExistingExplanation() async throws {
        let store = try makeStore()
        let counter = RequestCounter()
        store.glossProvider = { word, _ in
            await counter.increment()
            return self.item(word)
        }

        store.warmGlossCache(
            from: SegmentExplanation(
                translation: "t", explanation: "e",
                vocabulary: [VocabularyItem(word: "字幕", meaning: "来自精讲", reading: "じまく")]))

        let result = await store.gloss(word: "字幕", in: "これは字幕です。")
        #expect(result?.meaning == "来自精讲")
        #expect(await counter.value == 0)
    }

    // MARK: - 失败与重试

    @Test func reportsNotConfiguredWithoutProvider() async throws {
        let store = try makeStore()
        _ = await store.gloss(word: "字幕", in: "これは字幕です。")
        #expect(store.glossState(for: "字幕") == .failed(.notConfigured))
    }

    /// 失败的查询要能重试，且重试会真的重新发请求。
    @Test func retryClearsFailureAndCallsAgain() async throws {
        let store = try makeStore()
        let counter = RequestCounter()
        store.glossProvider = { word, _ in
            await counter.increment()
            if await counter.value == 1 { throw AIClientError.rateLimited }
            return self.item(word)
        }

        _ = await store.gloss(word: "字幕", in: "これは字幕です。")
        #expect(store.glossState(for: "字幕") == .failed(.rateLimited))

        await store.retryGloss(word: "字幕", in: "これは字幕です。")
        #expect(store.glossState(for: "字幕") == .loaded(item("字幕")))
        #expect(await counter.value == 2)
    }

    /// 取消不该留下失败态——否则用户下次点这个词会看到一个假的错误。
    @Test func cancellationLeavesNoFailureState() async throws {
        let store = try makeStore()
        store.glossProvider = { _, _ in throw CancellationError() }
        _ = await store.gloss(word: "字幕", in: "これは字幕です。")
        #expect(store.glossState(for: "字幕") == nil)
    }

    // MARK: - 收藏接线

    /// 查到的词条能直接进生词本，用户一个字都不用打。
    @Test func glossResultGoesStraightIntoVocabulary() async throws {
        let store = try makeStore()
        await store.load()
        store.glossProvider = { word, _ in self.item(word) }
        store.importArticle(title: "T", content: "これは日本語の字幕です。")
        let article = try #require(store.articles.first { $0.title == "T" })

        let looked = try #require(await store.gloss(word: "字幕", in: "これは日本語の字幕です。"))
        store.toggleFavorite(looked, source: article)

        let saved = try #require(store.favorites.first { $0.word == "字幕" })
        #expect(saved.meaning == "释义:字幕")
        #expect(saved.sourceArticleId == article.id)
    }
}

private actor RequestCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
