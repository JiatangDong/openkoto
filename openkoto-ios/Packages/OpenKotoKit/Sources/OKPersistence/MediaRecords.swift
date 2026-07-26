import Foundation
import GRDB
import OKModels

// 视频/音频相关表的记录类型。约定与 Records.swift / BookRecords.swift 一致：
// 显式 snake_case CodingKeys、`init(_ domainModel:now:)`、`domainModel() throws`，
// 未知枚举值一律抛 `PersistenceError.corruptRow`，不静默降级。

// MARK: - media

struct MediaRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "media"

    var id: String
    var title: String
    var kind: String
    var dirName: String
    var fileName: String?
    var bookmarkData: Data?
    var sourceLabel: String?
    var duration: Double
    var language: String?
    var transcriptSource: String
    var hasWordTiming: Bool
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title, kind, duration, language
        case dirName = "dir_name"
        case fileName = "file_name"
        case bookmarkData = "bookmark_data"
        case sourceLabel = "source_label"
        case transcriptSource = "transcript_source"
        case hasWordTiming = "has_word_timing"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(_ media: Media, now: Date) {
        id = uuidString(media.id)
        title = media.title
        kind = media.kind.rawValue
        dirName = media.dirName
        fileName = media.fileName
        bookmarkData = media.bookmarkData
        sourceLabel = media.sourceLabel
        duration = media.duration
        language = media.language
        transcriptSource = media.transcriptSource.rawValue
        hasWordTiming = media.hasWordTiming
        createdAt = media.createdAt
        updatedAt = now
    }

    func domainModel() throws -> Media {
        guard let resolvedKind = MediaKind(rawValue: kind) else {
            throw PersistenceError.corruptRow(
                table: Self.databaseTableName, id: id, reason: "unknown kind \(kind)")
        }
        guard let resolvedSource = TranscriptSource(rawValue: transcriptSource) else {
            throw PersistenceError.corruptRow(
                table: Self.databaseTableName, id: id,
                reason: "unknown transcript_source \(transcriptSource)")
        }
        return Media(
            id: try parseUUID(id, table: Self.databaseTableName),
            title: title,
            kind: resolvedKind,
            dirName: dirName,
            fileName: fileName,
            bookmarkData: bookmarkData,
            sourceLabel: sourceLabel,
            duration: duration,
            language: language,
            transcriptSource: resolvedSource,
            hasWordTiming: hasWordTiming,
            createdAt: createdAt)
    }
}

// MARK: - media_part

struct MediaPartRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "media_part"

    var articleId: String
    var mediaId: String
    var partIndex: Int

    enum CodingKeys: String, CodingKey {
        case articleId = "article_id"
        case mediaId = "media_id"
        case partIndex = "part_index"
    }

    init(_ part: MediaPart) {
        articleId = uuidString(part.articleId)
        mediaId = uuidString(part.mediaId)
        partIndex = part.partIndex
    }

    func domainModel() throws -> MediaPart {
        MediaPart(
            articleId: try parseUUID(articleId, table: Self.databaseTableName),
            mediaId: try parseUUID(mediaId, table: Self.databaseTableName),
            partIndex: partIndex)
    }
}

// MARK: - media_progress

struct MediaProgressRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "media_progress"

    var mediaId: String
    var position: Double
    var rate: Double
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case position, rate
        case mediaId = "media_id"
        case updatedAt = "updated_at"
    }

    init(_ progress: MediaProgress) {
        mediaId = uuidString(progress.mediaId)
        position = progress.position
        rate = progress.rate
        updatedAt = progress.updatedAt
    }

    func domainModel() throws -> MediaProgress {
        MediaProgress(
            mediaId: try parseUUID(mediaId, table: Self.databaseTableName),
            position: position,
            rate: rate,
            updatedAt: updatedAt)
    }
}
