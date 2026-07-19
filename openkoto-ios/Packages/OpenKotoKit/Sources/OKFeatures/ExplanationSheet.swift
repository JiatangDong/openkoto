#if os(iOS)
import SwiftUI
import NaturalLanguage
import OKModels
import OKAIClient
import OKDesignSystem
import OKLocalization

/// 精讲底部弹层（设计文档 §6.4）：
/// 分区 = 翻译 → 讲解 → 词汇（星标收藏）→ 语法 → 文化背景/难度/学习建议；
/// 底部工具条 = 上一句/下一句/朗读/复制。
struct ExplanationSheet: View {
    @Environment(ContentStore.self) private var store
    @Environment(\.theme) private var theme

    let article: Article
    let segmentID: UUID
    let onSelectSegment: (UUID) -> Void

    @State private var speech = SpeechService()

    private var segments: [ArticleSegment] {
        store.segments(for: article.id)
    }

    private var segment: ArticleSegment? {
        segments.first { $0.id == segmentID }
    }

    /// 原文源语言提示（BCP-47）。孤立汉字难以自动区分中/日，
    /// 故从整篇正文检测一次，作为词/句发音的语种提示。
    private var articleLanguage: String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(article.content.prefix(400)))
        return recognizer.dominantLanguage?.rawValue
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let segment {
                    content(for: segment)
                        .padding()
                }
            }
            .background(theme.background)
            .safeAreaInset(edge: .bottom) { bottomBar }
            .task(id: segmentID) {
                await store.generateExplanation(articleID: article.id, segmentID: segmentID)
            }
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private func content(for segment: ArticleSegment) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // 原句 + 注音
            VStack(alignment: .leading, spacing: 4) {
                Text(segment.text).font(.title3.weight(.medium))
                if let reading = segment.readingText ?? segment.explanation?.readingText {
                    Text(reading)
                        .font(.footnote.monospaced())
                        .foregroundStyle(theme.mutedForeground)
                }
            }

            if let explanation = segment.explanation {
                explanationSections(explanation)
            } else if store.generatingSegmentIDs.contains(segment.id) {
                loadingView
            } else if let error = store.generationErrors[segment.id] {
                errorView(error, segmentID: segment.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorView(_ error: AIClientError, segmentID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(userMessage(for: error), systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(theme.destructive)
            Button {
                Task { await store.generateExplanation(articleID: article.id, segmentID: segmentID) }
            } label: {
                Label(L("explanation.retry"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func explanationSections(_ explanation: SegmentExplanation) -> some View {
        section("explanation.translation", icon: "globe") {
            TranslationBox(explanation.translation)
        }
        section("explanation.explanation", icon: "text.book.closed") {
            Text(explanation.explanation).font(.subheadline)
        }
        if !explanation.vocabulary.isEmpty {
            section("explanation.vocabulary", icon: "character.book.closed") {
                VStack(spacing: 8) {
                    ForEach(explanation.vocabulary, id: \.word) { item in
                        VocabCard(
                            word: item.word,
                            reading: item.reading,
                            meaning: item.meaning,
                            isFavorite: store.isFavorite(word: item.word),
                            onSpeak: {
                                speech.speak(item.word, reading: item.reading, language: articleLanguage)
                            },
                            onToggleFavorite: {
                                store.toggleFavorite(item, source: article)
                            }
                        )
                    }
                }
            }
        }
        if !explanation.grammarPoints.isEmpty {
            section("explanation.grammar", icon: "textformat.abc.dottedunderline") {
                VStack(spacing: 10) {
                    ForEach(explanation.grammarPoints, id: \.point) { point in
                        GrammarCard(
                            point: point.point,
                            explanation: point.explanation,
                            example: point.example
                        )
                    }
                }
            }
        }
        if let culture = explanation.culturalContext {
            section("explanation.culture", icon: "building.columns") {
                Text(culture).font(.footnote).foregroundStyle(theme.mutedForeground)
            }
        }
        if let tips = explanation.learningTips {
            section("explanation.tips", icon: "lightbulb") {
                Text(tips).font(.footnote).foregroundStyle(theme.mutedForeground)
            }
        }
    }

    private func section(
        _ titleKey: String.LocalizationValue, icon: String,
        @ViewBuilder body: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L(titleKey), systemImage: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(theme.primary)
            body()
        }
    }

    private var loadingView: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 4)
                    .fill(theme.muted)
                    .frame(height: 14)
            }
            Text(L("explanation.loading"))
                .font(.footnote)
                .foregroundStyle(theme.mutedForeground)
        }
        .accessibilityLabel(Text(L("explanation.loading")))
    }

    // MARK: - 底部工具条

    private var bottomBar: some View {
        HStack(spacing: 28) {
            navButton(systemImage: "chevron.up", offset: -1)
            navButton(systemImage: "chevron.down", offset: +1)
            Spacer()
            Button {
                if let segment {
                    speech.speak(
                        segment.text,
                        reading: segment.readingText ?? segment.explanation?.readingText,
                        language: articleLanguage)
                }
            } label: {
                Image(systemName: "speaker.wave.2")
            }
            .accessibilityLabel(Text(L("explanation.speak")))
            Button {
                if let segment { UIPasteboard.general.string = segment.text }
            } label: {
                Image(systemName: "doc.on.doc")
            }
        }
        .font(.title3)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func navButton(systemImage: String, offset: Int) -> some View {
        let index = segments.firstIndex { $0.id == segmentID }
        let target = index.flatMap { i -> UUID? in
            let next = i + offset
            return segments.indices.contains(next) ? segments[next].id : nil
        }
        return Button {
            if let target { onSelectSegment(target) }
        } label: {
            Image(systemName: systemImage)
        }
        .disabled(target == nil)
    }
}
#endif
