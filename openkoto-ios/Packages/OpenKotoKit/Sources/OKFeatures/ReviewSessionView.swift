#if os(iOS)
import SwiftUI
import OKModels
import OKDesignSystem
import OKLocalization
import OKSRS

/// 闪卡复习页(规范 §2.5:三档评分映射 FSRS Again/Hard/Good)。
/// 顶部显示今日进度(新词 x/上限 · 复习 y/上限)。
struct ReviewSessionView: View {
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
