import Foundation
import Testing

@testable import OKModels

/// 传输格式的信封与导入判定规则（跨设备同步 P2）。
///
/// 判定逻辑刻意做成纯函数放在这里：落库那层要建库、要事务，跑得慢也难穷举；
/// 而「导入两次会不会产生重复」这种问题的根在判定，不在写库。
@Suite struct TransferBundleTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private var t1: Date { t0.addingTimeInterval(3600) }

    // MARK: - 信封

    @Test func roundTripsThroughJSON() throws {
        let bundle = TransferBundle(
            exportedAt: t0, sourceApp: "test",
            vocabulary: [
                FavoriteVocabulary(
                    word: "夢", meaning: "梦", dueDate: "2026-01-01",
                    createdAt: t0, updatedAt: t0)
            ])
        let decoded = try TransferBundle.decode(from: bundle.encoded())
        #expect(decoded.vocabulary.first?.word == "夢")
        #expect(decoded.sourceApp == "test")
        #expect(decoded.schemaVersion == TransferBundle.currentSchemaVersion)
    }

    /// 同样的数据必须产出同样的字节，否则「导出两次」会被 diff 和备份工具当成有变更。
    @Test func encodingIsDeterministic() throws {
        let bundle = TransferBundle(exportedAt: t0, sourceApp: "test")
        #expect(try bundle.encoded() == bundle.encoded())
    }

    /// 未来版本必须报明确的错。直接整包解码的话，新增字段会让错误变成
    /// 「缺字段」之类的噪音，用户完全看不出真正的原因是「App 太旧」。
    @Test func futureVersionIsRejectedWithAClearError() throws {
        var bundle = TransferBundle(exportedAt: t0)
        bundle.schemaVersion = TransferBundle.currentSchemaVersion + 1
        let data = try bundle.encoded()

        #expect(throws: TransferBundle.DecodeError.self) {
            try TransferBundle.decode(from: data)
        }
        do {
            _ = try TransferBundle.decode(from: data)
        } catch let error as TransferBundle.DecodeError {
            #expect(
                error
                    == .unsupportedVersion(
                        found: TransferBundle.currentSchemaVersion + 1,
                        supported: TransferBundle.currentSchemaVersion))
        }
    }

    /// 拿别的 JSON（比如 .okpack.json 分享格式）来导，要说"这不是传输包"，
    /// 而不是抛一堆解码细节。
    @Test func aDifferentFormatIsRejectedAsNotATransferBundle() throws {
        let okpack = #"{"schema_version":"openkoto-word-pack-v1","pack":{},"entries":[]}"#
        #expect(throws: TransferBundle.DecodeError.notATransferBundle) {
            try TransferBundle.decode(from: Data(okpack.utf8))
        }
        #expect(throws: TransferBundle.DecodeError.notATransferBundle) {
            try TransferBundle.decode(from: Data("not json at all".utf8))
        }
    }

    /// 跨语言互操作最容易翻车的一处：Rust 的 `chrono::to_rfc3339()` 默认带小数秒，
    /// 而 Swift 的 `.iso8601` 策略**不接受**小数秒 —— 一个时间戳就能让整包解码失败。
    @Test(arguments: [
        "2026-07-29T12:00:00Z",  // Swift 导出的形式
        "2026-07-29T12:00:00.123Z",  // 带毫秒
        "2026-07-29T12:00:00.123456789+00:00",  // Rust chrono 默认形式
        "2026-07-29T20:00:00+08:00",  // 带时区偏移
    ])
    func decodesEveryTimestampShapeTheDesktopMightEmit(stamp: String) throws {
        let json = """
            {"format":"openkoto-transfer","schemaVersion":1,"exportedAt":"\(stamp)",
             "vocabulary":[],"packs":[],"articles":[],"segments":[],
             "reviewEvents":[],"tombstones":[]}
            """
        let decoded = try TransferBundle.decode(from: Data(json.utf8))
        #expect(decoded.exportedAt.timeIntervalSince1970 > 0)
    }

    @Test func fileNameCarriesTheExportDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let name = TransferBundle.fileName(
            for: Date(timeIntervalSince1970: 1_767_225_600), calendar: calendar)
        #expect(name == "OpenKoto-2026-01-01.okdata")
    }

    // MARK: - 导入判定

    @Test func tombstoneWinsOverEverything() {
        #expect(
            ImportRules.decide(isTombstoned: true, localUpdatedAt: nil, incomingUpdatedAt: t1)
                == .skipDeleted)
        #expect(
            ImportRules.decide(isTombstoned: true, localUpdatedAt: t0, incomingUpdatedAt: t1)
                == .skipDeleted)
    }

    @Test func missingLocalRecordIsInserted() {
        #expect(
            ImportRules.decide(isTombstoned: false, localUpdatedAt: nil, incomingUpdatedAt: t0)
                == .insert)
    }

    @Test func newerIncomingUpdatesAndOlderIsSkipped() {
        #expect(
            ImportRules.decide(isTombstoned: false, localUpdatedAt: t0, incomingUpdatedAt: t1)
                == .update)
        #expect(
            ImportRules.decide(isTombstoned: false, localUpdatedAt: t1, incomingUpdatedAt: t0)
                == .skipLocalNewer)
    }

    /// 时间戳相等必须保留本地，让"重复导入同一个文件"成为**彻底的空操作**。
    /// 若这里判成 update，每次导入都会把全库的 updated_at 推高，
    /// P3 的同步水位线随即把整库当成有变更重新推上云。
    @Test func equalTimestampsAreATrueNoOp() {
        #expect(
            ImportRules.decide(isTombstoned: false, localUpdatedAt: t0, incomingUpdatedAt: t0)
                == .skipLocalNewer)
    }

    // MARK: - 段落合并：只补不覆盖

    private func segment(translation: String? = nil, explanation: String? = nil)
        -> ArticleSegment
    {
        var s = ArticleSegment(articleId: UUID(), order: 0, text: "一句。", createdAt: t0)
        s.translation = translation
        s.explanation = explanation.map {
            SegmentExplanation(translation: translation ?? "", explanation: $0)
        }
        return s
    }

    @Test func newSegmentIsInserted() {
        #expect(
            ImportRules.decideSegment(local: nil, incoming: segment(explanation: "讲解"))
                == .insert)
    }

    @Test func missingExplanationIsFilledIn() {
        #expect(
            ImportRules.decideSegment(
                local: segment(), incoming: segment(explanation: "讲解")) == .fillMissing)
    }

    /// 本地已有的精讲绝不覆盖：用户可能已经用更好的模型重新生成过，
    /// 文件里的反而是旧的。
    @Test func existingExplanationIsNeverOverwritten() {
        #expect(
            ImportRules.decideSegment(
                local: segment(explanation: "本地"), incoming: segment(explanation: "文件"))
                == .skip)
        // 文件里没内容时更不该动本地
        #expect(
            ImportRules.decideSegment(local: segment(explanation: "本地"), incoming: segment())
                == .skip)
        // 两边都空 → 无事可做
        #expect(ImportRules.decideSegment(local: segment(), incoming: segment()) == .skip)
    }

    // MARK: - 文章：存在即跳过

    @Test func articleIsNeverOverwritten() {
        #expect(ImportRules.decideArticle(isTombstoned: false, existsLocally: false) == .insert)
        #expect(
            ImportRules.decideArticle(isTombstoned: false, existsLocally: true)
                == .skipLocalNewer)
        #expect(
            ImportRules.decideArticle(isTombstoned: true, existsLocally: false) == .skipDeleted)
    }

    // MARK: - 计数

    @Test func countsReportSkipsSoTheUICanExplainThem() {
        var counts = ImportCounts()
        counts.record(ImportDecision.insert)
        counts.record(ImportDecision.update)
        counts.record(ImportDecision.skipDeleted)
        counts.record(ImportDecision.skipLocalNewer)
        #expect(counts.total == 4)
        #expect(counts.changed == 2)

        var result = ImportResult()
        #expect(!result.changedAnything)
        result.vocabulary = counts
        #expect(result.changedAnything)
    }

    /// 全被跳过时 `changedAnything` 必须是 false —— UI 靠它区分
    /// 「导入成功」和「导入成功但什么都没进来」，后者需要给用户一个解释。
    @Test func allSkippedIsNotAChange() {
        var counts = ImportCounts()
        counts.record(ImportDecision.skipDeleted)
        counts.record(ImportDecision.skipLocalNewer)
        var result = ImportResult()
        result.vocabulary = counts
        #expect(!result.changedAnything)
        #expect(counts.total == 2)
    }
}
