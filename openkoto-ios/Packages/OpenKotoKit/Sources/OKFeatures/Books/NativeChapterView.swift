#if os(iOS)
import SwiftUI
import OKModels
import OKDesignSystem
import OKLocalization

/// 原生模式的正文渲染：段落 LazyVStack + 段内 FlowLayout 逐句 chip。
///
/// 从 `ReaderView` 抽出来给书籍阅读器按章复用——chip 状态、点击选中、三种视图模式
/// 只此一份实现，不做第二套。
struct NativeChapterView: View {
    @Environment(\.theme) private var theme

    let segments: [ArticleSegment]
    @Binding var selectedSegmentID: UUID?
    let fontSize: Double
    let viewMode: ReaderViewMode
    /// 进入时滚到该句序（续读位置）。仅在首次布局与该值变化时生效。
    var restoreOrder: Int?
    /// 当前视口顶部的句序，用于记录阅读位置。
    var onVisibleOrderChanged: ((Int) -> Void)?
    /// 已划线/加书签的句序，用于底色标注。
    var markedOrders: Set<Int> = []
    /// 词级读音（segmentID → runs）。空字典 = 关闭注音，正文与今天完全一致。
    var readingRuns: [UUID: [ReadingRun]] = [:]
    /// 长按句子后的标记动作（书籍阅读器才提供）。
    var onMark: ((ArticleSegment, BookMark.Kind) -> Void)?

    private static let scrollSpace = "NativeChapterScroll"

    /// 按 isNewParagraph 分组成段落。
    private var paragraphs: [[ArticleSegment]] {
        var result: [[ArticleSegment]] = []
        for segment in segments {
            if segment.isNewParagraph || result.isEmpty {
                result.append([segment])
            } else {
                result[result.count - 1].append(segment)
            }
        }
        return result
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: CGFloat(fontSize)) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        paragraphView(paragraph)
                            .id(paragraph.first?.order ?? 0)
                            .background(offsetReporter(order: paragraph.first?.order ?? 0))
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
                // 正文限宽居中。加在 padding 之外、ScrollView 之内：
                // 滚动条仍贴屏幕右缘、背景不断层，只有文字被收窄。
                //
                // 不限宽的话 iPad 13" 横屏一行 70+ 个汉字，而且段内的 FlowLayout
                // 会把三四个句子塞进同一行，chip 边框给的句子边界线索被稀释成一片色块。
                //
                // 放在这里而不是三个调用方：ReaderView / BookReaderView /
                // MediaPlayerView 的全文稿共用本视图，改一处三处都好。
                .readableTextWidth(fontSize: fontSize)
            }
            .coordinateSpace(name: Self.scrollSpace)
            .onPreferenceChange(VisibleParagraphKey.self) { offsets in
                guard let order = Self.topmostVisible(offsets) else { return }
                onVisibleOrderChanged?(order)
            }
            .task(id: restoreOrder) { restore(with: proxy) }
        }
    }

    /// 续读定位：滚到目标句所在段落的顶部。
    /// LazyVStack 未布局到的行没有 id，等一帧再滚。
    private func restore(with proxy: ScrollViewProxy) {
        guard let restoreOrder, restoreOrder > 0, !segments.isEmpty else { return }
        let anchor = paragraphs
            .compactMap(\.first?.order)
            .last { $0 <= restoreOrder }
        guard let anchor else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            proxy.scrollTo(anchor, anchor: .top)
        }
    }

    private func offsetReporter(order: Int) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: VisibleParagraphKey.self,
                value: [order: geometry.frame(in: .named(Self.scrollSpace)).minY])
        }
    }

    /// 视口顶部那一段：取所有 minY ≤ 0 中最大的（刚滚过顶边的那段），
    /// 全部在顶边以下时取最靠上的一段。
    static func topmostVisible(_ offsets: [Int: CGFloat]) -> Int? {
        guard !offsets.isEmpty else { return nil }
        let above = offsets.filter { $0.value <= 1 }
        if let best = above.max(by: { $0.value < $1.value }) { return best.key }
        return offsets.min(by: { $0.value < $1.value })?.key
    }

    // MARK: - 段落渲染

    @ViewBuilder
    private func paragraphView(_ paragraph: [ArticleSegment]) -> some View {
        switch viewMode {
        case .original:
            FlowLayout {
                ForEach(paragraph) { segment in
                    chip(for: segment)
                }
            }
        case .bilingual:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(paragraph) { segment in
                    VStack(alignment: .leading, spacing: 4) {
                        // 词级注音是整句注音行的超集，两个同时显示纯属冗余。
                        if let reading = segment.readingText, readingRuns[segment.id] == nil {
                            Text(reading)
                                .font(.system(size: fontSize * 0.8).monospaced())
                                .foregroundStyle(theme.mutedForeground)
                        }
                        chip(for: segment)
                        if let translation = segment.translation {
                            TranslationBox(translation)
                                .font(.system(size: fontSize * 0.95))
                        }
                    }
                }
            }
        case .translation:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(paragraph) { segment in
                    if let translation = segment.translation {
                        Text(translation)
                            .font(.system(size: fontSize))
                            .foregroundStyle(theme.foreground)
                    } else {
                        // 未翻译句显示原文占位，不允许"正文消失"（设计文档 §6.4）
                        Button {
                            selectedSegmentID = segment.id
                        } label: {
                            (Text(segment.text) + Text(" ↻"))
                                .font(.system(size: fontSize))
                                .foregroundStyle(theme.mutedForeground)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func chip(for segment: ArticleSegment) -> some View {
        let base = SentenceChip(
            text: segment.text,
            state: segment.explanation != nil ? .explained
                : segment.translation != nil ? .translated : .plain,
            isSelected: segment.id == selectedSegmentID,
            fontSize: fontSize,
            runs: readingRuns[segment.id]?.map { RubyRun(text: $0.text, reading: $0.reading) }
        ) {
            selectedSegmentID = segment.id
        }
        // 划线用底色标注。不给 SentenceChip 加新状态——那是设计系统的公共组件，
        // "被标记"是书籍域的概念，留在这一层。
        .background(
            markedOrders.contains(segment.order)
                ? theme.vocabAccent.opacity(0.18) : .clear,
            in: RoundedRectangle(cornerRadius: OKRadius.chip))

        if let onMark {
            base.contextMenu {
                Button {
                    onMark(segment, .bookmark)
                } label: {
                    Label(L("bookmark.add"), systemImage: "bookmark")
                }
                Button {
                    onMark(segment, .highlight)
                } label: {
                    Label(L("bookmark.highlight"), systemImage: "highlighter")
                }
            }
        } else {
            base
        }
    }
}

/// 各段落在滚动坐标系里的纵向偏移。LazyVStack 只布局可见行，字典因此很小。
private struct VisibleParagraphKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] { [:] }

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}
#endif
