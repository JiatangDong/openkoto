import Foundation
import GRDB
import OKModels

// `Tombstone` / `TombstoneTable` 的值类型定义在 OKModels（传输格式也要用）。
// 这里只放 GRDB 行映射。

// MARK: - deleted_record

struct TombstoneRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "deleted_record"

    var tableName: String
    var recordId: String
    var deletedAt: Date

    enum CodingKeys: String, CodingKey {
        case tableName = "table_name"
        case recordId = "record_id"
        case deletedAt = "deleted_at"
    }

    init(table: TombstoneTable, recordID: String, deletedAt: Date) {
        self.tableName = table.rawValue
        self.recordId = recordID
        self.deletedAt = deletedAt
    }

    var tombstone: Tombstone? {
        guard let table = TombstoneTable(rawValue: tableName) else { return nil }
        return Tombstone(table: table, recordID: recordId, deletedAt: deletedAt)
    }
}

extension TombstoneRecord {
    /// 记一笔墓碑。**必须与删除同事务**，否则崩溃在两者之间会留下
    /// "行没了但没有墓碑"的状态——那条记录会在下次导入时悄悄复活。
    ///
    /// 用 `save` 而非 `insert`：重复删除同一 id（例如导入后又删）应当幂等，
    /// 且刷新 `deleted_at` 让剪枝从最后一次删除算起。
    static func mark(
        _ db: Database, table: TombstoneTable, recordID: String, at date: Date
    ) throws {
        try TombstoneRecord(table: table, recordID: recordID, deletedAt: date).save(db)
    }

    static func mark(
        _ db: Database, table: TombstoneTable, id: UUID, at date: Date
    ) throws {
        try mark(db, table: table, recordID: id.uuidString.lowercased(), at: date)
    }
}
