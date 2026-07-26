import Foundation
import OKModels

/// 跟读模式的状态规则。
///
/// 三个开关（盲听、单句循环、慢速）本来就各自存在很久了，桌面端也是——
/// 但实际上没人用，因为**没人愿意为练一句手动点三次**。这里把它们合成一个姿势。
///
/// 规则单独抽出来而不是写在 `MediaPlayerView` 里：它是纯逻辑，
/// 可以在 macOS 上 `swift test`，而视图不能。
enum Shadowing {
    /// 跟读的慢速。再慢会让语调失真到听不出重音，练了反而有害。
    static let rate: Float = 0.75

    /// 三件事同时成立才算在跟读里；任一被单独关掉就算退出。
    ///
    /// 这样用户在跟读中单独调回 1× 或点掉循环，入口会诚实地变回"进入跟读"，
    /// 而不是留一个已经名不副实的"退出跟读"。
    static func isActive(isBlind: Bool, loopingSegmentID: UUID?, rate: Float) -> Bool {
        isBlind && loopingSegmentID != nil && rate == Self.rate
    }

    struct State: Equatable {
        var isBlind: Bool
        var loopSegmentID: UUID?
        var rate: Float
    }

    /// 切换后应有的状态。`target` 为 nil（没有可循环的句子）时原样返回——
    /// 调用方应当据此禁用入口，而不是让用户点一个没有效果的按钮。
    static func toggled(
        isBlind: Bool, loopingSegmentID: UUID?, rate: Float, target: UUID?
    ) -> State {
        let current = State(isBlind: isBlind, loopSegmentID: loopingSegmentID, rate: rate)
        if isActive(isBlind: isBlind, loopingSegmentID: loopingSegmentID, rate: rate) {
            return State(isBlind: false, loopSegmentID: nil, rate: 1)
        }
        guard let target else { return current }
        return State(isBlind: true, loopSegmentID: target, rate: Self.rate)
    }

    /// 能循环的句子必须有起止时间——没有时间轴就没有"这一句"可循环。
    static func isLoopable(_ segment: ArticleSegment) -> Bool {
        segment.startTime != nil && segment.endTime != nil
    }
}
