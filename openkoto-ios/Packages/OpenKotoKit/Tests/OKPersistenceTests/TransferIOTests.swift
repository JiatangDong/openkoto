import Foundation
import GRDB
import OKModels
import Testing

@testable import OKPersistence

/// 传输包的导入/导出（跨设备同步 P2）。
///
/// 这组测试的重心只有一个：**幂等**。用户不会只导一次——桌面加了 50 个词导一次，
/// 下周又加 30 个还会再导一次。如果导入写成"读文件→逐条插入"，第二次就是
/// 80 条里 50 条重复，而 P3 的 CloudKit 会把这些重复忠实地推到所有设备。
@Suite struct TransferIOTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private var t1: Date { t0.addingTimeInterval(3600) }

    private func makeRepository() throws -> ContentRepository {
        ContentRepository(database: try AppDatabase.inMemory())
    }

    private func makeVocab(
        id: UUID = UUID(), word: String = "夢", meaning: String = "梦",
        packIds: [UUID] = [], updatedAt: Date
    ) -> FavoriteVocabulary {
        FavoriteVocabulary(
            id: id, word: word, meaning: meaning, packIds: packIds,
            dueDate: "2026-01-01", createdAt: updatedAt, updatedAt: updatedAt)
    }

    private func bundle(
        vocabulary: [FavoriteVocabulary] = [], packs: [WordPack] = [],
        articles: [Article] = [], segments: [ArticleSegment] = [],
        reviewEvents: [ReviewEvent] = [], tombstones: [Tombstone] = []
    ) -> TransferBundle {
        TransferBundle(
            exportedAt: t0, sourceApp: "test", vocabulary: vocabulary, packs: packs,
            articles: articles, segments: segments, reviewEvents: reviewEvents,
            tombstones: tombstones)
    }

    // MARK: - 幂等（本阶段最重要的一条）

    @Test func importingTheSameBundleTwiceCreatesNoDuplicates() async throws {
        let repo = try makeRepository()
        let pack = WordPack(name: "N1", createdAt: t0, updatedAt: t0)
        let vocab = makeVocab(packIds: [pack.id], updatedAt: t0)
        let payload = bundle(vocabulary: [vocab], packs: [pack])

        let first = try await repo.importTransferBundle(payload, now: t1)
        #expect(first.vocabulary.inserted == 1)
        #expect(first.packs.inserted == 1)
        #expect(first.memberships.inserted == 1)

        let second = try await repo.importTransferBundle(payload, now: t1)
        #expect(second.vocabulary.inserted == 0)
        #expect(second.packs.inserted == 0)
        #expect(second.memberships.inserted == 0)
        // 第二次必须是彻底的空操作，连 update 都不该有——否则 updated_at 会被推高，
        // P3 的水位线会把整库当成"有变更"重新推上云。
        #expect(second.vocabulary.updated == 0)
        #expect(second.packs.updated == 0)

        let snapshot = try await repo.loadAll()
        #expect(snapshot.favorites.count == 1)
        #expect(snapshot.packs.filter { !$0.isSystem }.count == 1)
    }

    @Test func importingTwiceKeepsExactlyOneMembershipRow() async throws {
        let repo = try makeRepository()
        let pack = WordPack(name: "N1", createdAt: t0, updatedAt: t0)
        let vocab = makeVocab(packIds: [pack.id], updatedAt: t0)
        let payload = bundle(vocabulary: [vocab], packs: [pack])

        _ = try await repo.importTransferBundle(payload, now: t1)
        _ = try await repo.importTransferBundle(payload, now: t1)

        let count = try await repo.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM word_pack_membership") ?? -1
        }
        #expect(count == 1)
    }

    // MARK: - 冲突：本地更新时间更晚就保留本地

    @Test func localEditsSurviveAnOlderFile() async throws {
        let repo = try makeRepository()
        let id = UUID()
        try await repo.insertFavorite(
            makeVocab(id: id, meaning: "手机上改过的释义", updatedAt: t1), now: t1)

        // 文件里是更早的版本
        let result = try await repo.importTransferBundle(
            bundle(vocabulary: [makeVocab(id: id, meaning: "旧释义", updatedAt: t0)]), now: t1)

        #expect(result.vocabulary.skippedLocalNewer == 1)
        let loaded = try await repo.loadAll().favorites.first
        #expect(loaded?.meaning == "手机上改过的释义")
    }

    @Test func newerFileUpdatesLocalRecord() async throws {
        let repo = try makeRepository()
        let id = UUID()
        try await repo.insertFavorite(makeVocab(id: id, meaning: "旧", updatedAt: t0), now: t0)

        let result = try await repo.importTransferBundle(
            bundle(vocabulary: [makeVocab(id: id, meaning: "新", updatedAt: t1)]), now: t1)

        #expect(result.vocabulary.updated == 1)
        #expect(try await repo.loadAll().favorites.first?.meaning == "新")
    }

    // MARK: - 墓碑：删过的不许复活

    @Test func deletedVocabularyIsNotResurrectedByImport() async throws {
        let repo = try makeRepository()
        let vocab = makeVocab(updatedAt: t0)
        try await repo.insertFavorite(vocab, now: t0)
        try await repo.deleteFavorite(id: vocab.id, now: t0)

        let result = try await repo.importTransferBundle(
            bundle(vocabulary: [vocab]), now: t1)

        #expect(result.vocabulary.skippedDeleted == 1)
        #expect(try await repo.loadAll().favorites.isEmpty)
    }

    /// 「把词移出词包」也不能被导入撤销——生词本身还在，只是不该回到那个包。
    @Test func removedMembershipIsNotRestoredByImport() async throws {
        let repo = try makeRepository()
        _ = try await repo.ensureDefaultPack(now: t0)
        let pack = WordPack(name: "N1", createdAt: t0, updatedAt: t0)
        try await repo.insertPack(pack, now: t0)
        let vocab = makeVocab(packIds: [pack.id], updatedAt: t0)
        try await repo.insertFavorite(vocab, now: t0)
        try await repo.setPackIds(vocabularyId: vocab.id, packIds: [], now: t0)

        let result = try await repo.importTransferBundle(
            bundle(vocabulary: [vocab], packs: [pack]), now: t1)

        #expect(result.memberships.skippedDeleted == 1)
        let count = try await repo.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM word_pack_membership") ?? -1
        }
        #expect(count == 0)
    }

    /// 生词内容一个字没改、但在来源端被加进了一个新词包 —— 这次分组必须同步过来。
    /// （成员关系一度被卡片的 `updatedAt` 挡住，是真出现过的 bug。）
    @Test func newMembershipSyncsEvenWhenTheWordItselfIsUnchanged() async throws {
        let repo = try makeRepository()
        _ = try await repo.ensureDefaultPack(now: t0)
        let vocab = makeVocab(updatedAt: t0)
        try await repo.insertFavorite(vocab, now: t0)

        // 来源端把它加进了 N1；卡片本身没动，updatedAt 仍是 t0
        let pack = WordPack(name: "N1", createdAt: t0, updatedAt: t0)
        var regrouped = vocab
        regrouped.packIds = [pack.id]

        let result = try await repo.importTransferBundle(
            bundle(vocabulary: [regrouped], packs: [pack]), now: t1)

        #expect(result.vocabulary.skippedLocalNewer == 1)  // 卡片确实没动
        #expect(result.memberships.inserted == 1)  // 但分组进来了
        #expect(try await repo.loadAll().favorites.first?.packIds == [pack.id])
    }

    /// 来源端的墓碑**只防复活，绝不删本地已有的行**。
    /// 文件是任意时刻的快照，凭它删用户手上的数据，风险远大于多留一条记录。
    @Test func incomingTombstoneNeverDeletesExistingLocalRow() async throws {
        let repo = try makeRepository()
        let vocab = makeVocab(updatedAt: t0)
        try await repo.insertFavorite(vocab, now: t0)

        _ = try await repo.importTransferBundle(
            bundle(tombstones: [
                Tombstone(
                    table: .favoriteVocabulary,
                    recordID: vocab.id.uuidString.lowercased(), deletedAt: t1)
            ]), now: t1)

        #expect(try await repo.loadAll().favorites.count == 1)
        // 本地还有这条 → 不记墓碑，否则会留下"行在、却被标记删过"的矛盾状态
        #expect(try await repo.tombstoneIDs(for: .favoriteVocabulary).isEmpty)
    }

    @Test func incomingTombstonePreventsFutureResurrection() async throws {
        let repo = try makeRepository()
        let vocab = makeVocab(updatedAt: t0)
        let stone = Tombstone(
            table: .favoriteVocabulary, recordID: vocab.id.uuidString.lowercased(),
            deletedAt: t1)

        _ = try await repo.importTransferBundle(bundle(tombstones: [stone]), now: t1)
        let result = try await repo.importTransferBundle(bundle(vocabulary: [vocab]), now: t1)

        #expect(result.vocabulary.skippedDeleted == 1)
        #expect(try await repo.loadAll().favorites.isEmpty)
    }

    // MARK: - 文章与段落

    @Test func articleIsInsertedWithSegmentsButNeverOverwritten() async throws {
        let repo = try makeRepository()
        let article = Article(title: "夢十夜", content: "こんな夢を見た。", createdAt: t0)
        let segment = ArticleSegment(
            articleId: article.id, order: 0, text: "こんな夢を見た。", createdAt: t0)

        let first = try await repo.importTransferBundle(
            bundle(articles: [article], segments: [segment]), now: t1)
        #expect(first.articles.inserted == 1)
        #expect(first.segments.inserted == 1)

        var edited = article
        edited.title = "被文件覆盖了"
        let second = try await repo.importTransferBundle(
            bundle(articles: [edited], segments: [segment]), now: t1)
        #expect(second.articles.skippedLocalNewer == 1)
        #expect(try await repo.loadAll().articles.first?.title == "夢十夜")
    }

    /// 精讲是花钱生成的：本地缺就补上。
    @Test func missingExplanationIsFilledFromFile() async throws {
        let repo = try makeRepository()
        let article = Article(title: "T", content: "一句。", createdAt: t0)
        let bare = ArticleSegment(articleId: article.id, order: 0, text: "一句。", createdAt: t0)
        try await repo.insertArticle(article, segments: [bare], now: t0)

        var explained = bare
        explained.translation = "一句译文"
        explained.explanation = SegmentExplanation(translation: "一句译文", explanation: "讲解")

        let result = try await repo.importTransferBundle(
            bundle(articles: [article], segments: [explained]), now: t1)

        #expect(result.segments.updated == 1)
        let loaded = try await repo.loadSegments(articleID: article.id).first
        #expect(loaded?.explanation?.explanation == "讲解")
    }

    /// 但本地已有的精讲绝不覆盖——用户可能已经用更好的模型重生成过。
    @Test func existingExplanationIsNeverOverwritten() async throws {
        let repo = try makeRepository()
        let article = Article(title: "T", content: "一句。", createdAt: t0)
        var local = ArticleSegment(articleId: article.id, order: 0, text: "一句。", createdAt: t0)
        local.explanation = SegmentExplanation(translation: "本地译文", explanation: "本地讲解")
        try await repo.insertArticle(article, segments: [local], now: t0)

        var incoming = local
        incoming.explanation = SegmentExplanation(translation: "文件译文", explanation: "文件讲解")
        let result = try await repo.importTransferBundle(
            bundle(articles: [article], segments: [incoming]), now: t1)

        #expect(result.segments.skippedLocalNewer == 1)
        let loaded = try await repo.loadSegments(articleID: article.id).first
        #expect(loaded?.explanation?.explanation == "本地讲解")
    }

    /// 父文章不在本地（也不在这个包里）的句子必须跳过——外键会挡，写了就是整批回滚。
    @Test func orphanSegmentsAreSkippedInsteadOfFailingTheWholeImport() async throws {
        let repo = try makeRepository()
        let orphan = ArticleSegment(
            articleId: UUID(), order: 0, text: "孤儿句", createdAt: t0)
        let vocab = makeVocab(updatedAt: t0)

        let result = try await repo.importTransferBundle(
            bundle(vocabulary: [vocab], segments: [orphan]), now: t1)

        #expect(result.segments.skippedDeleted == 1)
        // 整批没有因为它回滚
        #expect(result.vocabulary.inserted == 1)
    }

    // MARK: - 复习事件

    @Test func reviewEventsAreAppendedOnceEvenAcrossRepeatedImports() async throws {
        let repo = try makeRepository()
        let vocab = makeVocab(updatedAt: t0)
        let event = ReviewEvent(
            vocabularyId: vocab.id, reviewedAt: t0, dateLocal: "2026-01-01", grade: 3,
            elapsedDays: 0, previousState: .new, schedulerVersion: "fsrs6",
            desiredRetention: 0.9, resultStability: 3.0, resultDifficulty: 5.0,
            resultIntervalDays: 3, resultState: .review)
        let payload = bundle(vocabulary: [vocab], reviewEvents: [event])

        let first = try await repo.importTransferBundle(payload, now: t1)
        let second = try await repo.importTransferBundle(payload, now: t1)

        #expect(first.reviewEvents.inserted == 1)
        #expect(second.reviewEvents.inserted == 0)
        let count = try await repo.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_log") ?? -1
        }
        #expect(count == 1)
    }

    // MARK: - 系统包

    /// "未分组"是每台设备各自 ensureDefaultPack 保证存在的固定 id，
    /// 跨设备传输它只会引起无谓的更新。
    @Test func systemPackIsNeitherExportedNorImported() async throws {
        let repo = try makeRepository()
        let system = try await repo.ensureDefaultPack(now: t0)

        let exported = try await repo.exportTransferBundle(exportedAt: t0)
        #expect(exported.packs.isEmpty)

        let result = try await repo.importTransferBundle(bundle(packs: [system]), now: t1)
        #expect(result.packs.total == 0)
    }

    // MARK: - 导出 → 导入 round-trip

    @Test func exportThenImportIntoAFreshDatabaseReproducesEverything() async throws {
        let source = try makeRepository()
        _ = try await source.ensureDefaultPack(now: t0)
        let pack = WordPack(name: "N1", createdAt: t0, updatedAt: t0)
        try await source.insertPack(pack, now: t0)
        let vocab = makeVocab(word: "夢", packIds: [pack.id], updatedAt: t0)
        try await source.insertFavorite(vocab, now: t0)
        let article = Article(title: "夢十夜", content: "こんな夢を見た。", createdAt: t0)
        let segment = ArticleSegment(
            articleId: article.id, order: 0, text: "こんな夢を見た。", createdAt: t0)
        try await source.insertArticle(article, segments: [segment], now: t0)

        let exported = try await source.exportTransferBundle(exportedAt: t0)
        let data = try exported.encoded()
        let decoded = try TransferBundle.decode(from: data)

        let target = try makeRepository()
        _ = try await target.ensureDefaultPack(now: t0)
        let result = try await target.importTransferBundle(decoded, now: t1)

        #expect(result.vocabulary.inserted == 1)
        #expect(result.packs.inserted == 1)
        #expect(result.articles.inserted == 1)
        #expect(result.segments.inserted == 1)

        let snapshot = try await target.loadAll()
        #expect(snapshot.favorites.first?.word == "夢")
        #expect(snapshot.favorites.first?.packIds == [pack.id])
        #expect(snapshot.articles.first?.title == "夢十夜")
    }
}
