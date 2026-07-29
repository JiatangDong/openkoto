import Foundation

/// 一条记录的导入判定。
public enum ImportDecision: String, Equatable, Sendable {
    case insert
    case update
    /// 墓碑命中：用户主动删过，不许从文件里复活。
    case skipDeleted
    /// 本地版本更新：保留本地。
    case skipLocalNewer
}

/// 段落（句子）的合并判定。段落走的是「只补不覆盖」，与整条记录不同。
public enum SegmentMergeDecision: String, Equatable, Sendable {
    case insert
    /// 本地缺译文/精讲，用文件里的补上。
    case fillMissing
    /// 本地已有内容，不动。
    case skip
}

/// 导入规则。**全部是纯函数**——这是唯一能自动守住「导入两次不产生重复」的层。
public enum ImportRules {
    /// 生词 / 词包的判定，按顺序短路。
    ///
    /// 第三条（本地更新时间更晚就跳过）是刻意保守的：宁可少写一条，
    /// 也不要静默吃掉用户在手机上改过的释义。用户看得到跳过计数，
    /// 而被覆盖掉的编辑是无声无息的。
    public static func decide(
        isTombstoned: Bool,
        localUpdatedAt: Date?,
        incomingUpdatedAt: Date
    ) -> ImportDecision {
        if isTombstoned { return .skipDeleted }
        guard let localUpdatedAt else { return .insert }
        // 相等时也保留本地：反复导入同一个文件应当是完全的空操作，
        // 而不是每次都重写一遍所有行（那会把 updated_at 全部推高，
        // 进而让 P3 的水位线把整库当成"有变更"推上云）。
        if localUpdatedAt >= incomingUpdatedAt { return .skipLocalNewer }
        return .update
    }

    /// 段落：**只补不覆盖**。
    ///
    /// 精讲是调 API 花钱生成的，本地缺就该补上；但本地已经有的绝不覆盖——
    /// 用户可能已经用更好的模型重新生成过一次，文件里的反而是旧的。
    public static func decideSegment(
        local: ArticleSegment?, incoming: ArticleSegment
    ) -> SegmentMergeDecision {
        guard let local else { return .insert }
        let localHasContent = local.translation != nil || local.explanation != nil
        let incomingHasContent = incoming.translation != nil || incoming.explanation != nil
        if !localHasContent && incomingHasContent { return .fillMissing }
        return .skip
    }

    /// 文章：**存在即跳过，永不覆盖**。
    ///
    /// 正文一旦切分过，覆盖会让本地 segment 与新正文对不上（切分结果是按正文算的），
    /// 精讲、生词的来源句引用会一起错位。新增没问题，覆盖没有安全的做法。
    public static func decideArticle(isTombstoned: Bool, existsLocally: Bool) -> ImportDecision {
        if isTombstoned { return .skipDeleted }
        return existsLocally ? .skipLocalNewer : .insert
    }
}

// MARK: - 结果

public struct ImportCounts: Sendable, Equatable, Codable {
    public var inserted = 0
    public var updated = 0
    public var skippedDeleted = 0
    public var skippedLocalNewer = 0

    public init() {}

    public var total: Int { inserted + updated + skippedDeleted + skippedLocalNewer }
    public var changed: Int { inserted + updated }

    public mutating func record(_ decision: ImportDecision) {
        switch decision {
        case .insert: inserted += 1
        case .update: updated += 1
        case .skipDeleted: skippedDeleted += 1
        case .skipLocalNewer: skippedLocalNewer += 1
        }
    }

    public mutating func record(_ decision: SegmentMergeDecision) {
        switch decision {
        case .insert: inserted += 1
        case .fillMissing: updated += 1
        case .skip: skippedLocalNewer += 1
        }
    }
}

/// 分类报数，供 UI 直接展示。
///
/// **必须把跳过也报出来**：用户导入 100 个词只进来 60 个，
/// 不给理由的话他只会认为导入坏了。
public struct ImportResult: Sendable, Equatable, Codable {
    public var vocabulary = ImportCounts()
    public var packs = ImportCounts()
    public var articles = ImportCounts()
    public var segments = ImportCounts()
    public var reviewEvents = ImportCounts()
    public var memberships = ImportCounts()

    public init() {}

    /// 是否真的写进去了东西——用于区分「导入成功但全被跳过」这种需要解释的情况。
    public var changedAnything: Bool {
        [vocabulary, packs, articles, segments, reviewEvents, memberships]
            .contains { $0.changed > 0 }
    }
}
