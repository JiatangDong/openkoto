#if os(iOS)
import SwiftUI
import OKDesignSystem
import OKLocalization

extension View {
    /// 详情面板的宽窄双形态。
    ///
    /// - 宽屏（iPad 横屏 / iPad 13" 竖屏 / Mac 窗口）：右侧常驻分栏。正文不被遮挡，
    ///   点下一句直接换右栏内容——这才是「边读边讲」在宽屏上的正确形态。
    /// - 窄屏（iPhone 不论横竖 / 小 iPad）：保持今天的半屏 sheet + detents，一点不变。
    ///
    /// 之所以必须分形态：`presentationDetents` 在 iPad 的 regular 宽度下会被系统忽略，
    /// sheet 退化成居中的模态浮窗，`presentationBackgroundInteraction` 跟着一起失效。
    /// 于是「半屏看讲解、正文继续滚、点下一句」整个心智模型在 iPad 上就没了。
    ///
    /// 两种形态共用同一份 `detail` 内容，外壳由本 modifier 套：sheet 形态套 NavigationStack，
    /// 分栏形态套带关闭按钮的外壳（右栏没有下滑关闭手势，必须给显式出口）。
    func adaptiveDetailPane<Detail: View, Placeholder: View>(
        isPresented: Binding<Bool>,
        isCollapsed: Bool = false,
        @ViewBuilder detail: @escaping () -> Detail,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) -> some View {
        modifier(
            AdaptiveDetailPaneModifier(
                isPresented: isPresented,
                isCollapsed: isCollapsed,
                detail: detail,
                placeholder: placeholder))
    }

    /// 阅读时收起底部 tab 栏，让正文多一行。
    ///
    /// 只在窄屏收：宽屏用的是 `sidebarAdaptable` 的侧边栏，那是 App 的主导航，
    /// 藏掉等于把用户困在阅读器里出不去。
    func hidesAppTabBar() -> some View {
        modifier(HidesAppTabBarModifier())
    }
}

private struct AdaptiveDetailPaneModifier<Detail: View, Placeholder: View>: ViewModifier {
    @Environment(\.okCanvas) private var canvas
    @Environment(\.theme) private var theme

    @Binding var isPresented: Bool
    let isCollapsed: Bool
    let detail: () -> Detail
    let placeholder: () -> Placeholder

    private var usesSplit: Bool { canvas.isWide && !isCollapsed }

    func body(content: Content) -> some View {
        if usesSplit {
            HStack(spacing: 0) {
                content
                Divider()
                // 右栏常驻。没选中句时显示占位而不是让它塌陷——
                // 塌陷的话点第一句时整片正文会横向跳一次。
                Group {
                    if isPresented {
                        DetailPaneShell(onClose: { isPresented = false }, content: detail)
                    } else {
                        placeholder()
                    }
                }
                .frame(width: canvas.detailPaneWidth)
            }
        } else {
            content.sheet(isPresented: $isPresented) {
                NavigationStack { detail() }
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
        }
    }
}

/// 分栏形态的右栏外壳：一条细头栏 + 关闭按钮。
private struct DetailPaneShell<Content: View>: View {
    @Environment(\.theme) private var theme

    let onClose: () -> Void
    let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(theme.mutedForeground)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L("common.close")))
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            content()
        }
        .background(theme.background)
    }
}

private struct HidesAppTabBarModifier: ViewModifier {
    @Environment(\.okCanvas) private var canvas

    func body(content: Content) -> some View {
        content.toolbar(canvas.isWide ? .automatic : .hidden, for: .tabBar)
    }
}
#endif
