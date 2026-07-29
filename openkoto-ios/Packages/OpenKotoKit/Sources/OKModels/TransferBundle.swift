import Foundation

/// 跨设备搬家用的传输包（`.okdata.json`）。
///
/// **与 `openkoto-word-pack-v1`（`.okpack.json`）并存，互不替代：**
/// 那个是分享格式——不带 id、不带任何 FSRS 状态，按词面去重，
/// 适合「把词单发给朋友」；一旦用它搬自己的数据，复习进度会全部归零。
/// 这个才是搬家格式：带稳定 id、带完整 FSRS 状态，因此可以反复导入而不产生重复。
///
/// 主要用途是把 Tauri 桌面版（另一个 App，进不了同一个 CloudKit 容器）
/// 加工好的素材与词库送进 Apple 生态；Apple 三平台之间由 CloudKit 自动同步。
/// 同时它也是「用户带走自己的数据」的出口。
public struct TransferBundle: Codable, Sendable {
    /// 格式标识。与 schemaVersion 分开：换格式和升版本是两件事，
    /// 把别的 JSON 误当成传输包时能给出准确的错误。
    public static let formatID = "openkoto-transfer"
    /// 当前信封版本。**加了新的顶层字段就要 +1。**
    public static let currentSchemaVersion = 1
    /// 单一扩展名，不用 `.okdata.json`：系统只看最后一段路径扩展名，
    /// 双扩展名注册成 UTI 匹配不上，文件选择器里会是灰的、根本选不中
    /// （同 `.srt` 那条既有的坑）。内容仍然是 JSON，UTI 也声明为 conforms to public.json。
    public static let fileExtension = "okdata"
    /// 我们自己定义的格式，所以是 Exported 而非 Imported 类型。
    public static let contentTypeIdentifier = "com.openkoto.transfer"

    public var format: String
    public var schemaVersion: Int
    public var exportedAt: Date
    /// "openkoto-ios" / "textlingo-desktop"，只用于排查问题，不参与任何判定。
    public var sourceApp: String?

    // 以下全部可选：导出方按需裁剪，导入方按需消费。
    public var vocabulary: [FavoriteVocabulary]
    public var packs: [WordPack]
    public var articles: [Article]
    public var segments: [ArticleSegment]
    /// 只增不删，天然无冲突。复习进度的真相在这里，不在卡片快照上。
    public var reviewEvents: [ReviewEvent]
    /// 来源端删过的记录，让「删除」也能跨设备传递，而不是每次导入都复活。
    public var tombstones: [Tombstone]

    public init(
        format: String = TransferBundle.formatID,
        schemaVersion: Int = TransferBundle.currentSchemaVersion,
        exportedAt: Date,
        sourceApp: String? = nil,
        vocabulary: [FavoriteVocabulary] = [],
        packs: [WordPack] = [],
        articles: [Article] = [],
        segments: [ArticleSegment] = [],
        reviewEvents: [ReviewEvent] = [],
        tombstones: [Tombstone] = []
    ) {
        self.format = format
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.sourceApp = sourceApp
        self.vocabulary = vocabulary
        self.packs = packs
        self.articles = articles
        self.segments = segments
        self.reviewEvents = reviewEvents
        self.tombstones = tombstones
    }
}

// MARK: - 编解码

extension TransferBundle {
    public enum DecodeError: Error, Equatable, Sendable {
        case notATransferBundle
        /// 文件版本高于本端。**调用方必须保留文件，不要删** ——
        /// 用户升级 App 之后还要能导进来。同 `ShareInbox.drain` 的既定约定。
        case unsupportedVersion(found: Int, supported: Int)
        case malformed(String)
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // 排序键让同样的数据产出同样的字节，diff 和「导出两次是否一致」才有意义。
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        // **不能直接用 `.iso8601`。** 它不接受小数秒，而 Rust 那边
        // `chrono::to_rfc3339()` 默认就带（"…T12:00:00.123456789+00:00"），
        // 一个时间戳就能让整包解码失败，错误还是「日期格式不对」这种没法定位的噪音。
        // 桌面端已改成输出无小数秒的形式，这里再宽容一层：两种都收。
        //
        // 两个 formatter 建成局部变量由闭包捕获，而不是 static：
        // `ISO8601DateFormatter` 不是 Sendable，做成静态属性过不了 Swift 6 的并发检查；
        // 而每条日期新建一个又太浪费（一个包可能有上万条时间戳）。
        // 每个 decoder 各持一份，正好。
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: text) { return date }
            if let date = plain.date(from: text) { return date }
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "无法解析的时间戳：\(text)"))
        }
        return decoder
    }

    public func encoded() throws -> Data {
        try Self.encoder().encode(self)
    }

    /// 只探测信封头的两个字段——**必须先于完整解码**。
    ///
    /// 直接 `decode(TransferBundle.self)` 的话，未来版本新增的字段会让整包解码失败，
    /// 错误信息是「缺字段」之类的噪音，用户完全看不出真正的原因是「App 太旧」。
    private struct Probe: Decodable {
        var format: String?
        var schemaVersion: Int?
    }

    public static func decode(from data: Data) throws -> TransferBundle {
        let decoder = decoder()
        guard let probe = try? decoder.decode(Probe.self, from: data) else {
            throw DecodeError.notATransferBundle
        }
        guard probe.format == formatID else {
            throw DecodeError.notATransferBundle
        }
        let version = probe.schemaVersion ?? 0
        guard version <= currentSchemaVersion else {
            throw DecodeError.unsupportedVersion(
                found: version, supported: currentSchemaVersion)
        }
        do {
            return try decoder.decode(TransferBundle.self, from: data)
        } catch {
            throw DecodeError.malformed("\(error)")
        }
    }

    /// 导出文件名。带日期便于用户在文件 App 里分辨多次导出。
    public static func fileName(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let stamp = String(
            format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return "OpenKoto-\(stamp).\(fileExtension)"
    }
}
