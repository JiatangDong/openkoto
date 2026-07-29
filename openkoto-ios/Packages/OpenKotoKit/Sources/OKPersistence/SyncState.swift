import Foundation
import GRDB
import OKModels

/// 同步引擎的持久状态（单行表 `sync_state`）。
struct SyncStateRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sync_state"
    /// 单行表的固定主键。
    static let singletonID = "default"

    var id: String
    var engineState: Data?
    var lastSyncedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case engineState = "engine_state"
        case lastSyncedAt = "last_synced_at"
    }
}

extension ContentRepository {
    /// 推送水位线：`updated_at` 晚于它的行才需要推上云。
    /// nil 表示从未同步过（首次同步要推全部）。
    public func syncWatermark() async throws -> Date? {
        try await database.writer.read { db in
            try SyncStateRecord.fetchOne(db, key: SyncStateRecord.singletonID)?.lastSyncedAt
        }
    }

    public func setSyncWatermark(_ date: Date?) async throws {
        try await database.writer.write { db in
            try Self.writeSyncState(db) { $0.lastSyncedAt = date }
        }
    }

    /// `CKSyncEngine.State.Serialization`。丢了不会丢数据，
    /// 只会导致下一次同步做一轮全量对账。
    public func syncEngineState() async throws -> Data? {
        try await database.writer.read { db in
            try SyncStateRecord.fetchOne(db, key: SyncStateRecord.singletonID)?.engineState
        }
    }

    public func setSyncEngineState(_ data: Data?) async throws {
        try await database.writer.write { db in
            try Self.writeSyncState(db) { $0.engineState = data }
        }
    }

    /// 单行读改写。`save` 覆盖同一主键，天然幂等。
    static func writeSyncState(_ db: Database, _ mutate: (inout SyncStateRecord) -> Void) throws {
        var record =
            try SyncStateRecord.fetchOne(db, key: SyncStateRecord.singletonID)
            ?? SyncStateRecord(id: SyncStateRecord.singletonID, engineState: nil, lastSyncedAt: nil)
        mutate(&record)
        try record.save(db)
    }

    /// 推送候选：`updated_at` 晚于水位线的主键。
    ///
    /// 故意向前重叠几秒：SQLite 的时间戳只到秒，同一秒内"读水位线"与"写数据"
    /// 的先后没有保证，不重叠会漏推。上层的 upsert 是幂等的，多推几条不要紧，
    /// **漏推一条却是永久性的数据不一致**。
    public static let watermarkOverlap: TimeInterval = 5

    public func changedRecordIDs(
        table: TombstoneTable, since watermark: Date?
    ) async throws -> [String] {
        let sqlTable: String
        switch table {
        case .favoriteVocabulary: sqlTable = "favorite_vocabulary"
        case .wordPack: sqlTable = "word_pack"
        case .article: sqlTable = "article"
        case .wordPackMembership:
            // 成员关系没有 updated_at（只有 created_at），按创建时间判定即可：
            // 这张表只有插入和删除，没有"修改"。
            return try await database.writer.read { db in
                guard let watermark else {
                    return try String.fetchAll(
                        db,
                        sql:
                            "SELECT vocabulary_id || '_' || pack_id FROM word_pack_membership")
                }
                return try String.fetchAll(
                    db,
                    sql: """
                        SELECT vocabulary_id || '_' || pack_id FROM word_pack_membership
                        WHERE created_at >= ?
                        """,
                    arguments: [watermark.addingTimeInterval(-Self.watermarkOverlap)])
            }
        }
        return try await database.writer.read { db in
            guard let watermark else {
                return try String.fetchAll(db, sql: "SELECT id FROM \(sqlTable)")
            }
            return try String.fetchAll(
                db,
                sql: "SELECT id FROM \(sqlTable) WHERE updated_at >= ?",
                arguments: [watermark.addingTimeInterval(-Self.watermarkOverlap)])
        }
    }
}
