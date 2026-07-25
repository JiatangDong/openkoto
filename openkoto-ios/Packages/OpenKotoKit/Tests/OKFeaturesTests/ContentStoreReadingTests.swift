import Foundation
import OKModels
import OKPersistence
import Testing

@testable import OKFeatures

/// 阅读页词级注音的接线：打开文章 → 后台注音 → 按 segmentID 取 runs。
@MainActor
@Suite struct ContentStoreReadingTests {
    private func makeStore() throws -> ContentStore {
        let repository = try ContentRepository(database: AppDatabase.inMemory())
        let suiteName = "ContentStoreReadingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return ContentStore(repository: repository, defaults: defaults)
    }

    private func openArticle(_ store: ContentStore, content: String) async -> UUID {
        store.importArticle(title: "T", content: content)
        let id = store.articles[0].id
        await store.openArticle(id)
        return id
    }

    /// 日语文章：打开即有注音，且注音只落在含汉字的词上。
    @Test func annotatesJapaneseArticleOnOpen() async throws {
        let store = try makeStore()
        let id = await openArticle(store, content: "夜に駆ける。君の声が聞こえる。")

        let runs = store.readingRuns(for: id)
        #expect(!runs.isEmpty)

        for (segmentID, segmentRuns) in runs {
            let segment = store.segments(for: id).first { $0.id == segmentID }
            // 注音不能改写正文
            #expect(segmentRuns.plainText == segment?.text)
            #expect(segmentRuns.hasReadings)
        }
    }

    /// 语种判不出来（英文）时整篇不标注——开关会因此灰掉。
    @Test func skipsAnnotationForUnsupportedLanguage() async throws {
        let store = try makeStore()
        let id = try await openArticle(
            store, content: "The quick brown fox jumps over the lazy dog. It was a fine day.")
        #expect(store.readingRuns(for: id).isEmpty)
    }

    /// 中文文章注拼音，且不会被误判成日语（注出假名）。
    @Test func annotatesChineseArticleWithPinyin() async throws {
        let store = try makeStore()
        let id = try await openArticle(
            store, content: "银行行长说这首歌的长度不够。他每天都来这里散步。")

        let readings = store.readingRuns(for: id).values.flatMap { $0 }.compactMap(\.reading)
        #expect(!readings.isEmpty)
        #expect(readings.allSatisfy { !ReadingLanguageDetectorProbe.containsKana($0) })
    }

    /// 精讲带回的生词读音比离线注音准，落库后要立刻盖上去（不必退出重进）。
    @Test func explanationVocabularyOverridesOfflineReading() async throws {
        let store = try makeStore()
        let id = await openArticle(store, content: "仰向に寝た。")
        let segmentID = try #require(store.segments(for: id).first).id

        // 离线注音器把「仰向」拆成两个词读错了：仰(あおぐ) + 向(むき)
        let before = try #require(store.readingRuns(for: id)[segmentID])
        #expect(before.contains { $0.text == "仰" && $0.reading == "あおぐ" })
        #expect(before.contains { $0.text == "向" && $0.reading == "むき" })

        store.explanationProvider = { _ in
            GeneratedExplanation(
                explanation: SegmentExplanation(
                    translation: "仰面躺着。", explanation: "讲解",
                    vocabulary: [
                        VocabularyItem(word: "仰向", meaning: "仰面", reading: "あおむけ")
                    ]),
                meta: ExplanationMeta(
                    targetLanguage: "zh-CN", providerId: "p", modelId: "m",
                    promptVersion: "explain-v1", generatedAt: .now, sourceTextHash: "h"))
        }
        #expect(await store.generateExplanation(articleID: id, segmentID: segmentID))

        // 一个覆盖段吃掉两个底层 run，合并成一个正确的注音
        let after = try #require(store.readingRuns(for: id)[segmentID])
        #expect(after.contains { $0.text == "仰向" && $0.reading == "あおむけ" })
        #expect(!after.contains { $0.reading == "あおぐ" || $0.reading == "むき" })
        #expect(after.plainText == "仰向に寝た。")
    }

    /// 英语这类系统给不出读音的语种：精讲之后靠 AI 的 IPA 也能有读音，
    /// 开关不再是死的。
    @Test func englishGetsReadingsFromExplanationOnly() async throws {
        let store = try makeStore()
        let id = await openArticle(
            store, content: "The thorough report arrived. It was a fine day for reading.")
        let segmentID = try #require(store.segments(for: id).first).id
        #expect(store.readingRuns(for: id).isEmpty)  // 离线层对英语无能为力

        store.explanationProvider = { _ in
            GeneratedExplanation(
                explanation: SegmentExplanation(
                    translation: "详尽的报告到了。", explanation: "讲解",
                    vocabulary: [
                        VocabularyItem(word: "thorough", meaning: "详尽的", reading: "ˈθʌrə")
                    ]),
                meta: ExplanationMeta(
                    targetLanguage: "zh-CN", providerId: "p", modelId: "m",
                    promptVersion: "explain-v1", generatedAt: .now, sourceTextHash: "h"))
        }
        #expect(await store.generateExplanation(articleID: id, segmentID: segmentID))

        let runs = try #require(store.readingRuns(for: id)[segmentID])
        #expect(runs.contains { $0.text == "thorough" && $0.reading == "ˈθʌrə" })
        #expect(runs.plainText == "The thorough report arrived.")
    }

    /// LRU 卸载文章时注音缓存要跟着走，否则读一本长书会一直涨。
    @Test func evictsReadingCacheWithSegments() async throws {
        let store = try makeStore()
        let first = await openArticle(store, content: "夜に駆ける。")
        #expect(!store.readingRuns(for: first).isEmpty)

        for index in 0..<ContentStore.loadedArticleLimit {
            _ = await openArticle(store, content: "東京へ行く。\(index)")
        }

        #expect(store.segmentsByArticle[first] == nil)
        #expect(store.readingRuns(for: first).isEmpty)
    }
}

/// 测试里判断字符串有没有假名。OKBooks 的判定器是 internal，这里不跨模块 @testable。
private enum ReadingLanguageDetectorProbe {
    static func containsKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
    }
}
