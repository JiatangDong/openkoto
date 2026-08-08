import Foundation
import OKModels
import Testing

@testable import OKFeatures

/// 每日提醒的排期口径。
///
/// 这块逻辑最容易坏在"没人看得见"的地方：数字和生词页对不上、今天那条排在过去、
/// 已掌握的卡还在催。真机上要等到当天那个时刻才知道错了，所以口径必须钉在这里。
@Suite struct ReviewReminderTests {
    /// 固定时区，否则跑测试的机器换个地方结果就变。
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    /// 2026-08-07 09:00（周五）。
    private static let now: Date = {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 8
        parts.day = 7
        parts.hour = 9
        return calendar.date(from: parts)!
    }()

    /// 距 `now` 第 n 天的本地日期串。
    private static func day(_ offset: Int) -> String {
        let date = calendar.date(byAdding: .day, value: offset, to: now)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private func favorite(due: String, suspended: Bool = false) -> FavoriteVocabulary {
        FavoriteVocabulary(
            word: "w", meaning: "m", suspendedAt: suspended ? Self.now : nil, dueDate: due)
    }

    private func plan(_ favorites: [FavoriteVocabulary], at minutes: Int = 20 * 60)
        -> [ReviewReminder.Plan]
    {
        ReviewReminder.plan(
            favorites: favorites, minutesFromMidnight: minutes,
            now: Self.now, calendar: Self.calendar)
    }

    @Test func skipsDaysWithNothingDue() {
        // 只有第 2 天到期：第 0、1 天不该排。
        let plans = plan([favorite(due: Self.day(2))])
        #expect(plans.map(\.dayOffset) == [2, 3, 4, 5, 6])
        #expect(plans.allSatisfy { $0.dueCount == 1 })
    }

    /// 累计口径：第 n 天要催的是"到那天为止攒下的全部欠账"，不是那天新到期的几张。
    /// 用户一周不开 App 时，第 3 天收到的必须是 3 张而不是 1 张。
    @Test func countsAccumulateAcrossDays() {
        let plans = plan([
            favorite(due: Self.day(0)),
            favorite(due: Self.day(1)),
            favorite(due: Self.day(3)),
        ])
        let counts = Dictionary(uniqueKeysWithValues: plans.map { ($0.dayOffset, $0.dueCount) })
        #expect(counts[0] == 1)
        #expect(counts[1] == 2)
        #expect(counts[2] == 2)
        #expect(counts[3] == 3)
        #expect(counts[6] == 3)
    }

    /// 提醒点已经过了就不排今天——日期分量写到分钟的日历触发器没有"下一次匹配"，
    /// 排了也只是一条永不触发的僵尸。
    @Test func skipsTodayWhenTimeAlreadyPassed() {
        let plans = plan([favorite(due: Self.day(0))], at: 8 * 60)  // 08:00，now 是 09:00
        #expect(!plans.contains { $0.dayOffset == 0 })
        #expect(plans.first?.dayOffset == 1)
    }

    @Test func includesTodayWhenTimeStillAhead() {
        let plans = plan([favorite(due: Self.day(0))], at: 20 * 60)
        #expect(plans.first?.dayOffset == 0)
    }

    /// 与 `dueQueue`／生词页"今日到期"同口径：坏日期（含空串）一律算已到期。
    /// 三处对不上，用户就会收到"有 5 个"却点进去只看到 3 张。
    @Test func treatsMalformedDueDateAsDue() {
        #expect(plan([favorite(due: "")]).first?.dueCount == 1)
        #expect(plan([favorite(due: "2026-8-7")]).first?.dueCount == 1)
    }

    @Test func ignoresSuspendedCards() {
        let plans = plan([
            favorite(due: Self.day(0), suspended: true),
            favorite(due: Self.day(0), suspended: true),
        ])
        #expect(plans.isEmpty)
    }

    @Test func emptyVocabularyPlansNothing() {
        #expect(plan([]).isEmpty)
    }

    /// 全都排在窗口之外时一条都不排——没有"好久没学了"的兜底催促。
    @Test func nothingDueWithinHorizonPlansNothing() {
        #expect(plan([favorite(due: Self.day(30))]).isEmpty)
    }

    @Test func neverExceedsHorizon() {
        let plans = plan([favorite(due: Self.day(0))])
        #expect(plans.count <= ReviewReminder.horizonDays)
        #expect(plans.allSatisfy { $0.dayOffset < ReviewReminder.horizonDays })
    }

    /// 提醒时刻真的落在设定的墙上时间。
    @Test func firesAtConfiguredWallClockTime() {
        let plans = plan([favorite(due: Self.day(0))], at: 21 * 60 + 30)
        let parts = Self.calendar.dateComponents(
            [.hour, .minute], from: plans[0].fireDate)
        #expect(parts.hour == 21)
        #expect(parts.minute == 30)
    }
}
