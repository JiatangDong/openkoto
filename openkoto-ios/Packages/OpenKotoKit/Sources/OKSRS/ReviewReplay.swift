import Foundation
import OKModels

/// 从复习事件重放出卡片的 FSRS 状态。
///
/// **这是跨设备同步唯一正确的冲突解决方式，卡片状态绝不做 last-writer-wins。**
///
/// 设想：A、B 两台设备都离线，各把同一张卡复习了一轮。联网后两条 `ReviewEvent`
/// 都会同步过来（事件表只增不删，天然无冲突），但卡片快照只有一份。
/// 若按 `updated_at` 后写胜，晚同步的那台会**整轮覆盖**掉另一台——
/// 用户明明复习了两次，进度只记了一次，而且没有任何提示。
///
/// 重放的做法是：把这张卡的全部事件按时间排好，从"新卡"状态一路算下来。
/// 两轮复习都会被计入，结果与"在同一台设备上依次复习两次"完全一致。
///
/// 与 `ContentStore` 里的实时复习共用 `FSRS.nextReview` 与 `FSRS.dueDate`，
/// 保证"重放出来的状态"和"当时算出来的状态"是同一套规则。
public enum ReviewReplay {
    public struct CardState: Sendable, Equatable {
        public var srsState: SRSState
        public var stability: Double
        public var difficulty: Double
        public var lastReviewedAt: Date
        public var dueDate: String
        public var reviewCount: Int
        public var schedulerVersion: String
    }

    /// 按 `reviewedAt` 重放一张卡的全部事件。
    ///
    /// - Returns: 没有事件时返回 nil（卡片保持"未学"，由调用方决定怎么处理）。
    public static func replay(
        _ events: [ReviewEvent],
        desiredRetention: Double = FSRS.defaultDesiredRetention,
        calendar: Calendar = .current
    ) -> CardState? {
        guard !events.isEmpty else { return nil }

        // 排序必须是**确定性**的：同一批事件在任何设备上都要得到同一个结果。
        // 时间戳可能相同（同一秒内连点两下），再按 id 兜底定序。
        let ordered = events.sorted {
            $0.reviewedAt == $1.reviewedAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.reviewedAt < $1.reviewedAt
        }

        var stability = 0.0
        var difficulty = 0.0
        var state = SRSState.new
        var previousReviewedAt: Date?
        var lastUpdate: FSRS.Update?

        for event in ordered {
            guard let grade = FSRS.Grade(rawValue: event.grade) else { continue }
            // **重算间隔，不用事件里记的 `elapsedDays`**：那个值是当时那台设备
            // 按它自己看到的历史算的，重放时前面的事件可能不一样。
            let elapsed = elapsedDays(
                from: previousReviewedAt, to: event.reviewedAt, calendar: calendar)
            guard
                let update = try? FSRS.nextReview(
                    stability: stability, difficulty: difficulty,
                    elapsedDays: elapsed, grade: grade,
                    desiredRetention: desiredRetention)
            else { continue }
            stability = update.stability
            difficulty = update.difficulty
            state = update.state
            lastUpdate = update
            previousReviewedAt = event.reviewedAt
        }

        guard let lastUpdate, let lastReviewedAt = previousReviewedAt,
            let lastGrade = FSRS.Grade(rawValue: ordered.last(where: {
                FSRS.Grade(rawValue: $0.grade) != nil
            })?.grade ?? 0)
        else { return nil }

        return CardState(
            srsState: state,
            stability: stability,
            difficulty: difficulty,
            lastReviewedAt: lastReviewedAt,
            dueDate: FSRS.dueDate(
                grade: lastGrade, intervalDays: lastUpdate.intervalDays,
                reviewedAt: lastReviewedAt, calendar: calendar),
            reviewCount: ordered.count,
            schedulerVersion: FSRS.schedulerVersion)
    }

    /// 两次复习之间跨了几个自然日。与 `ContentStore.elapsedDays` 同规则。
    static func elapsedDays(from: Date?, to: Date, calendar: Calendar) -> Int {
        guard let from else { return 0 }
        let start = calendar.startOfDay(for: from)
        let end = calendar.startOfDay(for: to)
        return max(calendar.dateComponents([.day], from: start, to: end).day ?? 0, 0)
    }
}

extension FSRS {
    /// 本地日期串 "YYYY-MM-DD"（天粒度，与桌面端语义一致）。
    public static func localDateString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 下次到期日。**同日巩固步骤（规范 §2.8）**：
    /// 没答对（again/hard）的卡**留在今天**，当天还会回到队列里，
    /// 直到点"认识"才排到未来。FSRS 的最小间隔是 1 天，照搬就等于
    /// "一答错当天再也见不到"。
    ///
    /// 实时复习与事件重放共用这一处，否则同一张卡会因为路径不同而算出不同的到期日。
    public static func dueDate(
        grade: Grade, intervalDays: Int, reviewedAt: Date, calendar: Calendar = .current
    ) -> String {
        guard grade.rawValue >= Grade.good.rawValue else {
            return localDateString(reviewedAt, calendar: calendar)
        }
        let next =
            calendar.date(byAdding: .day, value: intervalDays, to: reviewedAt) ?? reviewedAt
        return localDateString(next, calendar: calendar)
    }
}
