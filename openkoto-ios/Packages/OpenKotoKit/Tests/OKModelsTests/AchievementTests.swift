import Foundation
import Testing
@testable import OKModels

@Suite struct AchievementTests {
    @Test func emptyMetricsLockAllWithZeroProgress() {
        let achievements = AchievementCatalog.evaluate(AchievementMetrics())
        #expect(achievements.count == Achievement.Kind.allCases.count)
        for achievement in achievements {
            #expect(achievement.tiersReached == 0)
            #expect(achievement.unlocked == false)
            #expect(achievement.currentValue == 0)
            #expect(achievement.progressToNext == 0)
            #expect(achievement.nextThreshold != nil)   // first tier still ahead
        }
    }

    @Test func reachingExactThresholdUnlocksTier() {
        // streak tiers [3, 7, 30, 100]
        let streak = AchievementCatalog.evaluate(AchievementMetrics(streakDays: 7))
            .first { $0.kind == .streak }!
        #expect(streak.tiersReached == 2)          // 3 and 7 reached
        #expect(streak.unlocked)
        #expect(streak.nextThreshold == 30)
        #expect(streak.progressToNext == 0)        // (7-7)/(30-7)
    }

    @Test func progressIsFractionBetweenTiers() {
        // wordsCollected tiers [1, 10, 50, 200, 500]; value 30 -> reached {1,10}, next 50
        let achievement = AchievementCatalog.evaluate(AchievementMetrics(wordsCollected: 30))
            .first { $0.kind == .wordsCollected }!
        #expect(achievement.tiersReached == 2)
        #expect(achievement.nextThreshold == 50)
        #expect(abs(achievement.progressToNext - 0.5) < 1e-9)   // (30-10)/(50-10)
    }

    @Test func maxedTierHasNoNextAndFullProgress() {
        // totalReviews tiers [10, 100, 500, 2000]
        let achievement = AchievementCatalog.evaluate(AchievementMetrics(totalReviews: 5000))
            .first { $0.kind == .totalReviews }!
        #expect(achievement.tiersReached == 4)
        #expect(achievement.nextThreshold == nil)
        #expect(achievement.progressToNext == 1)
    }

    @Test func valueBelowFirstThresholdStaysLocked() {
        // wordsMastered tiers [1, 10, 50, 100]
        let achievement = AchievementCatalog.evaluate(AchievementMetrics(wordsMastered: 0))
            .first { $0.kind == .wordsMastered }!
        #expect(achievement.tiersReached == 0)
        #expect(achievement.nextThreshold == 1)
        #expect(achievement.progressToNext == 0)
    }
}
