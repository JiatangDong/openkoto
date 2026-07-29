import Foundation
import GRDB
import OKModels
import Testing

@testable import OKPersistence

/// CloudKit 同步的数据层（跨设备同步 P3）。
///
/// CloudKit 本身的往返（真机、两台设备、同一个 iCloud 账号）没法在这里跑，
/// 所以**能验的每一条都必须验**：变更收集、冲突合并、删除传播、复习重放。
/// 这些恰恰也是出了错最不容易被发现的地方 —— 同步的失败模式几乎全是静默的。
@Suite struct CloudSyncTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private var t1: Date { t0.addingTimeInterval(3600) }
    private var t2: Date { t0.addingTimeInterval(7200) }

    private func makeRepository() throws -> ContentRepository {
        ContentRepository(database: try AppDatabase.inMemory())
    }

    private func makeVocab(
        id: UUID = UUID(), word: String = "夢", meaning: String = "梦", updatedAt: Date
    ) -> FavoriteVocabulary {
        FavoriteVocabulary(
            id: id, word: word, meaning: meaning, dueDate: "2026-01-01",
            createdAt: updatedAt, updatedAt: updatedAt)
    }

    private func payload(_ vocab: FavoriteVocabulary) throws -> CloudPayload {
        CloudPayload(
            type: .vocabulary, id: vocab.id.uuidString.lowercased(),
            data: try CloudRecord.encoder().encode(vocab), updatedAt: vocab.updatedAt)
    }

    // MARK: - 记录命名

    /// 记录名带类型前缀是必需的：词包成员的键是 `vocabId:packId`，
    /// 而文章与句子各有自己的 UUID 空间。
    @Test func recordNamesRoundTrip() throws {
        let name = CloudRecord.recordName(.vocabulary, "AABBCCDD-1111-2222-3333-444455556666")
        #expect(name == "Vocabulary_aabbccdd-1111-2222-3333-444455556666")
        let parsed = try #require(CloudRecord.parse(recordName: name))
        #expect(parsed.type == .vocabulary)
        #expect(parsed.id == "aabbccdd-1111-2222-3333-444455556666")
    }

    /// 词包成员的 id 自带一个下划线，解析必须只切第一个。
    /// **分隔符不能用冒号**：CloudKit 会回 `serverRejectedRequest`（实测过），
    /// 而且这种记录名会带两个冒号。
    @Test func membershipRecordNameSurvivesItsOwnSeparator() throws {
        let key = Tombstone.membershipKey(vocabularyID: UUID(), packID: UUID())
        let parsed = try #require(
            CloudRecord.parse(recordName: CloudRecord.recordName(.wordPackMembership, key)))
        #expect(parsed.type == .wordPackMembership)
        #expect(parsed.id == key)
    }

    @Test func unknownRecordNamesAreRejected() {
        #expect(CloudRecord.parse(recordName: "NotAType_abc") == nil)
        #expect(CloudRecord.parse(recordName: "noseparator") == nil)
    }

    // MARK: - 变更收集（水位线）

    @Test func firstSyncCollectsEverything() async throws {
        let repo = try makeRepository()
        try await repo.insertFavorite(makeVocab(updatedAt: t0), now: t0)

        let payloads = try await repo.pendingCloudPayloads(since: nil)
        #expect(payloads.contains { $0.type == .vocabulary })
    }

    @Test func laterSyncsOnlyCollectWhatChanged() async throws {
        let repo = try makeRepository()
        try await repo.insertFavorite(makeVocab(word: "旧", updatedAt: t0), now: t0)
        try await repo.setSyncWatermark(t1)
        try await repo.insertFavorite(makeVocab(word: "新", updatedAt: t2), now: t2)

        let payloads = try await repo.pendingCloudPayloads(since: t1)
        let words = try payloads.filter { $0.type == .vocabulary }.map {
            try CloudRecord.decoder().decode(FavoriteVocabulary.self, from: $0.data).word
        }
        #expect(words == ["新"])
    }

    /// SQLite 的时间戳只到秒，"读水位线"与"写数据"在同一秒内没有先后保证。
    /// 不向前重叠就会漏推，而**漏推是永久性的数据不一致**（重推只是浪费流量）。
    @Test func watermarkOverlapsBackwardsSoNothingIsMissed() async throws {
        let repo = try makeRepository()
        // 数据的时间戳比水位线早 2 秒，落在 5 秒重叠窗口里
        try await repo.insertFavorite(makeVocab(updatedAt: t1.addingTimeInterval(-2)), now: t1)

        let payloads = try await repo.pendingCloudPayloads(since: t1)
        #expect(payloads.contains { $0.type == .vocabulary })
    }

    @Test func systemPackIsNeverPushed() async throws {
        let repo = try makeRepository()
        _ = try await repo.ensureDefaultPack(now: t0)
        let payloads = try await repo.pendingCloudPayloads(since: nil)
        #expect(!payloads.contains { $0.type == .wordPack })
    }

    @Test func deletionsComeFromTombstones() async throws {
        let repo = try makeRepository()
        let vocab = makeVocab(updatedAt: t0)
        try await repo.insertFavorite(vocab, now: t0)
        try await repo.deleteFavorite(id: vocab.id, now: t1)

        let deletions = try await repo.pendingCloudDeletions(since: nil)
        #expect(deletions.contains { $0.type == .vocabulary && $0.id == vocab.id.uuidString.lowercased() })
    }

    // MARK: - 合并云端变更

    @Test func newRecordFromCloudIsInserted() async throws {
        let repo = try makeRepository()
        let vocab = makeVocab(updatedAt: t0)
        let applied = try await repo.applyCloudPayloads([try payload(vocab)], now: t1)
        #expect(applied == 1)
        #expect(try await repo.loadAll().favorites.first?.word == "夢")
    }

    /// 与文件导入同一条规则：本地更新时间更晚就保留本地。
    @Test func localEditsAreNotOverwrittenByOlderCloudRecords() async throws {
        let repo = try makeRepository()
        let id = UUID()
        try await repo.insertFavorite(
            makeVocab(id: id, meaning: "本地改过的", updatedAt: t2), now: t2)

        _ = try await repo.applyCloudPayloads(
            [try payload(makeVocab(id: id, meaning: "云端旧的", updatedAt: t0))], now: t2)

        #expect(try await repo.loadAll().favorites.first?.meaning == "本地改过的")
    }

    /// 本地删过的记录不能被云端推回来。
    @Test func tombstonedRecordsAreNotResurrectedFromCloud() async throws {
        let repo = try makeRepository()
        let vocab = makeVocab(updatedAt: t0)
        try await repo.insertFavorite(vocab, now: t0)
        try await repo.deleteFavorite(id: vocab.id, now: t1)

        let applied = try await repo.applyCloudPayloads([try payload(vocab)], now: t2)
        #expect(applied == 0)
        #expect(try await repo.loadAll().favorites.isEmpty)
    }

    /// 云端的删除要在本地留墓碑，否则另一台设备下一轮又会把它推上来，
    /// 变成两台设备互相推、永远收敛不了。
    @Test func cloudDeletionsLeaveALocalTombstone() async throws {
        let repo = try makeRepository()
        let vocab = makeVocab(updatedAt: t0)
        try await repo.insertFavorite(vocab, now: t0)

        try await repo.applyCloudDeletions(
            [(type: .vocabulary, id: vocab.id.uuidString.lowercased())], now: t1)

        #expect(try await repo.loadAll().favorites.isEmpty)
        #expect(try await repo.tombstoneIDs(for: .favoriteVocabulary).count == 1)
    }

    /// 父文章不在本地的句子必须跳过 —— 外键会挡，硬写就是整批回滚，
    /// 一条孤儿句子会让整轮同步失败。
    @Test func orphanSegmentsDoNotAbortTheWholeMerge() async throws {
        let repo = try makeRepository()
        let orphan = ArticleSegment(articleId: UUID(), order: 0, text: "孤儿", createdAt: t0)
        let vocab = makeVocab(updatedAt: t0)

        let applied = try await repo.applyCloudPayloads(
            [
                CloudPayload(
                    type: .segment, id: orphan.id.uuidString.lowercased(),
                    data: try CloudRecord.encoder().encode(orphan), updatedAt: t0),
                try payload(vocab),
            ], now: t1)

        #expect(applied == 1)  // 只有生词进来了，整批没回滚
    }

    // MARK: - 复习进度：绝不 LWW

    /// **本组测试里最重要的一条。**
    ///
    /// A、B 两台设备各离线复习同一张卡一轮。若卡片状态按 `updated_at` 后写胜，
    /// 晚同步的那台会整轮覆盖掉另一台 —— 用户复习了两次、进度只记了一次。
    /// 正确做法是同步事件（只增不删），再重放算出卡片状态。
    @Test func twoOfflineReviewsBothSurviveTheMerge() async throws {
        let repo = try makeRepository()
        let vocab = makeVocab(updatedAt: t0)
        try await repo.insertFavorite(vocab, now: t0)

        func event(at: Date) -> ReviewEvent {
            ReviewEvent(
                vocabularyId: vocab.id, reviewedAt: at, dateLocal: "2026-01-01", grade: 3,
                elapsedDays: 0, previousState: .new, schedulerVersion: "fsrs6",
                desiredRetention: 0.9, resultStability: 1, resultDifficulty: 5,
                resultIntervalDays: 1, resultState: .review)
        }
        let deviceA = event(at: t0)
        let deviceB = event(at: t0.addingTimeInterval(2 * 24 * 3600))

        _ = try await repo.applyCloudPayloads(
            [deviceA, deviceB].map {
                CloudPayload(
                    type: .reviewEvent, id: $0.id.uuidString.lowercased(),
                    data: try! CloudRecord.encoder().encode($0), updatedAt: $0.reviewedAt)
            }, now: t2)

        let card = try #require(try await repo.loadAll().favorites.first)
        // 两轮都被计入，而不是只剩一轮
        #expect(card.reviewCount == 2)
        #expect(card.stability > 0)
        #expect(card.srsState == .review)
    }

    /// 复习事件是 append-only，重复同步同一条不能产生第二行。
    @Test func repeatedReviewEventsAreDeduplicated() async throws {
        let repo = try makeRepository()
        let vocab = makeVocab(updatedAt: t0)
        try await repo.insertFavorite(vocab, now: t0)
        let event = ReviewEvent(
            vocabularyId: vocab.id, reviewedAt: t0, dateLocal: "2026-01-01", grade: 3,
            elapsedDays: 0, previousState: .new, schedulerVersion: "fsrs6",
            desiredRetention: 0.9, resultStability: 1, resultDifficulty: 5,
            resultIntervalDays: 1, resultState: .review)
        let cloud = CloudPayload(
            type: .reviewEvent, id: event.id.uuidString.lowercased(),
            data: try CloudRecord.encoder().encode(event), updatedAt: t0)

        _ = try await repo.applyCloudPayloads([cloud], now: t1)
        _ = try await repo.applyCloudPayloads([cloud], now: t1)

        let count = try await repo.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_log") ?? -1
        }
        #expect(count == 1)
    }

    // MARK: - 导入与同步的联动

    /// 导入刻意保留了来源端的 `updatedAt`，那些时间戳可能比水位线还旧。
    /// 不回拨水位线的话，刚导进来的几百个词**永远上不了云**，其它设备完全看不见。
    @Test func importRewindsTheWatermarkSoImportedDataStillGetsPushed() async throws {
        let repo = try makeRepository()
        try await repo.setSyncWatermark(t2)

        // 文件里是很旧的记录
        let old = makeVocab(updatedAt: t0)
        let bundle = TransferBundle(exportedAt: t0, vocabulary: [old])
        let result = try await repo.importTransferBundle(bundle, now: t2)
        #expect(result.vocabulary.inserted == 1)

        #expect(try await repo.syncWatermark() == nil)
        // 水位线归零后，这条旧记录才会被收集去推送
        let payloads = try await repo.pendingCloudPayloads(since: nil)
        #expect(payloads.contains { $0.type == .vocabulary })
    }

    /// 什么都没导进来时不该白白触发一次全量重推。
    @Test func aNoOpImportLeavesTheWatermarkAlone() async throws {
        let repo = try makeRepository()
        try await repo.setSyncWatermark(t2)
        _ = try await repo.importTransferBundle(TransferBundle(exportedAt: t0), now: t2)
        #expect(try await repo.syncWatermark() == t2)
    }

    // MARK: - 引擎状态

    @Test func syncStateRoundTrips() async throws {
        let repo = try makeRepository()
        #expect(try await repo.syncEngineState() == nil)
        #expect(try await repo.syncWatermark() == nil)

        try await repo.setSyncEngineState(Data([1, 2, 3]))
        try await repo.setSyncWatermark(t1)
        #expect(try await repo.syncEngineState() == Data([1, 2, 3]))
        #expect(try await repo.syncWatermark() == t1)

        // 两个字段互不干扰（单行表读改写最容易在这里出错）
        try await repo.setSyncWatermark(t2)
        #expect(try await repo.syncEngineState() == Data([1, 2, 3]))
    }
}
