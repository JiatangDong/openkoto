import Foundation
import OKModels
import OKPersistence

/// iCloud 同步的接线（跨设备同步 P3）。
///
/// **同步是增强，不是依赖**：关掉、没登录 iCloud、或者根本没有网络时，
/// App 的每一个功能都必须照常可用。所以这里所有失败都只记状态，不阻断任何流程。
extension ContentStore {
    /// 状态本身不依赖 CloudKit，放在条件编译之外 ——
    /// `ContentStore` 在 macOS 上也要编译（`swift test` 跑的就是那一份）。
    public enum SyncStatus: Sendable, Equatable {
        case disabled
        case idle(lastSyncedAt: Date?)
        case syncing
        /// 没登录 iCloud / 账号不可用。这不是错误，是一种正常状态，
        /// 文案上要区别于"同步失败"。
        case unavailable
        case failed(String)
    }

    /// 用户开关。默认**关闭**：把用户的学习记录传到云上这件事，
    /// 必须由他自己点头，不能靠默认值替他决定。
    public static let syncEnabledKey = "sync.iCloudEnabled"

    public var isSyncEnabled: Bool {
        defaults.bool(forKey: Self.syncEnabledKey)
    }
}

#if os(iOS)
import CloudKit
import UIKit

extension ContentStore {
    /// 开或关同步。
    ///
    /// 关闭时**不删本地任何数据**，也不删云端的 —— 用户只是不想再传了，
    /// 不是要放弃自己的学习记录。想彻底清云端数据请走系统设置里的 iCloud 管理。
    public func setSyncEnabled(_ enabled: Bool) async {
        defaults.set(enabled, forKey: Self.syncEnabledKey)
        if enabled {
            await syncNow()
        } else {
            syncStatus = .disabled
        }
    }

    /// 手动同步一次：先拉后推。
    ///
    /// 顺序是刻意的 —— 先把别的设备的变更拉回来合并，再推本地的，
    /// 这样本地推上去的已经是合并后的结果，少一轮往返。
    public func syncNow() async {
        guard isSyncEnabled else {
            syncStatus = .disabled
            return
        }
        guard #available(iOS 17.0, macOS 14.0, *) else {
            syncStatus = .unavailable
            return
        }
        guard let engine = await makeSyncEngineIfNeeded() else {
            syncStatus = .unavailable
            return
        }

        syncStatus = .syncing
        do {
            try await engine.pull()
            try await engine.push()
            await load()
            let watermark = try? await repository.syncWatermark()
            syncStatus = .idle(lastSyncedAt: watermark ?? .now)
        } catch let error as CKError where error.code == .notAuthenticated {
            // 没登录 iCloud：不是故障，别用红色错误吓用户。
            syncStatus = .unavailable
        } catch {
            // 完整展开而不是 localizedDescription：CloudKit 的那句
            // "The operation couldn't be completed. (CKErrorDomain error 15.)"
            // 既没说 15 是什么，也没说服务端到底拒绝了什么。
            let report = CloudKitErrorReport.describe(error)
            Self.logger.error("sync failed: \(report, privacy: .public) | raw: \(error)")
            syncStatus = .failed(report)
        }
    }

    /// 向 APNs 注册。
    ///
    /// **CKSyncEngine 一初始化就会去创建数据库订阅，而订阅要绑定推送 topic。**
    /// 没注册过的话服务端拒绝建订阅，报出来是
    /// `serverRejectedRequest (15) / CKInternalErrorDomain 2000`，
    /// 日志里那句 `error saving subscriptions` 才是真正的线索。
    ///
    /// 不需要向用户申请通知权限：CloudKit 用的是静默推送，
    /// `registerForRemoteNotifications()` 单独调用不会弹任何框。
    @MainActor
    private func registerForSilentPushIfNeeded() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    @available(iOS 17.0, macOS 14.0, *)
    private func makeSyncEngineIfNeeded() async -> CloudKitSyncEngine? {
        if let existing = cloudSyncEngine as? CloudKitSyncEngine { return existing }
        await registerForSilentPushIfNeeded()
        // 账号不可用时不要建引擎：它一建出来就会自行调度，
        // 只会不断产生注定失败的请求。
        let status = try? await CKContainer(
            identifier: CloudKitSyncEngine.containerIdentifier
        ).accountStatus()
        guard status == .available else { return nil }
        let engine = CloudKitSyncEngine(repository: repository)
        cloudSyncEngine = engine
        return engine
    }
}
#endif
