import Foundation
import GRDB

/// 一条云端记录"上次同步成功时的样子"。
///
/// 见 migration v9 的注释：`systemFields` 是 CloudKit 保存能成功的**必要条件**，
/// `payloadHash` 则用来掐掉"拉下来又原样推回去"的回声。
public struct CloudRecordMeta: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "cloud_record_meta"

    public var recordName: String
    public var systemFields: Data?
    public var payloadHash: String?
    public var syncedAt: Date

    public enum CodingKeys: String, CodingKey {
        case recordName = "record_name"
        case systemFields = "system_fields"
        case payloadHash = "payload_hash"
        case syncedAt = "synced_at"
    }

    public init(recordName: String, systemFields: Data?, payloadHash: String?, syncedAt: Date) {
        self.recordName = recordName
        self.systemFields = systemFields
        self.payloadHash = payloadHash
        self.syncedAt = syncedAt
    }
}

extension ContentRepository {
    /// 全量读进内存：几千行、每行几百字节，比按 id 逐条查快得多，
    /// 而且推送前本来就要跟每一条候选比对。
    public func cloudRecordMeta() async throws -> [String: CloudRecordMeta] {
        try await database.writer.read { db in
            let rows = try CloudRecordMeta.fetchAll(db)
            return Dictionary(rows.map { ($0.recordName, $0) }, uniquingKeysWith: { _, last in last })
        }
    }

    /// `save` 覆盖同一主键，重复写入天然幂等。
    public func saveCloudRecordMeta(_ rows: [CloudRecordMeta]) async throws {
        guard !rows.isEmpty else { return }
        try await database.writer.write { db in
            for row in rows { try row.save(db) }
        }
    }

    /// 记录在云上没了（我们删的，或别的设备删的）——本地这份 change tag 也就失效了。
    /// 留着的话，万一同一个 id 被重新创建，会带着一个早就不存在的 tag 去保存。
    public func deleteCloudRecordMeta(recordNames: [String]) async throws {
        guard !recordNames.isEmpty else { return }
        try await database.writer.write { db in
            _ = try CloudRecordMeta.deleteAll(db, keys: recordNames)
        }
    }

    /// 关闭同步 / 换账号时清空：换了 iCloud 账号之后，
    /// 旧账号的 change tag 拿到新账号里一条都对不上。
    public func clearCloudRecordMeta() async throws {
        try await database.writer.write { db in
            _ = try CloudRecordMeta.deleteAll(db)
        }
    }
}
