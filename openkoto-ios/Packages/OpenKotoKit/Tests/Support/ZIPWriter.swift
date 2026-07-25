import Compression
import CoreFoundation
import Foundation

/// 测试专用的最小 ZIP 写入器。
///
/// 存在的意义是让 fixture 在**测试期合成**——git 里不放二进制压缩包，
/// 对抗用例（路径穿越、符号链接、zip bomb、Zip64、CP437 名）也才能精确构造。
/// 支持刻意写坏的字段（`crcOverride` / `uncompressedSizeOverride`），生产代码不需要这些。
public struct ZIPWriter {
    public struct File {
        public var path: String
        public var contents: Data
        public var compressed: Bool = true
        /// Unix 制作者的外部属性；符号链接用 0xA1FF0000。
        public var externalAttributes: UInt32 = 0
        /// 写入错误 CRC，用于校验失败路径。
        public var crcOverride: UInt32?
        /// 谎报解压后大小，用于 zip bomb 闸门。
        public var uncompressedSizeOverride: Int?
        /// 通用标志位 0（ZIP 口令加密）。
        public var encrypted: Bool = false

        public init(
            path: String, contents: Data, compressed: Bool = true,
            externalAttributes: UInt32 = 0, crcOverride: UInt32? = nil,
            uncompressedSizeOverride: Int? = nil, encrypted: Bool = false
        ) {
            self.path = path
            self.contents = contents
            self.compressed = compressed
            self.externalAttributes = externalAttributes
            self.crcOverride = crcOverride
            self.uncompressedSizeOverride = uncompressedSizeOverride
            self.encrypted = encrypted
        }
    }

    public init() {}

    public var files: [File] = []
    /// 归档注释：非空时 EOCD 不在文件末尾，用于验证向前扫描。
    public var comment: Data = Data()
    /// 用 Zip64 哨兵 + 0x0001 扩展字段写中央目录。
    public var forceZip64 = false
    /// 关闭通用标志位 11，文件名按 CP437 编码。
    public var utf8Names = true

    public mutating func addFile(_ path: String, _ contents: String, compressed: Bool = true) {
        files.append(File(path: path, contents: Data(contents.utf8), compressed: compressed))
    }

    public mutating func addDirectory(_ path: String) {
        let normalized = path.hasSuffix("/") ? path : path + "/"
        files.append(File(path: normalized, contents: Data(), compressed: false))
    }

    public func build() -> Data {
        var output = Data()
        var central = Data()
        var count = 0

        for file in files {
            let localOffset = output.count
            let payload = file.compressed && !file.contents.isEmpty
                ? Self.deflate(file.contents) : file.contents
            let method: UInt16 = (file.compressed && !file.contents.isEmpty) ? 8 : 0
            let crc = file.crcOverride ?? Self.crc32(file.contents)
            let declaredUncompressed = file.uncompressedSizeOverride ?? file.contents.count
            let nameData = encodeName(file.path)
            var flags: UInt16 = utf8Names ? 0x0800 : 0
            if file.encrypted { flags |= 0x0001 }

            // 本地文件头
            output.appendLE(UInt32(0x0403_4B50))
            output.appendLE(UInt16(20))
            output.appendLE(flags)
            output.appendLE(method)
            output.appendLE(UInt16(0))  // time
            output.appendLE(UInt16(0))  // date
            output.appendLE(crc)
            output.appendLE(UInt32(payload.count))
            output.appendLE(UInt32(truncatingIfNeeded: declaredUncompressed))
            output.appendLE(UInt16(nameData.count))
            output.appendLE(UInt16(0))  // extra length
            output.append(nameData)
            output.append(payload)

            // 中央目录记录
            central.appendLE(UInt32(0x0201_4B50))
            central.appendLE(UInt16(0x0314))  // 制作者：Unix + version 20
            central.appendLE(UInt16(20))
            central.appendLE(flags)
            central.appendLE(method)
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(crc)

            var extra = Data()
            if forceZip64 {
                central.appendLE(UInt32(0xFFFF_FFFF))  // compressed
                central.appendLE(UInt32(0xFFFF_FFFF))  // uncompressed
                extra.appendLE(UInt16(0x0001))
                extra.appendLE(UInt16(24))
                // 顺序按 ZIP 规范：uncompressed, compressed, localHeaderOffset
                extra.appendLE(UInt64(declaredUncompressed))
                extra.appendLE(UInt64(payload.count))
                extra.appendLE(UInt64(localOffset))
            } else {
                central.appendLE(UInt32(payload.count))
                central.appendLE(UInt32(truncatingIfNeeded: declaredUncompressed))
            }

            central.appendLE(UInt16(nameData.count))
            central.appendLE(UInt16(extra.count))
            central.appendLE(UInt16(0))  // comment length
            central.appendLE(UInt16(0))  // disk start
            central.appendLE(UInt16(0))  // internal attributes
            central.appendLE(file.externalAttributes)
            central.appendLE(forceZip64 ? UInt32(0xFFFF_FFFF) : UInt32(localOffset))
            central.append(nameData)
            central.append(extra)
            count += 1
        }

        let centralOffset = output.count
        output.append(central)

        if forceZip64 {
            let zip64Offset = output.count
            output.appendLE(UInt32(0x0606_4B50))
            output.appendLE(UInt64(44))  // 本记录剩余大小
            output.appendLE(UInt16(45))
            output.appendLE(UInt16(45))
            output.appendLE(UInt32(0))
            output.appendLE(UInt32(0))
            output.appendLE(UInt64(count))
            output.appendLE(UInt64(count))
            output.appendLE(UInt64(central.count))
            output.appendLE(UInt64(centralOffset))
            // Zip64 EOCD 定位器：必须紧邻 EOCD 之前 20 字节
            output.appendLE(UInt32(0x0706_4B50))
            output.appendLE(UInt32(0))
            output.appendLE(UInt64(zip64Offset))
            output.appendLE(UInt32(1))
        }

        output.appendLE(UInt32(0x0605_4B50))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(forceZip64 ? UInt16(0xFFFF) : UInt16(count))
        output.appendLE(forceZip64 ? UInt16(0xFFFF) : UInt16(count))
        output.appendLE(UInt32(central.count))
        output.appendLE(forceZip64 ? UInt32(0xFFFF_FFFF) : UInt32(centralOffset))
        output.appendLE(UInt16(comment.count))
        output.append(comment)
        return output
    }

    private func encodeName(_ name: String) -> Data {
        if utf8Names { return Data(name.utf8) }
        let cp437 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
        return name.data(using: cp437) ?? Data(name.utf8)
    }

    // MARK: - 压缩与校验（与被测实现独立实现，避免自证）

    public static func deflate(_ data: Data) -> Data {
        let capacity = data.count + 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(
                destination, capacity, base, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return data }
        return Data(bytes: destination, count: written)
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    fileprivate mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8 & 0xFF))
    }

    fileprivate mutating func appendLE(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            append(UInt8(value >> UInt32(shift) & 0xFF))
        }
    }

    fileprivate mutating func appendLE(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            append(UInt8(value >> UInt64(shift) & 0xFF))
        }
    }
}
