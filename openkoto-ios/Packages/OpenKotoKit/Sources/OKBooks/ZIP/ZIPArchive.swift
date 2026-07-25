import CoreFoundation
import Foundation

/// 只读 ZIP 归档（EPUB 容器用）。
///
/// 自研而非引第三方：EPUB 只用到 stored(0) 与 deflate(8) 两种方法，
/// 而"能被信任地读一个用户从网上下载的压缩包"这件事的要害不是覆盖度，是**防御**——
/// 路径穿越、符号链接、zip bomb、截断，全部按具名错误大声失败，绝不静默降级。
///
/// 尺寸与偏移一律取自**中央目录**：本地文件头在带 data descriptor（通用标志位 3）时
/// 三个字段都是 0，照读会得到空文件。
public struct ZIPArchive: Sendable {
    // MARK: - 配置与类型

    public struct Limits: Sendable {
        /// 条目数上限（EPUB 通常几百个）。
        public var maxEntries = 20_000
        /// 单条目解压后上限。
        public var maxEntryUncompressed = 64 << 20
        /// 整包解压后上限。
        public var maxTotalUncompressed = 512 << 20
        /// 压缩比上限（zip bomb 闸门）。只对大条目生效——
        /// 小的重复性 XHTML 轻松突破 200:1，对它们查压缩比全是误报。
        public var maxCompressionRatio = 200.0
        /// 低于此大小的条目不查压缩比。
        public var ratioCheckThreshold = 1 << 20

        public init() {}
        public static let `default` = Limits()
    }

    public struct Entry: Sendable, Equatable {
        /// 已规范化并通过安全校验的相对路径（分隔符统一为 `/`）。
        public let path: String
        public let uncompressedSize: Int
        public let compressedSize: Int
        public let crc32: UInt32
        public let isDirectory: Bool
        let method: UInt16
        let localHeaderOffset: Int
    }

    public enum Failure: Error, Equatable {
        case notAZipFile
        case truncated
        case unsupportedMethod(UInt16)
        case checksumMismatch(String)
        case unsafePath(String)
        case symlinkEntry(String)
        case encryptedEntry(String)
        case tooManyEntries
        case entryTooLarge(String)
        case archiveTooLarge
        case suspiciousRatio(String)
        case entryNotFound(String)
    }

    private let data: Data
    private let limits: Limits
    public let entries: [Entry]
    private let indexByPath: [String: Int]

    // MARK: - 构造

    public init(url: URL, limits: Limits = .default) throws {
        try self.init(data: try Data(contentsOf: url, options: .mappedIfSafe), limits: limits)
    }

    public init(data: Data, limits: Limits = .default) throws {
        self.data = data
        self.limits = limits

        let directory = try Self.locateCentralDirectory(in: data)
        guard directory.entryCount <= limits.maxEntries else { throw Failure.tooManyEntries }

        var parsed: [Entry] = []
        parsed.reserveCapacity(min(directory.entryCount, 4096))
        var index: [String: Int] = [:]
        var totalUncompressed = 0
        var cursor = directory.offset

        for _ in 0..<directory.entryCount {
            let (entry, next) = try Self.parseCentralDirectoryEntry(
                data, at: cursor, limits: limits)
            cursor = next
            guard entry.uncompressedSize <= limits.maxEntryUncompressed else {
                throw Failure.entryTooLarge(entry.path)
            }
            totalUncompressed += entry.uncompressedSize
            guard totalUncompressed <= limits.maxTotalUncompressed else {
                throw Failure.archiveTooLarge
            }
            if entry.uncompressedSize >= limits.ratioCheckThreshold {
                let ratio = Double(entry.uncompressedSize) / Double(max(entry.compressedSize, 1))
                guard ratio <= limits.maxCompressionRatio else {
                    throw Failure.suspiciousRatio(entry.path)
                }
            }
            index[entry.path] = parsed.count
            parsed.append(entry)
        }

        self.entries = parsed
        self.indexByPath = index
    }

    // MARK: - 查询与解压

    public func entry(at path: String) -> Entry? {
        indexByPath[Self.normalize(path)].map { entries[$0] }
    }

    public func data(for entry: Entry) throws -> Data {
        guard !entry.isDirectory else { return Data() }
        let payload = try locatePayload(of: entry)

        let output: Data
        switch entry.method {
        case 0:
            output = payload
        case 8:
            output = try RawDeflate.inflate(
                payload,
                expectedSize: entry.uncompressedSize,
                limit: min(limits.maxEntryUncompressed, entry.uncompressedSize + 4096))
        default:
            throw Failure.unsupportedMethod(entry.method)
        }

        guard CRC32.checksum(output) == entry.crc32 else {
            throw Failure.checksumMismatch(entry.path)
        }
        return output
    }

    public func data(at path: String) throws -> Data {
        guard let entry = entry(at: path) else { throw Failure.entryNotFound(path) }
        return try data(for: entry)
    }

    /// 全量落盘。逐条写出，不在内存里驻留整棵树。
    /// 目标路径二次校验：即使 `Entry.path` 已过安全检查，落盘前仍确认没跑出 `directory`。
    public func extractAll(to directory: URL) throws {
        let manager = FileManager.default
        let root = directory.standardizedFileURL
        try manager.createDirectory(at: root, withIntermediateDirectories: true)

        for entry in entries {
            let destination = root.appendingPathComponent(entry.path).standardizedFileURL
            guard destination.path.hasPrefix(root.path + "/") || destination.path == root.path
            else { throw Failure.unsafePath(entry.path) }

            if entry.isDirectory {
                try manager.createDirectory(at: destination, withIntermediateDirectories: true)
                continue
            }
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data(for: entry).write(to: destination, options: .atomic)
        }
    }

    /// 从本地文件头算出数据起始位置——头部的名称/扩展区长度可能与中央目录不同。
    private func locatePayload(of entry: Entry) throws -> Data {
        let reader = ByteReader(data)
        guard let signature = reader.uint32(at: entry.localHeaderOffset), signature == 0x0403_4B50
        else { throw Failure.truncated }
        guard let nameLength = reader.uint16(at: entry.localHeaderOffset + 26),
            let extraLength = reader.uint16(at: entry.localHeaderOffset + 28)
        else { throw Failure.truncated }

        let start = entry.localHeaderOffset + 30 + Int(nameLength) + Int(extraLength)
        let end = start + entry.compressedSize
        guard start >= 0, end <= data.count, start <= end else { throw Failure.truncated }
        return data.subdata(in: start..<end)
    }

    // MARK: - 中央目录定位

    private struct CentralDirectory {
        let offset: Int
        let entryCount: Int
    }

    /// EOCD 从尾部向前扫：ZIP 允许最长 65535 字节的归档注释跟在 EOCD 后面，
    /// 直接假设 EOCD 在文件末尾会漏掉带注释的包。
    private static func locateCentralDirectory(in data: Data) throws -> CentralDirectory {
        let reader = ByteReader(data)
        let minimumEOCD = 22
        guard data.count >= minimumEOCD else { throw Failure.notAZipFile }

        let searchWindow = min(data.count, minimumEOCD + 0xFFFF)
        var eocd: Int?
        var position = data.count - minimumEOCD
        let lowerBound = data.count - searchWindow
        while position >= lowerBound {
            if reader.uint32(at: position) == 0x0605_4B50 {
                eocd = position
                break
            }
            position -= 1
        }
        guard let eocd else { throw Failure.notAZipFile }

        guard var entryCount = reader.uint16(at: eocd + 10).map(Int.init),
            var offset = reader.uint32(at: eocd + 16).map(Int.init)
        else { throw Failure.truncated }

        // Zip64：定位器紧挨在 EOCD 前 20 字节。
        if entryCount == 0xFFFF || offset == 0xFFFF_FFFF {
            let locator = eocd - 20
            guard locator >= 0, reader.uint32(at: locator) == 0x0706_4B50,
                let zip64Offset = reader.uint64(at: locator + 8).map(Int.init),
                zip64Offset >= 0, zip64Offset + 56 <= data.count,
                reader.uint32(at: zip64Offset) == 0x0606_4B50,
                let zip64Count = reader.uint64(at: zip64Offset + 32).map(Int.init),
                let zip64CDOffset = reader.uint64(at: zip64Offset + 48).map(Int.init)
            else { throw Failure.truncated }
            entryCount = zip64Count
            offset = zip64CDOffset
        }

        guard offset >= 0, offset < data.count, entryCount >= 0 else { throw Failure.truncated }
        return CentralDirectory(offset: offset, entryCount: entryCount)
    }

    /// 解析一条中央目录记录，返回条目与下一条的偏移。
    private static func parseCentralDirectoryEntry(
        _ data: Data, at offset: Int, limits: Limits
    ) throws -> (Entry, Int) {
        let reader = ByteReader(data)
        guard reader.uint32(at: offset) == 0x0201_4B50 else { throw Failure.truncated }
        guard let versionMadeBy = reader.uint16(at: offset + 4),
            let flags = reader.uint16(at: offset + 8),
            let method = reader.uint16(at: offset + 10),
            let crc = reader.uint32(at: offset + 16),
            let rawCompressed = reader.uint32(at: offset + 20),
            let rawUncompressed = reader.uint32(at: offset + 24),
            let nameLength = reader.uint16(at: offset + 28).map(Int.init),
            let extraLength = reader.uint16(at: offset + 30).map(Int.init),
            let commentLength = reader.uint16(at: offset + 32).map(Int.init),
            let externalAttributes = reader.uint32(at: offset + 38),
            let rawLocalOffset = reader.uint32(at: offset + 42)
        else { throw Failure.truncated }

        let nameStart = offset + 46
        guard let nameData = reader.slice(at: nameStart, count: nameLength)
        else { throw Failure.truncated }
        // 通用标志位 11 = 名称是 UTF-8；否则按 ZIP 规范是 CP437。
        let isUTF8 = (flags & 0x0800) != 0
        let rawName = decodeEntryName(nameData, isUTF8: isUTF8)

        // 通用标志位 0 = 条目加密（ZIP 自带口令，非 EPUB DRM）。
        guard (flags & 0x0001) == 0 else { throw Failure.encryptedEntry(rawName) }

        var compressedSize = Int(rawCompressed)
        var uncompressedSize = Int(rawUncompressed)
        var localOffset = Int(rawLocalOffset)

        // Zip64 扩展字段 0x0001：只为值等于哨兵的字段依次补 8 字节。
        if rawUncompressed == 0xFFFF_FFFF || rawCompressed == 0xFFFF_FFFF
            || rawLocalOffset == 0xFFFF_FFFF
        {
            let extraStart = nameStart + nameLength
            var cursor = extraStart
            let extraEnd = extraStart + extraLength
            while cursor + 4 <= extraEnd {
                guard let fieldID = reader.uint16(at: cursor),
                    let fieldSize = reader.uint16(at: cursor + 2).map(Int.init)
                else { throw Failure.truncated }
                if fieldID == 0x0001 {
                    var field = cursor + 4
                    if rawUncompressed == 0xFFFF_FFFF {
                        guard let value = reader.uint64(at: field) else { throw Failure.truncated }
                        uncompressedSize = Int(value)
                        field += 8
                    }
                    if rawCompressed == 0xFFFF_FFFF {
                        guard let value = reader.uint64(at: field) else { throw Failure.truncated }
                        compressedSize = Int(value)
                        field += 8
                    }
                    if rawLocalOffset == 0xFFFF_FFFF {
                        guard let value = reader.uint64(at: field) else { throw Failure.truncated }
                        localOffset = Int(value)
                    }
                    break
                }
                cursor += 4 + fieldSize
            }
        }

        // 符号链接：Unix 制作者(3)的外部属性高 16 位是 st_mode。
        // 解压符号链接可以把写入引出目标目录，直接拒绝整包。
        if (versionMadeBy >> 8) == 3 {
            let mode = (externalAttributes >> 16) & 0xF000
            if mode == 0xA000 { throw Failure.symlinkEntry(rawName) }
        }

        let isDirectory = rawName.hasSuffix("/")
        let path = try safePath(rawName)

        guard compressedSize >= 0, uncompressedSize >= 0, localOffset >= 0,
            localOffset < data.count
        else { throw Failure.truncated }

        let entry = Entry(
            path: path,
            uncompressedSize: uncompressedSize,
            compressedSize: compressedSize,
            crc32: crc,
            isDirectory: isDirectory,
            method: method,
            localHeaderOffset: localOffset)
        return (entry, nameStart + nameLength + extraLength + commentLength)
    }

    // MARK: - 名称与路径

    private static func decodeEntryName(_ data: Data, isUTF8: Bool) -> String {
        if isUTF8, let text = String(data: data, encoding: .utf8) { return text }
        let cp437 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
        if let text = String(data: data, encoding: cp437) { return text }
        return EncodingDetector.decode(data).text
    }

    static func normalize(_ path: String) -> String {
        // Windows 工具偶尔写反斜杠；统一后再做安全判断，避免绕过。
        var normalized = path.replacingOccurrences(of: "\\", with: "/")
        while normalized.hasPrefix("./") { normalized.removeFirst(2) }
        return normalized
    }

    /// 路径穿越防御：绝对路径、`..` 分量、盘符、NUL 一律拒绝。
    static func safePath(_ rawName: String) throws -> String {
        let normalized = normalize(rawName)
        guard !normalized.isEmpty else { throw Failure.unsafePath(rawName) }
        guard !normalized.contains("\0") else { throw Failure.unsafePath(rawName) }
        guard !normalized.hasPrefix("/") else { throw Failure.unsafePath(rawName) }
        // "C:/..." 之类的盘符前缀
        if normalized.count >= 2 {
            let characters = Array(normalized)
            if characters[1] == ":" , characters[0].isLetter {
                throw Failure.unsafePath(rawName)
            }
        }
        for component in normalized.split(separator: "/", omittingEmptySubsequences: true)
        where component == ".." {
            throw Failure.unsafePath(rawName)
        }
        return normalized
    }
}

/// 越界安全的小端读取器：所有访问返回 Optional，由调用方翻译成 `.truncated`。
private struct ByteReader {
    private let data: Data

    init(_ data: Data) { self.data = data }

    func slice(at offset: Int, count: Int) -> Data? {
        guard offset >= 0, count >= 0, offset + count <= data.count else { return nil }
        return data.subdata(in: offset..<(offset + count))
    }

    func uint16(at offset: Int) -> UInt16? {
        guard let bytes = slice(at: offset, count: 2) else { return nil }
        return UInt16(bytes[bytes.startIndex]) | UInt16(bytes[bytes.startIndex + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32? {
        guard let bytes = slice(at: offset, count: 4) else { return nil }
        var value: UInt32 = 0
        for index in (0..<4).reversed() {
            value = value << 8 | UInt32(bytes[bytes.startIndex + index])
        }
        return value
    }

    func uint64(at offset: Int) -> UInt64? {
        guard let bytes = slice(at: offset, count: 8) else { return nil }
        var value: UInt64 = 0
        for index in (0..<8).reversed() {
            value = value << 8 | UInt64(bytes[bytes.startIndex + index])
        }
        return value
    }
}
