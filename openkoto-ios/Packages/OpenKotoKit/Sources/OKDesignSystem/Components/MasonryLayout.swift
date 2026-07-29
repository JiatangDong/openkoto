import SwiftUI

/// 瀑布流布局：等宽多列，每个子视图放进当前最矮的那一列。
///
/// 与 `LazyVGrid` 的区别是行对齐：LazyVGrid 把同一行的高度统一成"行内最高者"，
/// 卡片高度差大时短卡下面会留下明显的空洞。统计看板正是这种情况——
/// 环形图卡比单条保持率卡高三倍。
///
/// 单列时退化成纯竖直堆叠，与窄屏今天的版式一致。
public struct MasonryLayout: Layout {
    public var columns: Int
    public var spacing: CGFloat

    public init(columns: Int, spacing: CGFloat = 12) {
        self.columns = max(1, columns)
        self.spacing = spacing
    }

    /// 一次走完所有子视图，返回每个的 frame（相对原点）与总高度。
    /// 布局与测量必须走同一份计算，否则两遍的列分配会不一致。
    private func solve(subviews: Subviews, containerWidth: CGFloat) -> ([CGRect], CGFloat) {
        let count = CGFloat(columns)
        let columnWidth = max((containerWidth - spacing * (count - 1)) / count, 1)
        var columnHeights = [CGFloat](repeating: 0, count: columns)
        var frames: [CGRect] = []
        frames.reserveCapacity(subviews.count)

        for subview in subviews {
            // 取最矮的一列；并列时取最靠左的，保证阅读顺序尽量还是从左到右。
            var target = 0
            for index in 1..<columns where columnHeights[index] < columnHeights[target] - 0.5 {
                target = index
            }
            let height = subview.sizeThatFits(
                ProposedViewSize(width: columnWidth, height: nil)
            ).height
            let x = CGFloat(target) * (columnWidth + spacing)
            let y = columnHeights[target]
            frames.append(CGRect(x: x, y: y, width: columnWidth, height: height))
            columnHeights[target] = y + height + spacing
        }

        // 末尾多加的那一份 spacing 要减掉，否则容器底部会多出一条空隙。
        let total = (columnHeights.max() ?? 0) - (subviews.isEmpty ? 0 : spacing)
        return (frames, max(total, 0))
    }

    public func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? 0
        let (_, height) = solve(subviews: subviews, containerWidth: width)
        return CGSize(width: width, height: height)
    }

    public func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let (frames, _) = solve(subviews: subviews, containerWidth: bounds.width)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}
