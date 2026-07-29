import Foundation
import GRDB
import OKModels

/// 传输包（`.okdata.json`）的落库与导出。
///
/// 判定逻辑全在 `OKModels/ImportRules` 里（纯函数、有单测），
/// 这里只负责"按判定结果写库"和"把库读成一个包"。
extension ContentRepository {

    // MARK: - 导入

    /// 把传输包合并进本地库。**整个过程在单一事务里**：
    /// 中途失败必须整体回滚，否则会留下"词包进来了但生词没进来"的半截状态。
    ///
    /// - Note: 导入会保留来源端的 `updatedAt`（而不是写成当前时间），
    ///   否则「导入旧文件 → 再导入新文件」时，新文件的编辑会被误判成
    ///   "本地更新"而丢弃。代价是 P3 的同步水位线可能扫不到这些行
    ///   （它们的时间戳可能很旧），所以**导入之后必须把水位线回拨**——
    ///   见 `SyncWatermark.reset`。
    public func importTransferBundle(
        _ bundle: TransferBundle, now: Date = .now
    ) async throws -> ImportResult {
        try await database.writer.write { db in
            var result = ImportResult()

            let deletedVocab = try Self.tombstoneSet(db, .favoriteVocabulary)
            let deletedPacks = try Self.tombstoneSet(db, .wordPack)
            let deletedMemberships = try Self.tombstoneSet(db, .wordPackMembership)
            let deletedArticles = try Self.tombstoneSet(db, .article)

            // 1) 词包先行——生词的成员关系有指向它的外键。
            for pack in bundle.packs {
                // 系统包（"未分组"）在每台设备上由 ensureDefaultPack 各自保证存在，
                // 不该跨设备传输：它的 id 是固定常量，导入只会引起无谓的更新。
                guard !pack.isSystem, pack.id != WordPack.systemUngroupedID else { continue }
                let packId = uuidString(pack.id)
                let local = try WordPackRecord.fetchOne(db, key: packId)
                let decision = ImportRules.decide(
                    isTombstoned: deletedPacks.contains(packId),
                    localUpdatedAt: local?.updatedAt,
                    incomingUpdatedAt: pack.updatedAt)
                result.packs.record(decision)
                switch decision {
                case .insert: try WordPackRecord(pack, now: pack.updatedAt).insert(db)
                case .update: try WordPackRecord(pack, now: pack.updatedAt).update(db)
                case .skipDeleted, .skipLocalNewer: break
                }
            }

            // 2) 生词
            for vocab in bundle.vocabulary {
                let vocabId = uuidString(vocab.id)
                let local = try FavoriteVocabularyRecord.fetchOne(db, key: vocabId)
                let decision = ImportRules.decide(
                    isTombstoned: deletedVocab.contains(vocabId),
                    localUpdatedAt: local?.updatedAt,
                    incomingUpdatedAt: vocab.updatedAt)
                result.vocabulary.record(decision)
                switch decision {
                case .insert: try FavoriteVocabularyRecord(vocab, now: vocab.updatedAt).insert(db)
                case .update: try FavoriteVocabularyRecord(vocab, now: vocab.updatedAt).update(db)
                case .skipLocalNewer: break  // 卡片本身不动，但成员关系照常处理，见下
                case .skipDeleted: continue  // 词都删了，它的关系一并跳过
                }

                // 3) 成员关系：两端都必须真实存在（两条外键都是 cascade），
                //    且这条关系本身没被删过——「把词移出词包」是独立的删除意图。
                //
                //    **不受上面 `skipLocalNewer` 的支配**：membership 是独立记录，
                //    有自己的生命周期。生词内容一个字没改、但被加进了一个新词包，
                //    是完全正常的情况；用卡片的时间戳把它挡掉会让那次分组永远同步不过来。
                for packID in vocab.packIds {
                    let packId = uuidString(packID)
                    let key = Tombstone.membershipKey(vocabularyID: vocab.id, packID: packID)
                    guard !deletedMemberships.contains(key),
                        !deletedPacks.contains(packId),
                        try WordPackRecord.fetchOne(db, key: packId) != nil
                    else {
                        result.memberships.record(ImportDecision.skipDeleted)
                        continue
                    }
                    let exists = try Bool.fetchOne(
                        db,
                        sql: """
                            SELECT EXISTS(SELECT 1 FROM word_pack_membership
                            WHERE vocabulary_id = ? AND pack_id = ?)
                            """,
                        arguments: [vocabId, packId]) ?? false
                    if exists {
                        result.memberships.record(ImportDecision.skipLocalNewer)
                    } else {
                        try WordPackMembershipRecord(
                            vocabularyId: vocabId, packId: packId, createdAt: now
                        ).insert(db)
                        result.memberships.record(ImportDecision.insert)
                    }
                }
            }

            // 4) 文章：存在即跳过，永不覆盖（覆盖会让本地 segment 与新正文错位）
            var insertedArticles: Set<UUID> = []
            for article in bundle.articles {
                let articleId = uuidString(article.id)
                let exists = try ArticleRecord.fetchOne(db, key: articleId) != nil
                let decision = ImportRules.decideArticle(
                    isTombstoned: deletedArticles.contains(articleId), existsLocally: exists)
                result.articles.record(decision)
                guard decision == .insert else { continue }
                try ArticleRecord(article, now: article.createdAt).insert(db)
                insertedArticles.insert(article.id)
            }

            // 5) 段落：新文章的整批插入；已有文章的只补不覆盖。
            for segment in bundle.segments {
                // 文章被删过 → 它的句子一并跳过，不留孤儿。
                if deletedArticles.contains(uuidString(segment.articleId)) {
                    result.segments.record(ImportDecision.skipDeleted)
                    continue
                }
                let segmentId = uuidString(segment.id)
                let local: ArticleSegment?
                if insertedArticles.contains(segment.articleId) {
                    local = nil
                } else {
                    local = try SegmentRecord.fetchOne(db, key: segmentId)?.domainModel()
                }
                // 父文章在本地根本不存在（既不是这次插入的，也没有旧行）→ 外键会挡，跳过。
                if local == nil, !insertedArticles.contains(segment.articleId),
                    try ArticleRecord.fetchOne(db, key: uuidString(segment.articleId)) == nil
                {
                    result.segments.record(ImportDecision.skipDeleted)
                    continue
                }
                let decision = ImportRules.decideSegment(local: local, incoming: segment)
                result.segments.record(decision)
                switch decision {
                case .insert:
                    try SegmentRecord(segment, meta: nil, now: segment.createdAt).insert(db)
                case .fillMissing:
                    try SegmentRecord(segment, meta: nil, now: now).update(db)
                case .skip:
                    break
                }
            }

            // 6) 复习事件：append-only，id 撞了就是同一条，跳过即可。
            //    vocabulary_id 刻意没有外键（事件要在卡片删除后存活），所以不依赖顺序。
            for event in bundle.reviewEvents {
                let eventId = uuidString(event.id)
                if try ReviewLogRecord.fetchOne(db, key: eventId) != nil {
                    result.reviewEvents.record(ImportDecision.skipLocalNewer)
                } else {
                    try ReviewLogRecord(event).insert(db)
                    result.reviewEvents.record(ImportDecision.insert)
                }
            }

            // 7) 来源端的墓碑：**只用来防复活，绝不删本地已有的行。**
            //    文件可能是任意时刻导出的快照，凭它删用户手上的数据风险远大于
            //    多留一条记录。所以只在"本地压根没有这条"时才记墓碑。
            for tombstone in bundle.tombstones {
                guard try !Self.recordExists(db, tombstone) else { continue }
                try TombstoneRecord.mark(
                    db, table: tombstone.table, recordID: tombstone.recordID,
                    at: tombstone.deletedAt)
            }

            // 8) 回拨同步水位线 —— **必须与导入同事务**。
            //
            // 导入刻意保留了来源端的 `updatedAt`（否则「先导旧文件、再导新文件」时，
            // 新文件里的编辑会被误判成"本地更新"而丢弃）。副作用是这些行的时间戳
            // 可能比水位线还旧，P3 的推送扫描 `updated_at >= 水位线` 会**整批扫不到**，
            // 于是刚导进来的几百个词永远上不了 iCloud，其它设备完全看不见。
            //
            // 置 nil 让下一次同步做一轮全量对账。代价只是多扫一遍表（几千行量级），
            // 换来的是"导入的东西一定会同步出去"这个确定性。
            if result.changedAnything {
                try Self.writeSyncState(db) { $0.lastSyncedAt = nil }
            }

            return result
        }
    }

    private static func tombstoneSet(_ db: Database, _ table: TombstoneTable) throws -> Set<String>
    {
        Set(
            try String.fetchAll(
                db, sql: "SELECT record_id FROM deleted_record WHERE table_name = ?",
                arguments: [table.rawValue]))
    }

    private static func recordExists(_ db: Database, _ tombstone: Tombstone) throws -> Bool {
        switch tombstone.table {
        case .favoriteVocabulary:
            return try FavoriteVocabularyRecord.fetchOne(db, key: tombstone.recordID) != nil
        case .wordPack:
            return try WordPackRecord.fetchOne(db, key: tombstone.recordID) != nil
        case .article:
            return try ArticleRecord.fetchOne(db, key: tombstone.recordID) != nil
        case .wordPackMembership:
            let parts = tombstone.recordID.split(separator: "_", maxSplits: 1)
            guard parts.count == 2 else { return false }
            return try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(SELECT 1 FROM word_pack_membership
                    WHERE vocabulary_id = ? AND pack_id = ?)
                    """,
                arguments: [String(parts[0]), String(parts[1])]) ?? false
        }
    }

    // MARK: - 导出

    /// 把本地库读成一个传输包。
    ///
    /// - Parameter includeContent: 是否带上文章与段落。词库通常只有几百 KB，
    ///   而带上全部正文与精讲可能是几十 MB——让调用方决定。
    public func exportTransferBundle(
        includeContent: Bool = true, exportedAt: Date = .now, sourceApp: String? = "openkoto-ios"
    ) async throws -> TransferBundle {
        try await database.writer.read { db in
            let packs = try WordPackRecord.fetchAll(db)
                .compactMap { try? $0.domainModel() }
                // 系统包不导出：每台设备自己会建，id 又是固定常量。
                .filter { !$0.isSystem && $0.id != WordPack.systemUngroupedID }

            let memberships = try WordPackMembershipRecord.fetchAll(db)
            let packIdsByVocab = Dictionary(grouping: memberships, by: \.vocabularyId)
                .mapValues { $0.compactMap { UUID(uuidString: $0.packId) } }

            let vocabulary = try FavoriteVocabularyRecord.fetchAll(db)
                .compactMap { record in
                    try? record.domainModel(packIds: packIdsByVocab[record.id] ?? [])
                }

            let reviewEvents = try ReviewLogRecord
                .order(Column("reviewed_at"))
                .fetchAll(db)
                .compactMap { try? $0.domainModel() }

            let tombstones = try TombstoneRecord.fetchAll(db).compactMap(\.tombstone)

            var articles: [Article] = []
            var segments: [ArticleSegment] = []
            if includeContent {
                articles = try ArticleRecord.fetchAll(db).compactMap { try? $0.domainModel() }
                segments = try SegmentRecord
                    .order(Column("article_id"), Column("order_index"))
                    .fetchAll(db)
                    .compactMap { try? $0.domainModel() }
            }

            return TransferBundle(
                exportedAt: exportedAt,
                sourceApp: sourceApp,
                vocabulary: vocabulary,
                packs: packs,
                articles: articles,
                segments: segments,
                reviewEvents: reviewEvents,
                tombstones: tombstones)
        }
    }
}
