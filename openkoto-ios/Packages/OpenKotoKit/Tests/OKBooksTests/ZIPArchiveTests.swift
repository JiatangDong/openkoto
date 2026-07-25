import Foundation
import OKTestSupport
import Testing

@testable import OKBooks

/// ZIP 读取器测试。归档全部由 `ZIPWriter` 在测试期合成。
@Suite struct ZIPArchiveTests {
    private func text(_ archive: ZIPArchive, _ path: String) throws -> String {
        String(decoding: try archive.data(at: path), as: UTF8.self)
    }

    // MARK: - 正常读取

    @Test func readsStoredAndDeflatedEntries() throws {
        var writer = ZIPWriter()
        let long = String(repeating: "吾輩は猫である。", count: 500)
        writer.addFile("mimetype", "application/epub+zip", compressed: false)
        writer.addFile("OEBPS/ch1.xhtml", long, compressed: true)

        let archive = try ZIPArchive(data: writer.build())
        #expect(archive.entries.count == 2)
        #expect(try text(archive, "mimetype") == "application/epub+zip")
        #expect(try text(archive, "OEBPS/ch1.xhtml") == long)
    }

    @Test func exposesEntryMetadataAndLookup() throws {
        var writer = ZIPWriter()
        writer.addFile("a.txt", "hello")
        writer.addDirectory("OEBPS")

        let archive = try ZIPArchive(data: writer.build())
        let entry = try #require(archive.entry(at: "a.txt"))
        #expect(entry.uncompressedSize == 5)
        #expect(entry.isDirectory == false)
        #expect(try #require(archive.entry(at: "OEBPS/")).isDirectory)
        #expect(archive.entry(at: "missing.txt") == nil)
        #expect(throws: ZIPArchive.Failure.entryNotFound("missing.txt")) {
            try archive.data(at: "missing.txt")
        }
    }

    @Test func handlesEmptyFileEntry() throws {
        var writer = ZIPWriter()
        writer.addFile("empty.txt", "")
        let archive = try ZIPArchive(data: writer.build())
        #expect(try archive.data(at: "empty.txt").isEmpty)
    }

    /// EOCD 可能被最长 64KB 的归档注释推离文件末尾，必须向前扫描。
    @Test func findsEOCDBehindArchiveComment() throws {
        var writer = ZIPWriter()
        writer.addFile("a.txt", "hello")
        writer.comment = Data(repeating: 0x21, count: 40_000)

        let archive = try ZIPArchive(data: writer.build())
        #expect(try text(archive, "a.txt") == "hello")
    }

    /// Zip64：尺寸/偏移写哨兵，真值放 0x0001 扩展字段。
    @Test func handlesZip64CentralDirectory() throws {
        var writer = ZIPWriter()
        writer.forceZip64 = true
        writer.addFile("OEBPS/ch1.xhtml", "第一章 内容", compressed: true)

        let archive = try ZIPArchive(data: writer.build())
        #expect(archive.entries.count == 1)
        #expect(try text(archive, "OEBPS/ch1.xhtml") == "第一章 内容")
    }

    /// 通用标志位 11 未置时文件名按 CP437 解码。
    @Test func decodesCP437EntryNames() throws {
        var writer = ZIPWriter()
        writer.utf8Names = false
        writer.addFile("café.txt", "hello")

        let archive = try ZIPArchive(data: writer.build())
        #expect(archive.entries.first?.path == "café.txt")
        #expect(try text(archive, "café.txt") == "hello")
    }

    // MARK: - 完整性

    @Test func rejectsChecksumMismatch() throws {
        var writer = ZIPWriter()
        writer.files.append(
            .init(path: "a.txt", contents: Data("hello".utf8), compressed: false,
                  crcOverride: 0xDEAD_BEEF))

        let archive = try ZIPArchive(data: writer.build())
        #expect(throws: ZIPArchive.Failure.checksumMismatch("a.txt")) {
            try archive.data(at: "a.txt")
        }
    }

    @Test func rejectsTruncatedArchive() throws {
        var writer = ZIPWriter()
        writer.addFile("a.txt", "hello")
        let complete = writer.build()

        #expect(throws: ZIPArchive.Failure.notAZipFile) {
            try ZIPArchive(data: complete.dropLast(200))
        }
    }

    @Test func rejectsNonZipData() {
        #expect(throws: ZIPArchive.Failure.notAZipFile) {
            try ZIPArchive(data: Data(repeating: 0x41, count: 512))
        }
        #expect(throws: ZIPArchive.Failure.notAZipFile) {
            try ZIPArchive(data: Data())
        }
    }

    @Test func crc32MatchesKnownVector() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data()) == 0)
    }

    // MARK: - 安全

    @Test(arguments: [
        "../../evil.txt",
        "OEBPS/../../evil.txt",
        "/etc/passwd",
        "C:/Windows/system.ini",
    ])
    func rejectsUnsafePaths(path: String) throws {
        var writer = ZIPWriter()
        writer.addFile(path, "pwned")
        #expect(throws: ZIPArchive.Failure.unsafePath(path)) {
            try ZIPArchive(data: writer.build())
        }
    }

    /// 反斜杠分隔符不能绕过 `..` 检查。
    @Test func rejectsBackslashTraversal() throws {
        var writer = ZIPWriter()
        writer.addFile("..\\..\\evil.txt", "pwned")
        #expect(throws: (any Error).self) { try ZIPArchive(data: writer.build()) }
    }

    @Test func rejectsSymlinkEntries() throws {
        var writer = ZIPWriter()
        writer.files.append(
            .init(path: "link", contents: Data("/etc/passwd".utf8), compressed: false,
                  externalAttributes: 0xA1FF_0000))
        #expect(throws: ZIPArchive.Failure.symlinkEntry("link")) {
            try ZIPArchive(data: writer.build())
        }
    }

    @Test func rejectsPasswordProtectedEntries() throws {
        var writer = ZIPWriter()
        writer.files.append(
            .init(path: "secret.txt", contents: Data("x".utf8), compressed: false,
                  encrypted: true))
        #expect(throws: ZIPArchive.Failure.encryptedEntry("secret.txt")) {
            try ZIPArchive(data: writer.build())
        }
    }

    /// zip bomb：极小的压缩体谎报巨大的解压后大小。
    /// 声明值刻意压在单条目上限之下，否则先撞 `entryTooLarge`，测不到压缩比这道闸门。
    @Test func rejectsSuspiciousCompressionRatio() throws {
        var writer = ZIPWriter()
        writer.files.append(
            .init(path: "bomb.txt", contents: Data(repeating: 0x41, count: 1024),
                  compressed: true, uncompressedSizeOverride: 32 << 20))
        #expect(throws: ZIPArchive.Failure.suspiciousRatio("bomb.txt")) {
            try ZIPArchive(data: writer.build())
        }
    }

    /// 声明值超过单条目上限时，先于压缩比被拦下。
    @Test func rejectsOversizedDeclaredEntry() throws {
        var writer = ZIPWriter()
        writer.files.append(
            .init(path: "bomb.txt", contents: Data(repeating: 0x41, count: 1024),
                  compressed: true, uncompressedSizeOverride: 500 << 20))
        #expect(throws: ZIPArchive.Failure.entryTooLarge("bomb.txt")) {
            try ZIPArchive(data: writer.build())
        }
    }

    /// 小文件即使压缩比很高也不该误报——重复内容的 XHTML 轻松超过 200:1。
    @Test func allowsHighRatioOnSmallEntries() throws {
        var writer = ZIPWriter()
        writer.addFile("repeat.xhtml", String(repeating: "a", count: 100_000))
        let archive = try ZIPArchive(data: writer.build())
        #expect(try archive.data(at: "repeat.xhtml").count == 100_000)
    }

    @Test func enforcesEntryCountLimit() throws {
        var writer = ZIPWriter()
        for index in 0..<5 { writer.addFile("f\(index).txt", "x") }
        var limits = ZIPArchive.Limits.default
        limits.maxEntries = 3
        #expect(throws: ZIPArchive.Failure.tooManyEntries) {
            try ZIPArchive(data: writer.build(), limits: limits)
        }
    }

    @Test func enforcesPerEntrySizeLimit() throws {
        var writer = ZIPWriter()
        writer.addFile("big.txt", String(repeating: "a", count: 10_000))
        var limits = ZIPArchive.Limits.default
        limits.maxEntryUncompressed = 1_000
        #expect(throws: ZIPArchive.Failure.entryTooLarge("big.txt")) {
            try ZIPArchive(data: writer.build(), limits: limits)
        }
    }

    @Test func enforcesTotalSizeLimit() throws {
        var writer = ZIPWriter()
        for index in 0..<5 { writer.addFile("f\(index).txt", String(repeating: "a", count: 1_000)) }
        var limits = ZIPArchive.Limits.default
        limits.maxTotalUncompressed = 2_500
        #expect(throws: ZIPArchive.Failure.archiveTooLarge) {
            try ZIPArchive(data: writer.build(), limits: limits)
        }
    }

    // MARK: - 落盘

    @Test func extractAllWritesTreeToDisk() throws {
        var writer = ZIPWriter()
        writer.addFile("mimetype", "application/epub+zip", compressed: false)
        writer.addFile("META-INF/container.xml", "<container/>")
        writer.addFile("OEBPS/ch1.xhtml", "<p>第一章</p>")
        writer.addDirectory("OEBPS/images")

        let archive = try ZIPArchive(data: writer.build())
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("okbooks-zip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try archive.extractAll(to: root)

        let container = root.appendingPathComponent("META-INF/container.xml")
        #expect(FileManager.default.fileExists(atPath: container.path))
        #expect(try String(contentsOf: container, encoding: .utf8) == "<container/>")

        var isDirectory: ObjCBool = false
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("OEBPS/images").path,
                isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }
}
