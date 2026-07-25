import Foundation
import GRDB
import OKModels

/// 书籍读写入口。与 `ContentRepository` 同样的约定：每个写方法一个事务，
/// 调用方（ContentStore）负责串行化提交顺序。
public struct BookRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - 读

    public func loadBooks() async throws -> [Book] {
        try await database.writer.read { db in
            try BookRecord
                .order(Column("created_at").desc, Column("id"))
                .fetchAll(db)
                .map { try $0.domainModel() }
        }
    }

    /// 章节摘要（不含正文）：标题取自 article，其余取自 book_chapter。
    public func chapterSummaries(bookID: UUID) async throws -> [BookChapterSummary] {
        try await database.writer.read { db in
            try Self.fetchChapterSummaries(db, bookID: bookID)
        }
    }

    static func fetchChapterSummaries(_ db: Database, bookID: UUID) throws
        -> [BookChapterSummary]
    {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT c.article_id, c.chapter_index, c.char_count, c.is_segmented,
                       c.source_href, a.title
                FROM book_chapter c
                JOIN article a ON a.id = c.article_id
                WHERE c.book_id = ?
                ORDER BY c.chapter_index
                """,
            arguments: [uuidString(bookID)])
        return try rows.map { row in
            BookChapterSummary(
                articleId: try parseUUID(row["article_id"], table: "book_chapter"),
                index: row["chapter_index"],
                title: row["title"],
                charCount: row["char_count"],
                isSegmented: row["is_segmented"],
                sourceHref: row["source_href"])
        }
    }

    /// 某章的归属信息（首开时判断是否需要延迟切分、去哪读原始文件）。
    public func chapter(articleID: UUID) async throws -> BookChapter? {
        try await database.writer.read { db in
            try BookChapterRecord
                .filter(Column("article_id") == uuidString(articleID))
                .fetchOne(db)?
                .domainModel()
        }
    }

    // MARK: - 写

    /// 导入：书 + 全部章节 article 行 + 归属行在同一事务写入。
    /// **不写 segment**——切分推迟到首次打开该章（见设计说明 B）。
    public func insertBook(
        _ book: Book, chapters: [(article: Article, chapter: BookChapter)], now: Date = .now
    ) async throws {
        try await database.writer.write { db in
            try BookRecord(book, now: now).insert(db)
            for entry in chapters {
                try ArticleRecord(entry.article, now: now).insert(db)
                try BookChapterRecord(entry.chapter).insert(db)
            }
        }
    }

    /// 删书。book → article 的级联没法用外键表达，这里显式做，且**顺序要紧**：
    /// 先删 article（触发 segment 级联删除、收藏 source_article_id 置空），
    /// 再删 book（级联清掉 book_chapter / book_progress / book_mark）。
    public func deleteBook(id: UUID) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: """
                    DELETE FROM article
                    WHERE id IN (SELECT article_id FROM book_chapter WHERE book_id = ?)
                    """,
                arguments: [uuidString(id)])
            try db.execute(sql: "DELETE FROM book WHERE id = ?", arguments: [uuidString(id)])
        }
    }

    // MARK: - 阅读位置

    public func loadProgress() async throws -> [UUID: BookProgress] {
        try await database.writer.read { db in
            var result: [UUID: BookProgress] = [:]
            for record in try BookProgressRecord.fetchAll(db) {
                let progress = try record.domainModel()
                result[progress.bookId] = progress
            }
            return result
        }
    }

    /// 每本书一行，直接 upsert。
    public func saveProgress(_ progress: BookProgress) async throws {
        try await database.writer.write { db in
            try BookProgressRecord(progress).upsert(db)
        }
    }

    // MARK: - 书签 / 划线

    public func marks(bookID: UUID) async throws -> [BookMark] {
        try await database.writer.read { db in
            try BookMarkRecord
                .filter(Column("book_id") == uuidString(bookID))
                .order(Column("chapter_index"), Column("created_at"))
                .fetchAll(db)
                .map { try $0.domainModel() }
        }
    }

    public func saveMark(_ mark: BookMark, now: Date = .now) async throws {
        try await database.writer.write { db in
            try BookMarkRecord(mark, now: now).upsert(db)
        }
    }

    public func deleteMark(id: UUID) async throws {
        _ = try await database.writer.write { db in
            try BookMarkRecord.deleteOne(db, key: uuidString(id))
        }
    }
}
