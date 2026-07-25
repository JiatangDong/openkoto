import Foundation
import GRDB
import Testing
import OKModels

@testable import OKPersistence

/// v2 → v3 升级的数据安全网。
///
/// 迁移是纯追加的，但"追加"这件事本身要有测试兜底：
/// 老用户库里已有文章、句子、精讲和生词，升级后一条都不能少，
/// 新列也必须落到预期的默认值上。仓库此前没有任何迁移测试。
@Suite struct MigrationV3Tests {
    /// 停在 v2 的库——GRDB 支持只迁移到指定版本。
    private func makeV2Database() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v2")
        return queue
    }

    @Test func v2DatabaseHasNoBookTables() async throws {
        let queue = try makeV2Database()
        let tables = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(tables.contains("article"))
        #expect(tables.contains("reading_session"))
        #expect(tables.contains("book") == false)
        #expect(tables.contains("book_chapter") == false)
    }

    @Test func upgradingFromV2PreservesExistingData() async throws {
        let queue = try makeV2Database()

        // 老库里塞进一篇文章 + 两句 + 一条精讲 + 一个生词。
        let articleID = UUID().uuidString.lowercased()
        let segmentID = UUID().uuidString.lowercased()
        let favoriteID = UUID().uuidString.lowercased()
        // vocabulary / grammar_points 没有默认值，缺了整行会被判为损坏。
        let explanationJSON = #"""
            {"explanation":{"explanation":"e","translation":"t","vocabulary":[],
             "grammar_points":[]}}
            """#
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO article (id, title, content, source_type, created_at, updated_at)
                    VALUES (?, '夢十夜', '本文', 'article', '2026-01-01 00:00:00',
                            '2026-01-01 00:00:00')
                    """,
                arguments: [articleID])
            try db.execute(
                sql: """
                    INSERT INTO segment
                      (id, article_id, order_index, text, explanation_json, is_new_paragraph,
                       created_at, updated_at)
                    VALUES (?, ?, 0, '一句目。', ?, 1,
                            '2026-01-01 00:00:00', '2026-01-01 00:00:00')
                    """,
                arguments: [segmentID, articleID, explanationJSON])
            try db.execute(
                sql: """
                    INSERT INTO segment
                      (id, article_id, order_index, text, is_new_paragraph, created_at, updated_at)
                    VALUES (?, ?, 1, '二句目。', 0,
                            '2026-01-01 00:00:00', '2026-01-01 00:00:00')
                    """,
                arguments: [UUID().uuidString.lowercased(), articleID])
            try db.execute(
                sql: """
                    INSERT INTO favorite_vocabulary
                      (id, word, normalized_word, meaning, source_article_id, source_article_title,
                       srs_state, review_count, created_at, updated_at)
                    VALUES (?, '夢', '夢', '梦', ?, '夢十夜', 'new', 0,
                            '2026-01-01 00:00:00', '2026-01-01 00:00:00')
                    """,
                arguments: [favoriteID, articleID])
        }

        // 升级：AppDatabase 的构造函数会把剩余迁移全部应用。
        let database = try AppDatabase(queue)
        let repository = ContentRepository(database: database)

        let snapshot = try await repository.loadAll()
        #expect(snapshot.articles.map(\.title) == ["夢十夜"])
        #expect(snapshot.favorites.map(\.word) == ["夢"])
        #expect(snapshot.favorites.first?.sourceArticleTitle == "夢十夜")

        // 新增的计数查询要能算对老数据（含那条部分索引覆盖的已精讲句）。
        let id = try #require(UUID(uuidString: articleID))
        #expect(snapshot.segmentCounts[id] == .init(total: 2, explained: 1))

        let segments = try await repository.loadSegments(articleID: id)
        #expect(segments.map(\.text) == ["一句目。", "二句目。"])
        #expect(segments[0].explanation?.translation == "t")
        #expect(segments[1].explanation == nil)
    }

    @Test func upgradingFromV2CreatesBookTablesWithDefaults() async throws {
        let database = try AppDatabase(try makeV2Database())
        let books = BookRepository(database: database)

        let book = Book(title: "书", format: .txt, dirName: "dir")
        try await books.insertBook(book, chapters: [])
        let loaded = try #require(await books.loadBooks().first)
        // 新列的默认值：默认原生模式、非仅原版。
        #expect(loaded.defaultMode == .native)
        #expect(loaded.originalOnly == false)
        #expect(loaded.totalChars == 0)
    }

    /// 迁移是幂等的：已经在 v3 的库重开不会重复建表或报错。
    @Test func migratingAlreadyUpgradedDatabaseIsNoop() async throws {
        let queue = try DatabaseQueue()
        _ = try AppDatabase(queue)
        _ = try AppDatabase(queue)
        let applied = try await queue.read { db in
            try String.fetchAll(
                db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        #expect(applied.contains("v3"))
        #expect(applied.count == Set(applied).count)
    }
}
