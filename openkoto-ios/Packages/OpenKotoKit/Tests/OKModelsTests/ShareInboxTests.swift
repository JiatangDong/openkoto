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
}
