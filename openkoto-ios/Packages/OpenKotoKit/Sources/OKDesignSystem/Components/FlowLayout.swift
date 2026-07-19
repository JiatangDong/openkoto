import SwiftUI

/// 逐句 chip 的流式布局（设计文档 §6.4）。
/// 子视图从左到右排布，放不下时换行；用于单个段落内部——
/// 段落之间由外层 LazyVStack 虚拟化，避免长文一次性布局。
public struct FlowLayout: Layout {
    public var lineSpacing: CGFloat
    public var itemSpacing: CGFloat

    public init(lineSpacing: CGFloat = 6, itemSpacing: CGFloat = 2) {
        self.lineSpacing = lineSpacing
        self.itemSpacing = itemSpacing
    }

    /// 超过容器宽度的子视图（长句）按容器宽度限宽，让 Text 在 chip 内部折行。
    private func measuredSize(of subview: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let natural = subview.sizeThatFits(.unspecified)
        guard natural.width > maxWidth, maxWidth.isFinite else { return natural }
        return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }

    public func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = measuredSize(of: subview, maxWidth: width)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + itemSpacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + lineHeight)
    }

    public func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = measuredSize(of: subview, maxWidth: bounds.width)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + itemSpacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
