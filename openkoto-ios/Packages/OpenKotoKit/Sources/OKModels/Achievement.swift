import Foundation

/// 成就指标快照(由统计现算，无独立持久化)。
public struct AchievementMetrics: Sendable, Equatable {
    public var streakDays: Int
    public var wordsCollected: Int
    public var wordsMastered: Int
    public var totalReviews: Int
    public var readingDays: Int
    public var readingMinutes: Int

    public init(
        streakDays: Int = 0,
        wordsCollected: Int = 0,
        wordsMastered: Int = 0,
        totalReviews: Int = 0,
        readingDays: Int = 0,
        readingMinutes: Int = 0
    ) {
        self.streakDays = streakDays
        self.wordsCollected = wordsCollected
        self.wordsMastered = wordsMastered
        self.totalReviews = totalReviews
        self.readingDays = readingDays
        self.readingMinutes = readingMinutes
    }
}

/// 单个成就的解锁状态(游戏化徽章 + 阶梯里程碑)。
public struct Achievement: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case streak
        case wordsCollected
        case wordsMastered
        case totalReviews
        case readingDays
        case readingMinutes
    }

    public var kind: Kind
    public var currentValue: Int
    /// 已达成的里程碑档数(0 = 未解锁)。
    public var tiersReached: Int
    /// 下一档阈值(nil = 已满档)。
    public var nextThreshold: Int?
    /// 距下一档进度 0...1(满档为 1)。
    public var progressToNext: Double
    public var unlocked: Bool { tiersReached > 0 }
    public var id: String { kind.rawValue }

    public init(
        kind: Kind,
        currentValue: Int,
        tiersReached: Int,
        nextThreshold: Int?,
        progressToNext: Double
    ) {
        self.kind = kind
        self.currentValue = currentValue
        self.tiersReached = tiersReached
        self.nextThreshold = nextThreshold
        self.progressToNext = progressToNext
    }
}

/// 成就阈值表与纯评估器(可单测)。
public enum AchievementCatalog {
    /// 每类成就的里程碑阶梯(升序)。
    public static let thresholds: [Achievement.Kind: [Int]] = [
        .streak: [3, 7, 30, 100],
        .wordsCollected: [1, 10, 50, 200, 500],
        .wordsMastered: [1, 10, 50, 100],
        .totalReviews: [10, 100, 500, 2000],
        .readingDays: [3, 7, 30, 100],
        .readingMinutes: [30, 120, 600, 3000],
    ]

    public static func value(_ kind: Achievement.Kind, in metrics: AchievementMetrics) -> Int {
        switch kind {
        case .streak: metrics.streakDays
        case .wordsCollected: metrics.wordsCollected
        case .wordsMastered: metrics.wordsMastered
        case .totalReviews: metrics.totalReviews
        case .readingDays: metrics.readingDays
        case .readingMinutes: metrics.readingMinutes
        }
    }

    /// 按 `Kind.allCases` 顺序评估全部成就。
    public static func evaluate(_ metrics: AchievementMetrics) -> [Achievement] {
        Achievement.Kind.allCases.map { kind in
            let tiers = thresholds[kind] ?? []
            let current = value(kind, in: metrics)
            let reached = tiers.filter { $0 <= current }.count
            let next = tiers.first { $0 > current }
            let previous = reached > 0 ? tiers[reached - 1] : 0
            let progress: Double
            if let next {
                let span = next - previous
                progress = span > 0
                    ? min(max(Double(current - previous) / Double(span), 0), 1)
                    : 0
            } else {
                progress = 1
            }
            return Achievement(
                kind: kind,
                currentValue: current,
                tiersReached: reached,
                nextThreshold: next,
                progressToNext: progress
            )
        }
    }
}
