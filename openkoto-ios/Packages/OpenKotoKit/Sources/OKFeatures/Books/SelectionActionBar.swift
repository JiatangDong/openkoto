#if os(iOS)
import SwiftUI
import OKDesignSystem
import OKLocalization

/// 原版模式的划词操作条。
///
/// 用原生浮层而不是往 WKWebView 的系统菜单里塞菜单项：iOS 17 上给 web 选区扩展编辑菜单
/// 要么依赖已废弃的 `UIMenuController`，要么绕一大圈 `UIMenuBuilder` 且不稳定。
/// 自绘浮层行为确定、能跟主题走、也能测。
struct SelectionActionBar: View {
    @Environment(\.theme) private var theme

    /// 选区在 WebView 坐标系里的矩形（用于定位）。
    let anchor: CGRect
    let canExplain: Bool
    let onExplain: () -> Void
    let onFavorite: () -> Void
    let onHighlight: () -> Void
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if canExplain {
                button(L("reader.selection.explain"), "sparkles", onExplain)
                divider
            }
            button(L("reader.selection.favorite"), "star", onFavorite)
            divider
            button(L("reader.selection.highlight"), "highlighter", onHighlight)
            divider
            button(L("reader.selection.copy"), "doc.on.doc", onCopy)
        }
        .padding(.horizontal, 4)
        .background(theme.card, in: RoundedRectangle(cornerRadius: OKRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: OKRadius.card)
                .strokeBorder(theme.border, lineWidth: 1))
        .shadow(radius: 8, y: 2)
        .fixedSize()
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.border)
            .frame(width: 1, height: 20)
    }

    private func button(_ title: String, _ symbol: String, _ action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.footnote)
                Text(title).font(.caption2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .foregroundStyle(theme.cardForeground)
        }
        .buttonStyle(.plain)
    }
}
#endif
