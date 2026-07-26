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
    /// 从搜索结果进来时定位到的句序。`NativeChapterView.restoreOrder` 已支持滚到指定句，
    /// 这里只是把值传下去。
    var initialSegmentOrder: Int?

    @AppStorage("reader.fontSize") private var fontSize: Double = 18
    /// 词级读音开关。与三种视图模式正交（哪种模式下都可能想看读音），所以不做成第四种 mode。
    @AppStorage("reader.showReading") private var showReading = false
    @State private var viewMode: ReaderViewMode = .original
    @State private var selectedSegmentID: UUID?
    /// 本段前台阅读计时起点(阅读时长统计用)。
    @State private var readingStart: Date?

    private var segments: [ArticleSegment] {
        store.segments(for: article.id)
    }

    private var readingRuns: [UUID: [ReadingRun]] {
        showReading ? store.readingRuns(for: article.id) : [:]
    }

    /// 这篇文章有没有可显示的读音。没有时把开关灰掉并说明，好过让用户点了没反应。
    private var hasReadings: Bool { !store.readingRuns(for: article.id).isEmpty }

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
        NativeChapterView(
            segments: segments,
            selectedSegmentID: $selectedSegmentID,
            fontSize: fontSize,
            viewMode: viewMode,
            restoreOrder: initialSegmentOrder,
            readingRuns: readingRuns
        )
        .background(theme.background)
        .safeAreaInset(edge: .bottom) { batchBar }
        // 句子按需加载：启动时只查计数，进阅读器才把这篇的句子读进内存。
        .task(id: article.id) {
            await store.openArticle(article.id)
            // 截图/UI 测试用：自动选中第一句（含预置精讲）。
            // 必须等 openArticle 之后——句子现在是懒加载的，onAppear 时还是空的。
            if ProcessInfo.processInfo.arguments.contains("-prototypeDemo") {
                selectedSegmentID = segments.first?.id
            }
        }
        .onAppear { readingStart = Date() }
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
        // 阅读时收起底部 tab 栏：正文多一行，返回上一级会自动恢复。
        .toolbar(.hidden, for: .tabBar)
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

    // MARK: - 批量任务进度条

    private var batchBar: some View {
        BatchProgressBar(articleID: article.id)
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
        // 常驻按钮：唱歌/跟读时要频繁开关，藏进菜单太深。
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showReading.toggle()
            } label: {
                Image(systemName: "character.phonetic")
                    .foregroundStyle(showReading ? theme.primary : theme.mutedForeground)
            }
            .disabled(!hasReadings)
            .accessibilityLabel(Text(L("reader.showReading")))
            .accessibilityAddTraits(showReading ? .isSelected : [])
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section {
                    Toggle(isOn: $showReading) {
                        Label(L("reader.showReading"), systemImage: "character.phonetic")
                    }
                    .disabled(!hasReadings)
                } header: {
                    if !hasReadings { Text(L("reader.reading.unavailable")) }
                }
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
