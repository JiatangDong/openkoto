#if os(iOS)
import SwiftUI
import OKModels
import OKDesignSystem
import OKLocalization

extension View {
    /// 三个阅读入口（文章 / 书籍章节 / 媒体字幕）共用的精讲面板接线。
    ///
    /// 这三处原本各写了一遍几乎相同的 `.sheet` + detents + 背景可交互，
    /// 收敛到这里之后，宽窄形态、外壳、空态、关闭语义只有一份实现。
    ///
    /// `article` 收成可选：书籍按章、媒体按转写结果拿文章，两处都可能还没就绪。
    func explanationPane(
        article: Article?,
        selection: Binding<UUID?>,
        isCollapsed: Bool = false
    ) -> some View {
        adaptiveDetailPane(
            isPresented: Binding(
                get: { article != nil && selection.wrappedValue != nil },
                set: { if !$0 { selection.wrappedValue = nil } }),
            isCollapsed: isCollapsed,
            detail: {
                if let article, let segmentID = selection.wrappedValue {
                    ExplanationPane(
                        article: article,
                        segmentID: segmentID,
                        onSelectSegment: { selection.wrappedValue = $0 })
                }
            },
            placeholder: { ExplanationPanePlaceholder() })
    }
}

/// 右栏未选中句时的占位。
///
/// 必须常驻占位、不能塌陷：右栏宽度一变，左边正文就要重新折行，
/// 点第一句时会看到整片正文横向跳一次。
private struct ExplanationPanePlaceholder: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ContentUnavailableView {
            Label(L("reader.pane.empty.title"), systemImage: "sparkles")
        } description: {
            Text(L("reader.pane.empty.message"))
        }
        .background(theme.background)
    }
}
#endif
