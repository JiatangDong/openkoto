import Foundation
import GRDB
import OKModels

// 书籍相关表的记录类型。约定与 Records.swift 一致：
// 显式 snake_case CodingKeys、`init(_ domainModel:now:)`、`domainModel() throws`，
// 未知枚举值一律抛 `PersistenceError.corruptRow`，不静默降级。

// MARK: - book

struct BookRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "book"

    var id: String
    var title: String
    var author: String?
    var language: String?
    var format: String
    var dirName: String
    var opfPath: String?
    var coverHref: String?
    var totalChars: Int
    var defaultMode: String
    var originalOnly: Bool
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title, author, language, format
        case dirName = "dir_name"
        case opfPath = "opf_path"
        case coverHref = "cover_href"
        case totalChars = "total_chars"
        case defaultMode = "default_mode"
        case originalOnly = "original_only"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(_ book: Book, now: Date) {
        id = uuidString(book.id)
        title = book.title
        author = book.author
        language = book.language
        format = book.format.rawValue
        dirName = book.dirName
        opfPath = book.opfPath
        coverHref = book.coverHref
        totalChars = book.totalChars
        defaultMode = book.defaultMode.rawValue
        originalOnly = book.originalOnly
        createdAt = book.createdAt
        updatedAt = now
    }

    func domainModel() throws -> Book {
        guard let resolvedFormat = BookFormat(rawValue: format) else {
            throw PersistenceError.corruptRow(
                table: Self.databaseTableName, id: id, reason: "unknown format \(format)")
        }
        guard let resolvedMode = BookRenderMode(rawValue: defaultMode) else {
            throw PersistenceError.corruptRow(
                table: Self.databaseTableName, id: id,
                reason: "unknown default_mode \(defaultMode)")
        }
        return Book(
            id: try parseUUID(id, table: Self.databaseTableName),
            title: title,
            author: author,
            language: language,
            format: resolvedFormat,
            dirName: dirName,
            opfPath: opfPath,
            coverHref: coverHref,
            totalChars: totalChars,
            defaultMode: resolvedMode,
            originalOnly: originalOnly,
            createdAt: createdAt)
    }
}

// MARK: - book_chapter

struct BookChapterRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "book_chapter"

    var articleId: String
    var bookId: String
    var chapterIndex: Int
    var sourceHref: String?
    var isSegmented: Bool
    var charCount: Int

    enum CodingKeys: String, CodingKey {
        case articleId = "article_id"
        case bookId = "book_id"
        case chapterIndex = "chapter_index"
        case sourceHref = "source_href"
        case isSegmented = "is_segmented"
        case charCount = "char_count"
    }

    init(_ chapter: BookChapter) {
        articleId = uuidString(chapter.articleId)
        bookId = uuidString(chapter.bookId)
        chapterIndex = chapter.index
        sourceHref = chapter.sourceHref
        isSegmented = chapter.isSegmented
        charCount = chapter.charCount
    }

    func domainModel() throws -> BookChapter {
        BookChapter(
            articleId: try parseUUID(articleId, table: Self.databaseTableName),
            bookId: try parseUUID(bookId, table: Self.databaseTableName),
            index: chapterIndex,
            sourceHref: sourceHref,
            isSegmented: isSegmented,
            charCount: charCount)
    }
}

// MARK: - book_progress

struct BookProgressRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "book_progress"

    var bookId: String
    var chapterArticleId: String?
    var chapterIndex: Int
    var segmentOrder: Int?
    var scrollFraction: Double?
    var mode: String
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case bookId = "book_id"
        case chapterArticleId = "chapter_article_id"
        case chapterIndex = "chapter_index"
        case segmentOrder = "segment_order"
        case scrollFraction = "scroll_fraction"
        case mode
        case updatedAt = "updated_at"
    }

    init(_ progress: BookProgress) {
        bookId = uuidString(progress.bookId)
        chapterArticleId = progress.chapterArticleId.map(uuidString)
        chapterIndex = progress.chapterIndex
        segmentOrder = progress.segmentOrder
        scrollFraction = progress.scrollFraction
        mode = progress.mode.rawValue
        updatedAt = progress.updatedAt
    }

    func domainModel() throws -> BookProgress {
        guard let resolvedMode = BookRenderMode(rawValue: mode) else {
            throw PersistenceError.corruptRow(
                table: Self.databaseTableName, id: bookId, reason: "unknown mode \(mode)")
        }
        return BookProgress(
            bookId: try parseUUID(bookId, table: Self.databaseTableName),
            chapterArticleId: try chapterArticleId.map {
                try parseUUID($0, table: Self.databaseTableName)
            },
            chapterIndex: chapterIndex,
            segmentOrder: segmentOrder,
            scrollFraction: scrollFraction,
            mode: resolvedMode,
            updatedAt: updatedAt)
    }
}

// MARK: - book_mark

struct BookMarkRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "book_mark"

    var id: String
    var bookId: String
    var chapterArticleId: String?
    var chapterIndex: Int
    var kind: String
    var segmentOrder: Int?
    var charStart: Int?
    var charEnd: Int?
    var locator: String?
    var scrollFraction: Double?
    var selectedText: String?
    var note: String?
    var color: String?
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case bookId = "book_id"
        case chapterArticleId = "chapter_article_id"
        case chapterIndex = "chapter_index"
        case kind
        case segmentOrder = "segment_order"
        case charStart = "char_start"
        case charEnd = "char_end"
        case locator
        case scrollFraction = "scroll_fraction"
        case selectedText = "selected_text"
        case note, color
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(_ mark: BookMark, now: Date) {
        id = uuidString(mark.id)
        bookId = uuidString(mark.bookId)
        chapterArticleId = mark.chapterArticleId.map(uuidString)
        chapterIndex = mark.chapterIndex
        kind = mark.kind.rawValue
        segmentOrder = mark.segmentOrder
        charStart = mark.charStart
        charEnd = mark.charEnd
        locator = mark.locator
        scrollFraction = mark.scrollFraction
        selectedText = mark.selectedText
        note = mark.note
        color = mark.color
        createdAt = mark.createdAt
        updatedAt = now
    }

    func domainModel() throws -> BookMark {
        guard let resolvedKind = BookMark.Kind(rawValue: kind) else {
            throw PersistenceError.corruptRow(
                table: Self.databaseTableName, id: id, reason: "unknown kind \(kind)")
        }
        return BookMark(
            id: try parseUUID(id, table: Self.databaseTableName),
            bookId: try parseUUID(bookId, table: Self.databaseTableName),
            chapterArticleId: try chapterArticleId.map {
                try parseUUID($0, table: Self.databaseTableName)
            },
            chapterIndex: chapterIndex,
            kind: resolvedKind,
            segmentOrder: segmentOrder,
            charStart: charStart,
            charEnd: charEnd,
            locator: locator,
            scrollFraction: scrollFraction,
            selectedText: selectedText,
            note: note,
            color: color,
            createdAt: createdAt,
            updatedAt: updatedAt)
    }
}
