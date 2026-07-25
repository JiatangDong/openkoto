import Foundation

/// 书籍文件目录管理。
///
/// 放 Application Support 而不是 Caches——解压出来的资源是**原版模式**的必需品，
/// iOS 随时可以清空 Caches。整个 `Books/` 排除 iCloud 备份：几十 MB 的书不该撑大每次备份，
/// 丢了也只是降级（正文另存在 sqlite 的 `article.content` 里，重新导入即可恢复原版模式）。
///
/// 导入是原子的：先解到 `.staging/<uuid>`，校验通过再整体 move 到位，
/// 中途崩溃只会留下 staging 垃圾，不会留下半本书。
public struct BookStorage: Sendable {
    public let root: URL

    private static let stagingDirectoryName = ".staging"

    public init(root: URL) {
        self.root = root
    }

    /// 主 App 用的位置：`Application Support/OpenKoto/Books`（与 sqlite 同级）。
    public static func applicationSupport() throws -> BookStorage {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return BookStorage(
            root: support
                .appendingPathComponent("OpenKoto", isDirectory: true)
                .appendingPathComponent("Books", isDirectory: true))
    }

    /// 建根目录并设置排除备份。App 启动时调用一次即可。
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

    public func stagingDirectory(for id: UUID) throws -> URL {
        let url = root
            .appendingPathComponent(Self.stagingDirectoryName, isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 原子落位：staging → Books/<uuid>。
    @discardableResult
    public func commit(staging: URL, to id: UUID) throws -> URL {
        let destination = directory(for: id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: staging, to: destination)
        return destination
    }

    public func discardStaging(for id: UUID) {
        let url = root
            .appendingPathComponent(Self.stagingDirectoryName, isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try? FileManager.default.removeItem(at: url)
    }

    public func remove(id: UUID) throws {
        try? FileManager.default.removeItem(at: directory(for: id))
    }

    /// 清理孤儿目录：库里没有的书，以及所有 staging 残留。
    /// 崩溃/中途取消都会留下垃圾，启动时低优先级扫一遍。
    public func sweepOrphans(knownIDs: Set<UUID>) throws {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
        else { return }

        let known = Set(knownIDs.map { $0.uuidString.lowercased() })
        for entry in entries {
            let name = entry.lastPathComponent
            if name == Self.stagingDirectoryName {
                try? manager.removeItem(at: entry)
                continue
            }
            guard !known.contains(name.lowercased()) else { continue }
            try? manager.removeItem(at: entry)
        }
    }
}
