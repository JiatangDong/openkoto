import Foundation
import GRDB
import OKModels
import Testing

@testable import OKPersistence

/// v3 → v4 升级的数据安全网。
///
/// v4 给 segment 加了两列时间轴、建了 media 三张表。追加是安全的，
/// 但「追加」这件事本身要有测试兜底：老用户库里的文章、句子、精讲、生词、
/// 书籍章节升级后一条都不能少，新列要落在 NULL 上而不是 0（0 秒是合法时刻，
/// 混进来就分不清「没时间轴」和「从头开始」）。
@Suite struct MigrationV4Tests {
    private func makeV3Database() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v3")
        return queue
    }

    @Test func v3DatabaseHasNoMediaTables() async throws {
        let queue = try makeV3Database()
        let tables = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(tables.contains("book"))
        #expect(tables.contains("media") == false)
        #expect(tables.contains("media_part") == false)
        #expect(tables.contains("media_progress") == false)
    }

    @Test func upgradingFromV3PreservesDataAndLeavesTimingNull() async throws {
        let queue = try makeV3Database()

        let articleID = UUID().uuidString.lowercased()
        let segmentID = UUID().uuidString.lowercased()
        let bookID = UUID().uuidString.lowercased()
        let chapterID = UUID().uuidString.lowercased()
        let explanationJSON = #"""
            {"explanation":{"explanation":"e","translation":"t","vocabulary":[],
             "grammar_points":[]}}
            """#

        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO article (id, title, content, source_type, created_at, updated_at)
                    VALUES (?, '旧文章', '正文', 'article', '2026-01-01 00:00:00',
                            '2026-01-01 00:00:00')
                    """,
                arguments: [articleID])
            try db.execute(
                sql: """
                    INSERT INTO segment
                      (id, article_id, order_index, text, explanation_json, is_new_paragraph,
                       created_at, updated_at)
                    VALUES (?, ?, 0, '第一句。', ?, 1, '2026-01-01 00:00:00',
                            '2026-01-01 00:00:00')
                    """,
                arguments: [segmentID, articleID, explanationJSON])
            // 书籍章节：升级后照样归 book 管，不能被媒体的过滤条件误伤
            try db.execute(
                sql: """
                    INSERT INTO book (id, title, format, dir_name, created_at, updated_at)
                    VALUES (?, '旧书', 'epub', 'dir', '2026-01-01 00:00:00',
                            '2026-01-01 00:00:00')
                    """,
                arguments: [bookID])
            try db.execute(
                sql: """
                    INSERT INTO article (id, title, content, source_type, created_at, updated_at)
                    VALUES (?, '第一章', '章节正文', 'article', '2026-01-01 00:00:00',
                            '2026-01-01 00:00:00')
                    """,
                arguments: [chapterID])
            try db.execute(
                sql: """
                    INSERT INTO book_chapter (article_id, book_id, chapter_index)
                    VALUES (?, ?, 0)
                    """,
                arguments: [chapterID, bookID])
        }

        try AppDatabase.migrator.migrate(queue)

        let (articleCount, segment, chapterCount) = try await queue.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article") ?? 0,
                try Row.fetchOne(
                    db, sql: "SELECT * FROM segment WHERE id = ?", arguments: [segmentID]),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM book_chapter") ?? 0
            )
        }

        #expect(articleCount == 2)
        #expect(chapterCount == 1)
        let row = try #require(segment)
        #expect(row["text"] as String? == "第一句。")
        #expect(row["explanation_json"] as String? != nil)
        // 新列必须是 NULL —— 不能默认成 0，0 秒是合法时刻
        #expect(row["start_time"] as Double? == nil)
        #expect(row["end_time"] as Double? == nil)
    }

    /// 迁移必须幂等：重复跑不报错、不重复建表。
    @Test func migratingTwiceIsIdempotent() async throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)
        try AppDatabase.migrator.migrate(queue)
        let tables = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(tables.filter { $0 == "media" }.count == 1)
    }

    // MARK: - 新表的行为

    /// 删除 media 要显式先删 article（触发 segment 级联），再删 media。
    /// 顺序反了会留下孤儿 article 行。
    @Test func deleteMediaRemovesArticleAndSegments() async throws {
        let database = try AppDatabase.inMemory()
        let repository = MediaRepository(database: database)

        let media = Media(
            title: "讲座", kind: .video, dirName: "dir", transcriptSource: .srt)
        let article = Article(title: "讲座", content: "第一句。第二句。")
        let segments = [
            ArticleSegment(
                articleId: article.id, order: 0, text: "第一句。", startTime: 0, endTime: 2),
            ArticleSegment(
                articleId: article.id, order: 1, text: "第二句。", startTime: 2, endTime: 4),
        ]
        try await repository.insertMedia(
            media, article: article,
            part: MediaPart(articleId: article.id, mediaId: media.id), segments: segments)

        #expect(try await repository.loadMedia().count == 1)
        try await repository.deleteMedia(id: media.id)

        let (mediaCount, articleCount, segmentCount) = try await database.writer.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM segment") ?? 0
            )
        }
        #expect(mediaCount == 0)
        #expect(articleCount == 0)
        #expect(segmentCount == 0)
    }

    /// 时间轴要能原样存取（Double 精度不丢）。
    @Test func roundTripsSegmentTiming() async throws {
        let database = try AppDatabase.inMemory()
        let media = MediaRepository(database: database)
        let content = ContentRepository(database: database)

        let article = Article(title: "音频", content: "一句话。")
        let segment = ArticleSegment(
            articleId: article.id, order: 0, text: "一句话。",
            startTime: 12.345, endTime: 15.678)
        let record = Media(title: "音频", kind: .audio, dirName: "d", transcriptSource: .vtt)
        try await media.insertMedia(
            record, article: article,
            part: MediaPart(articleId: article.id, mediaId: record.id), segments: [segment])

        let loaded = try await content.loadSegments(articleID: article.id)
        #expect(loaded.count == 1)
        #expect(loaded[0].startTime == 12.345)
        #expect(loaded[0].endTime == 15.678)
    }

    /// 媒体文稿不能出现在书库顶层文章列表里（它以视频卡片出现）。
    @Test func mediaTranscriptIsExcludedFromArticleList() async throws {
        let database = try AppDatabase.inMemory()
        let media = MediaRepository(database: database)
        let content = ContentRepository(database: database)

        let plain = Article(title: "普通文章", content: "正文")
        try await content.insertArticle(plain, segments: [])

        let transcript = Article(title: "视频文稿", content: "字幕")
        let mediaID = UUID()
        try await media.insertMedia(
            Media(id: mediaID, title: "视频", kind: .video, dirName: "d", transcriptSource: .srt),
            article: transcript,
            part: MediaPart(articleId: transcript.id, mediaId: mediaID), segments: [])

        let snapshot = try await content.loadAll()
        #expect(snapshot.articles.map(\.title) == ["普通文章"])
    }
}
