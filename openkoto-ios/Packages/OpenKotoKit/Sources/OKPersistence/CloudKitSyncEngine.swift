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
    /// 本轮推送覆盖到的最新时间戳。全部发送成功后才推进水位线——
    /// 中途失败就保持原样，下次重来，宁可重推也不能漏推。
    private var inflightHighWaterMark: Date?

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

    public func push() async throws {
        let engine = try await makeEngineIfNeeded()
        try await enqueuePendingChanges(into: engine)
        try await engine.sendChanges()
    }

    public func pull() async throws {
        let engine = try await makeEngineIfNeeded()
        try await engine.fetchChanges()
    }

    /// 把水位线之后的本地变更登记成待发送。
    private func enqueuePendingChanges(into engine: CKSyncEngine) async throws {
        let watermark = try await repository.syncWatermark()
        let payloads = try await repository.pendingCloudPayloads(since: watermark)
        let deletions = try await repository.pendingCloudDeletions(since: watermark)
        guard !payloads.isEmpty || !deletions.isEmpty else {
            inflightHighWaterMark = nil
            return
        }

        // 记下本轮覆盖到的最新时间戳，全部成功后才据此推进水位线。
        inflightHighWaterMark = payloads.map(\.updatedAt).max()

        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        changes.append(
            contentsOf: payloads.map {
                .saveRecord(
                    CKRecord.ID(
                        recordName: CloudRecord.recordName($0.type, $0.id), zoneID: zoneID))
            })
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

        case .sentRecordZoneChanges(let sent):
            await handleSent(sent)

        case .accountChange(let change):
            await handleAccountChange(change)

        case .willFetchChanges, .didFetchChanges, .willSendChanges, .didSendChanges,
            .fetchedDatabaseChanges, .sentDatabaseChanges, .willFetchRecordZoneChanges,
            .didFetchRecordZoneChanges:
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
        let payloads = (try? await repository.pendingCloudPayloads(since: watermark)) ?? []
        // `let` 而非 `var`：闭包要跨并发边界捕获它，可变捕获过不了 Swift 6 检查。
        let byRecordName = Dictionary(
            payloads.map { (CloudRecord.recordName($0.type, $0.id), $0) },
            uniquingKeysWith: { _, latest in latest })

        let temporaryDirectory = self.temporaryDirectory
        let logger = self.logger
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            guard let payload = byRecordName[recordID.recordName] else {
                // 本地已经没有这条了（推送排队期间被删掉）。返回 nil 让引擎丢弃这次保存。
                return nil
            }
            let record = CKRecord(
                recordType: payload.type.rawValue, recordID: recordID)
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
        var payloads: [CloudPayload] = []
        for modification in changes.modifications {
            let record = modification.record
            guard let parsed = CloudRecord.parse(recordName: record.recordID.recordName),
                let data = CloudRecord.readPayload(from: record)
            else { continue }
            let updatedAt = record[CloudRecord.updatedAtKey] as? Date ?? record.modificationDate
            payloads.append(
                CloudPayload(
                    type: parsed.type, id: parsed.id, data: data,
                    updatedAt: updatedAt ?? .now))
        }

        var deletions: [(type: CloudRecordType, id: String)] = []
        for deletion in changes.deletions {
            guard let parsed = CloudRecord.parse(recordName: deletion.recordID.recordName) else {
                continue
            }
            deletions.append((parsed.type, parsed.id))
        }

        do {
            // 先删后写：同一批里既删又建同一条时，应当以"建"为准。
            if !deletions.isEmpty { try await repository.applyCloudDeletions(deletions) }
            if !payloads.isEmpty { try await repository.applyCloudPayloads(payloads) }
        } catch {
            logger.error("failed to apply fetched changes: \(error)")
        }
    }

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges) async {
        for failure in sent.failedRecordSaves {
            switch failure.error.code {
            case .serverRecordChanged:
                // 服务端有更新的版本：下一轮 fetch 会把它拉回来并按规则合并。
                // 这里什么都不做是对的——强行覆盖等于丢掉另一台设备的编辑。
                logger.debug("server record changed, will merge on next fetch")
            case .zoneNotFound:
                // zone 被删了（用户在系统设置里清了 iCloud 数据）：重建并全量重推。
                logger.notice("zone missing, recreating")
                engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                try? await repository.setSyncWatermark(nil)
            default:
                logger.error("record save failed: \(failure.error.localizedDescription)")
            }
        }

        // **全部成功才推进水位线。** 有任何失败就保持原样，下次重来：
        // 重推是幂等的，漏推却是永久性的数据不一致。
        if sent.failedRecordSaves.isEmpty, sent.failedRecordDeletes.isEmpty,
            let mark = inflightHighWaterMark
        {
            try? await repository.setSyncWatermark(mark)
            inflightHighWaterMark = nil
        }
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) async {
        switch change.changeType {
        case .signIn:
            // 换了账号：本地数据不动（那是用户的），但要全量重推一遍到新账号。
            try? await repository.setSyncWatermark(nil)
        case .signOut, .switchAccounts:
            // **不删本地数据。** 退出 iCloud 不等于放弃自己的学习记录，
            // 删掉才是真正不可挽回的伤害。只把同步状态清空。
            try? await repository.setSyncEngineState(nil)
            try? await repository.setSyncWatermark(nil)
            engine = nil
        @unknown default:
            break
        }
    }
}
