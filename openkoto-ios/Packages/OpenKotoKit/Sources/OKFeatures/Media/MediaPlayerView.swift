#if os(iOS)
import OKDesignSystem
import OKLocalization
import OKModels
import SwiftUI

/// 媒体播放页：画面 + 传输条 + 字幕列表 + 精讲弹窗。
///
/// 学习管线一行不改就复用：字幕句就是 `ArticleSegment`，
/// 所以 `ExplanationSheet` 原样拿来即可（含上一句/下一句、朗读、收藏生词）。
struct MediaPlayerView: View {
    @Environment(ContentStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase

    let media: Media
    /// 从搜索结果进来时定位到的句序：选中它并把播放位置也跳过去。
    var initialSegmentOrder: Int?

    @AppStorage("reader.fontSize") private var fontSize: Double = 18
    @AppStorage("reader.showReading") private var showReading = false

    @State private var playback = PlaybackModel()
    @State private var selectedSegmentID: UUID?
    @State private var showTranscript = false
    @State private var showTranscribe = false
    @State private var batchKind: ContentStore.BatchState.Kind?
    @State private var isLoaded = false
    @State private var lastSavedAt: Date?
    /// 盲听：遮住字幕，逼自己先用耳朵听。**不持久化**——下次点开视频却看不见字幕，
    /// 用户只会以为字幕丢了。
    @State private var isBlind = false
    /// 盲听中临时揭晓的那一句；播放推进到下一句就重新遮上。
    @State private var revealedID: UUID?

    /// 端上转写要 iOS 26，且必须真的有媒体文件可读。
    private var canTranscribe: Bool {
        guard #available(iOS 26, *) else { return false }
        return store.mediaFileURL(for: media) != nil
    }

    /// 播放位置写库的最小间隔——每秒十次写库没有意义。
    private static let saveInterval: TimeInterval = 3

    private var articleID: UUID? { store.mediaArticleID(for: media.id) }
    private var article: Article? { articleID.flatMap { store.chapterArticle(id: $0) } }
    private var segments: [ArticleSegment] { articleID.map { store.segments(for: $0) } ?? [] }
    /// 当前播放到的句序，作为批量范围的默认起点。
    private var currentOrder: Int {
        guard let activeID = playback.activeID,
            let segment = segments.first(where: { $0.id == activeID })
        else { return 0 }
        return segment.order
    }

    private var readingRuns: [UUID: [ReadingRun]] {
        guard showReading, let articleID else { return [:] }
        return store.readingRuns(for: articleID)
    }

    var body: some View {
        VStack(spacing: 0) {
            MediaSurface(
                media: media, player: playback.player,
                isAvailable: store.mediaFileURL(for: media) != nil)
            TransportBar(
                currentTime: playback.currentTime,
                duration: playback.duration,
                isPlaying: playback.isPlaying,
                isEnabled: playback.canPlay,
                isBlind: isBlind,
                rate: $playback.rate,
                onTogglePlay: { playback.togglePlay() },
                onSkip: { playback.skip(by: $0) },
                onScrub: { playback.seek(to: $0) },
                onToggleBlind: { toggleBlind() })
            Divider()
            SubtitleListView(
                segments: segments,
                activeID: playback.activeID,
                isInGap: playback.isInGap,
                selectedID: selectedSegmentID,
                loopingID: playback.loopingSegmentID,
                readingRuns: readingRuns,
                fontSize: fontSize,
                isBlind: isBlind,
                revealedID: revealedID,
                onTap: { segment in
                    // 盲听时第一下是"揭晓"，再点才跳过去：
                    // 想看一眼的人不会被意外跳走，想跳的人多点一下也到得了。
                    if isBlind, revealedID != segment.id {
                        revealedID = segment.id
                        return
                    }
                    playback.seek(toSegment: segment.id)
                    saveProgress(force: true)
                },
                onExplain: { selectedSegmentID = $0.id },
                onToggleLoop: { playback.toggleLoop(segmentID: $0.id) })
        }
        .background(theme.background)
        .explanationPane(article: article, selection: $selectedSegmentID)
        .navigationTitle(media.title)
        .navigationBarTitleDisplayMode(.inline)
        .hidesAppTabBar()
        .toolbar { playerToolbar }
        .task(id: media.id) { await loadIfNeeded() }
        .onDisappear {
            saveProgress(force: true)
            playback.teardown()
        }
        .onChange(of: scenePhase) {
            // 后台不承诺继续播（没开 UIBackgroundModes），进后台就存位置并暂停。
            if scenePhase != .active {
                playback.pause()
                saveProgress(force: true)
            }
        }
        .onChange(of: playback.currentTime) { saveProgress(force: false) }
        // 播到下一句就重新遮上——单句循环时 activeID 不变，揭晓会一直留着，正合跟读所需。
        .onChange(of: playback.activeID) { revealedID = nil }
        .sheet(item: $batchKind) { kind in
            if let articleID {
                BatchScopeSheet(
                    articleID: articleID, kind: kind,
                    currentOrder: currentOrder)
                    .presentationDetents([.medium])
                    .okSheetSizing(.form)
            }
        }
        .sheet(isPresented: $showTranscribe) {
            if #available(iOS 26, *) {
                TranscribeSheet(media: media)
            }
        }
        .sheet(isPresented: $showTranscript) {
            if let article {
                NavigationStack {
                    // 「当文章读」白捡的功能：字幕句就是普通 segment，
                    // 直接把现成的正文渲染器拿过来即可。
                    NativeChapterView(
                        segments: segments,
                        selectedSegmentID: $selectedSegmentID,
                        fontSize: fontSize,
                        viewMode: .original,
                        readingRuns: readingRuns
                    )
                    .background(theme.background)
                    .navigationTitle(article.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L("common.close")) { showTranscript = false }
                        }
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var playerToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Toggle(isOn: $showReading) {
                    Label(L("reader.showReading"), systemImage: "character.phonetic")
                }
                .disabled(articleID.map { store.readingRuns(for: $0).isEmpty } ?? true)
                Button {
                    showTranscript = true
                } label: {
                    Label(L("media.readAsArticle"), systemImage: "text.alignleft")
                }
                if canTranscribe {
                    Button {
                        showTranscribe = true
                    } label: {
                        Label(
                            segments.isEmpty
                                ? L("media.transcribe.generate") : L("media.transcribe.redo"),
                            systemImage: "waveform.badge.mic")
                    }
                }
                // 批量任务对视频**必须**先划范围：一小时视频 600 句，
                // 一键全做就是 600 次调用。
                if !segments.isEmpty {
                    Section {
                        Button {
                            batchKind = .explain
                        } label: {
                            Label(L("reader.batch.explainAll"), systemImage: "sparkles")
                        }
                        Button {
                            batchKind = .translate
                        } label: {
                            Label(
                                L("reader.batch.translateAll"),
                                systemImage: "character.book.closed")
                        }
                    }
                    .disabled(articleID.map { store.isBatchRunning(articleID: $0) } ?? true)
                }
                if shadowingTarget != nil {
                    Button {
                        toggleShadowing()
                    } label: {
                        Label(
                            isShadowing ? L("media.shadowing.stop") : L("media.shadowing.start"),
                            systemImage: isShadowing
                                ? "person.wave.2.fill" : "person.wave.2")
                    }
                }
                if playback.loopingSegmentID != nil {
                    Button {
                        playback.stopLooping()
                    } label: {
                        Label(L("media.loop.stop"), systemImage: "repeat.1")
                    }
                }
                Section(L("reader.fontSize")) {
                    Stepper(value: $fontSize, in: 12...32, step: 2) {
                        Text(verbatim: "\(Int(fontSize)) pt")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - 跟读

    private var isShadowing: Bool {
        Shadowing.isActive(
            isBlind: isBlind, loopingSegmentID: playback.loopingSegmentID, rate: playback.rate)
    }

    /// 跟读要循环的那一句：优先当前播放句，否则第一句可循环的——
    /// 别让入口在刚打开、还没播的时候是个死键。
    private var shadowingTarget: UUID? {
        if let activeID = playback.activeID,
            let segment = segments.first(where: { $0.id == activeID }),
            Shadowing.isLoopable(segment)
        {
            return activeID
        }
        return segments.first(where: Shadowing.isLoopable)?.id
    }

    /// 一键进入跟读姿势：当前句循环 + 放慢 + 盲听。
    private func toggleShadowing() {
        let next = Shadowing.toggled(
            isBlind: isBlind, loopingSegmentID: playback.loopingSegmentID,
            rate: playback.rate, target: shadowingTarget)
        if next.loopSegmentID != playback.loopingSegmentID {
            if let id = next.loopSegmentID {
                playback.toggleLoop(segmentID: id)
            } else {
                playback.stopLooping()
            }
        }
        playback.rate = next.rate
        isBlind = next.isBlind
        revealedID = nil
    }

    private func toggleBlind() {
        isBlind.toggle()
        revealedID = nil
    }

    private func loadIfNeeded() async {
        guard let articleID else { return }
        await store.openArticle(articleID)
        guard !isLoaded else { return }
        isLoaded = true
        playback.load(
            url: store.mediaFileURL(for: media),
            segments: store.segments(for: articleID),
            startAt: store.progress(ofMedia: media.id)?.position ?? 0)
        // 从搜索结果进来：定位到那一句，并把播放位置也带过去
        if let order = initialSegmentOrder,
            let target = store.segments(for: articleID).first(where: { $0.order == order })
        {
            selectedSegmentID = target.id
            playback.seek(toSegment: target.id, autoPlay: false)
        }
    }

    /// 节流写库。位置只是便利功能，丢一点无所谓，写太勤才是问题。
    private func saveProgress(force: Bool) {
        guard playback.duration > 0 || playback.currentTime > 0 else { return }
        let now = Date()
        if !force, let lastSavedAt, now.timeIntervalSince(lastSavedAt) < Self.saveInterval {
            return
        }
        lastSavedAt = now
        store.saveMediaProgress(
            MediaProgress(
                mediaId: media.id, position: playback.currentTime,
                rate: Double(playback.rate), updatedAt: now))
    }
}
#endif
