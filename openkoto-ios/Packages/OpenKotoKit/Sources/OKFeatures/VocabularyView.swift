#if os(iOS)
import SwiftUI
import OKModels
import OKDesignSystem
import OKLocalization

/// 生词本(设计文档 §6.5 + SRS 规范):统计头 + 搜索 + 列表 + 复习入口。
struct VocabularyView: View {
    @Environment(ContentStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.okCanvas) private var canvas
    @State private var speech = SpeechService()
    @State private var searchText = ""
    @State private var isAddPresented = false
    @State private var isPackManagerPresented = false
    @State private var editingFavorite: FavoriteVocabulary?
    @State private var previewFavorite: FavoriteVocabulary?

    /// 今日清空后底部按钮改开提前复习，两种情况共用同一个 sheet。
    ///
    /// 用 `.sheet(item:)` 而不是「一个 Bool + 一个模式变量」：后者要在同一次动作里
    /// 改两个 state，sheet 的内容闭包可能拿着**旧的**模式先构造一次，
    /// `ReviewSessionView` 的 `@State` 只初始化一次，于是点「提前复习」开出来的是普通复习。
    private struct ReviewSession: Identifiable {
        let id = UUID()
        let mode: ReviewSessionView.Mode
    }
    @State private var reviewSession: ReviewSession?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                packChips
                Group {
                    if store.favorites.isEmpty {
                        ContentUnavailableView(
                            L("tab.vocabulary"),
                            systemImage: "star",
                            description: Text(L("vocabulary.empty"))
                        )
                    } else {
                        list
                    }
                }
            }
            // 限宽放在 chip 条和列表的共同父节点上，两者才会对齐。
            // 只限列表的话，chip 会孤零零贴在最左边。
            .frame(maxWidth: canvas.isWide ? Self.contentMaxWidth : .infinity)
            .frame(maxWidth: .infinity)
            .background(theme.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isAddPresented = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(L("vocabulary.addWord"))
                }
            }
            .sheet(item: $reviewSession) { session in
                // 关 sheet 与置跳转在同一次状态更新里完成：SwiftUI 一个事务处理完，
                // 视觉上是"卡片消失，人已经在原文里了"，不会先看到 sheet 落下再跳一次。
                ReviewSessionView(
                    onOpenSource: { jump in
                        reviewSession = nil
                        store.pendingJump = jump
                    },
                    initialMode: session.mode)
            }
            .sheet(isPresented: $isAddPresented) {
                VocabEditSheet(favorite: nil)
            }
            .sheet(isPresented: $isPackManagerPresented) {
                PackManagerSheet()
            }
            .sheet(item: $editingFavorite) { favorite in
                VocabEditSheet(favorite: favorite)
            }
            .sheet(item: $previewFavorite) { favorite in
                SourcePreviewSheet(favorite: favorite) { jump in
                    previewFavorite = nil
                    store.pendingJump = jump
                }
            }
            .onChange(of: store.activePackId) {
                Task { await store.refreshStats() }
            }
        }
    }

    /// 当前选中合集内的收藏(nil = 全部)。
    private var packFavorites: [FavoriteVocabulary] {
        guard let packId = store.activePackId else { return store.favorites }
        return store.favorites.filter { $0.packIds.contains(packId) }
    }

    private var filteredFavorites: [FavoriteVocabulary] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return packFavorites }
        return packFavorites.filter { favorite in
            favorite.word.lowercased().contains(query)
                || favorite.meaning.lowercased().contains(query)
                || (favorite.reading ?? "").lowercased().contains(query)
        }
    }

    /// 与 `dueQueue` 同口径：坏日期（含空串）视为已到期。
    /// 两边不一致的话，底部按钮会在队列还有卡时就换成「提前复习」。
    private var dueTodayCount: Int {
        let today = ContentStore.localDateString()
        return packFavorites.count {
            $0.suspendedAt == nil && ($0.dueDate.count != 10 || $0.dueDate <= today)
        }
    }

    /// 合集筛选条。窄屏横滚（chip 多了也不占高度）；
    /// 宽屏改用现成的 FlowLayout 自动折行——横滚条在 1000pt 宽下只挤在最左边，
    /// 右边一大片空，还得拖着找。
    @ViewBuilder
    private var packChips: some View {
        if canvas.isWide {
            FlowLayout(lineSpacing: 8, itemSpacing: 8) { packChipItems }
                .padding(.horizontal)
                .padding(.vertical, 8)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { packChipItems }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private var packChipItems: some View {
        chip(L("vocabulary.packAll"), isSelected: store.activePackId == nil) {
            store.activePackId = nil
        }
        ForEach(store.packs) { pack in
            chip(PackDisplay.name(pack), isSelected: store.activePackId == pack.id) {
                store.activePackId = pack.id
            }
        }
        Button {
            isPackManagerPresented = true
        } label: {
            Image(systemName: "folder.badge.gearshape")
                .font(.subheadline)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(theme.muted, in: Capsule())
                .foregroundStyle(theme.mutedForeground)
        }
        .accessibilityLabel(L("vocabulary.packListTitle"))
    }

    private func chip(
        _ label: String, isSelected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? theme.primary : theme.muted, in: Capsule())
                .foregroundStyle(isSelected ? theme.primaryForeground : theme.mutedForeground)
        }
        .buttonStyle(.plain)
    }

    private var list: some View {
        List {
            Section {
                statsHeader
                    .listRowBackground(theme.card)
            }
            Section {
                ForEach(filteredFavorites) { favorite in
                    row(favorite)
                        .listRowBackground(theme.card)
                        .contentShape(Rectangle())
                        .onTapGesture { editingFavorite = favorite }
                        // 同时产出右键菜单：Mac 上横扫不可用，
                        // 「标记掌握」「回原文」只写 swipe 的话会变成不可达功能。
                        .okRowActions(
                            leading: rowLeadingActions(favorite),
                            trailing: [
                                OKRowAction(
                                    title: L("common.delete"), systemImage: "trash",
                                    role: .destructive
                                ) {
                                    store.removeFavorite(favorite.id)
                                }
                            ])
                }
            }
        }
        .scrollContentBackground(.hidden)
        .searchable(text: $searchText, prompt: Text(L("vocabulary.searchPrompt")))
        .safeAreaInset(edge: .bottom) {
            reviewButton
        }
    }

    /// 生词行只有一个词加一句释义，横跨 1300pt 会让视线在两端来回跑，
    /// 所以限宽居中；但不改多列——网格里放横扫手势是反模式。
    private static let contentMaxWidth: CGFloat = 760

    private var statsHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 24) {
                stat(L("vocabulary.total"), value: packFavorites.count)
                stat(L("vocabulary.dueToday"), value: dueTodayCount)
                if let stats = store.reviewStats {
                    stat(L("vocabulary.streak"), value: stats.streakDays)
                }
            }
            if let stats = store.reviewStats {
                HStack(spacing: 12) {
                    distributionChip(L("vocabulary.stateNew"), count: stats.countNew,
                                     color: theme.mutedForeground.opacity(0.6))
                    distributionChip(L("vocabulary.stateLearning"), count: stats.countLearning,
                                     color: theme.srsFading)
                    distributionChip(L("vocabulary.stateReview"), count: stats.countReview,
                                     color: theme.srsStrong)
                    distributionChip(L("vocabulary.stateMastered"), count: stats.countSuspended,
                                     color: theme.mutedForeground)
                }
                // 与复习页的进度条同口径：只数今天答对了的。
                Text(L("vocabulary.todayProgress\(stats.passedNewToday)\(stats.passedReviewToday)"))
                    .font(.caption)
                    .foregroundStyle(theme.mutedForeground)
            }
        }
        .padding(.vertical, 2)
    }

    /// 今日清空了就换成「提前复习」，而不是给一个点不动的灰按钮——
    /// 真正无事可做（一张未来到期的卡都没有）时才置灰。
    private var reviewButton: some View {
        let isAhead = dueTodayCount == 0
        let canStart = isAhead ? store.aheadAvailableCount > 0 : true
        return Button {
            reviewSession = .init(mode: isAhead ? .ahead : .due)
        } label: {
            Label(
                isAhead ? L("vocabulary.startAhead") : L("vocabulary.startReview"),
                systemImage: isAhead ? "arrow.clockwise" : "rectangle.on.rectangle.angled")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(isAhead ? theme.srsFading : theme.primary)
        // 内层 maxWidth:.infinity 让文字在按钮里居中；
        // 这里再夹一层，否则宽屏上会变成横跨整屏的巨型按钮。
        .frame(maxWidth: canvas.isWide ? 420 : .infinity)
        .padding(.horizontal)
        .padding(.bottom, 4)
        .disabled(!canStart)
        // 底栏必须整条铺满并带底色：safeAreaInset 只是给列表让出高度，
        // 按钮收窄后，列表内容会从按钮两侧的空隙里露出来。
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func stat(_ label: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.title2.bold().monospacedDigit())
                .foregroundStyle(theme.primary)
            Text(label)
                .font(.caption)
                .foregroundStyle(theme.mutedForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func distributionChip(_ label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(label) \(count)")
                .font(.caption2)
                .foregroundStyle(theme.mutedForeground)
        }
    }

    /// 行首侧操作：掌握/恢复复习，以及有出处时的「回原文」。
    private func rowLeadingActions(_ favorite: FavoriteVocabulary) -> [OKRowAction] {
        let isSuspended = favorite.suspendedAt != nil
        var actions = [
            OKRowAction(
                title: isSuspended ? L("vocabulary.resumeReview") : L("vocabulary.markMastered"),
                systemImage: isSuspended ? "arrow.counterclockwise" : "checkmark.circle",
                tint: isSuspended ? theme.srsFading : theme.srsStrong
            ) {
                store.setSuspended(favorite.id, suspended: !isSuspended)
            }
        ]
        // 出处：先弹详情（句子 + 译文 + 讲解），要回原文再从详情里点——
        // 与复习卡片走同一个弹窗，同一件事在两个入口有两种行为比两处都笨拙更糟。
        // 只在有出处时出现：存量卡片（v5 之前收藏的）没有来源，不给一个点了没反应的按钮。
        if favorite.sourceArticleId != nil {
            actions.append(
                OKRowAction(
                    title: L("source.title"), systemImage: "text.viewfinder", tint: theme.primary
                ) {
                    previewFavorite = favorite
                })
        }
        return actions
    }

    private func row(_ favorite: FavoriteVocabulary) -> some View {
        let isSuspended = favorite.suspendedAt != nil
        return HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(RetentionBucket.bucket(for: favorite).color(theme))
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(favorite.word).font(.headline)
                    if let reading = favorite.reading {
                        Text(reading)
                            .font(.caption.monospaced())
                            .foregroundStyle(theme.mutedForeground)
                    }
                    Button {
                        speech.speak(favorite.word, reading: favorite.reading)
                    } label: {
                        Image(systemName: "speaker.wave.2")
                            .font(.caption)
                            .foregroundStyle(theme.mutedForeground)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L("explanation.speak")))
                    if isSuspended {
                        Text(L("vocabulary.stateMastered"))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.muted, in: Capsule())
                            .foregroundStyle(theme.mutedForeground)
                    }
                }
                Text(favorite.meaning).font(.subheadline)
                HStack(spacing: 8) {
                    if let retention = RetentionBucket.retention(for: favorite) {
                        Text(L("vocabulary.retention\(Int((retention * 100).rounded()))"))
                            .font(.caption2)
                            .foregroundStyle(RetentionBucket.bucket(for: favorite).color(theme))
                    }
                    if let source = favorite.sourceArticleTitle {
                        Text(source)
                            .font(.caption2)
                            .foregroundStyle(theme.mutedForeground)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(isSuspended ? 0.55 : 1)
    }
}
#endif
