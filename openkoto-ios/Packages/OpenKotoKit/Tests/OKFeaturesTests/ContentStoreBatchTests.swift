import Foundation
import Testing
import OKModels
import OKAIClient
import OKPersistence
@testable import OKFeatures

/// 翻译路径 + 全文批量任务（精讲/翻译）的接线测试。
@MainActor
@Suite struct ContentStoreBatchTests {
    private func makeStore() throws -> (ContentStore, ContentRepository, UserDefaults) {
        let repository = try ContentRepository(database: AppDatabase.inMemory())
        let suite = "ContentStoreBatchTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (ContentStore(repository: repository, defaults: defaults), repository, defaults)
    }

    private func importSample(_ store: ContentStore) -> UUID {
        store.importArticle(title: "T", content: "一句目。二句目。三句目。")
        return store.articles.first { $0.title == "T" }!.id
    }

    private func waitForBatch(_ store: ContentStore, _ id: UUID) async throws {
        var guardCount = 0
        while store.isBatchRunning(articleID: id) {
            try await Task.sleep(for: .milliseconds(10))
            guardCount += 1
            #expect(guardCount < 500, "batch did not finish in time")
            if guardCount >= 500 { break }
        }
    }

    // MARK: - 单句翻译（快翻）

    @Test func generateTranslationFillsTranslationAndPersists() async throws {
        let (store, repository, defaults) = try makeStore()
        await store.load()
        let articleID = importSample(store)
        store.translationProvider = { "T:\($0)" }
        let segmentID = store.segments(for: articleID)[0].id

        let ok = await store.generateTranslation(articleID: articleID, segmentID: segmentID)
        #expect(ok)
        let segment = store.segments(for: articleID).first { $0.id == segmentID }
        #expect(segment?.translation == "T:一句目。")
        #expect(segment?.explanation == nil)   // 只翻译，不精讲

        await store.flushPersistence()
        let restarted = ContentStore(repository: repository, defaults: defaults)
        await restarted.load()
        await restarted.openArticle(articleID)
        #expect(restarted.segments(for: articleID).first { $0.id == segmentID }?.translation
            == "T:一句目。")
    }

    @Test func translationWithoutProviderReportsNotConfigured() async throws {
        let (store, _, _) = try makeStore()
        await store.load()
        let articleID = importSample(store)
        let segmentID = store.segments(for: articleID)[0].id

        let ok = await store.generateTranslation(articleID: articleID, segmentID: segmentID)
        #expect(!ok)
        #expect(store.generationErrors[segmentID] == .notConfigured)
    }

    // MARK: - 全文批量翻译 / 精讲

    @Test func batchTranslateAllFillsEverySegment() async throws {
        let (store, _, _) = try makeStore()
        await store.load()
        let articleID = importSample(store)
        store.translationProvider = { "译:\($0)" }

        store.batchTranslateAll(articleID: articleID)
        try await waitForBatch(store, articleID)

        let segments = store.segments(for: articleID)
        #expect(segments.allSatisfy { $0.translation != nil })
        #expect(store.batchByArticle[articleID] == nil)   // 完成后清理进度
    }

    @Test func batchExplainAllFillsEverySegment() async throws {
        let (store, repository, defaults) = try makeStore()
        await store.load()
        let articleID = importSample(store)
        store.explanationProvider = { text in
            GeneratedExplanation(
                explanation: SegmentExplanation(translation: "译:\(text)", explanation: "讲"),
                meta: ExplanationMeta(
                    targetLanguage: "zh-CN", providerId: "p", modelId: "m",
                    promptVersion: "explain-v1", generatedAt: .now, sourceTextHash: "h"))
        }

        store.batchExplainAll(articleID: articleID)
        try await waitForBatch(store, articleID)

        #expect(store.progress(for: articleID) == (explained: 3, total: 3))
        await store.flushPersistence()
        let restarted = ContentStore(repository: repository, defaults: defaults)
        await restarted.load()
        #expect(restarted.progress(for: articleID).explained == 3)
    }

    @Test func batchTranslateSkipsAlreadyExplained() async throws {
        let (store, _, _) = try makeStore()
        await store.load()
        let articleID = importSample(store)
        store.explanationProvider = { text in
            GeneratedExplanation(
                explanation: SegmentExplanation(translation: "E", explanation: "x"),
                meta: ExplanationMeta(
                    targetLanguage: "zh-CN", providerId: "p", modelId: "m",
                    promptVersion: "explain-v1", generatedAt: .now, sourceTextHash: "h"))
        }
        let first = store.segments(for: articleID)[0].id
        await store.generateExplanation(articleID: articleID, segmentID: first)

        var translated: [String] = []
        store.translationProvider = { translated.append($0); return "译:\($0)" }
        store.batchTranslateAll(articleID: articleID)
        try await waitForBatch(store, articleID)

        // 已精讲的第一句不再被翻译请求命中
        #expect(translated.count == 2)
        #expect(store.segments(for: articleID)[0].translation == "E")   // 保留精讲的译文
    }

    /// 取消**不是瞬时的**：在飞的请求要断开需要时间。
    ///
    /// 旧实现把 `batchTasks` 同步清空，于是 `isBatchRunning` 立刻变 false、
    /// `startBatch` 的 guard 失效——用户"取消后立刻重开"会叠加两批请求、账单翻倍
    /// 且毫无察觉。现在取消期间任务仍在册，状态标成 `.cancelling`。
    @Test func cancelBatchEntersCancellingThenClears() async throws {
        let (store, _, _) = try makeStore()
        await store.load()
        let articleID = importSample(store)
        store.translationProvider = { text in
            try await Task.sleep(for: .milliseconds(50))
            return "译:\(text)"
        }
        store.batchTranslateAll(articleID: articleID)
        store.cancelBatch(articleID: articleID)

        // 取消窗口期内：状态可见、任务仍在册
        #expect(store.batchByArticle[articleID]?.phase == .cancelling)
        #expect(store.isBatchRunning(articleID: articleID))

        // 收尾后自行清干净
        try await waitForBatch(store, articleID)
        #expect(store.batchByArticle[articleID] == nil)
        #expect(!store.isBatchRunning(articleID: articleID))
    }

    /// 取消窗口期内重开会叠加两批请求——这是旧实现最花钱的 bug。
    @Test func cannotStartSecondBatchWhileCancelling() async throws {
        let (store, _, _) = try makeStore()
        await store.load()
        let articleID = importSample(store)
        let counter = RequestCounter()
        store.translationProvider = { text in
            await counter.increment()
            try await Task.sleep(for: .milliseconds(60))
            return "译:\(text)"
        }

        store.batchTranslateAll(articleID: articleID)
        store.cancelBatch(articleID: articleID)
        store.batchTranslateAll(articleID: articleID)  // 立刻重开：必须被挡住
        try await waitForBatch(store, articleID)

        // 三句话最多只会有第一批的请求在飞，不该出现第二批
        #expect(await counter.value <= 3)
    }

    /// 取消要真的传播到在飞的子任务，否则请求跑完照样计费。
    @Test func cancelPropagatesToInFlightRequests() async throws {
        let (store, _, _) = try makeStore()
        await store.load()
        let articleID = importSample(store)
        let counter = RequestCounter()
        store.translationProvider = { text in
            await counter.increment()
            // 足够长，保证取消发生在请求进行中
            try await Task.sleep(for: .milliseconds(200))
            return "译:\(text)"
        }

        store.batchTranslateAll(articleID: articleID)
        try await Task.sleep(for: .milliseconds(20))
        store.cancelBatch(articleID: articleID)
        try await waitForBatch(store, articleID)

        // 并发度默认 3，取消后不应再有新一批发出
        #expect(await counter.value <= 3)
        // 被取消的句子不该留下译文
        #expect(store.segments(for: articleID).allSatisfy { $0.translation == nil })
    }
}

/// 统计 provider 被调用了几次。
private actor RequestCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// 批量范围。视频文稿是一整个 article——一小时视频 600 句，
/// 不划范围一键全做就是 600 次调用。
@MainActor
@Suite struct BatchScopeTests {
    private func makeStore() throws -> ContentStore {
        let repository = try ContentRepository(database: AppDatabase.inMemory())
        let suite = "BatchScopeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return ContentStore(repository: repository, defaults: defaults)
    }

    /// 十句话的文章。
    private func importTen(_ store: ContentStore) -> UUID {
        let content = (0..<10).map { "第\($0)句。" }.joined()
        store.importArticle(title: "T", content: content)
        return store.articles.first { $0.title == "T" }!.id
    }

    @Test func countsPendingWithinScope() throws {
        let store = try makeStore()
        let id = importTen(store)
        #expect(store.segments(for: id).count == 10)
        #expect(store.pendingCount(articleID: id, kind: .explain, scope: .all) == 10)
        #expect(
            store.pendingCount(articleID: id, kind: .explain, scope: .from(order: 3, count: 4))
                == 4)
        #expect(
            store.pendingCount(articleID: id, kind: .explain, scope: .orderRange(0...2)) == 3)
    }

    /// 范围超出末尾时按实际剩余算，不能报一个大于总数的假数字。
    @Test func clampsScopeAtEnd() throws {
        let store = try makeStore()
        let id = importTen(store)
        #expect(
            store.pendingCount(articleID: id, kind: .explain, scope: .from(order: 8, count: 50))
                == 2)
    }

    /// 只处理范围内的句子——范围外的一句都不能碰。
    @Test func onlyProcessesSegmentsInScope() async throws {
        let store = try makeStore()
        await store.load()
        let id = importTen(store)
        store.translationProvider = { "译:\($0)" }

        store.batchTranslateAll(articleID: id, scope: .from(order: 2, count: 3))
        var guardCount = 0
        while store.isBatchRunning(articleID: id) {
            try await Task.sleep(for: .milliseconds(10))
            guardCount += 1
            if guardCount > 300 { break }
        }

        let translated = store.segments(for: id).filter { $0.translation != nil }
        #expect(translated.map(\.order) == [2, 3, 4])
    }

    /// 已处理过的句子不重复计入——省钱的前提是不重复做。
    @Test func excludesAlreadyProcessed() async throws {
        let store = try makeStore()
        await store.load()
        let id = importTen(store)
        store.translationProvider = { "译:\($0)" }
        _ = await store.generateTranslation(
            articleID: id, segmentID: store.segments(for: id)[0].id)

        #expect(store.pendingCount(articleID: id, kind: .translate, scope: .all) == 9)
    }
}
