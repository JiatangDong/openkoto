import Foundation
import GRDB
import OKModels

/// 视频/音频读写入口。与 `BookRepository` 同样的约定：每个写方法一个事务，
/// 调用方（ContentStore）负责串行化提交顺序。
public struct MediaRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - 读

    public func loadMedia() async throws -> [Media] {
        try await database.writer.read { db in
            try MediaRecord
                .order(Column("created_at").desc, Column("id"))
                .fetchAll(db)
                .map { try $0.domainModel() }
        }
    }

    /// 某个 media 的文稿归属（一个 media 目前只有一条 part）。
    public func parts(mediaID: UUID) async throws -> [MediaPart] {
        try await database.writer.read { db in
            try MediaPartRecord
                .filter(Column("media_id") == uuidString(mediaID))
                .order(Column("part_index"))
                .fetchAll(db)
                .map { try $0.domainModel() }
        }
    }

    /// 反查：这条 article 属于哪个 media（阅读器判断要不要显示播放器）。
    public func part(articleID: UUID) async throws -> MediaPart? {
        try await database.writer.read { db in
            try MediaPartRecord
                .filter(Column("article_id") == uuidString(articleID))
                .fetchOne(db)?
                .domainModel()
        }
    }

    // MARK: - 写

    /// 导入：media + 文稿 article 行 + 归属行 + 全部字幕句在同一事务写入。
    ///
    /// 与书籍**不同**：这里连 segment 一起写。字幕文稿本来就是切好的，
    /// 没有「一本书上万句、导入时切会卡死」的问题，也就不需要懒切分。
    public func insertMedia(
        _ media: Media, article: Article, part: MediaPart, segments: [ArticleSegment],
        now: Date = .now
    ) async throws {
        try await database.writer.write { db in
            try MediaRecord(media, now: now).insert(db)
            try ArticleRecord(article, now: now).insert(db)
            try MediaPartRecord(part).insert(db)
            for segment in segments {
                try SegmentRecord(segment, meta: nil, now: now).insert(db)
            }
        }
    }

    /// 删除。media → article 的级联没法用外键表达，这里显式做，且**顺序要紧**：
    /// 先删 article（触发 segment 级联删除、收藏 source_article_id 置空），
    /// 再删 media（级联清掉 media_part / media_progress）。
    public func deleteMedia(id: UUID) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: """
                    DELETE FROM article
                    WHERE id IN (SELECT article_id FROM media_part WHERE media_id = ?)
                    """,
                arguments: [uuidString(id)])
            try db.execute(sql: "DELETE FROM media WHERE id = ?", arguments: [uuidString(id)])
        }
    }

    /// 重新转写后替换文稿：换掉 segment 但**保住 article 行**（精讲继承在上层按文本做）。
    public func replaceTranscript(
        mediaID: UUID, articleID: UUID, segments: [ArticleSegment], content: String,
        source: TranscriptSource, hasWordTiming: Bool, duration: Double, now: Date = .now
    ) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM segment WHERE article_id = ?",
                arguments: [uuidString(articleID)])
            for segment in segments {
                try SegmentRecord(segment, meta: nil, now: now).insert(db)
            }
            try db.execute(
                sql: "UPDATE article SET content = ?, updated_at = ? WHERE id = ?",
                arguments: [content, now, uuidString(articleID)])
            try db.execute(
                sql: """
                    UPDATE media
                    SET transcript_source = ?, has_word_timing = ?, duration = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    source.rawValue, hasWordTiming, duration, now, uuidString(mediaID),
                ])
        }
    }

    /// 引用模式下 bookmark 变陈旧时回写新的。
    public func updateBookmark(mediaID: UUID, data: Data?, now: Date = .now) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE media SET bookmark_data = ?, updated_at = ? WHERE id = ?",
                arguments: [data, now, uuidString(mediaID)])
        }
    }

    // MARK: - 播放位置

    public func loadProgress() async throws -> [UUID: MediaProgress] {
        try await database.writer.read { db in
            var result: [UUID: MediaProgress] = [:]
            for record in try MediaProgressRecord.fetchAll(db) {
                let progress = try record.domainModel()
                result[progress.mediaId] = progress
            }
            return result
        }
    }

    public func saveProgress(_ progress: MediaProgress) async throws {
        try await database.writer.write { db in
            try MediaProgressRecord(progress).upsert(db)
        }
    }
}
