#if os(iOS)
import SwiftUI
import OKModels
import OKDesignSystem
import OKLocalization
import OKSRS

/// 闪卡复习页(规范 §2.5:三档评分映射 FSRS Again/Hard/Good)。
/// 顶部显示今日进度(新词 x/上限 · 复习 y/上限)。
struct ReviewSessionView: View {
    /// 点「出处」时交回给呈现方——复习页是 sheet，得由持有 binding 的那一侧
    /// 先关掉它再跳，否则 tab 在 sheet 底下切走，用户眼前什么都没发生。
    var onOpenSource: (ContentStore.PendingJump) -> Void

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
    /// 当前卡的出处。正面就开始查，翻面时已经在手上了——查库虽然只要几毫秒，
    /// 但翻面是这个界面唯一的关键动作，不该有任何一帧的空档。
    @State private var source: ContentStore.FavoriteSource?

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
            .navigationTitle(L("review.title"))
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
                queue = await store.dueQueue()
                isLoading = false
            }
            .task(id: current?.id) {
                source = nil
                guard let current else { return }
                source = await store.resolveSource(for: current)
            }
        }
    }

    private var progressHeader: some View {
        VStack(spacing: 8) {
            if let stats = store.reviewStats {
                HStack(spacing: 16) {
                    progressBar(
                        label: L("review.progressNew"),
                        value: stats.newToday, limit: ContentStore.dailyNewLimit,
                        color: theme.srsStrong)
                    progressBar(
                        label: L("review.progressReview"),
                        value: stats.reviewToday, limit: ContentStore.dailyReviewLimit,
                        color: theme.srsFading)
                }
            }
            Text(L("review.remaining\(queue.count)"))
                .font(.caption)
                .foregroundStyle(theme.mutedForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                        Text(favorite.meaning)
                            .font(.title3.weight(.medium))
                        if let usage = favorite.usage, !usage.isEmpty {
                            Text(usage)
                                .font(.subheadline)
                                .foregroundStyle(theme.mutedForeground)
                        }
                        if let example = favorite.example, !example.isEmpty {
                            Text(example)
                                .font(.subheadline.italic())
                                .foregroundStyle(theme.mutedForeground)
                                .multilineTextAlignment(.center)
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
                        gradeButton(L("review.gradeUnknown"), color: theme.srsWeak, grade: .again)
                        gradeButton(L("review.gradeUncertain"), color: theme.srsFading, grade: .hard)
                        gradeButton(L("review.gradeKnown"), color: theme.srsStrong, grade: .good)
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

    /// 出处：来源名 + 收藏时所在的那一句，整块可点，点了跳回原文。
    ///
    /// 「这词我在哪见过来着」才是用户翻到背面时真正想起的问题，所以句子本身
    /// 就是主要价值——跳转是第二层。跳走会结束本轮复习，但不丢进度：
    /// 评过分的卡片当场就落库了，重进复习时 `dueQueue()` 不会再把它们排进来。
    private func sourceSection(_ source: ContentStore.FavoriteSource, word: String) -> some View {
        Button {
            onOpenSource(source.jump)
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
        .accessibilityHint(Text(L("vocab.backToSource")))
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func gradeButton(_ label: String, color: Color, grade: FSRS.Grade) -> some View {
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
    }

    private func submitGrade(_ grade: FSRS.Grade) {
        guard let favorite = current else { return }
        store.review(favorite.id, grade: grade)
        queue.removeFirst()
        showAnswer = false
    }
}
#endif
