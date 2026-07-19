import Foundation

/// 云同步接口占位(设计文档 §8.3 / SRS 规范 §8)。
///
/// 一期只落地数据层前置条件(客户端 UUID、created_at/updated_at、append-only 复习事件、
/// 词包关系表);传输协议、cursor、鉴权与冲突规则由二期 Sync RFC 定义后再实现。
/// 开源构建默认注入 `NoopSyncEngine`;商业闭源实现(OpenKotoCommerce)遵循同一协议。
public protocol SyncEngine: Sendable {
    /// 将本地未同步的变更推送到云端。
    func push() async throws
    /// 拉取云端变更并合并到本地(复习状态以事件重放重算,不做快照 LWW)。
    func pull() async throws
}

/// 开源版默认实现:不做任何事。
public struct NoopSyncEngine: SyncEngine {
    public init() {}
    public func push() async throws {}
    public func pull() async throws {}
}
