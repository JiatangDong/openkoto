#if os(iOS)
import SwiftUI
import Charts
import OKModels
import OKDesignSystem
import OKLocalization

/// 统计分析(设计文档 §6 扩展)：成就徽章 + 复习活跃度 / 状态 / 评分 / 预测 / 记忆保持 + 阅读时长。
/// 首个 Swift Charts 使用者；数据来自 `ContentStore.statistics`(全局，独立于生词本词包)。
struct StatisticsView: View {
    @Environment(ContentStore.self) private var store
    @Environment(\.theme) private var theme

    /// 图表用切片(状态分布 / 记忆保持)。
    private struct Slice: Identifiable {
        let label: String
        let count: Int
        let color: Color
        var id: String { label }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let stats = store.statistics, hasAnyData(stats) {
                    content(stats)
                } else {
                    ContentUnavailableView(
                        L("stats.empty.title"),
                        systemImage: "chart.bar",
                        description: Text(L("stats.empty.message")))
                }
            }
            .background(theme.background)
            .navigationTitle(L("tab.statistics"))
        }
        .task { await store.refreshStatistics() }
    }

    private func hasAnyData(_ stats: StudyStatistics) -> Bool {
        stats.totalReviews > 0 || !store.favorites.isEmpty || stats.readingSecondsTotal > 0
    }

    private func content(_ stats: StudyStatistics) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    overviewTiles(stats)
                    achievementsSection(stats)
                    activitySection(stats)
                    statesSection(stats)
                    gradesSection(stats)
                    forecastSection(stats)
                    retentionSection()
                    readingSection(stats).id("reading")
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .onAppear {
                // 截图/UI 测试用：直接滚到底部阅读时长区。
                if ProcessInfo.processInfo.arguments.contains("-statsScrollReading") {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(500))
                        proxy.scrollTo("reading", anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - A. 概览小卡

    private func overviewTiles(_ stats: StudyStatistics) -> some View {
        ThemedCard {
            HStack(spacing: 12) {
                statTile("\(store.favorites.count)", "stats.metric.words", tint: theme.primary)
                statTile("\(stats.reviewStats.streakDays)", "vocabulary.streak", tint: theme.srsStrong)
                statTile("\(stats.totalReviews)", "stats.metric.reviews", tint: theme.primary)
                statTile("\(stats.activeDays)", "stats.metric.activeDays", tint: theme.primary)
            }
        }
    }

    // MARK: - B. 成就

    private func achievementsSection(_ stats: StudyStatistics) -> some View {
        let metrics = AchievementMetrics(
            streakDays: stats.reviewStats.streakDays,
            wordsCollected: store.favorites.count,
            wordsMastered: stats.reviewStats.countSuspended,
            totalReviews: stats.totalReviews,
            readingDays: stats.readingDaysTotal,
            readingMinutes: stats.readingSecondsTotal / 60)
        let achievements = AchievementCatalog.evaluate(metrics)
        return sectionCard("stats.section.achievements", systemImage: "rosette") {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10
            ) {
                ForEach(achievements) { badge in
                    achievementBadge(badge)
                }
            }
        }
    }

    private func achievementBadge(_ achievement: Achievement) -> some View {
        let tint = achievement.unlocked ? theme.primary : theme.mutedForeground
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: achievementSymbol(achievement.kind))
                    .font(.title3)
                    .symbolVariant(achievement.unlocked ? .fill : .none)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L(achievementTitle(achievement.kind)))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.foreground)
                    Text(verbatim: achievement.nextThreshold.map {
                        "\(achievement.currentValue) / \($0)"
                    } ?? L("achievement.maxed"))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(theme.mutedForeground)
                }
                Spacer(minLength: 0)
            }
            miniProgress(achievement.progressToNext, tint: tint)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: OKRadius.chip).fill(theme.muted.opacity(0.4)))
        .opacity(achievement.unlocked ? 1 : 0.75)
    }

    // MARK: - C. 每日复习活跃度(堆叠柱)

    private func activitySection(_ stats: StudyStatistics) -> some View {
        let newLabel = L("stats.legend.new")
        let reviewLabel = L("stats.legend.review")
        return sectionCard("stats.section.activity", systemImage: "chart.bar.fill") {
            if stats.dailyActivity.allSatisfy({ $0.total == 0 }) {
                emptyHint("stats.empty.activity")
            } else {
                Chart(stats.dailyActivity) { day in
                    BarMark(
                        x: .value("date", String(day.dateLocal.suffix(5))),
                        y: .value("count", day.newCount))
                    .foregroundStyle(by: .value("type", newLabel))
                    BarMark(
                        x: .value("date", String(day.dateLocal.suffix(5))),
                        y: .value("count", day.reviewCount))
                    .foregroundStyle(by: .value("type", reviewLabel))
                }
                .chartForegroundStyleScale([
                    newLabel: theme.srsStrong,
                    reviewLabel: theme.primary,
                ])
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
                .chartLegend(position: .bottom)
                .frame(height: 180)
            }
        }
    }

    // MARK: - D. 卡片状态分布(环形)

    private func statesSection(_ stats: StudyStatistics) -> some View {
        let rs = stats.reviewStats
        let slices = [
            Slice(label: L("vocabulary.stateNew"), count: rs.countNew,
                  color: theme.mutedForeground.opacity(0.6)),
            Slice(label: L("vocabulary.stateLearning"), count: rs.countLearning,
                  color: theme.srsFading),
            Slice(label: L("vocabulary.stateReview"), count: rs.countReview,
                  color: theme.srsStrong),
            Slice(label: L("vocabulary.stateMastered"), count: rs.countSuspended,
                  color: theme.mutedForeground),
        ]
        return sectionCard("stats.section.states", systemImage: "circle.grid.2x2") {
            if rs.total == 0 {
                emptyHint("stats.empty.states")
            } else {
                Chart(slices) { slice in
                    SectorMark(
                        angle: .value("count", slice.count),
                        innerRadius: .ratio(0.62),
                        angularInset: 1.5)
                    .cornerRadius(3)
                    .foregroundStyle(by: .value("state", slice.label))
                }
                .chartForegroundStyleScale(
                    domain: slices.map(\.label), range: slices.map(\.color))
                .chartLegend(position: .bottom)
                .frame(height: 200)
                .overlay {
                    VStack(spacing: 0) {
                        Text("\(rs.total)")
                            .font(.title.bold().monospacedDigit())
                            .foregroundStyle(theme.foreground)
                        Text(L("stats.metric.words"))
                            .font(.caption2)
                            .foregroundStyle(theme.mutedForeground)
                    }
                    .offset(y: -18)
                }
            }
        }
    }

    // MARK: - E. 评分分布(横向柱)

    private func gradesSection(_ stats: StudyStatistics) -> some View {
        let order = [
            L("stats.grade.again"), L("stats.grade.hard"),
            L("stats.grade.good"), L("stats.grade.easy"),
        ]
        return sectionCard("stats.section.grades", systemImage: "hand.thumbsup") {
            if stats.totalReviews == 0 {
                emptyHint("stats.empty.activity")
            } else {
                Chart(stats.gradeCounts) { item in
                    BarMark(
                        x: .value("count", item.count),
                        y: .value("grade", L(gradeLabel(item.grade))))
                    .foregroundStyle(gradeColor(item.grade))
                    .annotation(position: .trailing) {
                        Text("\(item.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(theme.mutedForeground)
                    }
                }
                .chartYScale(domain: order)
                .chartXAxis(.hidden)
                .frame(height: 150)
            }
        }
    }

    // MARK: - F. 复习预测(柱)

    private func forecastSection(_ stats: StudyStatistics) -> some View {
        sectionCard("stats.section.forecast", systemImage: "calendar.badge.clock") {
            if stats.forecast.allSatisfy({ $0.dueCount == 0 }) {
                emptyHint("stats.empty.forecast")
            } else {
                Chart(stats.forecast) { day in
                    BarMark(
                        x: .value("date", String(day.dateLocal.suffix(5))),
                        y: .value("due", day.dueCount))
                    .foregroundStyle(theme.srsFading)
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
                .frame(height: 160)
            }
        }
    }

    // MARK: - G. 记忆保持分档(单条堆叠横向柱)

    private func retentionSection() -> some View {
        let dist = RetentionBucket.distribution(for: store.favorites)
        let slices = [
            Slice(label: L("stats.retention.strong"), count: dist.strong, color: theme.srsStrong),
            Slice(label: L("stats.retention.fading"), count: dist.fading, color: theme.srsFading),
            Slice(label: L("stats.retention.weak"), count: dist.weak, color: theme.srsWeak),
        ]
        return sectionCard("stats.section.retention", systemImage: "brain.head.profile") {
            if dist.strong + dist.fading + dist.weak == 0 {
                emptyHint("stats.empty.retention")
            } else {
                Chart(slices) { slice in
                    BarMark(x: .value("count", slice.count))
                        .foregroundStyle(by: .value("bucket", slice.label))
                }
                .chartForegroundStyleScale(
                    domain: slices.map(\.label), range: slices.map(\.color))
                .chartXAxis(.hidden)
                .chartLegend(position: .bottom)
                .frame(height: 56)
            }
        }
    }

    // MARK: - H. 阅读时长

    private func readingSection(_ stats: StudyStatistics) -> some View {
        sectionCard("stats.section.reading", systemImage: "book.fill") {
            HStack(spacing: 12) {
                statTile("\(stats.readingSecondsToday / 60)",
                         "stats.reading.todayMinutes", tint: theme.primary)
                statTile("\(stats.readingDaysThisMonth)",
                         "stats.reading.monthDays", tint: theme.srsStrong)
                statTile("\(stats.readingSecondsTotal / 60)",
                         "stats.reading.totalMinutes", tint: theme.primary)
            }
            if stats.readingByDay.allSatisfy({ $0.seconds == 0 }) {
                emptyHint("stats.empty.reading")
            } else {
                Chart(stats.readingByDay) { day in
                    BarMark(
                        x: .value("date", String(day.dateLocal.suffix(5))),
                        y: .value("minutes", day.minutes))
                    .foregroundStyle(theme.explained)
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
                .frame(height: 150)
            }
        }
    }

    // MARK: - 复用小组件

    private func sectionCard<Content: View>(
        _ titleKey: String.LocalizationValue,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(L(titleKey), systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.foreground)
                content()
            }
        }
    }

    private func statTile(
        _ value: String, _ labelKey: String.LocalizationValue, tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2.bold().monospacedDigit())
                .foregroundStyle(tint)
            Text(L(labelKey))
                .font(.caption)
                .foregroundStyle(theme.mutedForeground)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func miniProgress(_ value: Double, tint: Color) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.muted)
                Capsule().fill(tint)
                    .frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 5)
    }

    private func emptyHint(_ key: String.LocalizationValue) -> some View {
        Text(L(key))
            .font(.caption)
            .foregroundStyle(theme.mutedForeground)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 10)
    }

    private func achievementSymbol(_ kind: Achievement.Kind) -> String {
        switch kind {
        case .streak: "flame"
        case .wordsCollected: "star.square.on.square"
        case .wordsMastered: "checkmark.seal"
        case .totalReviews: "arrow.2.squarepath"
        case .readingDays: "calendar"
        case .readingMinutes: "book"
        }
    }

    private func achievementTitle(_ kind: Achievement.Kind) -> String.LocalizationValue {
        switch kind {
        case .streak: "achievement.streak.title"
        case .wordsCollected: "achievement.wordsCollected.title"
        case .wordsMastered: "achievement.wordsMastered.title"
        case .totalReviews: "achievement.totalReviews.title"
        case .readingDays: "achievement.readingDays.title"
        case .readingMinutes: "achievement.readingMinutes.title"
        }
    }

    private func gradeLabel(_ grade: Int) -> String.LocalizationValue {
        switch grade {
        case 1: "stats.grade.again"
        case 2: "stats.grade.hard"
        case 3: "stats.grade.good"
        default: "stats.grade.easy"
        }
    }

    private func gradeColor(_ grade: Int) -> Color {
        switch grade {
        case 1: theme.srsWeak
        case 2: theme.srsFading
        case 3: theme.srsStrong
        default: theme.primary
        }
    }
}
#endif
