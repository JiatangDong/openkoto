import SwiftUI

/// 字幕列表「自动跟随当前句」的脱离判定。
///
/// 抽成纯函数是为了能在 `swift test` 里覆盖——本机无法脚本滚动模拟器，
/// 而这条判定正是 Mac 上会静默失效的那个交互。
enum SubtitleFollow {
    /// 这个滚动阶段是否意味着「用户在自己翻」，应停止自动跟随。
    ///
    /// 只认用户直接驱动的两个阶段：
    /// - `.interacting` 手指/触控板正在拖
    /// - `.decelerating` 松手后的惯性滑行
    ///
    /// 明确排除 `.animating`：那是 `proxy.scrollTo` 自己发起的程序化滚动，
    /// 把它算成脱离的话，跟随功能一滚就会自我关闭。
    ///
    /// 原实现用 `DragGesture(minimumDistance: 12)` 判定，在 Mac 与 iPad 触控板上
    /// 都不成立——滚轮和两指滚动根本不产生 DragGesture，用户往回翻会被强行拽回当前句。
    static func shouldDisengage(_ phase: ScrollPhase) -> Bool {
        switch phase {
        case .interacting, .decelerating:
            return true
        case .animating, .idle, .tracking:
            return false
        @unknown default:
            return false
        }
    }
}
