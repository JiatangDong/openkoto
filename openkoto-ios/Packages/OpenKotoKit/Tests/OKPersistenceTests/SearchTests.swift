import Foundation
import GRDB
import OKModels
import Testing

@testable import OKPersistence

/// 全库搜索。
///
/// 这组测试锁的是两件容易做错的事：
/// ① 索引必须建在 `article.content` 上——书籍导入时**不写 segment**，
///    建 segment 索引会让新导入的书全部搜不到；
/// ② 中日文必须真的能搜到——默认的 unicode61 tokenizer 对 CJK 完全无效。
@Suite struct SearchTests {
    private func makeRepository() throws -> (ContentRepository, AppDatabase) {
        let database = try AppDatabase.inMemory()
        return (ContentRepository(database: database), database)
    }

    private func insert(
        _ repository: ContentRepository, title: String, content: String
    ) async throws -> UUID {
        let article = Article(title: title, content: content)
        try await repository.insertArticle(article, segments: [])
        return article.id
    }

    private func plain(_ snippet: String) -> String {
        snippet
            .replacingOccurrences(of: ContentRepository.SearchHit.highlightStart, with: "")
            .replacingOccurrences(of: ContentRepository.SearchHit.highlightEnd, with: "")
    }

    // MARK: - CJK（默认 tokenizer 在这里会全军覆没）

    @Test func findsJapanesePhrase() async throws {
        let (repository, _) = try makeRepository()
        let id = try await insert(
            repository, title: "夢十夜", content: "私は日本語を勉強しています。とても難しい。")

        let hits = try await repository.search("日本語")
        #expect(hits.map(\.articleID) == [id])
        #expect(plain(hits[0].snippet).contains("日本語"))
    }

    @Test func findsChinesePhrase() async throws {
        let (repository, _) = try makeRepository()
        _ = try await insert(repository, title: "文章", content: "银行行长说这首歌的长度不够。")
        #expect(try await repository.search("行长说").count == 1)
    }

    /// 命中片段要带高亮标记，UI 才能把命中词标出来。
    @Test func snippetMarksTheMatch() async throws {
        let (repository, _) = try makeRepository()
        _ = try await insert(repository, title: "T", content: "私は日本語を勉強しています。")
        let snippet = try await repository.search("日本語")[0].snippet
        #expect(snippet.contains(ContentRepository.SearchHit.highlightStart))
        #expect(snippet.contains(ContentRepository.SearchHit.highlightEnd))
    }

    // MARK: - 两字查询的兜底（trigram 的硬约束）

    /// trigram 查不到两字词，但"日本""文法"恰恰是最高频的中日文查询——
    /// 必须有 LIKE 兜底，不能让用户看到"请至少输入 3 个字"。
    @Test func twoCharacterQueryFallsBackToLike() async throws {
        let (repository, _) = try makeRepository()
        let id = try await insert(repository, title: "T", content: "私は日本語を勉強しています。")

        let hits = try await repository.search("日本")
        #expect(hits.map(\.articleID) == [id])
        #expect(plain(hits[0].snippet).contains("日本"))
    }

    @Test func fallbackSnippetHighlightsTheMatch() {
        let excerpt = ContentRepository.excerpt(
            from: "前面的文字私は日本語を勉強しています后面的文字", around: "日本")
        #expect(excerpt.contains(ContentRepository.SearchHit.highlightStart + "日本"))
    }

    @Test func emptyQueryReturnsNothing() async throws {
        let (repository, _) = try makeRepository()
        _ = try await insert(repository, title: "T", content: "内容")
        #expect(try await repository.search("   ").isEmpty)
    }

    // MARK: - 索引维护

    /// 新插入的文章立刻可搜（触发器）。
    @Test func newArticleIsSearchableImmediately() async throws {
        let (repository, _) = try makeRepository()
        #expect(try await repository.search("勉強しています").isEmpty)
        _ = try await insert(repository, title: "T", content: "私は日本語を勉強しています。")
        #expect(try await repository.search("勉強しています").count == 1)
    }

    /// 删除文章后不能再搜到——external content 表最容易在这里留下幽灵行。
    @Test func deletedArticleDisappearsFromIndex() async throws {
        let (repository, _) = try makeRepository()
        let id = try await insert(repository, title: "T", content: "私は日本語を勉強しています。")
        #expect(try await repository.search("日本語").count == 1)

        try await repository.deleteArticle(id: id)
        #expect(try await repository.search("日本語").isEmpty)
    }

    /// 正文变了（媒体重新转写会 UPDATE article.content）索引要跟着变。
    @Test func updatedContentIsReindexed() async throws {
        let (repository, database) = try makeRepository()
        let id = try await insert(repository, title: "T", content: "私は日本語を勉強しています。")
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE article SET content = ?, updated_at = ? WHERE id = ?",
                arguments: ["これは新しい内容です。", Date(), id.uuidString.lowercased()])
        }
        #expect(try await repository.search("日本語").isEmpty)
        #expect(try await repository.search("新しい内容").count == 1)
    }

    /// **精讲不该触发重索引**：`saveExplanation` 只 UPDATE segment，从不碰 article。
    /// 触发器带了 `WHEN old.content IS NOT new.content`，双保险。
    @Test func explanationWriteDoesNotDisturbIndex() async throws {
        let (repository, _) = try makeRepository()
        let article = Article(title: "T", content: "私は日本語を勉強しています。")
        let segment = ArticleSegment(
            articleId: article.id, order: 0, text: "私は日本語を勉強しています。")
        try await repository.insertArticle(article, segments: [segment])

        try await repository.saveExplanation(
            segmentID: segment.id,
            explanation: SegmentExplanation(translation: "t", explanation: "e"), meta: nil)

        #expect(try await repository.search("日本語").count == 1)
    }

    // MARK: - 后台回填

    /// 升级后待办表里应该有存量文章，回填器跑完要能搜到它们。
    @Test func backfillIndexesExistingArticles() async throws {
        let database = try DatabaseQueue()
        try AppDatabase.migrator.migrate(database, upTo: "v5")

        // v5 时代写进去的文章（那时还没有 FTS 表）
        try await database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO article (id, title, content, source_type, created_at, updated_at)
                    VALUES (?, '旧文章', '私は日本語を勉強しています。', 'article',
                            '2026-01-01 00:00:00', '2026-01-01 00:00:00')
                    """, arguments: [UUID().uuidString.lowercased()])
        }

        let app = try AppDatabase(database)
        let repository = ContentRepository(database: app)

        // 迁移只记待办、不建索引，所以此刻还搜不到
        #expect(try await repository.pendingIndexCount() == 1)
        #expect(try await repository.search("日本語").isEmpty)

        let indexer = SearchIndexer(database: app)
        await indexer.start()
        var waited = 0
        while try await repository.pendingIndexCount() > 0, waited < 200 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }

        #expect(try await repository.search("日本語").count == 1)
    }
}

/// 升级窗口：`fts_backfill` 还没排空时，用户对旧文章做了增删改。
///
/// 这是真实会发生的顺序——升级后第一次打开 App，回填要跑几秒，
/// 而用户可能立刻就删了一篇、或重新转写了一个视频。
@Suite struct SearchBackfillWindowTests {
    /// 造一个"刚升级完"的库：v5 时代写入的文章 + 已建表未回填的 v6。
    private func upgradedDatabase(articleTitle: String, content: String) async throws
        -> (AppDatabase, ContentRepository, UUID)
    {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v5")
        let id = UUID()
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO article (id, title, content, source_type, created_at, updated_at)
                    VALUES (?, ?, ?, 'article', '2026-01-01 00:00:00', '2026-01-01 00:00:00')
                    """, arguments: [id.uuidString.lowercased(), articleTitle, content])
        }
        let app = try AppDatabase(queue)
        return (app, ContentRepository(database: app), id)
    }

    private func integrityIsIntact(_ database: AppDatabase) async throws -> Bool {
        do {
            try await database.writer.write { db in
                try db.execute(
                    sql: "INSERT INTO article_fts(article_fts) VALUES('integrity-check')")
            }
            return true
        } catch {
            return false
        }
    }

    /// 待回填的文章被删掉：不能对索引发一条它根本不存在的 'delete'。
    @Test func deletingAPendingArticleKeepsTheIndexIntact() async throws {
        let (database, repository, id) = try await upgradedDatabase(
            articleTitle: "旧文章", content: "私は日本語を勉強しています。")
        #expect(try await repository.pendingIndexCount() == 1)

        try await repository.deleteArticle(id: id)
        #expect(try await integrityIsIntact(database))

        let indexer = SearchIndexer(database: database)
        await indexer.start()
        try await Task.sleep(for: .milliseconds(200))

        #expect(try await repository.search("日本語").isEmpty)
        #expect(try await integrityIsIntact(database))
    }

    /// 待回填的文章正文被改（重新转写）：回填后搜到的应当是新内容，且只有一条。
    @Test func updatingAPendingArticleIndexesItOnce() async throws {
        let (database, repository, id) = try await upgradedDatabase(
            articleTitle: "旧文章", content: "私は日本語を勉強しています。")

        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE article SET content = ? WHERE id = ?",
                arguments: ["これは新しい内容です。", id.uuidString.lowercased()])
        }

        let indexer = SearchIndexer(database: database)
        await indexer.start()
        try await Task.sleep(for: .milliseconds(200))

        #expect(try await repository.search("新しい内容").count == 1)
        #expect(try await repository.search("日本語").isEmpty)
        #expect(try await integrityIsIntact(database))
    }

    /// 回填排空之后，进度查询要给出 0，而不是因为表没了而抛错。
    @Test func progressIsZeroAfterBackfillDrains() async throws {
        let (database, repository, _) = try await upgradedDatabase(
            articleTitle: "旧文章", content: "私は日本語を勉強しています。")
        let indexer = SearchIndexer(database: database)
        await indexer.start()
        try await Task.sleep(for: .milliseconds(200))

        #expect(try await repository.pendingIndexCount() == 0)
    }
}

/// 线上用户真正会走的那一跳：0.2.5 停在 **v3**，这个版本一路补到 v6。
///
/// 单独钉住是因为中间的 v4（媒体表）、v5（生成列 + 部分索引）、v6（FTS）
/// 是三条分支各自加的，谁也没验过"带着真实数据连着跑完"。
@Suite struct UpgradeFromShippedVersionTests {
    private func shippedDatabase(articles: [(String, String)]) async throws -> AppDatabase {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v3")
        try await queue.write { db in
            for (title, content) in articles {
                try db.execute(
                    sql: """
                        INSERT INTO article (id, title, content, source_type, created_at, updated_at)
                        VALUES (?, ?, ?, 'article', '2026-01-01 00:00:00', '2026-01-01 00:00:00')
                        """,
                    arguments: [UUID().uuidString.lowercased(), title, content])
            }
        }
        return try AppDatabase(queue)
    }

    @Test func upgradingFromV3IndexesEverythingAndKeepsData() async throws {
        let database = try await shippedDatabase(articles: [
            ("夢十夜", "私は日本語を勉強しています。"),
            ("背影", "银行行长说这首歌的长度不够。"),
        ])
        let repository = ContentRepository(database: database)

        // 迁移本身只记待办，不建索引——这正是首启不卡的原因。
        #expect(try await repository.pendingIndexCount() == 2)
        #expect(try await repository.loadAll().articles.count == 2)

        let indexer = SearchIndexer(database: database)
        await indexer.start()
        var waited = 0
        while try await repository.pendingIndexCount() > 0, waited < 200 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }

        #expect(try await repository.search("日本語").count == 1)
        #expect(try await repository.search("行长说").count == 1)
        #expect(try await repository.pendingIndexCount() == 0)
    }

    /// 升级当下就删文章——回填还一条没跑。这在旧触发器下会直接报
    /// "database disk image is malformed"，把用户的删除操作打回去。
    @Test func deletingRightAfterUpgradeStillWorks() async throws {
        let database = try await shippedDatabase(articles: [("夢十夜", "私は日本語を勉強しています。")])
        let repository = ContentRepository(database: database)
        let article = try #require(try await repository.loadAll().articles.first)

        try await repository.deleteArticle(id: article.id)
        #expect(try await repository.loadAll().articles.isEmpty)

        let indexer = SearchIndexer(database: database)
        await indexer.start()
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await repository.search("日本語").isEmpty)
    }
}
