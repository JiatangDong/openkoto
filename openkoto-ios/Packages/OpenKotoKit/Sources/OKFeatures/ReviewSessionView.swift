#if os(iOS)
import SwiftUI
import OKModels
import OKDesignSystem
import OKLocalization
import OKSRS

/// 闪卡复习页(规范 §2.5:三档评分映射 FSRS Again/Hard/Good)。
/// 顶部显示今日进度(通过的新词 x/上限 · 通过的复习 y/上限)。
struct ReviewSessionView: View {
    /// 队列来源。两种模式共用同一套卡片与评分逻辑，只有取哪批卡、头部显示什么不同。
    enum Mode {
        /// 今日到期(含同日巩固卡)。
        case due
        /// 今日清空后的额外一组：提前复习最近要到期的卡。
        case ahead
    }

    /// 点「出处」时交回给呈现方——复习页是 sheet，得由持有 binding 的那一侧
    /// 先关掉它再跳，否则 tab 在 sheet 底下切走，用户眼前什么都没发生。
    var onOpenSource: (ContentStore.PendingJump) -> Void

    /// 模式在**构造时**就定下来（`_mode` 直接种进 `@State`），不靠 `.task` 补写：
    /// 那样的话呈现方只要在同一次动作里改两个 state，就可能先用旧模式构造一次，
    /// 而 `@State` 只初始化一次，「提前复习」就开成了普通复习。
    /// 进去以后完成页上还能切到 `.ahead`。
    init(
        onOpenSource: @escaping (ContentStore.PendingJump) -> Void,
        initialMode: Mode = .due
    ) {
        self.onOpenSource = onOpenSource
        _mode = State(initialValue: initialMode)
    }

    @Environment(ContentStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// 卡牌正面是否显示读音。默认关闭：日语假名/中文拼音直接给出读音,
    /// 对中文母语者几乎等于给出答案,会让回忆环节失效。翻面后始终显示。
    @AppStorage("srs.showReadingOnFront") private var showReadingOnFront = false

    @State private var speech = SpeechService()
    @State private var queue: [FavoriteVocabulary] = []
    @State private var showAnswer = false
    @State private var isLoading = true
    @State private var mode: Mode
    /// 当前卡的出处。正面就开始查，翻面时已经在手上了——查库虽然只要几毫秒，
    /// 但翻面是这个界面唯一的关键动作，不该有任何一帧的空档。
    @State private var source: ContentStore.FavoriteSource?
    @State private var isPreviewPresented = false
    /// 正在因为「在原文中查看」而离开。去看原句不是"没想起来"，
    /// 这一次关闭不该被下面的 `onDisappear` 记成 again。
    @State private var isLeavingForSource = false

    private var current: FavoriteVocabulary? { queue.first }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let current {
                    session(current)
                } else {
                    doneView
                }
            }
            .background(theme.background)
            .navigationTitle(mode == .due ? L("review.title") : L("vocabulary.startAhead"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.close")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Toggle(L("review.showReadingOnFront"), isOn: $showReadingOnFront)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(Text(L("review.options")))
                }
            }
            .task {
                await loadQueue()
            }
            // 翻了面还退出 = 确实没想起来，按「不认识」记，卡片留在今日队列。
            // 没点「显示答案」就关掉的**不写事件、不动状态**——点开看一眼就被扣分，
            // 比不记录更糟。`showAnswer` 评分后立刻重置、队列空时 `current` 为 nil，
            // 所以正常做完退出不会误记。
            .onDisappear {
                guard !isLeavingForSource, showAnswer, let current else { return }
                store.review(current.id, grade: .again)
            }
            .task(id: current?.id) {
                source = nil
                guard let current else { return }
                source = await store.resolveSource(for: current)
            }
            .sheet(isPresented: $isPreviewPresented) {
                if let current {
                    SourcePreviewSheet(favorite: current) { jump in
                        // 两层 sheet 一起收：这一层自己关，复习页由呈现方关。
                        isPreviewPresented = false
                        isLeavingForSource = true
                        onOpenSource(jump)
                    }
                }
            }
        }
    }

    /// 队列里等着再答一次的巩固卡（今天答错过、还没通过）。
    private var relearningCount: Int {
        queue.count { $0.srsState == .learning }
    }

    @ViewBuilder
    private var progressHeader: some View {
        VStack(spacing: 8) {
            // 日限进度条只在 `.due` 下有意义——提前复习本来就是把上限之外的活提前干了。
            if mode == .due, let stats = store.reviewStats {
                HStack(spacing: 16) {
                    // 用 passed* 而不是 newToday/reviewToday：答错的卡当天还会回来，
                    // 在点"认识"之前不该算学完。
                    progressBar(
                        label: L("review.progressNew"),
                        value: stats.passedNewToday, limit: ContentStore.dailyNewLimit,
                        color: theme.srsStrong)
                    progressBar(
                        label: L("review.progressReview"),
                        value: stats.passedReviewToday, limit: ContentStore.dailyReviewLimit,
                        color: theme.srsFading)
                }
            }
            HStack(spacing: 8) {
                Text(L("review.remaining\(queue.count)"))
                // 不解释一下的话，用户会看着"新词 15/20"却发现队列里还剩 5 张，
                // 不知道那 5 张是从哪来的。
                if relearningCount > 0 {
                    Text(L("review.relearning\(relearningCount)"))
                        .foregroundStyle(theme.srsFading)
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(theme.mutedForeground)
        }
        .padding(.horizontal)
    }

    private func progressBar(label: String, value: Int, limit: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                Spacer()
                Text("\(min(value, limit))/\(limit)")
            }
            .font(.caption2)
            .foregroundStyle(theme.mutedForeground)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.muted)
                    Capsule()
                        .fill(color)
                        .frame(
                            width: limit > 0
                                ? proxy.size.width * min(Double(value) / Double(limit), 1) : 0)
                }
            }
            .frame(height: 5)
        }
    }

    private func session(_ favorite: FavoriteVocabulary) -> some View {
        VStack(spacing: 20) {
            progressHeader
                .padding(.top, 8)

            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Text(favorite.word)
                        .font(.largeTitle.bold())
                        .foregroundStyle(theme.primary)
                    Button {
                        speech.speak(favorite.word, reading: favorite.reading)
                    } label: {
                        Image(systemName: "speaker.wave.2")
                            .font(.title3)
                            .foregroundStyle(theme.mutedForeground)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L("explanation.speak")))
                }
                // 读音属于答案的一部分:正面按开关决定,翻面后无条件显示。
                if let reading = favorite.reading, showAnswer || showReadingOnFront {
                    Text(reading)
                        .font(.callout.monospaced())
                        .foregroundStyle(theme.mutedForeground)
                }
                if showAnswer {
                    VStack(spacing: 8) {
                        MarkdownText(
                            favorite.meaning, font: .title3.weight(.medium), alignment: .center)
                        if let usage = favorite.usage, !usage.isEmpty {
                            MarkdownText(usage, font: .subheadline, alignment: .center)
                                .foregroundStyle(theme.mutedForeground)
                        }
                        if let example = favorite.example, !example.isEmpty {
                            MarkdownText(
                                example, font: .subheadline.italic(), alignment: .center)
                                .foregroundStyle(theme.mutedForeground)
                        }
                    }
                    .padding(.top, 4)
                } else {
                    Text(L("review.recallHint"))
                        .font(.subheadline)
                        .foregroundStyle(theme.mutedForeground)
                        .padding(.top, 4)
                }
                // 出处只在背面出现：原句里就含着这个词，放正面等于直接给答案。
                if showAnswer, let source {
                    Divider().padding(.vertical, 2)
                    sourceSection(source, word: favorite.word)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)

            Group {
                if showAnswer {
                    HStack(spacing: 10) {
                        // 1/2/3 评分是 Anki 的通用肌肉记忆，键盘环境下收益最大。
                        gradeButton(
                            L("review.gradeUnknown"), color: theme.srsWeak, grade: .again, key: "1")
                        gradeButton(
                            L("review.gradeUncertain"), color: theme.srsFading, grade: .hard,
                            key: "2")
                        gradeButton(
                            L("review.gradeKnown"), color: theme.srsStrong, grade: .good, key: "3")
                    }
                } else {
                    Button {
                        showAnswer = true
                    } label: {
                        Text(L("review.showAnswer"))
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.primary)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
    }

    /// 出处：来源名 + 收藏时所在的那一句，整块可点。
    ///
    /// 点了**先弹出处详情**（句子 + 译文 + 讲解），不直接跳原文——原文动辄几百段，
    /// 一步跳过去只会让人不知道自己落在哪儿，而且复习也就此中断了。
    /// 真要回原文，详情里还有一个按钮。
    private func sourceSection(_ source: ContentStore.FavoriteSource, word: String) -> some View {
        Button {
            isPreviewPresented = true
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "text.viewfinder")
                    Text(source.label)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                }
                .font(.caption)
                .foregroundStyle(theme.mutedForeground)
                if let sentence = source.sentence {
                    Text(highlighted(sentence, word: word))
                        .font(.subheadline)
                        .foregroundStyle(theme.foreground)
                        .multilineTextAlignment(.leading)
                        // 3 行封顶：卡片本身没有滚动，长句加上 usage/example 在 SE 上会顶出去。
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(source.sentence.map { "\(source.label)。\($0)" } ?? source.label))
        .accessibilityHint(Text(L("source.title")))
    }

    /// 把这个词在原句里标出来。找不到就整句原样显示——卡片是「勉強する」而原句写作
    /// 「勉強しています」这类活用差异很常见，为了标个色去做词形还原不划算。
    private func highlighted(_ sentence: String, word: String) -> AttributedString {
        var result = AttributedString(sentence)
        guard !word.isEmpty, let range = result.range(of: word) else { return result }
        result[range].font = .subheadline.bold()
        result[range].foregroundColor = theme.primary
        return result
    }

    private var doneView: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(theme.srsStrong)
            Text(L("review.done"))
                .font(.title3.bold())
            Text(L("review.doneDescription"))
                .font(.subheadline)
                .foregroundStyle(theme.mutedForeground)
                .multilineTextAlignment(.center)
            // 还想练就地续上一组，不用退出去再点一次进来。
            // `.ahead` 模式下不再给这个按钮：一组接一组地提前复习会把未来的队列掏空。
            if mode == .due, store.aheadAvailableCount > 0 {
                Button {
                    mode = .ahead
                    Task { await loadQueue() }
                } label: {
                    Label(
                        L("review.extraRound\(ContentStore.aheadRoundSize)"),
                        systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(theme.primary)
                .padding(.top, 6)
                Text(L("review.extraRoundHint"))
                    .font(.caption2)
                    .foregroundStyle(theme.mutedForeground)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadQueue() async {
        isLoading = true
        queue = mode == .due ? await store.dueQueue() : await store.aheadQueue()
        showAnswer = false
        isLoading = false
    }

    private func gradeButton(
        _ label: String, color: Color, grade: FSRS.Grade, key: KeyEquivalent
    ) -> some View {
        Button {
            submitGrade(grade)
        } label: {
            Text(label)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(color)
        // 无修饰键：复习时手一直放在数字键上，加 ⌘ 反而慢。
        .keyboardShortcut(key, modifiers: [])
    }

    /// 答错的卡隔几张回来。again 比 hard 早——刚才完全没想起来的那个更需要重来一次。
    /// 队列比这个数短就落到队尾。
    private static let relearnGap: [FSRS.Grade: Int] = [.again: 3, .hard: 8]

    private func submitGrade(_ grade: FSRS.Grade) {
        guard let favorite = current else { return }
        store.review(favorite.id, grade: grade)
        queue.removeFirst()
        // 没答对就回队，直到点"认识"才算这一轮学完（库里 dueDate 也留在今天，
        // 所以中途退出再进来它还在——两层是一致的）。
        if let gap = Self.relearnGap[grade] {
            var relearning = favorite
            // 队列里存的是快照，状态得跟上，否则"待巩固 n"数不到它。
            relearning.srsState = .learning
            queue.insert(relearning, at: min(gap, queue.count))
        }
        showAnswer = false
    }
}
#endif
