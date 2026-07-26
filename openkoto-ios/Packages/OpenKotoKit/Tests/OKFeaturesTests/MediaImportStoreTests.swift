import Foundation
import OKAIClient
import OKMedia
import OKModels
import OKPersistence
import Testing

@testable import OKFeatures

/// ContentStore 的媒体接线：导入字幕 → 文稿即 article → **既有学习管线一行不改就生效**。
///
/// 这一组测试是「复用 article/segment」这条主线的证明。播放器此时还不存在。
@MainActor
@Suite struct MediaImportStoreTests {
    private struct Harness {
        var store: ContentStore
        var content: ContentRepository
        var media: MediaRepository
        var storage: MediaStorage
        var defaults: UserDefaults
        var root: URL
    }

    private func makeHarness() throws -> Harness {
        let database = try AppDatabase.inMemory()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("okmedia-\(UUID().uuidString)")
        let storage = MediaStorage(root: root)
        try storage.prepare()
        let suiteName = "MediaImportStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let content = ContentRepository(database: database)
        let media = MediaRepository(database: database)
        return Harness(
            store: ContentStore(
                repository: content, mediaRepository: media, mediaStorage: storage,
                defaults: defaults),
            content: content, media: media, storage: storage, defaults: defaults, root: root)
    }

    /// 一句被字幕行切成两条 cue 的日语台词 + 一条独立句。
    private let sampleSRT = """
        1
        00:00:01,000 --> 00:00:03,000
        これは日本語の

        2
        00:00:03,000 --> 00:00:05,000
        字幕です。

        3
        00:00:06,500 --> 00:00:09,000
        勉強を続けましょう。
        """

    private func writeSubtitle(_ text: String, ext: String = "srt") throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sub-\(UUID().uuidString).\(ext)")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - 导入

    /// 跨 cue 合句必须在**入库这一层**就发生：库里存的是完整句子，
    /// 不是被字幕行宽切碎的片段。精讲拿到什么，取决于这里。
    @Test func importMergesSentencesAcrossCuesBeforePersisting() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        await harness.store.load()

        let subtitle = try writeSubtitle(sampleSRT)
        defer { try? FileManager.default.removeItem(at: subtitle) }

        let media = try #require(
            try await harness.store.importMedia(mediaURL: nil, subtitleURL: subtitle))
        await harness.store.flushPersistence()

        let articleID = try #require(harness.store.mediaArticleID(for: media.id))
        let segments = harness.store.segments(for: articleID)

        #expect(segments.count == 2)
        #expect(segments[0].text == "これは日本語の字幕です。")
        #expect(segments[1].text == "勉強を続けましょう。")
        // 时间轴落到句级
        #expect(segments[0].startTime == 1.0)
        #expect(segments[0].endTime == 5.0)
        #expect(segments[1].startTime == 6.5)
    }

    /// 重启后文稿与时间轴都还在。
    @Test func mediaSurvivesRestart() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        await harness.store.load()

        let subtitle = try writeSubtitle(sampleSRT)
        defer { try? FileManager.default.removeItem(at: subtitle) }
        let media = try #require(
            try await harness.store.importMedia(mediaURL: nil, subtitleURL: subtitle))
        await harness.store.flushPersistence()

        let restarted = ContentStore(
            repository: harness.content, mediaRepository: harness.media,
            mediaStorage: harness.storage, defaults: harness.defaults)
        await restarted.load()

        #expect(restarted.medias.map(\.id) == [media.id])
        let articleID = try #require(restarted.mediaArticleID(for: media.id))
        await restarted.openArticle(articleID)
        let segments = restarted.segments(for: articleID)
        #expect(segments.count == 2)
        #expect(segments[0].startTime == 1.0)
    }

    /// 媒体文稿不进书库顶层文章列表——它以视频卡片出现，不该重复成一条文章。
    @Test func transcriptDoesNotAppearInArticleList() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        await harness.store.load()
        let before = harness.store.articles.count

        let subtitle = try writeSubtitle(sampleSRT)
        defer { try? FileManager.default.removeItem(at: subtitle) }
        _ = try await harness.store.importMedia(mediaURL: nil, subtitleURL: subtitle)
        await harness.store.flushPersistence()

        let restarted = ContentStore(
            repository: harness.content, mediaRepository: harness.media,
            mediaStorage: harness.storage, defaults: harness.defaults)
        await restarted.load()
        #expect(restarted.articles.count == before)
        #expect(restarted.medias.count == 1)
    }

    // MARK: - 学习管线复用（这是整个设计的赌注）

    /// 精讲、生词收藏对媒体文稿**一行不改**即可生效。
    @Test func transcriptParticipatesInExplanationPipeline() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        await harness.store.load()
        harness.store.explanationProvider = { text in
            GeneratedExplanation(
                explanation: SegmentExplanation(
                    translation: "译:\(text)", explanation: "讲解",
                    vocabulary: [
                        VocabularyItem(word: "字幕", meaning: "字幕", reading: "じまく")
                    ]),
                meta: ExplanationMeta(
                    targetLanguage: "zh-CN", providerId: "p", modelId: "m",
                    promptVersion: "explain-v1", generatedAt: .now, sourceTextHash: "h"))
        }

        let subtitle = try writeSubtitle(sampleSRT)
        defer { try? FileManager.default.removeItem(at: subtitle) }
        let media = try #require(
            try await harness.store.importMedia(mediaURL: nil, subtitleURL: subtitle))
        let articleID = try #require(harness.store.mediaArticleID(for: media.id))
        let segmentID = harness.store.segments(for: articleID)[0].id

        #expect(await harness.store.generateExplanation(articleID: articleID, segmentID: segmentID))
        await harness.store.flushPersistence()

        let explained = harness.store.segments(for: articleID)[0]
        // LLM 拿到的是完整句子，不是半句
        #expect(explained.explanation?.translation == "译:これは日本語の字幕です。")
        // 时间轴不能被精讲写回抹掉
        #expect(explained.startTime == 1.0)

        // 生词照常收藏——文稿就是 article，收藏走的是同一条路
        let transcriptArticle = try #require(harness.store.chapterArticle(id: articleID))
        harness.store.toggleFavorite(
            VocabularyItem(word: "字幕", meaning: "字幕", reading: "じまく"),
            source: transcriptArticle)
        #expect(harness.store.favorites.contains { $0.word == "字幕" })
    }

    /// 词级注音对媒体文稿同样生效（日语文稿会被自动注上假名）。
    @Test func transcriptGetsReadingAnnotations() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        await harness.store.load()

        let subtitle = try writeSubtitle(sampleSRT)
        defer { try? FileManager.default.removeItem(at: subtitle) }
        let media = try #require(
            try await harness.store.importMedia(mediaURL: nil, subtitleURL: subtitle))
        let articleID = try #require(harness.store.mediaArticleID(for: media.id))
        await harness.store.openArticle(articleID)

        let runs = harness.store.readingRuns(for: articleID)
        #expect(!runs.isEmpty)
    }

    // MARK: - 删除

    @Test func deleteRemovesTranscriptAndFiles() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        await harness.store.load()

        let subtitle = try writeSubtitle(sampleSRT)
        defer { try? FileManager.default.removeItem(at: subtitle) }
        let media = try #require(
            try await harness.store.importMedia(mediaURL: nil, subtitleURL: subtitle))
        let articleID = try #require(harness.store.mediaArticleID(for: media.id))
        await harness.store.flushPersistence()
        let directory = harness.storage.directory(for: media.id)
        #expect(FileManager.default.fileExists(atPath: directory.path))

        harness.store.deleteMedia(media.id)
        await harness.store.flushPersistence()

        #expect(harness.store.medias.isEmpty)
        #expect(harness.store.segments(for: articleID).isEmpty)
        #expect(try await harness.media.loadMedia().isEmpty)
        #expect(try await harness.content.loadSegments(articleID: articleID).isEmpty)
    }

    // MARK: - 失败路径

    @Test func rejectsUnsupportedSubtitleFormat() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        await harness.store.load()

        let subtitle = try writeSubtitle("not a subtitle", ext: "ass")
        defer { try? FileManager.default.removeItem(at: subtitle) }

        await #expect(throws: MediaImporter.Failure.self) {
            try await harness.store.importMedia(mediaURL: nil, subtitleURL: subtitle)
        }
    }

    /// 时间戳全坏的字幕不能产出一个空文稿，要显式失败。
    @Test func rejectsSubtitleWithNoUsableCues() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        await harness.store.load()

        let subtitle = try writeSubtitle(
            """
            1
            1m00s --> 2m00s
            坏时间戳
            """)
        defer { try? FileManager.default.removeItem(at: subtitle) }

        await #expect(throws: MediaImporter.Failure.emptyTranscript) {
            try await harness.store.importMedia(mediaURL: nil, subtitleURL: subtitle)
        }
    }
}
