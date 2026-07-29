import CloudKit
import Foundation
import OKModels
import os

/// CloudKit 实现的跨设备同步（计划见 §P3）。
///
/// 用户的 iCloud 私有库，零服务器成本、零账号体系。iPhone / iPad / Mac Catalyst
/// 共用同一个 bundle id 与容器 id，**Mac 版不需要任何额外配置就是第三台设备**。
///
/// 同步的是词库、复习进度、词包、文章与精讲；**EPUB 与视频文件不同步**——
/// 几 GB 会吃爆用户的 iCloud 配额，而且引用模式的 security-scoped bookmark
/// 是设备本地的，同步过去也解析不出来。
///
/// 变更侦测走**水位线扫描**而不是在每个写入点标记 dirty：后者要动几十处写入路径，
/// 漏一处就是"这类数据永远不同步"的静默 bug。
@available(iOS 17.0, macOS 14.0, *)
public final class CloudKitSyncEngine: SyncEngine, @unchecked Sendable {
    /// 单自定义 zone：便于整 zone 原子操作，也让"关闭同步"退化成删一个 zone。
    public static let zoneName = "OpenKotoZone"
    public static let containerIdentifier = "iCloud.com.openkoto.ios"

    private let repository: ContentRepository
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private let temporaryDirectory: URL
    private let logger = Logger(subsystem: "app.openkoto", category: "CloudKitSync")

    private var engine: CKSyncEngine?
    /// 本轮推送覆盖到的最新时间戳。整轮**全部**发送成功后才据此推进水位线。
    private var inflightHighWaterMark: Date?
    /// 本轮推送出过错。哪怕只有一条失败，水位线也不动：
    /// 重推是幂等的，漏推却是永久性的数据不一致。
    private var sendPassFailed = false
    /// 本轮有冲突被就地合并了 —— 意味着再推一次就能成，见 `push()`。
    private var resolvedConflicts = false

    public init(
        repository: ContentRepository,
        container: CKContainer = CKContainer(identifier: CloudKitSyncEngine.containerIdentifier)
    ) {
        self.repository = repository
        self.database = container.privateCloudDatabase
        self.zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
        self.temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenKotoCloudAssets", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: temporaryDirectory, withIntermediateDirectories: true)
    }

    /// 懒初始化：`CKSyncEngine` 一旦建出来就会自行调度，
    /// 所以直到用户真的开启同步才建。
    private func makeEngineIfNeeded() async throws -> CKSyncEngine {
        if let engine { return engine }
        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: try await loadStateSerialization(),
            delegate: self)
        // 自动同步交给系统调度（省电、合并请求）。手动 push/pull 仍然可用。
        configuration.automaticallySync = true
        let created = CKSyncEngine(configuration)
        engine = created
        return created
    }

    private func loadStateSerialization() async throws -> CKSyncEngine.State.Serialization? {
        guard let data = try await repository.syncEngineState() else { return nil }
        // 状态解不开不是灾难：置空即可，代价是下一次做一轮全量对账。
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    // MARK: - SyncEngine

    /// 最多推两轮。
    ///
    /// 第一轮撞上"服务端那份更新"时，`handleSent` 会就地按同一套规则合并、
    /// 并存下服务端回传的 change tag，第二轮就推得上去了。只重试一次、且必须是
    /// 真的合并过冲突才重试，不会打转。
    ///
    /// 为什么值得多这一轮：**从旧版升上来的设备本地一条 change tag 都没有**，
    /// 首次同步注定整批冲突。不重试的话用户点一次"立即同步"看到的是刺眼的
    /// `partialFailure`，得再点一次才好 —— 而他并不知道要再点一次。
    public func push() async throws {
        let engine = try await makeEngineIfNeeded()
        var lastError: Error?
        for _ in 0..<2 {
            try await enqueuePendingChanges(into: engine)
            resolvedConflicts = false
            do {
                try await engine.sendChanges()
                lastError = nil
            } catch {
                lastError = error
            }
            guard resolvedConflicts else { break }
        }
        if let lastError { throw lastError }
    }

    public func pull() async throws {
        let engine = try await makeEngineIfNeeded()
        try await engine.fetchChanges()
    }

    /// 待推送的记录：水位线之后有改动、**且内容与云上那份不同**的，按 recordName 索引。
    ///
    /// 后半个条件是掐回声用的。从云端拉回来的记录会写进本地表，于是它的 `updated_at`
    /// 立刻越过水位线，下一轮扫描原样把它推回去 —— 一条都没变，白跑一趟。
    /// 加上水位线本身有 5 秒重叠（见 `watermarkOverlap`），刚推上去的那几条
    /// 每一轮都会被重推。按内容哈希比一下就全免了。
    private func pendingSaves(
        watermark: Date?, meta: [String: CloudRecordMeta]
    ) async throws -> [String: CloudPayload] {
        let payloads = try await repository.pendingCloudPayloads(since: watermark)
        return CloudRecord.changedPayloads(
            payloads, knownHashes: meta.compactMapValues(\.payloadHash))
    }

    /// 把水位线之后的本地变更登记成待发送。
    private func enqueuePendingChanges(into engine: CKSyncEngine) async throws {
        let watermark = try await repository.syncWatermark()
        let meta = try await repository.cloudRecordMeta()
        let saves = try await pendingSaves(watermark: watermark, meta: meta)
        let deletions = try await repository.pendingCloudDeletions(since: watermark)
        guard !saves.isEmpty || !deletions.isEmpty else { return }

        var changes: [CKSyncEngine.PendingRecordZoneChange] = saves.keys.map {
            .saveRecord(CKRecord.ID(recordName: $0, zoneID: zoneID))
        }
        changes.append(
            contentsOf: deletions.map {
                .deleteRecord(
                    CKRecord.ID(
                        recordName: CloudRecord.recordName($0.type, $0.id), zoneID: zoneID))
            })
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        engine.state.add(pendingRecordZoneChanges: changes)
    }
}

// MARK: - CKSyncEngineDelegate

@available(iOS 17.0, macOS 14.0, *)
extension CloudKitSyncEngine: CKSyncEngineDelegate {

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            // 引擎状态必须持久化，否则每次启动都要做全量对账。
            let data = try? JSONEncoder().encode(update.stateSerialization)
            try? await repository.setSyncEngineState(data)

        case .fetchedRecordZoneChanges(let changes):
            await applyFetched(changes)

        case .willSendChanges:
            sendPassFailed = false
            inflightHighWaterMark = nil

        case .sentRecordZoneChanges(let sent):
            await handleSent(sent, engine: syncEngine)

        case .didSendChanges:
            await advanceWatermarkIfClean(syncEngine)

        case .accountChange(let change):
            await handleAccountChange(change)

        case .willFetchChanges, .didFetchChanges, .fetchedDatabaseChanges, .sentDatabaseChanges,
            .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
            break

        @unknown default:
            logger.debug("unhandled sync event")
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pending.isEmpty else { return nil }

        // 只有 saveRecord 需要现造记录；deleteRecord 引擎自己处理。
        let watermark = try? await repository.syncWatermark()
        let meta = (try? await repository.cloudRecordMeta()) ?? [:]
        // `let` 而非 `var`：闭包要跨并发边界捕获它，可变捕获过不了 Swift 6 检查。
        let saves = (try? await pendingSaves(watermark: watermark, meta: meta)) ?? [:]

        // 水位线记在这里而不是 `push()` 里：自动同步（`automaticallySync`）不走 `push()`，
        // 记在那边的话自动同步永远推不动水位线，每一轮都退化成全表扫描。
        let batchMax = saves.values.map(\.updatedAt).max()
        if let batchMax, batchMax > (inflightHighWaterMark ?? .distantPast) {
            inflightHighWaterMark = batchMax
        }

        let temporaryDirectory = self.temporaryDirectory
        let logger = self.logger
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            guard let payload = saves[recordID.recordName] else {
                // 本地已经没有这条了，或者它跟云上那份一模一样。
                // 返回 nil 让引擎把这次保存丢掉。
                return nil
            }
            // **必须从上次同步存下的系统字段起手。** CloudKit 的保存是 compare-and-swap，
            // 请求要带上"我上次见到的 change tag"；现造一条空记录等于声称"这是新建的"，
            // 服务端一看已经有了就回 `serverRecordChanged` —— 任何一条已在云上的记录
            // 都会推不上去，而报出来只是笼统的 `partialFailure`。
            let record =
                meta[recordID.recordName]?.systemFields
                .flatMap(CloudRecord.decodeSystemFields)
                ?? CKRecord(recordType: payload.type.rawValue, recordID: recordID)
            do {
                try CloudRecord.write(
                    payload: payload.data, into: record, updatedAt: payload.updatedAt,
                    temporaryDirectory: temporaryDirectory)
            } catch {
                logger.error("failed to attach payload: \(error)")
                return nil
            }
            return record
        }
    }

    // MARK: - 事件处理

    private func applyFetched(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) async {
        await ingest(changes.modifications.map(\.record))

        var deletions: [(type: CloudRecordType, id: String)] = []
        var goneNames: [String] = []
        for deletion in changes.deletions {
            goneNames.append(deletion.recordID.recordName)
            guard let parsed = CloudRecord.parse(recordName: deletion.recordID.recordName) else {
                continue
            }
            deletions.append((parsed.type, parsed.id))
        }
        guard !deletions.isEmpty else { return }
        do {
            try await repository.applyCloudDeletions(deletions)
            // 记录在云上没了，本地存的 change tag 也就失效了。
            try await repository.deleteCloudRecordMeta(recordNames: goneNames)
        } catch {
            logger.error("failed to apply fetched deletions: \(error)")
        }
    }

    /// 把服务端来的记录合并进本地，并记下它们的系统字段与内容哈希。
    ///
    /// 拉回来的（`fetchedRecordZoneChanges`）和冲突时服务端回传的（`serverRecordChanged`）
    /// 走同一条路：合并规则只有一份，不会两处慢慢走偏。
    private func ingest(_ records: [CKRecord]) async {
        guard !records.isEmpty else { return }
        var payloads: [CloudPayload] = []
        var meta: [CloudRecordMeta] = []
        let now = Date()

        for record in records {
            let name = record.recordID.recordName
            guard let parsed = CloudRecord.parse(recordName: name),
                let data = CloudRecord.readPayload(from: record)
            else { continue }
            let updatedAt = record[CloudRecord.updatedAtKey] as? Date ?? record.modificationDate
            payloads.append(
                CloudPayload(
                    type: parsed.type, id: parsed.id, data: data, updatedAt: updatedAt ?? now))
            meta.append(
                CloudRecordMeta(
                    recordName: name,
                    systemFields: CloudRecord.encodeSystemFields(record),
                    payloadHash: CloudRecord.hash(data),
                    syncedAt: now))
        }

        do {
            if !payloads.isEmpty { try await repository.applyCloudPayloads(payloads) }
            try await repository.saveCloudRecordMeta(meta)
        } catch {
            // **整批没落地，而 CloudKit 的 change token 照样往前走** ——
            // 不做点什么的话这批记录再也不会被下发，用户看到的是"同步成功但数据没来"。
            // 清掉引擎状态，下一次同步重新全量对账，把它们再要一遍。
            //
            // 单条失败已经在 `applyCloudPayloads` 里用 savepoint 隔离掉了，
            // 走到这儿说明是系统性问题（库损坏之类），全量重来是对的。
            logger.error("failed to apply fetched changes, will refetch: \(error)")
            try? await repository.setSyncEngineState(nil)
        }
    }

    /// 丢掉全部同步状态，下一次同步从零开始重新对账。
    ///
    /// 只动同步状态，**不碰任何本地数据**。用来兜底"云上明明有、本机就是没有"
    /// 这种 change token 已经走过头的情况 —— 那种状态自己不会好。
    public func resetSyncState() async throws {
        try await repository.setSyncEngineState(nil)
        try await repository.setSyncWatermark(nil)
        try await repository.clearCloudRecordMeta()
        engine = nil
    }

    private func handleSent(
        _ sent: CKSyncEngine.Event.SentRecordZoneChanges, engine syncEngine: CKSyncEngine
    ) async {
        let now = Date()

        // 存下服务端回给我们的 change tag —— 下一次保存这条记录全靠它。
        let saved = sent.savedRecords.map { record in
            CloudRecordMeta(
                recordName: record.recordID.recordName,
                systemFields: CloudRecord.encodeSystemFields(record),
                // 大记录走 CKAsset，上传后本地文件未必还读得到；
                // 哈希留空只是让它下轮可能被重推一次，不影响正确性。
                payloadHash: CloudRecord.readPayload(from: record).map(CloudRecord.hash),
                syncedAt: now)
        }
        try? await repository.saveCloudRecordMeta(saved)
        try? await repository.deleteCloudRecordMeta(
            recordNames: sent.deletedRecordIDs.map(\.recordName))

        var conflicts: [CKRecord] = []
        for failure in sent.failedRecordSaves {
            sendPassFailed = true
            switch failure.error.code {
            case .serverRecordChanged:
                // 另一台设备先写了。服务端把它那份一起回传了过来 ——
                // 走跟 fetch 完全相同的合并规则，并存下它的 change tag。
                if let serverRecord = failure.error.serverRecord {
                    conflicts.append(serverRecord)
                } else {
                    logger.error("serverRecordChanged without a server record")
                }
            case .zoneNotFound:
                // zone 被删了（用户在系统设置里清了 iCloud 数据）：重建并全量重推。
                logger.notice("zone missing, recreating")
                syncEngine.state.add(
                    pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                try? await repository.setSyncWatermark(nil)
                try? await repository.clearCloudRecordMeta()
            case .unknownItem:
                // 云上已经没这条了（别的设备删掉了）。本地那份 change tag 是废的，
                // 留着会让"同一个 id 重新出现"时带着一个早就不存在的 tag 去保存。
                try? await repository.deleteCloudRecordMeta(
                    recordNames: [failure.record.recordID.recordName])
            default:
                logger.error("record save failed: \(failure.error.localizedDescription)")
            }
        }
        for (recordID, error) in sent.failedRecordDeletes {
            // 删一条云上本来就没有的记录不是错 —— 结果正是我们想要的。
            // 当成失败的话水位线永远推不动：墓碑一直在，每轮都重删、每轮都"失败"，
            // 于是每次同步都退化成全表扫描，而且真正的失败也再没人看得见。
            if error.code == .unknownItem {
                try? await repository.deleteCloudRecordMeta(recordNames: [recordID.recordName])
            } else {
                sendPassFailed = true
                logger.error("record delete failed: \(error.localizedDescription)")
            }
        }

        guard !conflicts.isEmpty else { return }
        await ingest(conflicts)
        resolvedConflicts = true
        // 重新排队。合并后本地若仍然更新，下一轮就带着正确的 change tag 推上去；
        // 若是服务端那份胜出，内容哈希已经对上，`pendingSaves` 会直接把它滤掉。
        syncEngine.state.add(
            pendingRecordZoneChanges: conflicts.map { .saveRecord($0.recordID) })
    }

    /// 整轮推送干净收尾才推进水位线。
    ///
    /// 不在 `sentRecordZoneChanges` 里推进：一次 `sendChanges` 可能拆成多个批次，
    /// 按批推进的话，早批里时间戳靠后的记录会把水位线顶过晚批里时间戳靠前的记录——
    /// 晚批一旦失败，那些行就永远扫不到了。**那是静默丢数据。**
    private func advanceWatermarkIfClean(_ syncEngine: CKSyncEngine) async {
        defer { inflightHighWaterMark = nil }
        guard !sendPassFailed,
            syncEngine.state.pendingRecordZoneChanges.isEmpty,
            let mark = inflightHighWaterMark
        else { return }
        try? await repository.setSyncWatermark(mark)
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) async {
        switch change.changeType {
        case .signIn:
            // 换了账号：本地数据不动（那是用户的），但要全量重推一遍到新账号。
            try? await repository.setSyncWatermark(nil)
            try? await repository.clearCloudRecordMeta()
        case .signOut, .switchAccounts:
            // **不删本地数据。** 退出 iCloud 不等于放弃自己的学习记录，
            // 删掉才是真正不可挽回的伤害。只把同步状态清空。
            try? await repository.setSyncEngineState(nil)
            try? await repository.setSyncWatermark(nil)
            // 旧账号的 change tag 在新账号里一条都对不上，留着只会全线冲突。
            try? await repository.clearCloudRecordMeta()
            engine = nil
        @unknown default:
            break
        }
    }
}
