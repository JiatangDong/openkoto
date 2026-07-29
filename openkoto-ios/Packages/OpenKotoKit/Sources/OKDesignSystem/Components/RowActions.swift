import SwiftUI

/// 列表行上的一个操作。
///
/// 标题传已本地化的字符串——OKDesignSystem 不依赖 OKLocalization，
/// 调用方自己 `L(...)`，与 `VocabCard` 等既有组件的做法一致。
public struct OKRowAction: Identifiable {
    public let id = UUID()
    public let title: String
    public let systemImage: String
    public let role: ButtonRole?
    public let tint: Color?
    public let action: () -> Void

    public init(
        title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.tint = tint
        self.action = action
    }
}

public extension View {
    /// 一次声明，同时产出 `swipeActions` 与 `contextMenu`。
    ///
    /// **为什么不能只写 swipeActions**：Mac（Catalyst）上 List 行不支持横扫，
    /// 鼠标用户根本触发不到。只写 swipe 等于把功能藏进一个 Mac 上不存在的手势里——
    /// 设置页删除 AI 模型就是这样一个除了 swipe 别无入口的操作，
    /// 不补右键菜单的话在 Mac 上会变成永久不可达。
    ///
    /// iPad 上也顺带受益：指针长按 = 右键菜单，比精确横扫一行容易得多。
    func okRowActions(
        leading: [OKRowAction] = [],
        trailing: [OKRowAction] = []
    ) -> some View {
        modifier(OKRowActionsModifier(leading: leading, trailing: trailing))
    }
}

private struct OKRowActionsModifier: ViewModifier {
    let leading: [OKRowAction]
    let trailing: [OKRowAction]

    func body(content: Content) -> some View {
        content
            .modifier(SwipeEdgeModifier(edge: .leading, actions: leading))
            .modifier(SwipeEdgeModifier(edge: .trailing, actions: trailing))
            .contextMenu {
                // 破坏性操作排在最后，符合系统菜单惯例，也降低误点。
                let ordered = (leading + trailing).sorted { lhs, _ in lhs.role != .destructive }
                ForEach(ordered) { action in
                    Button(role: action.role, action: action.action) {
                        Label(action.title, systemImage: action.systemImage)
                    }
                }
            }
    }
}

/// 空数组时完全不挂 `swipeActions`——挂一个空的会吃掉该侧的默认手势。
private struct SwipeEdgeModifier: ViewModifier {
    let edge: HorizontalEdge
    let actions: [OKRowAction]

    @ViewBuilder
    func body(content: Content) -> some View {
        if actions.isEmpty {
            content
        } else {
            content.swipeActions(edge: edge) {
                ForEach(actions) { action in
                    Button(role: action.role, action: action.action) {
                        Label(action.title, systemImage: action.systemImage)
                    }
                    .tint(action.tint)
                }
            }
        }
    }
}
