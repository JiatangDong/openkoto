import Foundation
import OKModels
import Testing

@testable import OKSRS

/// 复习事件重放（跨设备同步 P3 的冲突解决）。
///
/// 守的是同步里最容易悄悄丢数据的一处：两台设备各离线复习一轮，
/// 若卡片状态按 `updated_at` 后写胜，晚同步的那台会**整轮覆盖**掉另一台——
/// 用户复习了两次、进度只记了一次，且没有任何提示。
@Suite struct ReviewReplayTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private let day: TimeInterval = 24 * 60 * 60
    private var t0: Date { Date(timeIntervalSince1970: 1_767_225_600) }  // 2026-01-01 UTC

    private func event(
        id: UUID = UUID(), vocabulary: UUID, at: Date, grade: Int, previous: SRSState = .new
    ) -> ReviewEvent {
        ReviewEvent(
            id: id, vocabularyId: vocabulary, reviewedAt: at,
            dateLocal: FSRS.localDateString(at, calendar: calendar), grade: grade,
            elapsedDays: 0, previousState: previous, schedulerVersion: FSRS.schedulerVersion,
            desiredRetention: 0.9, resultStability: 0, resultDifficulty: 0,
            resultIntervalDays: 0, resultState: .review)
    }

    // MARK: - 基本

    @Test func noEventsMeansNothingToReplay() {
        #expect(ReviewReplay.replay([], calendar: calendar) == nil)
    }

    @Test func aSingleGoodReviewInitialisesTheCard() throws {
        let card = UUID()
        let state = try #require(
            ReviewReplay.replay(
                [event(vocabulary: card, at: t0, grade: 3)], calendar: calendar))
        #expect(state.reviewCount == 1)
        #expect(state.srsState == .review)
        #expect(state.stability > 0)
        #expect(state.difficulty > 0)
        #expect(state.lastReviewedAt == t0)
    }

    // MARK: - 核心：两台设备各离线复习一轮

    /// **本组测试的理由。** 两条事件都必须被计入，结果要与
    /// "在同一台设备上依次复习两次"完全一致。
    @Test func bothOfflineReviewsAreCounted() throws {
        let card = UUID()
        let deviceA = event(vocabulary: card, at: t0, grade: 3)
        let deviceB = event(vocabulary: card, at: t0.addingTimeInterval(2 * day), grade: 3)

        let merged = try #require(ReviewReplay.replay([deviceA, deviceB], calendar: calendar))
        #expect(merged.reviewCount == 2)

        // 只保留其中一条（即"被覆盖"的效果）会得到不同的、更弱的记忆状态
        let onlyOne = try #require(ReviewReplay.replay([deviceA], calendar: calendar))
        #expect(merged.stability > onlyOne.stability)
        #expect(merged.lastReviewedAt == deviceB.reviewedAt)
    }

    /// 同步过来的顺序是任意的，重放结果必须与顺序无关。
    @Test func replayIsIndependentOfArrivalOrder() throws {
        let card = UUID()
        let e1 = event(vocabulary: card, at: t0, grade: 3)
        let e2 = event(vocabulary: card, at: t0.addingTimeInterval(2 * day), grade: 2)
        let e3 = event(vocabulary: card, at: t0.addingTimeInterval(9 * day), grade: 4)

        let forward = try #require(ReviewReplay.replay([e1, e2, e3], calendar: calendar))
        let shuffled = try #require(ReviewReplay.replay([e3, e1, e2], calendar: calendar))
        let reversed = try #require(ReviewReplay.replay([e3, e2, e1], calendar: calendar))
        #expect(forward == shuffled)
        #expect(forward == reversed)
    }

    /// 时间戳完全相同（同一秒内连点两下）时也必须确定性定序，
    /// 否则两台设备会算出不同的状态，然后来回互相覆盖。
    @Test func identicalTimestampsStillOrderDeterministically() throws {
        let card = UUID()
        let a = event(
            id: UUID(uuidString: "00000000-0000-4000-8000-00000000000A")!,
            vocabulary: card, at: t0, grade: 1)
        let b = event(
            id: UUID(uuidString: "00000000-0000-4000-8000-00000000000B")!,
            vocabulary: card, at: t0, grade: 4)

        #expect(
            ReviewReplay.replay([a, b], calendar: calendar)
                == ReviewReplay.replay([b, a], calendar: calendar))
    }

    // MARK: - 间隔重算

    /// **不能用事件里记的 `elapsedDays`**：那是当时那台设备按它自己看到的历史算的，
    /// 重放时前面的事件可能完全不一样。这里两条事件的 elapsedDays 都写死 0，
    /// 但真实间隔是 5 天，重放必须按时间戳算。
    @Test func elapsedDaysAreRecomputedFromTimestamps() {
        #expect(ReviewReplay.elapsedDays(from: nil, to: t0, calendar: calendar) == 0)
        #expect(
            ReviewReplay.elapsedDays(
                from: t0, to: t0.addingTimeInterval(5 * day), calendar: calendar) == 5)
        // 时钟回拨不能算出负数间隔（FSRS 会直接抛错）
        #expect(
            ReviewReplay.elapsedDays(
                from: t0, to: t0.addingTimeInterval(-3 * day), calendar: calendar) == 0)
    }

    // MARK: - 同日巩固

    /// 答错的卡**留在今天**（规范 §2.8）。实时复习与重放共用 `FSRS.dueDate`，
    /// 两条路径算出的到期日必须一致。
    @Test func failedCardsStayDueToday() throws {
        let card = UUID()
        let failed = try #require(
            ReviewReplay.replay(
                [event(vocabulary: card, at: t0, grade: 1)], calendar: calendar))
        #expect(failed.dueDate == FSRS.localDateString(t0, calendar: calendar))

        let passed = try #require(
            ReviewReplay.replay(
                [event(vocabulary: card, at: t0, grade: 3)], calendar: calendar))
        #expect(passed.dueDate > FSRS.localDateString(t0, calendar: calendar))
    }

    @Test func dueDateRuleMatchesTheLiveReviewPath() {
        // again / hard 留在今天
        #expect(
            FSRS.dueDate(grade: .again, intervalDays: 5, reviewedAt: t0, calendar: calendar)
                == "2026-01-01")
        #expect(
            FSRS.dueDate(grade: .hard, intervalDays: 5, reviewedAt: t0, calendar: calendar)
                == "2026-01-01")
        // good / easy 才排到未来
        #expect(
            FSRS.dueDate(grade: .good, intervalDays: 5, reviewedAt: t0, calendar: calendar)
                == "2026-01-06")
        #expect(
            FSRS.dueDate(grade: .easy, intervalDays: 30, reviewedAt: t0, calendar: calendar)
                == "2026-01-31")
    }

    // MARK: - 脏数据

    /// 认不出的评分（比如将来加了新档位、或者数据损坏）跳过即可，
    /// 不能让整张卡的重放失败——那会让这张卡的进度彻底消失。
    @Test func unknownGradesAreSkippedRatherThanAbortingTheReplay() throws {
        let card = UUID()
        let good = event(vocabulary: card, at: t0, grade: 3)
        let bogus = event(vocabulary: card, at: t0.addingTimeInterval(day), grade: 99)

        let state = try #require(ReviewReplay.replay([good, bogus], calendar: calendar))
        #expect(state.lastReviewedAt == t0)  // 只有那条合法事件生效
    }

    @Test func replayOnlyOfBogusEventsYieldsNothing() {
        let card = UUID()
        #expect(
            ReviewReplay.replay(
                [event(vocabulary: card, at: t0, grade: 0)], calendar: calendar) == nil)
    }
}
