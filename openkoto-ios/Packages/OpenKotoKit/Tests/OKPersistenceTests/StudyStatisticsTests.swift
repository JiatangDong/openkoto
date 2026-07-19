import Foundation
import Testing
import OKModels
@testable import OKPersistence

/// `buildStudyStatistics` 纯函数口径测试(零填充 / 与 buildReviewStats 一致 / 预测 / 阅读)。
@Suite struct StudyStatisticsTests {
    private let today = "2026-07-19"

    private func review(
        _ card: UUID, date: String, grade: Int, previous: SRSState
    ) -> ReviewEvent {
        ReviewEvent(
            vocabularyId: card, reviewedAt: .now, dateLocal: date, grade: grade,
            elapsedDays: 0, previousState: previous, desiredRetention: 0.9,
            resultStability: 2, resultDifficulty: 5, resultIntervalDays: 1,
            resultState: previous == .new ? .learning : .review)
    }

    @Test func dailyActivityZeroFilledAndMatchesReviewStatsToday() {
        let cardA = UUID(), cardB = UUID()
        let favorites = [
            FavoriteVocabulary(id: cardA, word: "a", meaning: "m"),
            FavoriteVocabulary(id: cardB, word: "b", meaning: "m"),
        ]
        let events = [
            review(cardA, date: today, grade: 3, previous: .new),
            review(cardB, date: today, grade: 3, previous: .review),
        ]
        let stats = ContentRepository.buildStudyStatistics(
            favorites: favorites, events: events, readingSessions: [],
            packId: nil, dateLocal: today, rangeDays: 30, forecastDays: 14)

        #expect(stats.dailyActivity.count == 30)
        let todayEntry = stats.dailyActivity.last!         // 旧→新，末尾为今日
        #expect(todayEntry.dateLocal == today)
        #expect(todayEntry.newCount == stats.reviewStats.newToday)
        #expect(todayEntry.reviewCount == stats.reviewStats.reviewToday)
        #expect(stats.reviewStats.newToday == 1)
        #expect(stats.reviewStats.reviewToday == 1)
        #expect(stats.totalReviews == 2)
        #expect(stats.activeDays == 1)
    }

    @Test func newPrecedenceDedupeSameDay() {
        let card = UUID()
        let favorites = [FavoriteVocabulary(id: card, word: "a", meaning: "m")]
        let events = [
            review(card, date: today, grade: 3, previous: .new),
            review(card, date: today, grade: 3, previous: .review),
        ]
        let stats = ContentRepository.buildStudyStatistics(
            favorites: favorites, events: events, readingSessions: [],
            packId: nil, dateLocal: today, rangeDays: 7, forecastDays: 7)
        let todayEntry = stats.dailyActivity.last!
        #expect(todayEntry.newCount == 1)
        #expect(todayEntry.reviewCount == 0)   // 复习被新学减去
        #expect(stats.totalReviews == 2)       // 两条都计入总量
    }

    @Test func gradeBucketsAndForecast() {
        let c1 = UUID(), c2 = UUID(), c3 = UUID(), c4 = UUID()
        let favorites = [
            FavoriteVocabulary(id: c1, word: "1", meaning: "m", srsState: .review, dueDate: today),
            FavoriteVocabulary(id: c2, word: "2", meaning: "m", srsState: .review, dueDate: "2026-07-01"),
            FavoriteVocabulary(id: c3, word: "3", meaning: "m", srsState: .review,
                               suspendedAt: .now, dueDate: "2026-07-20"),
            FavoriteVocabulary(id: c4, word: "4", meaning: "m", srsState: .review, dueDate: "2026-07-21"),
        ]
        let events = [
            review(c1, date: "2026-07-18", grade: 1, previous: .review),
            review(c1, date: "2026-07-18", grade: 3, previous: .review),
            review(c2, date: "2026-07-17", grade: 4, previous: .review),
        ]
        let stats = ContentRepository.buildStudyStatistics(
            favorites: favorites, events: events, readingSessions: [],
            packId: nil, dateLocal: today, rangeDays: 30, forecastDays: 14)

        #expect(stats.gradeCounts.map(\.grade) == [1, 2, 3, 4])
        #expect(stats.gradeCounts.first { $0.grade == 1 }!.count == 1)
        #expect(stats.gradeCounts.first { $0.grade == 2 }!.count == 0)
        #expect(stats.gradeCounts.first { $0.grade == 3 }!.count == 1)
        #expect(stats.gradeCounts.first { $0.grade == 4 }!.count == 1)

        #expect(stats.forecast.count == 14)
        // 首日 = 今日到期(c1) + 逾期(c2)；已掌握 c3 排除
        #expect(stats.forecast.first!.dueCount == 2)
        #expect(stats.forecast.first { $0.dateLocal == "2026-07-21" }!.dueCount == 1)
    }

    @Test func readingAggregates() {
        let sessions = [
            ReadingSession(articleId: nil, dateLocal: today, startedAt: .now, seconds: 120),
            ReadingSession(articleId: nil, dateLocal: "2026-07-10", startedAt: .now, seconds: 300),
            ReadingSession(articleId: nil, dateLocal: "2026-06-15", startedAt: .now, seconds: 600),
        ]
        let stats = ContentRepository.buildStudyStatistics(
            favorites: [], events: [], readingSessions: sessions,
            packId: nil, dateLocal: today, rangeDays: 30, forecastDays: 14)
        #expect(stats.readingSecondsToday == 120)
        #expect(stats.readingSecondsThisMonth == 420)   // 07 月：120 + 300
        #expect(stats.readingDaysThisMonth == 2)
        #expect(stats.readingSecondsTotal == 1020)
        #expect(stats.readingDaysTotal == 3)
        #expect(stats.readingByDay.count == 30)
        #expect(stats.readingByDay.last!.seconds == 120)
    }

    @Test func emptyInputYieldsZeroFilledSeries() {
        let stats = ContentRepository.buildStudyStatistics(
            favorites: [], events: [], readingSessions: [],
            packId: nil, dateLocal: today, rangeDays: 30, forecastDays: 14)
        #expect(stats.dailyActivity.count == 30)
        #expect(stats.dailyActivity.allSatisfy { $0.total == 0 })
        #expect(stats.forecast.count == 14)
        #expect(stats.forecast.allSatisfy { $0.dueCount == 0 })
        #expect(stats.gradeCounts.count == 4)
        #expect(stats.readingByDay.count == 30)
        #expect(stats.totalReviews == 0)
        #expect(stats.reviewStats == ReviewStats())
    }
}
