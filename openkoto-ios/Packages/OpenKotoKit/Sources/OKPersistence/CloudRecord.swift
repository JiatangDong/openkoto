import CloudKit
import Foundation
import OKModels

/// 参与 CloudKit 同步的记录种类。
///
/// `rawValue` 就是 CloudKit 的 record type，**改名等于换一张表**，
/// 老设备推上去的记录会变成孤儿。
public enum CloudRecordType: String, Sendable, CaseIterable {
    case vocabulary = "Vocabulary"
    case wordPack = "WordPack"
    case wordPackMembership = "WordPackMembership"
    case article = "Article"
    case segment = "Segment"
    case reviewEvent = "ReviewEvent"
}

/// 领域模型 ↔ `CKRecord` 的编解码。
///
/// **整条记录按 JSON 存进一个字段，而不是逐字段映射。** 理由：
/// 逐字段映射意味着每个模型都要维护一份「属性名 → CKRecord key」的表，
/// 加一个字段忘了改就是静默丢数据；而我们从来不需要在云端按字段查询
/// （同步永远是整条读写）。JSON 一份，字段增减自动跟随 `Codable`。
///
/// 大记录（长章节正文）走 `CKAsset`：CKRecord 单条有 1MB 上限，
/// 一章 50 万字的小说正文能到 1.5MB，直接写字段会被服务端拒收。
public enum CloudRecord {
    /// 超过这个大小就改用 CKAsset。留足余量给其它字段与编码开销。
    static let inlinePayloadLimit = 700 * 1024

    static let payloadKey = "payload"
    static let payloadAssetKey = "payloadAsset"
    /// 冗余存一份，方便在 CloudKit Dashboard 里排查问题。
    static let updatedAtKey = "updatedAt"

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// 记录 ID：`类型_主键`。
    ///
    /// 带类型前缀是必需的 —— 文章与句子各有自己的 UUID 空间，不加前缀理论上可能撞。
    ///
    /// **分隔符必须是下划线。** 一开始用的是冒号，CloudKit 直接回
    /// `serverRejectedRequest`（error 15）——而且错误信息里完全看不出是记录名的问题。
    /// 词包成员的键本身还带一个分隔符，冒号方案会让记录名出现两个冒号。
    /// UUID 里不含下划线，所以 `split(maxSplits: 1)` 拆出来的类型与主键都不会歧义。
    public static func recordName(_ type: CloudRecordType, _ id: String) -> String {
        "\(type.rawValue)_\(id.lowercased())"
    }

    public static func parse(recordName: String) -> (type: CloudRecordType, id: String)? {
        let parts = recordName.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, let type = CloudRecordType(rawValue: String(parts[0])) else {
            return nil
        }
        return (type, String(parts[1]))
    }

    /// 把 payload 写进记录，按大小自动选择内联还是 asset。
    ///
    /// - Parameter temporaryDirectory: asset 落盘的临时目录。CloudKit 要求
    ///   asset 是一个真实文件；上传完成后由系统清理。
    public static func write(
        payload: Data, into record: CKRecord, updatedAt: Date, temporaryDirectory: URL
    ) throws {
        record[updatedAtKey] = updatedAt as CKRecordValue
        if payload.count <= inlinePayloadLimit {
            record[payloadKey] = payload as CKRecordValue
            record[payloadAssetKey] = nil
        } else {
            let url = temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try payload.write(to: url, options: .atomic)
            record[payloadAssetKey] = CKAsset(fileURL: url)
            record[payloadKey] = nil
        }
    }

    /// 读回 payload，内联与 asset 两种形态都认。
    public static func readPayload(from record: CKRecord) -> Data? {
        if let data = record[payloadKey] as? Data { return data }
        if let asset = record[payloadAssetKey] as? CKAsset,
            let url = asset.fileURL,
            let data = try? Data(contentsOf: url)
        {
            return data
        }
        return nil
    }
}
