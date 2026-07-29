import Foundation

/// Share Extension 与主 App 之间的 App Group 收件箱（设计文档 §6.3）。
///
/// 扩展只向 inbox 目录**原子**写入 `ImportEnvelope` JSON（不访问主库）；
/// 主 App 启动时 `drain()` 读取并清空。坏文件跳过并删除，保证队列不卡死。
public struct ShareInbox: Sendable {
    /// App Group 标识——需在主 App 与扩展两端 entitlements 中声明一致。
    ///
    /// iOS 上就是这个裸标识；**Mac（Catalyst / 原生）要求带 Team ID 前缀**
    /// （`ABCDE12345.group.com.openkoto.ios`），容器也落在 `~/Library/Group Containers/`。
    /// 前缀不带的话 `containerURL(...)` 返回 nil → `init?` 返回 nil →
    /// `ShareViewController` 的 guard 直接 return：**分享功能静默失效、一句报错都没有**。
    public static let appGroupID = "group.com.openkoto.ios"

    /// 候选标识列表：优先用 Info.plist 注入的值（Catalyst 那份带 `$(TeamIdentifierPrefix)`），
    /// 其次退回裸标识。
    ///
    /// 走 plist 注入而不是把 Team ID 硬编码进源码：Team ID 属于签名配置，
    /// 换团队/换证书时不该改代码。列表兜底则保证注入出错时不会静默失效。
    static var candidateAppGroupIDs: [String] {
        let injected = Bundle.main.object(forInfoDictionaryKey: "OKAppGroupIdentifier") as? String
        return [injected, appGroupID]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { unique, id in
                if !unique.contains(id) { unique.append(id) }
            }
    }

    private let directory: URL

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// 用 App Group 容器初始化；所有候选标识都拿不到容器（缺 entitlement）时返回 nil。
    public init?() {
        guard let container = Self.candidateAppGroupIDs.lazy
            .compactMap({
                FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
            })
            .first
        else { return nil }
        self.directory = container.appendingPathComponent("Inbox", isDirectory: true)
    }

    /// 指定 App Group 标识初始化（测试与特殊场景用）。
    public init?(appGroupID: String) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID)
        else { return nil }
        self.directory = container.appendingPathComponent("Inbox", isDirectory: true)
    }

    /// 自定义目录初始化（测试用）。
    public init(directory: URL) {
        self.directory = directory
    }

    /// 原子写入一个信封（扩展侧）。文件名用 `envelope.id` 保证唯一、幂等。
    public func write(_ envelope: ImportEnvelope) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(envelope)
        let url = directory.appendingPathComponent("\(envelope.id.uuidString).json")
        try data.write(to: url, options: .atomic)
    }

    /// 只探测版本号的信封头——用于判断"这封信我这个版本读不读得懂"。
    private struct VersionProbe: Decodable {
        var schemaVersion: Int
    }

    /// 读取并删除全部信封（主 App 侧），按 `createdAt` 升序返回。
    ///
    /// **版本高于本端的信封留在原地**：扩展可能已经升级而主 App 还没有，
    /// 那封信里可能是一本书。旧实现在解码之前就 `defer` 删除，任何解不开的信封都被静默销毁。
    /// 真正解不开的坏文件（连版本号都读不出）仍然删掉，否则队列会永久卡死。
    @discardableResult
    public func drain() -> [ImportEnvelope] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        var envelopes: [ImportEnvelope] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file) else {
                try? fm.removeItem(at: file)
                continue
            }
            if let probe = try? Self.decoder.decode(VersionProbe.self, from: data),
                probe.schemaVersion > ImportEnvelope.currentSchemaVersion
            {
                continue  // 未来版本：留给升级后的自己
            }
            guard let envelope = try? Self.decoder.decode(ImportEnvelope.self, from: data) else {
                try? fm.removeItem(at: file)
                continue
            }
            try? fm.removeItem(at: file)
            envelopes.append(envelope)
        }
        return envelopes.sorted { $0.createdAt < $1.createdAt }
    }

    /// 分享进来的文件落脚点（扩展写、主 App 读完即删）。
    public func blobsDirectory() throws -> URL {
        let url = directory.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 把 `.file` 信封里的相对路径还原成绝对 URL。
    public func fileURL(relativePath: String) -> URL {
        directory.appendingPathComponent(relativePath)
    }

    /// 待处理信封数（不删除；供 UI 徽标，可选）。
    public var pendingCount: Int {
        (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" }.count ?? 0
    }
}
