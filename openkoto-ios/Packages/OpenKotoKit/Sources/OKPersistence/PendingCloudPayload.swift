import Foundation
import GRDB

/// 依赖还没到本机、暂时合并不了的云端记录（见 migration v10）。
///
/// 停放而不是丢弃：CloudKit 的 change token 在事件送达时就前进了，
/// **一条记录只会被下发一次**。跳过等于永久丢失。
struct PendingCloudPayloadRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pending_cloud_payload"

    var recordName: String
    var recordType: String
    var recordId: String
    var payload: Data
    var updatedAt: Date
    var firstSeenAt: Date
    var attempts: Int

    enum CodingKeys: String, CodingKey {
        case recordName = "record_name"
        case recordType = "record_type"
        case recordId = "record_id"
        case payload
        case updatedAt = "updated_at"
        case firstSeenAt = "first_seen_at"
        case attempts
    }
}

extension ContentRepository {
    /// 停放上限。任意一条越界就丢弃**并记日志** —— 静默丢弃正是这一整轮同步 bug
    /// 的共同形状，宁可日志吵一点。
    ///
    /// **真正的上限是时间，不是次数。** 一次同步会拆成多个批次，每个批次都调一次
    /// `applyCloudPayloads`、都会重试一遍停放的记录 —— 一本 100 章的书拆成十几批时，
    /// 次数几十下就烧完了，那条章节归属会在它的 article 还没到之前就被丢掉，
    /// 而这正是停放机制要防的事。所以次数只当"跑飞了"的兜底，
    /// 判定"这个依赖再也不会来了"交给 30 天。
    static let pendingPayloadMaxAttempts = 500
    static let pendingPayloadMaxAge: TimeInterval = 30 * 24 * 3600

    /// 停放一条。`save` 覆盖同名记录：同一条又下发一次时以新的为准，
    /// 但 `first_seen_at` 与 `attempts` 要延续，否则永远不会到达上限。
    static func park(
        _ db: Database, type: CloudRecordType, id: String, payload: Data, updatedAt: Date,
        now: Date
    ) throws {
        let name = CloudRecord.recordName(type, id)
        let existing = try PendingCloudPayloadRecord.fetchOne(db, key: name)
        try PendingCloudPayloadRecord(
            recordName: name,
            recordType: type.rawValue,
            recordId: id,
            payload: payload,
            updatedAt: updatedAt,
            firstSeenAt: existing?.firstSeenAt ?? now,
            attempts: existing?.attempts ?? 0
        ).save(db)
    }

    /// 取出待重试的，按合并顺序排好 —— 一轮里父记录要先于子记录。
    static func parkedPayloads(_ db: Database) throws -> [PendingCloudPayloadRecord] {
        try PendingCloudPayloadRecord.fetchAll(db)
            .filter { CloudRecordType(rawValue: $0.recordType) != nil }
            .sorted {
                let lhs = CloudRecordType(rawValue: $0.recordType)!.mergeOrder
                let rhs = CloudRecordType(rawValue: $1.recordType)!.mergeOrder
                return lhs == rhs ? $0.recordName < $1.recordName : lhs < rhs
            }
    }

    /// 超龄 / 超次数的丢掉，返回被丢掉的记录名供调用方记日志。
    @discardableResult
    static func prunePendingPayloads(_ db: Database, now: Date) throws -> [String] {
        let cutoff = now.addingTimeInterval(-pendingPayloadMaxAge)
        let doomed = try PendingCloudPayloadRecord
            .filter(
                Column("attempts") > pendingPayloadMaxAttempts || Column("first_seen_at") < cutoff)
            .fetchAll(db)
            .map(\.recordName)
        guard !doomed.isEmpty else { return [] }
        _ = try PendingCloudPayloadRecord.deleteAll(db, keys: doomed)
        return doomed
    }

    /// 测试与排查用。
    public func pendingCloudPayloadCount() async throws -> Int {
        try await database.writer.read { db in
            try PendingCloudPayloadRecord.fetchCount(db)
        }
    }

    public func pendingCloudPayloadNames() async throws -> [String] {
        try await database.writer.read { db in
            try PendingCloudPayloadRecord.fetchAll(db).map(\.recordName).sorted()
        }
    }
}
