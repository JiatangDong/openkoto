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
    @Environment(\.okCanvas) private var canvas
    @Environment(\.scenePhase) private var scenePhase

    let media: Media
    /// 从搜索结果进来时定位到的句序：选中它并把播放位置也跳过去。
    var initialSegmentOrder: Int?

    @AppStorage("reader.fontSize") private var fontSize: Double = 18
    @AppStorage("reader.showReading") private var showReading = false
    /// 字幕显示：原文 / 对照 / 只看译文。与阅读器共用同一套模式，
    /// 但**单独存一个键**——看视频和读文章想要的默认形态不一样。
    @AppStorage("media.viewMode") private var viewMode: ReaderViewMode = .original

    /// 媒体页的三个弹窗收敛成一个。
    ///
    /// **多个 `.sheet` 叠在同一个 view 上，`dismiss()` 会失灵。** 弹是弹得出来的
    /// （哪个 binding 变 true 就弹哪个），但被展示内容拿到的 `dismiss` 环境值绑的是
    /// 最后一个 `.sheet` 修饰符的那个 presentation —— 于是「全文翻译」范围窗里的
    /// 「取消」实际是把一个本来就为 false 的 binding 又置了一次 false，窗口纹丝不动。
    /// 用户看到的就是"取消点了没有任何反应，只能强退"。
    ///
    /// 与 `LibraryView` 把三个 `.fileImporter` 收敛成一个是同一条教训：
    /// **一个 view 只挂一个 presentation。**
    private enum PlayerSheet: Identifiable {
        case batch(ContentStore.BatchState.Kind)
        case transcribe
        case transcript

        var id: String {
            switch self {
            case .batch(let kind): "batch-\(kind.rawValue)"
            case .transcribe: "transcribe"
            case .transcript: "transcript"
            }
        }
    }

    @State private var playback = PlaybackModel()
    @State private var selectedSegmentID: UUID?
    @State private var activeSheet: PlayerSheet?
    @State private var isLoaded = false
    @State private var lastSavedAt: Date?
    /// 盲听：遮住字幕，逼自己先用耳朵听。**不持久化**——下次点开视频却看不见字幕，
    /// 用户只会以为字幕丢了。
    @State private var isBlind = false
    /// 盲听中临时揭晓的那一句；播放推进到下一句就重新遮上。
    @State private var revealedID: UUID?
    /// 媒体文件位置，开页时解析一次就存住。
    ///
    /// **不能在 body 里现算。** `store.mediaFileURL` 解析 bookmark 要走 XPC，
    /// 而这个 body 跟着 `currentTime` 高频重算——实测两分钟 251 次 XPC 往返，
    /// 且那个 agent 的连接一断（休眠唤醒后必现）解析就返回 nil，
    /// 界面随即翻成"媒体文件不可用"。详见 `ContentStore.resolvedMediaURLs`。
    @State private var mediaURL: URL?

    /// 端上转写要 iOS 26，且必须真的有媒体文件可读。
    private var canTranscribe: Bool {
        guard #available(iOS 26, *) else { return false }
        return mediaURL != nil
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

    /// 段落集合的指纹，用来发现「字幕换了一批」。
    ///
    /// 不直接比 `[ArticleSegment]`：744 句每次 body 求值都做一次全量比较不值当，
    /// 而转写/重转写一定会改变句数或首尾句，这三项足够识别。
    private struct TimelineKey: Equatable {
        let count: Int
        let firstID: UUID?
        let lastID: UUID?
    }

    private var timelineKey: TimelineKey {
        TimelineKey(count: segments.count, firstID: segments.first?.id, lastID: segments.last?.id)
    }

    private var readingRuns: [UUID: [ReadingRun]] {
        guard showReading, let articleID else { return [:] }
        return store.readingRuns(for: articleID)
    }

    var body: some View {
        VStack(spacing: 0) {
            MediaSurface(
                media: media, player: playback.player,
                // 文件"找得到"不等于"读得了"：权限没拿到 / 文件损坏 / iCloud 没下完，
                // 都是解析得出 URL 但资产加载失败。这两种都归到"媒体不可用"，
                // 别让用户对着一块沉默的黑屏猜。
                isAvailable: mediaURL != nil && !playback.isUnplayable)
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
                viewMode: viewMode,
                isBlind: isBlind,
                revealedID: revealedID,
                onTap: { segment in
                    // 盲听时第一下是"揭晓"，再点才跳过去：
                    // 想看一眼的人不会被意外跳走，想跳的人多点一下也到得了。
                    if isBlind, revealedID != segment.id {
                        revealedID = segment.id
                        return
                    }
                    // 宽屏右栏常驻，点哪句就讲哪句——右栏占位文案写的就是这个约定
                    // （「点正文里的任意一句，讲解会显示在这里」），此前媒体页却只跳转不选中，
                    // 于是照着提示点了半天右栏一直是空的。
                    // 窄屏**不**跟着选：那会在每次点句跳转时弹出半屏 sheet 盖住字幕列表，
                    // iPhone 上仍走长按菜单里的「精讲」。
                    if canvas.isWide { selectedSegmentID = segment.id }
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
        // 转写完成后 segments 从 0 条变成几百条，必须让 playback 重建时间轴。
        // 少了这一步，字幕会照常显示，但当前句不高亮、列表不自动滚、点字幕也跳不过去。
        .onChange(of: timelineKey) { playback.updateTimeline(segments: segments) }
        // 播到下一句就重新遮上——单句循环时 activeID 不变，揭晓会一直留着，正合跟读所需。
        .onChange(of: playback.activeID) { revealedID = nil }
        // **只能有一个。** 见 `PlayerSheet` 的注释：叠多个的话弹得出来但关不掉。
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .batch(let kind):
                if let articleID {
                    BatchScopeSheet(
                        articleID: articleID, kind: kind,
                        currentOrder: currentOrder)
                        .presentationDetents([.medium])
                        .okSheetSizing(.form)
                }
            case .transcribe:
                if #available(iOS 26, *) {
                    TranscribeSheet(media: media)
                }
            case .transcript:
                if let article {
                    NavigationStack {
                        // 「当文章读」白捡的功能：字幕句就是普通 segment，
                        // 直接把现成的正文渲染器拿过来即可。
                        NativeChapterView(
                            segments: segments,
                            selectedSegmentID: $selectedSegmentID,
                            fontSize: fontSize,
                            // 跟着字幕列表的显示模式走：在列表里选了「译文」，
                            // 进「当文章读」却又变回原文，只会让人以为设置没生效。
                            viewMode: viewMode,
                            readingRuns: readingRuns
                        )
                        .background(theme.background)
                        .navigationTitle(article.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(L("common.close")) { activeSheet = nil }
                            }
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
                // 原文 / 对照 / 译文。与阅读器同一套模式、同一套文案——
                // 全文翻译完之后想「只看译文」或「对照着看」，入口就在这。
                Picker(selection: $viewMode, label: Text(verbatim: "")) {
                    ForEach(ReaderViewMode.allCases) { mode in
                        Text(L(mode.titleKey)).tag(mode)
                    }
                }
                Toggle(isOn: $showReading) {
                    Label(L("reader.showReading"), systemImage: "character.phonetic")
                }
                .disabled(articleID.map { store.readingRuns(for: $0).isEmpty } ?? true)
                Button {
                    activeSheet = .transcript
                } label: {
                    Label(L("media.readAsArticle"), systemImage: "text.alignleft")
                }
                if canTranscribe {
                    Button {
                        activeSheet = .transcribe
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
                            activeSheet = .batch(.explain)
                        } label: {
                            Label(L("reader.batch.explainAll"), systemImage: "sparkles")
                        }
                        Button {
                            activeSheet = .batch(.translate)
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
        // 整个播放会话只解析这一次，之后 body 读的都是这个 @State。
        mediaURL = store.mediaFileURL(for: media)
        playback.load(
            url: mediaURL,
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
        // 资产没加载成功时**一个字都不写**。
        //
        // 原条件是 `duration > 0 || currentTime > 0`：读不到文件时 `load` 里那次
        // `seek(to: 上次位置)` 会先把 currentTime 顶成 410，条件通过；紧接着
        // 时间观察者按死掉的 item 回调 0，于是把用户真实的观看位置覆写成 0。
        // 一次打不开，进度就永久没了。
        guard playback.duration > 0 else { return }
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
