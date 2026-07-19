import Foundation
import Testing
import OKModels
@testable import OKFeatures

@Suite struct StatisticsTests {
    @Test func retentionDistributionBucketsAndExcludesSuspended() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

        let favorites = [
            // new 卡 → .new 桶(排除出强/衰/弱)
            FavoriteVocabulary(word: "new", meaning: "m", srsState: .new),
            // 高稳定 + 刚复习 → 保持良好(R≈1)
            FavoriteVocabulary(word: "strong", meaning: "m", srsState: .review,
                               stability: 50, lastReviewedAt: daysAgo(0)),
            // 已掌握(暂停) → 整体排除
            FavoriteVocabulary(word: "susp", meaning: "m", srsState: .review,
                               stability: 50, suspendedAt: now, lastReviewedAt: daysAgo(0)),
            // 低稳定 + 久未复习 → 可能遗忘(R 低)
            FavoriteVocabulary(word: "weak", meaning: "m", srsState: .review,
                               stability: 1, lastReviewedAt: daysAgo(10)),
        ]
        let dist = RetentionBucket.distribution(for: favorites, now: now)
        #expect(dist.new == 1)
        #expect(dist.strong == 1)
        #expect(dist.weak == 1)
        #expect(dist.fading == 0)
        #expect(dist.total == 3)   // suspended 不计
    }
}
