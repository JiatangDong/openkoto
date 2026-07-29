import Foundation
import GRDB
import OKModels
import Testing

@testable import OKPersistence

/// 删除墓碑（跨设备同步 P1）。
///
/// 守的是一条只会在**第二次导入**时才暴露的 bug：用户在手机上删掉的生词，
/// 如果没有墓碑，下次从桌面文件导入就会原样复活——而且 CloudKit 上线后
/// 这条"复活"还会被忠实地推到其它所有设备。
@Suite struct TombstoneTests {
    private func makeRepository() throws -> (ContentRepository, AppDatabase) {
        let database = try AppDatabase.inMemory()
        return (ContentRepository(database: database), database)
    }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeFavorite(word: String = "夢") -> FavoriteVocabulary {
        FavoriteVocabulary(word: word, meaning: "梦", createdAt: now, updatedAt: now)
    }

    // MARK: - 建表 / v6 → v7 增量迁移

    @Test func migrationCreatesTombstoneTable() async throws {
        let (_, database) = try makeRepository()
        let tables = try await database.writer.read { db in
            try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(tables.contains("deleted_record"))
    }

    @Test func v6DatabaseHasNoTombstoneTable() async throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v6")
        let tables = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(!tables.contains("deleted_record"))
    }

    /// 老库升级：建表是纯追加，既有数据一行不动。
    /// `inMemory()` 走的是全新建库，证明不了这一点。
    @Test func upgradingFromV6AddsTableAndKeepsExistingRows() async throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v6")
        let articleID = UUID().uuidString.lowercased()
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO article (id, title, content, source_type, created_at, updated_at)
                    VALUES (?, 'T', 'C', 'article', '2026-01-01 00:00:00', '2026-01-01 00:00:00')
                    """, arguments: [articleID])
        }

        try AppDatabase.migrator.migrate(queue)

        let (articleCount, tombstoneCount) = try await queue.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM deleted_record") ?? -1
            )
        }
        #expect(articleCount == 1)
        // 升级不会给存量数据补墓碑——那些行本来就没被删过
        #expect(tombstoneCount == 0)
    }

    // MARK: - 四个删除入口

    @Test func deletingFavoriteLeavesTombstone() async throws {
        let (repo, _) = try makeRepository()
        let favorite = makeFavorite()
        try await repo.insertFavorite(favorite, now: now)
        try await repo.deleteFavorite(id: favorite.id, now: now)

        let ids = try await repo.tombstoneIDs(for: .favoriteVocabulary)
        #expect(ids == [favorite.id.uuidString.lowercased()])
    }

    @Test func deletingArticleLeavesTombstone() async throws {
        let (repo, _) = try makeRepository()
        let article = Article(title: "テスト", content: "本文", createdAt: now)
        try await repo.insertArticle(article, segments: [], now: now)
        try await repo.deleteArticle(id: article.id, now: now)

        let ids = try await repo.tombstoneIDs(for: .article)
        #expect(ids == [article.id.uuidString.lowercased()])
    }

    @Test func deletingPackLeavesTombstone() async throws {
        let (repo, _) = try makeRepository()
        _ = try await repo.ensureDefaultPack(now: now)
        let pack = WordPack(name: "N1", createdAt: now, updatedAt: now)
        try await repo.insertPack(pack, now: now)
        try await repo.deletePack(id: pack.id, now: now)

        let ids = try await repo.tombstoneIDs(for: .wordPack)
        #expect(ids == [pack.id.uuidString.lowercased()])
    }

    /// 「把词移出词包」是独立的删除意图——生词和词包都还活着，
    /// 所以这条关系必须有自己的墓碑，否则下次导入会把它塞回原来的包。
    @Test func removingFromPackLeavesMembershipTombstone() async throws {
        let (repo, _) = try makeRepository()
        _ = try await repo.ensureDefaultPack(now: now)
        let pack = WordPack(name: "N1", createdAt: now, updatedAt: now)
        try await repo.insertPack(pack, now: now)
        let favorite = makeFavorite()
        try await repo.insertFavorite(favorite, now: now)

        try await repo.setPackIds(vocabularyId: favorite.id, packIds: [pack.id], now: now)
        try await repo.setPackIds(vocabularyId: favorite.id, packIds: [], now: now)

        let ids = try await repo.tombstoneIDs(for: .wordPackMembership)
        #expect(
            ids == [Tombstone.membershipKey(vocabularyID: favorite.id, packID: pack.id)])
    }

    /// 加回去**不会**清掉墓碑——这是有意的：墓碑只表示"曾经删过"，
    /// 导入方判定的是 id 是否命中，而重新加入产生的是一条新的活行。
    /// 真正要防的是它变成重复墓碑把表撑大。
    @Test func repeatedDeletionIsIdempotent() async throws {
        let (repo, database) = try makeRepository()
        let favorite = makeFavorite()
        try await repo.insertFavorite(favorite, now: now)
        try await repo.deleteFavorite(id: favorite.id, now: now)
        // 第二次删除同一 id（行已不在）不应报错，也不应产生第二条墓碑
        try await repo.deleteFavorite(id: favorite.id, now: now.addingTimeInterval(60))

        let count = try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM deleted_record") ?? -1
        }
        #expect(count == 1)
    }

    // MARK: - 复合键

    /// 两端（iOS 与桌面导出）必须拼出同一个键，否则同一条关系会产生
    /// 两个互不认识的墓碑，去重形同虚设。
    @Test func membershipKeyIsStableAndLowercased() {
        let vocab = UUID(uuidString: "AABBCCDD-1111-2222-3333-444455556666")!
        let pack = UUID(uuidString: "99887766-5555-4444-3333-222211110000")!
        let key = Tombstone.membershipKey(vocabularyID: vocab, packID: pack)
        #expect(key == "aabbccdd-1111-2222-3333-444455556666_99887766-5555-4444-3333-222211110000")
        // 顺序固定：生词在前，词包在后
        #expect(key != Tombstone.membershipKey(vocabularyID: pack, packID: vocab))
    }

    // MARK: - 剪枝

    @Test func pruneCutoffIsRetentionBeforeNow() {
        let cutoff = Tombstone.pruneCutoff(now: now, retention: 180 * 24 * 60 * 60)
        #expect(cutoff == now.addingTimeInterval(-180 * 24 * 60 * 60))
    }

    @Test func pruneRemovesExpiredButKeepsRecent() async throws {
        let (repo, _) = try makeRepository()
        let old = makeFavorite(word: "旧")
        let recent = makeFavorite(word: "新")
        try await repo.insertFavorite(old, now: now)
        try await repo.insertFavorite(recent, now: now)

        let day = 24.0 * 60 * 60
        try await repo.deleteFavorite(id: old.id, now: now.addingTimeInterval(-200 * day))
        try await repo.deleteFavorite(id: recent.id, now: now.addingTimeInterval(-10 * day))

        let pruned = try await repo.pruneTombstones(now: now)
        #expect(pruned == 1)

        let ids = try await repo.tombstoneIDs(for: .favoriteVocabulary)
        #expect(ids == [recent.id.uuidString.lowercased()])
    }

    /// 边界：正好等于保留期的墓碑保留（用 `<` 而非 `<=`）。
    /// 差一天就复活一批删除，宁可多留。
    @Test func pruneKeepsTombstoneExactlyAtRetentionBoundary() async throws {
        let (repo, _) = try makeRepository()
        let favorite = makeFavorite()
        try await repo.insertFavorite(favorite, now: now)
        try await repo.deleteFavorite(
            id: favorite.id, now: now.addingTimeInterval(-Tombstone.retention))

        let pruned = try await repo.pruneTombstones(now: now)
        #expect(pruned == 0)
        #expect(try await repo.tombstoneIDs(for: .favoriteVocabulary).count == 1)
    }

    // MARK: - 导出

    @Test func allTombstonesReturnsEveryTableSortedByTime() async throws {
        let (repo, _) = try makeRepository()
        let favorite = makeFavorite()
        let article = Article(title: "テスト", content: "本文", createdAt: now)
        try await repo.insertFavorite(favorite, now: now)
        try await repo.insertArticle(article, segments: [], now: now)

        try await repo.deleteArticle(id: article.id, now: now)
        try await repo.deleteFavorite(id: favorite.id, now: now.addingTimeInterval(60))

        let all = try await repo.allTombstones()
        #expect(all.count == 2)
        #expect(all.map(\.table) == [.article, .favoriteVocabulary])
    }
}
