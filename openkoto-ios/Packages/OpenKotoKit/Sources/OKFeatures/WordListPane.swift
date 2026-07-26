#if os(iOS)
import OKAIClient
import OKDesignSystem
import OKLocalization
import OKModels
import OKSegmentation
import SwiftUI

/// 句内词表 + 单词释义。
///
/// 存在的理由：阅读时最高频的动作是"这个词啥意思"，而在此之前唯一的路径是
/// 点整句做精讲——一次要吐 600–1200 token。这一页把它压到 80–150 token，
/// 且**不需要先精讲**：分词是离线的。
struct WordListPane: View {
    @Environment(ContentStore.self) private var store
    @Environment(\.theme) private var theme

    let sentence: String
    let language: String?
    let article: Article
    /// 收藏时记下出处的那一句，生词卡才能回到原句。
    let segmentID: UUID

    @State private var selected: String?
    @State private var speech = SpeechService()

    private var candidates: [WordToken] {
        store.lookupCandidates(in: sentence, language: language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FlowLayout(lineSpacing: 8, itemSpacing: 8) {
                ForEach(candidates, id: \.range.lowerBound) { token in
                    wordChip(token.text)
                }
            }

            if let selected {
                glossCard(for: selected)
            } else {
                Text(L("gloss.hint"))
                    .font(.footnote)
                    .foregroundStyle(theme.mutedForeground)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func wordChip(_ word: String) -> some View {
        let isSelected = selected == word
        let isKnown = store.glossState(for: word) != nil
        return Button {
            selected = word
            Task { await store.gloss(word: word, in: sentence) }
        } label: {
            Text(word)
                .font(.body)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    isSelected ? theme.primary.opacity(0.18) : theme.muted,
                    in: RoundedRectangle(cornerRadius: OKRadius.chip)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: OKRadius.chip)
                        .strokeBorder(
                            // 查过的词加个淡边框，一眼看出哪些已经问过（不再花钱）
                            isSelected ? theme.primary : (isKnown ? theme.border : .clear),
                            lineWidth: 1)
                )
                .foregroundStyle(theme.foreground)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func glossCard(for word: String) -> some View {
        ThemedCard {
            switch store.glossState(for: word) {
            case .loaded(let item):
                loadedCard(item)
            case .failed(let error):
                VStack(alignment: .leading, spacing: 10) {
                    Label(userMessage(for: error), systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(theme.destructive)
                    if error.isRetryable {
                        Button(L("explanation.retry")) {
                            Task { await store.retryGloss(word: word, in: sentence) }
                        }
                        .font(.subheadline)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .loading, .none:
                HStack(spacing: 8) {
                    ProgressView()
                    Text(L("gloss.loading")).font(.subheadline)
                        .foregroundStyle(theme.mutedForeground)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func loadedCard(_ item: VocabularyItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.word)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.cardForeground)
                if let reading = item.reading, !reading.isEmpty {
                    Text(reading)
                        .font(.footnote.monospaced())
                        .foregroundStyle(theme.mutedForeground)
                }
                Button {
                    speech.speak(item.word, reading: item.reading, language: language)
                } label: {
                    Image(systemName: "speaker.wave.2")
                        .font(.footnote)
                        .foregroundStyle(theme.mutedForeground)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L("explanation.speak")))
                Spacer()
                favoriteButton(item)
            }

            Text(item.meaning)
                .font(.body)
                .foregroundStyle(theme.cardForeground)
            if let usage = item.usage, !usage.isEmpty {
                Text(usage)
                    .font(.footnote)
                    .foregroundStyle(theme.mutedForeground)
            }
            if let example = item.example, !example.isEmpty {
                Text(example)
                    .font(.footnote.italic())
                    .foregroundStyle(theme.mutedForeground)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func favoriteButton(_ item: VocabularyItem) -> some View {
        let isFavorite = store.isFavorite(word: item.word)
        return Button {
            store.toggleFavorite(item, source: article, segmentID: segmentID)
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .foregroundStyle(isFavorite ? theme.vocabAccent : theme.mutedForeground)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L("vocabulary.favorite")))
    }
}
#endif
