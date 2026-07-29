import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import OKFeatures

/// 字幕自动跟随的脱离判定。
///
/// 这组断言守的是一个在 Mac 上会静默失效的交互：原实现用 `DragGesture` 判定，
/// 而滚轮与触控板两指滚动都不产生 DragGesture，用户往回翻会被强行拽回当前句。
@Suite struct SubtitleFollowTests {
    @Test func userDrivenScrollingDisengagesFollowing() {
        #expect(SubtitleFollow.shouldDisengage(.interacting))
        #expect(SubtitleFollow.shouldDisengage(.decelerating))
    }

    /// 最关键的一条：`proxy.scrollTo` 发起的程序化滚动是 `.animating`。
    /// 若把它也算成脱离，自动跟随会在第一次滚动时就自我关闭。
    @Test func programmaticScrollingKeepsFollowing() {
        #expect(SubtitleFollow.shouldDisengage(.animating) == false)
    }

    @Test func idleAndTrackingKeepFollowing() {
        #expect(SubtitleFollow.shouldDisengage(.idle) == false)
        #expect(SubtitleFollow.shouldDisengage(.tracking) == false)
    }
}

/// 划词操作条的落点。宽屏下正文栏被精讲右栏挤窄，右边界溢出必现。
@Suite struct SelectionBarPlacementTests {
    private let barWidth: CGFloat = 240
    private let container: CGFloat = 700

    @Test func followsTheSelectionWhenThereIsRoom() {
        let x = SelectionBarPlacement.x(
            anchorMinX: 120, barWidth: barWidth, containerWidth: container)
        #expect(x == 120)
    }

    @Test func clampsToTheLeftMargin() {
        let x = SelectionBarPlacement.x(
            anchorMinX: -30, barWidth: barWidth, containerWidth: container)
        #expect(x == SelectionBarPlacement.margin)
    }

    /// 原实现只夹了左边，靠右划词时操作条会被推出可视区——这条是那个 bug 的回归防线。
    @Test func clampsToTheRightEdge() {
        let x = SelectionBarPlacement.x(
            anchorMinX: 660, barWidth: barWidth, containerWidth: container)
        #expect(x == container - barWidth - SelectionBarPlacement.margin)
        #expect(x + barWidth <= container)
    }

    @Test func neverOverflowsForAnyAnchor() {
        for anchor in stride(from: -100.0, through: 900.0, by: 25) {
            let x = SelectionBarPlacement.x(
                anchorMinX: anchor, barWidth: barWidth, containerWidth: container)
            #expect(x >= SelectionBarPlacement.margin)
            #expect(x + barWidth <= container)
        }
    }

    /// 极窄分屏：容器比操作条还窄时没有可行位置，贴左而不是算出负数。
    @Test func degradesGracefullyWhenContainerIsNarrowerThanTheBar() {
        let x = SelectionBarPlacement.x(anchorMinX: 40, barWidth: barWidth, containerWidth: 100)
        #expect(x == SelectionBarPlacement.margin)
    }

    /// 贴近顶边时操作条改到选区下方，否则浮在上方。
    @Test func flipsBelowTheSelectionNearTheTopEdge() {
        #expect(SelectionBarPlacement.y(anchorMinY: 200, anchorMaxY: 230) == 148)
        #expect(SelectionBarPlacement.y(anchorMinY: 20, anchorMaxY: 50) == 58)
    }
}
