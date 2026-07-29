import CoreGraphics

/// 划词操作条的落点计算。
///
/// 不包 `#if os(iOS)`：纯几何，macOS 下 `swift test` 可测——
/// 本机没法脚本划词，这是唯一能自动守住"操作条不越界"的地方。
enum SelectionBarPlacement {
    static let margin: CGFloat = 8

    /// 横向落点：先保证不越左边界，再保证不越右边界。
    ///
    /// 原实现只写了 `max(anchorMinX, 8)`，右边完全没挡。窄屏勉强不显，
    /// 宽屏下正文栏被精讲右栏挤窄后，在段落右侧划词必然把操作条推出可视区。
    static func x(anchorMinX: CGFloat, barWidth: CGFloat, containerWidth: CGFloat) -> CGFloat {
        let rightLimit = containerWidth - barWidth - margin
        // 容器比操作条还窄（极窄分屏）时没有可行位置，贴左即可。
        guard rightLimit > margin else { return margin }
        return min(max(anchorMinX, margin), rightLimit)
    }

    /// 纵向落点：默认浮在选区上方，贴近顶边时改到选区下方。
    static func y(anchorMinY: CGFloat, anchorMaxY: CGFloat) -> CGFloat {
        anchorMinY > 60 ? anchorMinY - 52 : anchorMaxY + 8
    }
}
