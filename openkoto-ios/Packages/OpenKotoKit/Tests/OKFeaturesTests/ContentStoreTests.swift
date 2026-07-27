import Foundation
import Testing
import OKModels
import OKAIClient
import OKPersistence
@testable import OKFeatures

private func stubExplanation(for text: String) -> GeneratedExplanation {
    GeneratedExplanation(
        explanation: SegmentExplanation(translation: "译:\(text)", explanation: "讲解"),
        meta: ExplanationMeta(
            targetLanguage: "zh-CN", providerId: "moonshot", modelId: "kimi-k2",
            promptVersion: "explain-v1", generatedAt: .now, sourceTextHash: "hash"))
}

/// ContentStore 与 GRDB 的接线测试：用同一个内存库开两个 store 实例模拟「重启」，
/// 验证导入/删除/精讲/收藏都真实落库、示例内容只种子一次。
@MainActor
@Suite struct ContentStoreTests {
    /// 每个测试独立的 UserDefaults 域（用后清理），避免种子防重标志串场。
    private func makeDefaults() -> UserDefaults {
        let suiteName = "ContentStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeStore() throws -> (ContentStore, ContentRepository, UserDefaults) {
        let repository = try ContentRepository(database: AppDatabase.inMemory())
        let defaults = makeDefaults()
        return (ContentStore(repository: repository, defaults: defaults), repository, defaults)
    }


    // MARK: - 首启种子

    @Test func firstLoadSeedsSampleArticlesButNoFavorites() async throws {
        let (store, _, _) = try makeStore()
        await store.load()

        // 示例文章是 App Review 硬约束（设计文档 §433a），必须在
        #expect(store.articles.count == 2)
        #expect(store.articles[0].title.contains("夢十夜"))
        let (explained, total) = store.progress(for: store.articles[0].id)
        #expect(total == 9)
        #expect(explained == 2)   // 预置精讲随示例文章保留
        // mock 生词收藏已清理：生词本从真实收藏流程开始
        #expect(store.favorites.isEmpty)
    }

    @Test func samplesDoNotComeBackAfterUserDeletesThem() async throws {
        let (store, repository, defaults) = try makeStore()
        await store.load()
        for article in store.articles {
            store.deleteArticle(article.id)
        }
        await store.flushPersistence()

        // 模拟重启：同库同 defaults 新实例
        let restarted = ContentStore(repository: repository, defaults: defaults)
        await restarted.load()
        #expect(restarted.articles.isEmpty)
    }

    // MARK: - 导入 / 删除持久化

    @Test func importedArticleSurvivesRestart() async throws {
        let (store, repository, defaults) = try makeStore()
        await store.load()
        store.importArticle(title: "新文章", content: "第一句。第二句。")
        await store.flushPersistence()

        let restarted = ContentStore(repository: repository, defaults: defaults)
        await restarted.load()
        let imported = try #require(restarted.articles.first { $0.title == "新文章" })
        await restarted.openArticle(imported.id)
        let segments = restarted.segments(for: imported.id)
        #expect(!segments.isEmpty)
        #expect(segments.map(\.order) == Array(0..<segments.count))
    }

    @Test func deleteArticlePersistsAndKeepsFavoriteTitleSnapshot() async throws {
        let (store, repository, defaults) = try makeStore()
        await store.load()
        let article = try #require(store.articles.first)
        store.toggleFavorite(
            VocabularyItem(word: "夢", meaning: "梦", reading: "ゆめ"), source: article)
        store.deleteArticle(article.id)
        await store.flushPersistence()

        let restarted = ContentStore(repository: repository, defaults: defaults)
        await restarted.load()
        #expect(!restarted.articles.contains { $0.id == article.id })
        // 注:#require 携带 FavoriteVocabulary 载荷会触发 arm64e 指针认证崩溃(编译器缺陷),用 guard-let 绕过
        guard let favorite = restarted.favorites.first(where: { $0.word == "夢" }) else {
            Issue.record("favorite 夢 not found")
            return
        }
        #expect(favorite.sourceArticleId == nil)
        #expect(favorite.sourceArticleTitle == article.title)
    }

    // MARK: - 精讲

    @Test func explanationWithoutProviderReportsNotConfigured() async throws {
        let (store, _, _) = try makeStore()
        await store.load()
        let article = try #require(store.articles.first)
        // 句子按需加载：读到正文前必须先 openArticle（对应 ReaderView 的 .task）。
        await store.openArticle(article.id)
        let plain = try #require(store.segments(for: article.id).first { $0.explanation == nil })

        await store.generateExplanation(articleID: article.id, segmentID: plain.id)

        // 不再伪造占位精讲：显式报未配置模型
        #expect(store.generationErrors[plain.id] == .notConfigured)
        let after = try #require(store.segments(for: article.id).first { $0.id == plain.id })
        #expect(after.explanation == nil)
    }

    @Test func generatedExplanationSurvivesRestart() async throws {
        let (store, repository, defaults) = try makeStore()
        await store.load()
        store.explanationProvider = { stubExplanation(for: $0) }
        let article = try #require(store.articles.first)
        await store.openArticle(article.id)
        let plain = try #require(store.segments(for: article.id).first { $0.explanation == nil })

        await store.generateExplanation(articleID: article.id, segmentID: plain.id)
        await store.flushPersistence()

        let restarted = ContentStore(repository: repository, defaults: defaults)
        await restarted.load()
        await restarted.openArticle(article.id)
        let segment = try #require(
            restarted.segments(for: article.id).first { $0.id == plain.id })
        #expect(segment.explanation?.translation == "译:\(plain.text)")
        #expect(segment.translation == "译:\(plain.text)")
    }

    // MARK: - 收藏

    @Test func favoriteTogglePersistsBothWays() async throws {
        let (store, repository, defaults) = try makeStore()
        await store.load()
        let article = try #require(store.articles.first)
        let item = VocabularyItem(word: "枕元", meaning: "枕边", reading: "まくらもと")

        store.toggleFavorite(item, source: article)
        #expect(store.isFavorite(word: "枕元"))
        await store.flushPersistence()

        let restarted = ContentStore(repository: repository, defaults: defaults)
        await restarted.load()
        #expect(restarted.isFavorite(word: "枕元"))

        restarted.toggleFavorite(item, source: article)
        #expect(!restarted.isFavorite(word: "枕元"))
        await restarted.flushPersistence()

        let restartedAgain = ContentStore(repository: repository, defaults: defaults)
        await restartedAgain.load()
        #expect(!restartedAgain.isFavorite(word: "枕元"))
    }

    // MARK: - 词包管理

    @Test func packCrudPersistsAcrossRestart() async throws {
        let (store, repository, defaults) = try makeStore()
        await store.load()
        #expect(store.packs.contains { $0.id == WordPack.systemUngroupedID })

        guard let pack = store.createPack(name: "  N2 词汇  ") else {
            Issue.record("createPack returned nil")
            return
        }
        #expect(pack.name == "N2 词汇")
        #expect(store.createPack(name: "   ") == nil)
        #expect(store.renamePack(pack.id, name: "N1 词汇"))
        #expect(!store.renamePack(WordPack.systemUngroupedID, name: "改名"))
        await store.flushPersistence()

        let restarted = ContentStore(repository: repository, defaults: defaults)
        await restarted.load()
        #expect(restarted.packs.first { $0.id == pack.id }?.name == "N1 词汇")
    }

    @Test func deletePackReassignsWordsAndClearsFilter() async throws {
        let (store, repository, defaults) = try makeStore()
        await store.load()
        guard let pack = store.createPack(name: "临时包") else {
            Issue.record("createPack returned nil")
            return
        }
        #expect(store.addManualWord(
            word: "孤児", meaning: "孤儿", reading: nil, usage: nil, example: nil,
            packIds: [pack.id]))
        store.activePackId = pack.id

        store.deletePack(pack.id)
        #expect(store.activePackId == nil)
        #expect(!store.packs.contains { $0.id == pack.id })
        #expect(store.favorites.first?.packIds == [WordPack.systemUngroupedID])
        await store.flushPersistence()

        let restarted = ContentStore(repository: repository, defaults: defaults)
        await restarted.load()
        #expect(restarted.favorites.first?.packIds == [WordPack.systemUngroupedID])
    }

    @Test func setPackIdsSanitizesEmptyToUngrouped() async throws {
        let (store, repository, defaults) = try makeStore()
        await store.load()
        guard let pack = store.createPack(name: "合集A") else {
            Issue.record("createPack returned nil")
            return
        }
        #expect(store.addManualWord(
            word: "夢", meaning: "梦", reading: nil, usage: nil, example: nil,
            packIds: [pack.id]))
        guard let id = store.favorites.first?.id else {
            Issue.record("favorites is empty")
            return
        }

        store.setPackIds(id, packIds: [])
        #expect(store.favorites.first?.packIds == [WordPack.systemUngroupedID])
        await store.flushPersistence()

        let restarted = ContentStore(repository: repository, defaults: defaults)
        await restarted.load()
        #expect(restarted.favorites.first?.packIds == [WordPack.systemUngroupedID])
    }

    @Test func dueQueueHonorsActivePackFilter() async throws {
        let (store, _, _) = try makeStore()
        await store.load()
        guard let pack = store.createPack(name: "合集B") else {
            Issue.record("createPack returned nil")
            return
        }
        #expect(store.addManualWord(
            word: "内側", meaning: "内侧", reading: nil, usage: nil, example: nil,
            packIds: [pack.id]))
        #expect(store.addManualWord(
            word: "外側", meaning: "外侧", reading: nil, usage: nil, example: nil))
        await store.flushPersistence()

        store.activePackId = pack.id
        let filtered = await store.dueQueue()
        #expect(filtered.map(\.word) == ["内側"])

        store.activePackId = nil
        let all = await store.dueQueue()
        #expect(Set(all.map(\.word)) == ["内側", "外側"])
    }

    /// 同日巩固步骤（规范 §2.8）：没答对的卡留在今天。
    ///
    /// FSRS 的最小间隔是 1 天，照搬就意味着一答错当天再也见不到那张卡——
    /// 而它恰恰是最该再看一遍的。记忆状态仍按 again/hard 正常更新，只覆盖 due_date。
    @Test func failingACardKeepsItDueToday() async throws {
        let (store, repository, defaults) = try makeStore()
        await store.load()
        let today = ContentStore.localDateString()
        #expect(store.addManualWord(
            word: "曖昧", meaning: "暧昧", reading: nil, usage: nil, example: nil))
        let id = try #require(store.favorites.first?.id)

        store.review(id, grade: .again)
        #expect(store.favorites.first?.dueDate == today)
        #expect(store.favorites.first?.srsState == .learning)

        store.review(id, grade: .hard)
        #expect(store.favorites.first?.dueDate == today)

        // 点「认识」才排到未来，间隔由 FSRS 从当时的记忆状态算出。
        store.review(id, grade: .good)
        let due = try #require(store.favorites.first?.dueDate)
        #expect(due > today)
        #expect(store.favorites.first?.reviewCount == 3)

        // 关键在于**落盘**：纯会话内回队做不到"中途退出再进来卡片还在今日队列"。
        // 用同一个库另开一个 store 模拟重启，重放到 again 这一步。
        await store.flushPersistence()
        store.review(id, grade: .again)
        await store.flushPersistence()
        let restarted = ContentStore(repository: repository, defaults: defaults)
        await restarted.load()
        #expect(restarted.favorites.first?.dueDate == today)
        #expect(await restarted.dueQueue().map(\.word) == ["曖昧"])
    }

    /// 提前复习只发未来到期的卡，且尊重当前词包。
    @Test func aheadQueueSkipsTodayAndHonorsThePackFilter() async throws {
        let (store, repository, _) = try makeStore()
        await store.load()
        guard let pack = store.createPack(name: "合集C") else {
            Issue.record("createPack returned nil")
            return
        }
        #expect(store.addManualWord(
            word: "明日", meaning: "明天", reading: nil, usage: nil, example: nil,
            packIds: [pack.id]))
        #expect(store.addManualWord(
            word: "今日", meaning: "今天", reading: nil, usage: nil, example: nil))
        await store.flushPersistence()

        // 「明日」推到未来；「今日」留在今天。
        let tomorrowCard = try #require(store.favorites.first { $0.word == "明日" })
        var moved = tomorrowCard
        moved.dueDate = ContentStore.localDateString(
            Calendar.current.date(byAdding: .day, value: 3, to: .now)!)
        try await repository.updateFavorite(moved)
        await store.load()

        #expect(await store.dueQueue().map(\.word) == ["今日"])
        #expect(await store.aheadQueue().map(\.word) == ["明日"])
        #expect(store.aheadAvailableCount == 1)

        store.activePackId = pack.id
        #expect(await store.aheadQueue().map(\.word) == ["明日"])
        #expect(store.aheadAvailableCount == 1)
    }
}
