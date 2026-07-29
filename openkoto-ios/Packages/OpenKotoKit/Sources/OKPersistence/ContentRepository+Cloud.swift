import Foundation
import GRDB
import OKModels
import OKSRS

/// 云端一条记录的载荷。引擎只管搬运，编解码与冲突判定都在这里。
public struct CloudPayload: Sendable {
    public let type: CloudRecordType
    public let id: String
    public let data: Data
    public let updatedAt: Date

    public init(type: CloudRecordType, id: String, data: Data, updatedAt: Date) {
        self.type = type
        self.id = id
        self.data = data
        self.updatedAt = updatedAt
    }
}

extension ContentRepository {

    // MARK: - 收集要推送的记录

    /// 水位线之后有变化的记录，编码成待推送载荷。
    ///
    /// 这里**不用 `dirty` 列**：那意味着要在所有 Repository 的每个写入点插一句标记，
    /// 几十处改动，且漏一处就是"这类数据永远不同步"的静默 bug。
    /// 水位线扫描的代价只是每次同步多读一遍表（几千行量级），换来写入路径零改动。
    public func pendingCloudPayloads(since watermark: Date?) async throws -> [CloudPayload] {
        let encoder = CloudRecord.encoder()
        return try await database.writer.read { db in
            var payloads: [CloudPayload] = []

            func cutoff() -> Date? {
                watermark.map { $0.addingTimeInterval(-Self.watermarkOverlap) }
            }

            // 生词（含它的词包成员，成员单独成记录见下）
            let vocabRecords: [FavoriteVocabularyRecord]
            if let since = cutoff() {
                vocabRecords = try FavoriteVocabularyRecord
                    .filter(Column("updated_at") >= since).fetchAll(db)
            } else {
                vocabRecords = try FavoriteVocabularyRecord.fetchAll(db)
            }
            for record in vocabRecords {
                let packIds = try WordPackMembershipRecord
                    .filter(Column("vocabulary_id") == record.id)
                    .fetchAll(db)
                    .compactMap { UUID(uuidString: $0.packId) }
                guard let model = try? record.domainModel(packIds: packIds),
                    let data = try? encoder.encode(model)
                else { continue }
                payloads.append(
                    CloudPayload(
                        type: .vocabulary, id: record.id, data: data,
                        updatedAt: record.updatedAt))
            }

            // 词包（系统包不上云：每台设备自己会建，id 又是固定常量）
            let packRecords: [WordPackRecord]
            if let since = cutoff() {
                packRecords = try WordPackRecord.filter(Column("updated_at") >= since).fetchAll(db)
            } else {
                packRecords = try WordPackRecord.fetchAll(db)
            }
            for record in packRecords {
                guard let model = try? record.domainModel(), !model.isSystem,
                    model.id != WordPack.systemUngroupedID,
                    let data = try? encoder.encode(model)
                else { continue }
                payloads.append(
                    CloudPayload(
                        type: .wordPack, id: record.id, data: data, updatedAt: record.updatedAt))
            }

            // 文章 + 段落
            let articleRecords: [ArticleRecord]
            if let since = cutoff() {
                articleRecords = try ArticleRecord
                    .filter(Column("updated_at") >= since).fetchAll(db)
            } else {
                articleRecords = try ArticleRecord.fetchAll(db)
            }
            for record in articleRecords {
                guard let model = try? record.domainModel(),
                    let data = try? encoder.encode(model)
                else { continue }
                payloads.append(
                    CloudPayload(
                        type: .article, id: record.id, data: data, updatedAt: record.updatedAt))
            }

            let segmentRecords: [SegmentRecord]
            if let since = cutoff() {
                segmentRecords = try SegmentRecord
                    .filter(Column("updated_at") >= since).fetchAll(db)
            } else {
                segmentRecords = try SegmentRecord.fetchAll(db)
            }
            for record in segmentRecords {
                guard let model = try? record.domainModel(),
                    let data = try? encoder.encode(model)
                else { continue }
                payloads.append(
                    CloudPayload(
                        type: .segment, id: record.id, data: data, updatedAt: record.updatedAt))
            }

            // 复习事件：只增不删，天然无冲突，是复习进度的真相所在。
            // 它没有 updated_at，用 reviewed_at 当水位线判据。
            let eventRecords: [ReviewLogRecord]
            if let since = cutoff() {
                eventRecords = try ReviewLogRecord
                    .filter(Column("reviewed_at") >= since).fetchAll(db)
            } else {
                eventRecords = try ReviewLogRecord.fetchAll(db)
            }
            for record in eventRecords {
                guard let model = try? record.domainModel(),
                    let data = try? encoder.encode(model)
                else { continue }
                payloads.append(
                    CloudPayload(
                        type: .reviewEvent, id: record.id, data: data,
                        updatedAt: record.reviewedAt))
            }

            return payloads
        }
    }

    /// 待推送的删除（来自墓碑表）。
    public func pendingCloudDeletions(since watermark: Date?) async throws -> [(
        type: CloudRecordType, id: String
    )] {
        let cutoff = watermark.map { $0.addingTimeInterval(-Self.watermarkOverlap) }
        return try await database.writer.read { db in
            let rows: [TombstoneRecord]
            if let cutoff {
                rows = try TombstoneRecord.filter(Column("deleted_at") >= cutoff).fetchAll(db)
            } else {
                rows = try TombstoneRecord.fetchAll(db)
            }
            return rows.compactMap { row -> (CloudRecordType, String)? in
                guard let table = TombstoneTable(rawValue: row.tableName) else { return nil }
                switch table {
                case .favoriteVocabulary: return (.vocabulary, row.recordId)
                case .wordPack: return (.wordPack, row.recordId)
                case .wordPackMembership: return (.wordPackMembership, row.recordId)
                case .article: return (.article, row.recordId)
                }
            }
        }
    }

    // MARK: - 应用云端拉回来的变更

    /// 把云端记录合并进本地。返回实际写入的条数。
    ///
    /// 冲突规则与文件导入一致（`ImportRules`），**唯独复习状态不走 LWW** ——
    /// 见下面的 `recomputeCardStates`。
    @discardableResult
    public func applyCloudPayloads(_ payloads: [CloudPayload], now: Date = .now) async throws
        -> Int
    {
        let decoder = CloudRecord.decoder()
        return try await database.writer.write { db in
            var applied = 0
            var touchedVocabulary: Set<String> = []

            for payload in payloads {
                switch payload.type {
                case .vocabulary:
                    guard let model = try? decoder.decode(FavoriteVocabulary.self, from: payload.data)
                    else { continue }
                    let local = try FavoriteVocabularyRecord.fetchOne(db, key: payload.id)
                    guard
                        Self.shouldWrite(
                            db, table: .favoriteVocabulary, id: payload.id,
                            localUpdatedAt: local?.updatedAt, incoming: model.updatedAt)
                    else { continue }
                    try FavoriteVocabularyRecord(model, now: model.updatedAt).save(db)
                    touchedVocabulary.insert(payload.id)
                    applied += 1

                case .wordPack:
                    guard let model = try? decoder.decode(WordPack.self, from: payload.data),
                        !model.isSystem
                    else { continue }
                    let local = try WordPackRecord.fetchOne(db, key: payload.id)
                    guard
                        Self.shouldWrite(
                            db, table: .wordPack, id: payload.id,
                            localUpdatedAt: local?.updatedAt, incoming: model.updatedAt)
                    else { continue }
                    try WordPackRecord(model, now: model.updatedAt).save(db)
                    applied += 1

                case .article:
                    guard let model = try? decoder.decode(Article.self, from: payload.data)
                    else { continue }
                    // 文章永不覆盖：正文变了，本地按旧正文切出来的 segment 会全部错位。
                    guard try ArticleRecord.fetchOne(db, key: payload.id) == nil,
                        try !Self.isTombstoned(db, .article, payload.id)
                    else { continue }
                    try ArticleRecord(model, now: model.createdAt).insert(db)
                    applied += 1

                case .segment:
                    guard let model = try? decoder.decode(ArticleSegment.self, from: payload.data)
                    else { continue }
                    // 父文章不在本地就跳过：外键会挡，硬写等于整批回滚。
                    guard
                        try ArticleRecord.fetchOne(db, key: uuidString(model.articleId)) != nil
                    else { continue }
                    let local = try SegmentRecord.fetchOne(db, key: payload.id)?.domainModel()
                    switch ImportRules.decideSegment(local: local, incoming: model) {
                    case .insert:
                        try SegmentRecord(model, meta: nil, now: model.createdAt).insert(db)
                        applied += 1
                    case .fillMissing:
                        try SegmentRecord(model, meta: nil, now: now).update(db)
                        applied += 1
                    case .skip:
                        break
                    }

                case .reviewEvent:
                    guard let model = try? decoder.decode(ReviewEvent.self, from: payload.data)
                    else { continue }
                    // append-only：id 撞了就是同一条
                    guard try ReviewLogRecord.fetchOne(db, key: payload.id) == nil else { continue }
                    try ReviewLogRecord(model).insert(db)
                    touchedVocabulary.insert(uuidString(model.vocabularyId))
                    applied += 1

                case .wordPackMembership:
                    let parts = payload.id.split(separator: "_", maxSplits: 1)
                    guard parts.count == 2 else { continue }
                    let (vocabId, packId) = (String(parts[0]), String(parts[1]))
                    guard try !Self.isTombstoned(db, .wordPackMembership, payload.id),
                        try FavoriteVocabularyRecord.fetchOne(db, key: vocabId) != nil,
                        try WordPackRecord.fetchOne(db, key: packId) != nil
                    else { continue }
                    let exists =
                        try Bool.fetchOne(
                            db,
                            sql: """
                                SELECT EXISTS(SELECT 1 FROM word_pack_membership
                                WHERE vocabulary_id = ? AND pack_id = ?)
                                """,
                            arguments: [vocabId, packId]) ?? false
                    guard !exists else { continue }
                    try WordPackMembershipRecord(
                        vocabularyId: vocabId, packId: packId, createdAt: now
                    ).insert(db)
                    applied += 1
                }
            }

            // 复习状态用事件重放重算，**绝不接受云端的卡片快照**。
            try Self.recomputeCardStates(db, vocabularyIDs: touchedVocabulary)
            return applied
        }
    }

    /// 云端的删除：本地也删，并记墓碑（防止别的设备把它推回来）。
    public func applyCloudDeletions(
        _ deletions: [(type: CloudRecordType, id: String)], now: Date = .now
    ) async throws {
        try await database.writer.write { db in
            for deletion in deletions {
                switch deletion.type {
                case .vocabulary:
                    _ = try FavoriteVocabularyRecord.deleteOne(db, key: deletion.id)
                    try TombstoneRecord.mark(
                        db, table: .favoriteVocabulary, recordID: deletion.id, at: now)
                case .wordPack:
                    _ = try WordPackRecord.deleteOne(db, key: deletion.id)
                    try TombstoneRecord.mark(
                        db, table: .wordPack, recordID: deletion.id, at: now)
                case .article:
                    _ = try ArticleRecord.deleteOne(db, key: deletion.id)
                    try TombstoneRecord.mark(db, table: .article, recordID: deletion.id, at: now)
                case .wordPackMembership:
                    let parts = deletion.id.split(separator: "_", maxSplits: 1)
                    guard parts.count == 2 else { continue }
                    try db.execute(
                        sql:
                            "DELETE FROM word_pack_membership WHERE vocabulary_id = ? AND pack_id = ?",
                        arguments: [String(parts[0]), String(parts[1])])
                    try TombstoneRecord.mark(
                        db, table: .wordPackMembership, recordID: deletion.id, at: now)
                case .segment, .reviewEvent:
                    // 段落随文章级联；复习事件只增不删。都不会收到独立的删除。
                    break
                }
            }
        }
    }

    // MARK: - 冲突判定

    private static func isTombstoned(
        _ db: Database, _ table: TombstoneTable, _ id: String
    ) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM deleted_record WHERE table_name = ? AND record_id = ?)",
            arguments: [table.rawValue, id]) ?? false
    }

    private static func shouldWrite(
        _ db: Database, table: TombstoneTable, id: String,
        localUpdatedAt: Date?, incoming: Date
    ) -> Bool {
        guard (try? isTombstoned(db, table, id)) == false else { return false }
        switch ImportRules.decide(
            isTombstoned: false, localUpdatedAt: localUpdatedAt, incomingUpdatedAt: incoming)
        {
        case .insert, .update: return true
        case .skipDeleted, .skipLocalNewer: return false
        }
    }

    /// 用复习事件重放，重算这些卡片的 FSRS 状态。
    ///
    /// **这是同步里唯一不能用 last-writer-wins 的地方。** 两台设备各离线复习一轮，
    /// 若按快照后写胜，晚同步的那台会整轮覆盖掉另一台——用户复习了两次、
    /// 进度只记了一次，而且毫无提示。事件表只增不删，重放出来的状态与
    /// "在同一台设备上依次复习两次"完全一致。
    static func recomputeCardStates(_ db: Database, vocabularyIDs: Set<String>) throws {
        for vocabId in vocabularyIDs {
            guard var record = try FavoriteVocabularyRecord.fetchOne(db, key: vocabId) else {
                continue
            }
            let events = try ReviewLogRecord
                .filter(Column("vocabulary_id") == vocabId)
                .order(Column("reviewed_at"))
                .fetchAll(db)
                .compactMap { try? $0.domainModel() }
            guard let state = ReviewReplay.replay(events) else { continue }
            record.srsState = state.srsState.rawValue
            record.stability = state.stability
            record.difficulty = state.difficulty
            record.dueDate = state.dueDate
            record.lastReviewedAt = state.lastReviewedAt
            record.reviewCount = state.reviewCount
            record.schedulerVersion = state.schedulerVersion
            try record.update(db)
        }
    }
}
