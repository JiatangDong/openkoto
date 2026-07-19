import Foundation
import SwiftUI
import OKModels
import OKDesignSystem
import OKSRS

/// 保持率分档(规范 §5):new 卡一律 new;其余按当前保持率分绿/琥珀/红。
enum RetentionBucket {
    case new
    case strong
    case fading
    case weak

    static func bucket(for favorite: FavoriteVocabulary, now: Date = .now) -> RetentionBucket {
        guard favorite.srsState != .new, favorite.stability > 0,
              let last = favorite.lastReviewedAt
        else { return .new }
        let elapsedDays = max(now.timeIntervalSince(last) / 86_400, 0)
        let retention = FSRS.retrievability(
            stability: favorite.stability, elapsedDays: elapsedDays)
        if retention >= 0.9 { return .strong }
        if retention >= 0.7 { return .fading }
        return .weak
    }

    /// 当前保持率(0-1);new 卡为 nil。
    static func retention(for favorite: FavoriteVocabulary, now: Date = .now) -> Double? {
        guard favorite.srsState != .new, favorite.stability > 0,
              let last = favorite.lastReviewedAt
        else { return nil }
        let elapsedDays = max(now.timeIntervalSince(last) / 86_400, 0)
        return FSRS.retrievability(stability: favorite.stability, elapsedDays: elapsedDays)
    }

    func color(_ theme: ThemeTokens) -> Color {
        switch self {
        case .new: return theme.mutedForeground.opacity(0.5)
        case .strong: return theme.srsStrong
        case .fading: return theme.srsFading
        case .weak: return theme.srsWeak
        }
    }
}

extension RetentionBucket {
    /// 记忆保持分档计数(排除已掌握/暂停卡)。统计图用。
    struct Distribution: Equatable {
        var new = 0
        var strong = 0
        var fading = 0
        var weak = 0
        var total: Int { new + strong + fading + weak }
    }

    static func distribution(
        for favorites: [FavoriteVocabulary], now: Date = .now
    ) -> Distribution {
        var dist = Distribution()
        for favorite in favorites where favorite.suspendedAt == nil {
            switch bucket(for: favorite, now: now) {
            case .new: dist.new += 1
            case .strong: dist.strong += 1
            case .fading: dist.fading += 1
            case .weak: dist.weak += 1
            }
        }
        return dist
    }
}
