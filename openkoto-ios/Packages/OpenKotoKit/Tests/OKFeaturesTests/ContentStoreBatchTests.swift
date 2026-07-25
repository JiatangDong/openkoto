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

    @Test func cancelBatchStopsAndClearsProgress() async throws {
        let (store, _, _) = try makeStore()
        await store.load()
        let articleID = importSample(store)
        store.translationProvider = { text in
            try? await Task.sleep(for: .milliseconds(50))
            return "译:\(text)"
        }
        store.batchTranslateAll(articleID: articleID)
        store.cancelBatch(articleID: articleID)
        #expect(store.batchByArticle[articleID] == nil)
        #expect(!store.isBatchRunning(articleID: articleID))
    }
}
