import Foundation

/// 参与同步的、用户可删除的表。
///
/// 只列**导入会碰、或需要把删除传播到其它设备**的表。
/// `review_event` / `reading_session` 只增不删，不需要墓碑；
/// `book` / `media` 的删除由同步引擎直接传播，也不是导入目标。
public enum TombstoneTable: String, Sendable, CaseIterable, Codable {
    case favoriteVocabulary = "favorite_vocabulary"
    case wordPack = "word_pack"
    case wordPackMembership = "word_pack_membership"
    case article
}

/// 一条删除记录。本地行已经硬删除了，这是它存在过、且被用户主动删掉的唯一证据。
///
/// 放在 OKModels 而不是 OKPersistence：传输格式（`TransferBundle`）也要带它，
/// 而分层规则是 `OKFeatures → 其余模块 → OKModels`。
/// GRDB 的行映射 `TombstoneRecord` 仍留在 OKPersistence。
public struct Tombstone: Sendable, Hashable, Codable {
    public let table: TombstoneTable
    /// 主键值；词包成员这类复合主键见 `Tombstone.membershipKey`。
    public let recordID: String
    public let deletedAt: Date

    public init(table: TombstoneTable, recordID: String, deletedAt: Date) {
        self.table = table
        self.recordID = recordID
        self.deletedAt = deletedAt
    }

    /// 词包成员没有单一主键，用 `vocabularyID_packID` 拼出稳定键。
    ///
    /// 顺序固定为「生词在前、词包在后」，两端（iOS / 桌面导出）必须一致，
    /// 否则同一条关系会产生两个互不认识的墓碑。
    ///
    /// **分隔符是下划线，不是冒号。** 这个键会直接进 CloudKit 的记录名，
    /// 而冒号在那里是风险字符（实测 `serverRejectedRequest`）。
    /// UUID 里不含下划线，用它做分隔符无歧义。
    public static func membershipKey(vocabularyID: UUID, packID: UUID) -> String {
        "\(vocabularyID.uuidString.lowercased())_\(packID.uuidString.lowercased())"
    }

    /// 墓碑保留期。
    ///
    /// 到期即剪枝，代价是**离线超过这个时长的设备重新上线时，那批删除会失效**
    /// —— 它带着本地还活着的旧行回来，而这边已经没有证据说"这条删过了"。
    /// 180 天是取舍：更长则墓碑无限膨胀，更短则失效窗口过窄。
    public static let retention: TimeInterval = 180 * 24 * 60 * 60

    /// 剪枝截止时间：早于它的墓碑可以清掉。抽成纯函数以便单测边界。
    public static func pruneCutoff(
        now: Date, retention: TimeInterval = Tombstone.retention
    ) -> Date {
        now.addingTimeInterval(-retention)
    }
}
