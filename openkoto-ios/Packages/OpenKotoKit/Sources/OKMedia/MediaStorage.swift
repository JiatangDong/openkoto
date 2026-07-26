import Foundation

/// 视频/音频的文件目录管理。结构与 `BookStorage` 一致，理由也一致：
/// 放 Application Support 而不是 Caches（iOS 随时可清空 Caches），整个 `Media/`
/// 排除 iCloud 备份——几十上百 MB 的视频更不该撑大每次备份，丢了也只是降级
/// （文稿与精讲都在 sqlite 里，只有播放不可用）。
///
/// 与书籍不同的是：**默认不拷贝媒体文件**。用户从「文件」选的视频走
/// security-scoped bookmark 引用，拷了就是双倍占盘。目录仍然要建——
/// 端上转写抽出的音轨、词级时间戳都落在这里。
public struct MediaStorage: Sendable {
    public let root: URL

    private static let stagingDirectoryName = ".staging"
    /// 端上转写抽出的音轨文件名（转写失败可重试，不必重抽）。
    public static let extractedAudioName = "audio.m4a"
    /// 词级时间戳。不进库：格式还会随来源演进，且只在播放时需要。
    public static let transcriptName = "transcript.json"

    public init(root: URL) {
        self.root = root
    }

    /// 主 App 用的位置：`Application Support/OpenKoto/Media`（与 sqlite、Books 同级）。
    public static func applicationSupport() throws -> MediaStorage {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return MediaStorage(
            root: support
                .appendingPathComponent("OpenKoto", isDirectory: true)
                .appendingPathComponent("Media", isDirectory: true))
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    public func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    /// 目录名只存相对值——沙盒绝对路径每次安装都会变。
    public func directoryName(for id: UUID) -> String {
        id.uuidString.lowercased()
    }

    @discardableResult
    public func createDirectory(for id: UUID) throws -> URL {
        let url = directory(for: id)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func stagingDirectory(for id: UUID) throws -> URL {
        let url = root
            .appendingPathComponent(Self.stagingDirectoryName, isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 原子落位：staging → Media/<uuid>。
    @discardableResult
    public func commit(staging: URL, to id: UUID) throws -> URL {
        let destination = directory(for: id)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: staging, to: destination)
        return destination
    }

    public func remove(id: UUID) throws {
        try? FileManager.default.removeItem(at: directory(for: id))
    }

    /// 启动时清理孤儿目录：删库成功但删文件失败、或导入中途崩溃留下的 staging。
    public func sweepOrphans(knownIDs: Set<UUID>) {
        let manager = FileManager.default
        try? manager.removeItem(
            at: root.appendingPathComponent(Self.stagingDirectoryName, isDirectory: true))
        let known = Set(knownIDs.map { $0.uuidString.lowercased() })
        guard
            let entries = try? manager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)
        else { return }
        for entry in entries where entry.lastPathComponent != Self.stagingDirectoryName {
            if !known.contains(entry.lastPathComponent) {
                try? manager.removeItem(at: entry)
            }
        }
    }
}
