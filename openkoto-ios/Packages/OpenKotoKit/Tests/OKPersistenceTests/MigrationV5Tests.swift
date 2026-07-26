import Foundation
import GRDB
import OKModels
import Testing

@testable import OKPersistence

/// v4 → v5 升级：精讲复用所需的生成列 + 索引，以及生词卡的 source_segment_id。
///
/// v5 是**纯 schema 变更**：生成列的值直接从既有 `explanation_json` 里取，
/// 一行数据都不重写。这组测试要证明的正是"追加是安全的"。
@Suite struct MigrationV5Tests {
    private func makeV4Database() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v4")
        return queue
    }

    private let explanationJSON = #"""
        {"explanation":{"explanation":"e","translation":"t","vocabulary":[],
         "grammar_points":[]},"source_text_hash":"abc123",
         "target_language":"zh-CN","prompt_version":"explain-v1"}
        """#

    @Test func v4DatabaseHasNoGeneratedColumn() async throws {
        let queue = try makeV4Database()
        let columns = try await queue.read { db in
            try db.columns(in: "segment").map(\.name)
        }
        #expect(columns.contains("start_time"))
        #expect(!columns.contains("source_text_hash"))
    }

    /// 升级不动任何一行数据，但生成列立刻就能读出既有 JSON 里的哈希。
    @Test func upgradeExposesHashFromExistingJSONWithoutRewriting() async throws {
        let queue = try makeV4Database()
        let articleID = UUID().uuidString.lowercased()
        let segmentID = UUID().uuidString.lowercased()

        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO article (id, title, content, source_type, created_at, updated_at)
                    VALUES (?, 'T', 'C', 'article', '2026-01-01 00:00:00', '2026-01-01 00:00:00')
                    """, arguments: [articleID])
            try db.execute(
                sql: """
                    INSERT INTO segment
                      (id, article_id, order_index, text, explanation_json, is_new_paragraph,
                       created_at, updated_at)
                    VALUES (?, ?, 0, '一句。', ?, 1, '2026-01-01 00:00:00', '2026-01-01 00:00:00')
                    """, arguments: [segmentID, articleID, explanationJSON])
        }

        try AppDatabase.migrator.migrate(queue)

        let (hash, count) = try await queue.read { db in
            (
                try String.fetchOne(
                    db, sql: "SELECT source_text_hash FROM segment WHERE id = ?",
                    arguments: [segmentID]),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM segment") ?? 0
            )
        }
        #expect(hash == "abc123")
        #expect(count == 1)
    }

    /// 未精讲的行哈希必须是 NULL——否则它们会互相误命中。
    @Test func unexplainedRowsHaveNullHash() async throws {
        let database = try AppDatabase.inMemory()
        let repository = ContentRepository(database: database)
        let article = Article(title: "T", content: "一句。二句。")
        try await repository.insertArticle(
            article,
            segments: [
                ArticleSegment(articleId: article.id, order: 0, text: "一句。"),
                ArticleSegment(articleId: article.id, order: 1, text: "二句。"),
            ])

        let nullCount = try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM segment WHERE source_text_hash IS NULL")
                ?? -1
        }
        #expect(nullCount == 2)
    }

    /// 复用查询必须走部分索引，否则句子一多就是全表扫。
    @Test func reuseQueryUsesPartialIndex() async throws {
        let database = try AppDatabase.inMemory()
        let plan = try await database.writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    EXPLAIN QUERY PLAN
                    SELECT explanation_json FROM segment
                    WHERE source_text_hash = ? AND explanation_json IS NOT NULL LIMIT 8
                    """, arguments: ["x"]
            ).map { $0["detail"] as String? ?? "" }.joined(separator: " ")
        }
        #expect(plan.contains("segment_on_source_hash"))
    }

    // MARK: - 复用查询的判据

    private func seedExplained(_ repository: ContentRepository, text: String) async throws {
        let article = Article(title: "旧文章", content: text)
        let segment = ArticleSegment(articleId: article.id, order: 0, text: text)
        try await repository.insertArticle(article, segments: [segment])
        try await repository.saveExplanation(
            segmentID: segment.id,
            explanation: SegmentExplanation(translation: "旧译文", explanation: "旧讲解"),
            meta: ExplanationMeta(
                targetLanguage: "zh-CN", providerId: "p", modelId: "m",
                promptVersion: "explain-v1", generatedAt: .now, sourceTextHash: "hash-A"))
    }

    @Test func findsExistingExplanationByHash() async throws {
        let repository = ContentRepository(database: try AppDatabase.inMemory())
        try await seedExplained(repository, text: "同一句话。")

        let found = try await repository.existingExplanation(
            sourceTextHash: "hash-A", targetLanguage: "zh-CN",
            compatiblePromptVersions: ["explain-v1"])
        #expect(found?.explanation.translation == "旧译文")
    }

    /// 讲解语言不同的结果不能复用——用户会拿到一份看不懂的讲解。
    @Test func rejectsDifferentTargetLanguage() async throws {
        let repository = ContentRepository(database: try AppDatabase.inMemory())
        try await seedExplained(repository, text: "同一句话。")

        let found = try await repository.existingExplanation(
            sourceTextHash: "hash-A", targetLanguage: "en",
            compatiblePromptVersions: ["explain-v1"])
        #expect(found == nil)
    }

    /// prompt 版本不兼容时不复用；但判据是**集合**，将来加新版本不必让旧结果作废。
    @Test func promptVersionIsCheckedAgainstCompatibleSet() async throws {
        let repository = ContentRepository(database: try AppDatabase.inMemory())
        try await seedExplained(repository, text: "同一句话。")

        #expect(
            try await repository.existingExplanation(
                sourceTextHash: "hash-A", targetLanguage: "zh-CN",
                compatiblePromptVersions: ["explain-v2"]) == nil)
        #expect(
            try await repository.existingExplanation(
                sourceTextHash: "hash-A", targetLanguage: "zh-CN",
                compatiblePromptVersions: ["explain-v1", "explain-v2"]) != nil)
    }

    /// 没有 meta 的历史数据（内置示例文章）不该被误命中。
    @Test func ignoresRowsWithoutMeta() async throws {
        let repository = ContentRepository(database: try AppDatabase.inMemory())
        let article = Article(title: "示例", content: "同一句话。")
        let segment = ArticleSegment(articleId: article.id, order: 0, text: "同一句话。")
        try await repository.insertArticle(article, segments: [segment])
        try await repository.saveExplanation(
            segmentID: segment.id,
            explanation: SegmentExplanation(translation: "t", explanation: "e"),
            meta: nil)

        let found = try await repository.existingExplanation(
            sourceTextHash: "hash-A", targetLanguage: "zh-CN",
            compatiblePromptVersions: ["explain-v1"])
        #expect(found == nil)
    }

    // MARK: - 生词卡的 source_segment_id

    @Test func favoriteRoundTripsSourceSegmentID() async throws {
        let repository = ContentRepository(database: try AppDatabase.inMemory())
        let segmentID = UUID()
        try await repository.insertFavorite(
            FavoriteVocabulary(
                word: "字幕", meaning: "字幕", sourceSegmentId: segmentID, dueDate: "2026-01-01"))

        let loaded = try await repository.loadAll().favorites
        #expect(loaded.first?.sourceSegmentId == segmentID)
    }
}
