import Foundation
import Testing
@testable import OKModels

@Suite struct ShareInboxTests {
    private func makeInbox() -> (ShareInbox, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-test-\(UUID().uuidString)", isDirectory: true)
        return (ShareInbox(directory: dir), dir)
    }

    @Test func writeThenDrainReturnsEnvelopesInOrderAndClears() throws {
        let (inbox, dir) = makeInbox()
        defer { try? FileManager.default.removeItem(at: dir) }

        let older = ImportEnvelope(
            payload: .plainText("first"), createdAt: Date(timeIntervalSince1970: 100))
        let newer = ImportEnvelope(
            payload: .url("https://x.test", title: "T", text: "body"),
            createdAt: Date(timeIntervalSince1970: 200))
        try inbox.write(newer)
        try inbox.write(older)

        #expect(inbox.pendingCount == 2)
        let drained = inbox.drain()
        #expect(drained.count == 2)
        #expect(drained[0].id == older.id)   // createdAt 升序
        #expect(drained[1].id == newer.id)
        // drain 后清空
        #expect(inbox.pendingCount == 0)
        #expect(inbox.drain().isEmpty)
    }

    @Test func drainSkipsAndRemovesCorruptFiles() throws {
        let (inbox, dir) = makeInbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        try inbox.write(ImportEnvelope(payload: .plainText("ok")))
        // 混入一个坏 JSON 文件
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("\(UUID()).json"))

        let drained = inbox.drain()
        #expect(drained.count == 1)
        #expect(inbox.pendingCount == 0)   // 坏文件也被清掉
    }

    @Test func envelopePayloadRoundTrips() throws {
        let (inbox, dir) = makeInbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        try inbox.write(ImportEnvelope(payload: .url("https://a.test", title: "标题", text: "正文")))
        let drained = inbox.drain()
        guard case let .url(url, title, text) = drained.first?.payload else {
            Issue.record("expected url payload"); return
        }
        #expect(url == "https://a.test")
        #expect(title == "标题")
        #expect(text == "正文")
    }
    // MARK: - 信封版本

    /// 加了 `.file` 之后信封升到 v2；老版本 App 见到 v2 不能把书吃掉。
    @Test func fileEnvelopeRoundTrips() throws {
        let (inbox, dir) = makeInbox()
        defer { try? FileManager.default.removeItem(at: dir) }

        let envelope = ImportEnvelope(
            payload: .file(
                relativePath: "blobs/abc.epub", filename: "吾輩は猫である.epub",
                uti: "org.idpf.epub-container"),
            sourceApp: "share-extension")
        #expect(envelope.schemaVersion == ImportEnvelope.currentSchemaVersion)
        try inbox.write(envelope)

        let drained = try #require(inbox.drain().first)
        guard case let .file(relativePath, filename, uti) = drained.payload else {
            Issue.record("payload 应为 .file")
            return
        }
        #expect(relativePath == "blobs/abc.epub")
        #expect(filename == "吾輩は猫である.epub")
        #expect(uti == "org.idpf.epub-container")
        #expect(inbox.fileURL(relativePath: relativePath).lastPathComponent == "abc.epub")
    }

    /// **版本高于本端的信封必须留在原地**：扩展可能先升级，那封信里可能是一本书。
    /// 旧实现在解码前就 defer 删除，任何读不懂的信封都被静默销毁。
    @Test func drainPreservesFutureVersionEnvelopes() throws {
        let (inbox, dir) = makeInbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let future = """
            {"id":"\(UUID().uuidString)","schemaVersion":99,
             "payload":{"somethingNew":{"_0":"x"}},"createdAt":"2026-07-25T00:00:00Z"}
            """
        let url = dir.appendingPathComponent("future.json")
        try Data(future.utf8).write(to: url)
        try inbox.write(ImportEnvelope(payload: .plainText("现在能读的")))

        let drained = inbox.drain()
        #expect(drained.count == 1)
        // 未来版本的那封还在，等升级后的自己来读。
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(inbox.pendingCount == 1)
    }

    @Test func blobsDirectoryIsCreatedUnderInbox() throws {
        let (inbox, dir) = makeInbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let blobs = try inbox.blobsDirectory()
        #expect(blobs.lastPathComponent == "blobs")
        #expect(FileManager.default.fileExists(atPath: blobs.path))
    }
}
