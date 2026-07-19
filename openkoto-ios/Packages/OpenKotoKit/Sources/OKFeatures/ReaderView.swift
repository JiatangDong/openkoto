#if os(iOS)
import SwiftUI
import OKModels
import OKDesignSystem
import OKLocalization

enum ReaderViewMode: String, CaseIterable, Identifiable {
    case original
    case bilingual
    case translation

    var id: String { rawValue }

    var titleKey: String.LocalizationValue {
        switch self {
        case .original: "reader.mode.original"
        case .bilingual: "reader.mode.bilingual"
        case .translation: "reader.mode.translation"
        }
    }
}

/// 阅读器（核心屏幕，设计文档 §6.4）：
/// 段落 LazyVStack 虚拟化 + 段内 FlowLayout 逐句 chip，
/// 点句弹出半屏 ExplanationSheet（半屏时正文仍可滚动换句）。
struct ReaderView: View {
    @Environment(ContentStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase

    let article: Article

    @AppStorage("reader.fontSize") private var fontSize: Double = 18
    @State private var viewMode: ReaderViewMode = .original
    @State private var selectedSegmentID: UUID?
    /// 本段前台阅读计时起点(阅读时长统计用)。
    @State private var readingStart: Date?

    private var segments: [ArticleSegment] {
        store.segments(for: article.id)
    }

    /// 按 isNewParagraph 分组成段落
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

    /// 结算本段前台阅读时长：丢弃 <3s(噪声)与 >2h(挂机)，否则落一条阅读会话。
    private func flushReadingSession() {
        guard let start = readingStart else { return }
        readingStart = nil
        let elapsed = Int(Date().timeIntervalSince(start))
        guard elapsed >= 3, elapsed <= 2 * 60 * 60 else { return }
        let articleID = article.id
        Task { await store.recordReadingSession(
            articleId: articleID, seconds: elapsed, startedAt: start) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CGFloat(fontSize)) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    paragraphView(paragraph)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .background(theme.background)
        .safeAreaInset(edge: .bottom) { batchBar }
        .onAppear {
            readingStart = Date()
            // 截图/UI 测试用：自动选中第一句（含预置精讲）
            if ProcessInfo.processInfo.arguments.contains("-prototypeDemo") {
                selectedSegmentID = segments.first?.id
            }
        }
        .onDisappear { flushReadingSession() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                if readingStart == nil { readingStart = Date() }
            case .inactive, .background:
                flushReadingSession()
            @unknown default:
                break
            }
        }
        .navigationTitle(article.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { readerToolbar }
        .sheet(
            isPresented: Binding(
                get: { selectedSegmentID != nil },
                set: { if !$0 { selectedSegmentID = nil } }
            )
        ) {
            if let segmentID = selectedSegmentID {
                ExplanationSheet(
                    article: article,
                    segmentID: segmentID,
                    onSelectSegment: { selectedSegmentID = $0 }
                )
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
        }
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
                        if let reading = segment.readingText {
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
                        // 未翻译句显示原文占位，不允许“正文消失”（设计文档 §6.4）
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

    private func chip(for segment: ArticleSegment) -> some View {
        SentenceChip(
            text: segment.text,
            state: segment.explanation != nil ? .explained
                : segment.translation != nil ? .translated : .plain,
            isSelected: segment.id == selectedSegmentID,
            fontSize: fontSize
        ) {
            selectedSegmentID = segment.id
        }
    }

    // MARK: - 批量任务进度条

    @ViewBuilder
    private var batchBar: some View {
        if let state = store.batchByArticle[article.id] {
            let fraction = state.total > 0
                ? Double(state.completed) / Double(state.total) : 0
            VStack(spacing: 6) {
                HStack {
                    Text(L(state.kind == .explain
                        ? "reader.batch.explaining" : "reader.batch.translating"))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(theme.foreground)
                    Spacer()
                    Text(verbatim: "\(state.completed)/\(state.total)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(theme.mutedForeground)
                    Button(L("reader.batch.cancel")) {
                        store.cancelBatch(articleID: article.id)
                    }
                    .font(.footnote)
                }
                ProgressView(value: fraction)
                    .tint(theme.primary)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                let progress = store.progress(for: article.id)
                let running = store.isBatchRunning(articleID: article.id)
                Section {
                    Button {
                        store.batchExplainAll(articleID: article.id)
                    } label: {
                        Label(L("reader.batch.explainAll"), systemImage: "sparkles")
                    }
                    .disabled(running || progress.explained >= progress.total)
                    Button {
                        store.batchTranslateAll(articleID: article.id)
                    } label: {
                        Label(L("reader.batch.translateAll"), systemImage: "character.book.closed")
                    }
                    .disabled(running)
                }
                Picker(selection: $viewMode, label: Text("")) {
                    ForEach(ReaderViewMode.allCases) { mode in
                        Text(L(mode.titleKey)).tag(mode)
                    }
                }
                Section(L("reader.fontSize")) {
                    Stepper(
                        value: $fontSize,
                        in: 12...32,
                        step: 2
                    ) {
                        Text(verbatim: "\(Int(fontSize)) pt")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}
#endif
