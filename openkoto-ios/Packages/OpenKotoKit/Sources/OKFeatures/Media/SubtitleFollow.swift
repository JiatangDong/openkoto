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

    /// 超过这个行距就不要动画滚动。
    static let animatedRowSpan = 5

    /// 这次跟随该不该带动画。
    ///
    /// 正常播放是一句一句往下走，动画让人看清"跳到哪了"。但两种情况会一次跨几十上百行：
    /// 续播开屏（上次看到 6:50，列表停在第 0 句）和拖进度条。
    /// `LazyVStack` 里跨大段未实现行的动画滚动经常滚不到位——看起来就像"自动滚动坏了"。
    /// 距离一远就直接定位，牺牲动画换必达。
    ///
    /// `from` 为 nil 表示之前没有当前句（刚解析出第一句），按远距离处理。
    static func shouldAnimateScroll(from: Int?, to: Int) -> Bool {
        guard let from else { return false }
        return abs(to - from) <= animatedRowSpan
    }
}
