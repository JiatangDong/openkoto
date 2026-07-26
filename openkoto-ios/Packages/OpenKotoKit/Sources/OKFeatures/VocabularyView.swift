#if os(iOS)
import SwiftUI
import OKModels
import OKDesignSystem
import OKLocalization

/// 生词本(设计文档 §6.5 + SRS 规范):统计头 + 搜索 + 列表 + 复习入口。
struct VocabularyView: View {
    @Environment(ContentStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var speech = SpeechService()
    @State private var searchText = ""
    @State private var isReviewPresented = false
    @State private var isAddPresented = false
    @State private var isPackManagerPresented = false
    @State private var editingFavorite: FavoriteVocabulary?
    @State private var previewFavorite: FavoriteVocabulary?

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
            .sheet(isPresented: $isReviewPresented) {
                // 关 sheet 与置跳转在同一次状态更新里完成：SwiftUI 一个事务处理完，
                // 视觉上是"卡片消失，人已经在原文里了"，不会先看到 sheet 落下再跳一次。
                ReviewSessionView { jump in
                    isReviewPresented = false
                    store.pendingJump = jump
                }
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

    private var dueTodayCount: Int {
        let today = ContentStore.localDateString()
        return packFavorites.count {
            $0.suspendedAt == nil && !$0.dueDate.isEmpty && $0.dueDate <= today
        }
    }

    private var packChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
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
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
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
                        .swipeActions(edge: .leading) {
                            suspendButton(favorite)
                            if favorite.sourceArticleId != nil {
                                backToSourceButton(favorite)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.removeFavorite(favorite.id)
                            } label: {
                                Label(L("common.delete"), systemImage: "trash")
                            }
                        }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .searchable(text: $searchText, prompt: Text(L("vocabulary.searchPrompt")))
        .safeAreaInset(edge: .bottom) {
            reviewButton
        }
    }

    /// 出处：先弹详情（句子 + 译文 + 讲解），要回原文再从详情里点。
    ///
    /// 与复习卡片走同一个弹窗——同一件事在两个入口有两种行为，比两处都笨拙更糟。
    /// 只在有出处时出现：存量卡片（v5 之前收藏的）没有来源，不给一个点了没反应的按钮。
    private func backToSourceButton(_ favorite: FavoriteVocabulary) -> some View {
        Button {
            previewFavorite = favorite
        } label: {
            Label(L("source.title"), systemImage: "text.viewfinder")
        }
        .tint(theme.primary)
    }

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
                Text(L("vocabulary.todayProgress\(stats.newToday)\(stats.reviewToday)"))
                    .font(.caption)
                    .foregroundStyle(theme.mutedForeground)
            }
        }
        .padding(.vertical, 2)
    }

    private var reviewButton: some View {
        Button {
            isReviewPresented = true
        } label: {
            Label(L("vocabulary.startReview"), systemImage: "rectangle.on.rectangle.angled")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(theme.primary)
        .padding(.horizontal)
        .padding(.bottom, 4)
        .disabled(dueTodayCount == 0)
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

    private func suspendButton(_ favorite: FavoriteVocabulary) -> some View {
        Button {
            store.setSuspended(favorite.id, suspended: favorite.suspendedAt == nil)
        } label: {
            if favorite.suspendedAt == nil {
                Label(L("vocabulary.markMastered"), systemImage: "checkmark.circle")
            } else {
                Label(L("vocabulary.resumeReview"), systemImage: "arrow.counterclockwise")
            }
        }
        .tint(favorite.suspendedAt == nil ? theme.srsStrong : theme.srsFading)
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
