#if os(iOS)
import SwiftUI
import OKModels
import OKDesignSystem
import OKLocalization

/// 生词卡的「出处」弹窗。
///
/// 复习时想起"这词我在哪见过来着"，需要的是**那一句加上它的讲解**，不是被扔进一篇
/// 几百段的原文里自己找。所以点出处先弹这一层：句子、译文、语法点、语境都在这儿，
/// 看完就能接着复习；真想回原文再点底部那个按钮。
struct SourcePreviewSheet: View {
    let favorite: FavoriteVocabulary
    /// 点「在原文中查看」时交回去——这一层和它上面的复习页都得先关掉，
    /// 才轮得到切 tab、推导航。
    var onOpenInText: (ContentStore.PendingJump) -> Void

    @Environment(ContentStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var speech = SpeechService()
    @State private var source: ContentStore.FavoriteSource?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if let source {
                    content(source)
                } else if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        L("source.title"), systemImage: "text.viewfinder",
                        description: Text(L("source.unavailable")))
                }
            }
            .background(theme.background)
            .navigationTitle(L("source.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.close")) { dismiss() }
                }
            }
            .task {
                source = await store.resolveSource(for: favorite)
                isLoading = false
            }
        }
        // 半屏起步：这是复习途中的一次侧看，不该把整个复习流盖住。
        .presentationDetents([.medium, .large])
        .okSheetSizing(.page)
    }

    private func content(_ source: ContentStore.FavoriteSource) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label(source.label, systemImage: "text.viewfinder")
                    .font(.footnote)
                    .foregroundStyle(theme.mutedForeground)

                if let segment = source.segment {
                    sentenceCard(segment)
                    details(segment)
                } else {
                    Text(L("source.sentenceUnavailable"))
                        .font(.subheadline)
                        .foregroundStyle(theme.mutedForeground)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .safeAreaInset(edge: .bottom) { openButton(source.jump) }
    }

    private func sentenceCard(_ segment: ArticleSegment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(highlighted(segment.text))
                .font(.title3)
                .foregroundStyle(theme.foreground)
            HStack(spacing: 12) {
                Button {
                    speech.speak(segment.text)
                } label: {
                    Label(L("explanation.speak"), systemImage: "speaker.wave.2")
                        .font(.footnote)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.mutedForeground)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(theme.card, in: RoundedRectangle(cornerRadius: 12))
    }

    /// 译文与精讲。
    ///
    /// **不列精讲里的词汇表**：这张卡本身就是从那份词汇表里收藏来的，复习途中再摆一排
    /// 「收藏」按钮只会把注意力从"想起这个词"上引开。要看整份精讲，回原文。
    @ViewBuilder
    private func details(_ segment: ArticleSegment) -> some View {
        if let explanation = segment.explanation {
            section("explanation.translation", icon: "globe") {
                TranslationBox(explanation.translation)
            }
            section("explanation.explanation", icon: "text.book.closed") {
                Text(explanation.explanation).font(.subheadline)
            }
            if !explanation.grammarPoints.isEmpty {
                section("explanation.grammar", icon: "textformat.abc.dottedunderline") {
                    VStack(spacing: 10) {
                        ForEach(explanation.grammarPoints, id: \.point) { point in
                            GrammarCard(
                                point: point.point,
                                explanation: point.explanation,
                                example: point.example)
                        }
                    }
                }
            }
            if let culture = explanation.culturalContext, !culture.isEmpty {
                section("explanation.culture", icon: "building.columns") {
                    Text(culture).font(.footnote).foregroundStyle(theme.mutedForeground)
                }
            }
            if let tips = explanation.learningTips, !tips.isEmpty {
                section("explanation.tips", icon: "lightbulb") {
                    Text(tips).font(.footnote).foregroundStyle(theme.mutedForeground)
                }
            }
        } else if let translation = segment.translation, !translation.isEmpty {
            // 只翻译过、没精讲过的句子。
            section("explanation.translation", icon: "globe") {
                TranslationBox(translation)
            }
        } else {
            Text(L("source.notExplained"))
                .font(.footnote)
                .foregroundStyle(theme.mutedForeground)
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openButton(_ jump: ContentStore.PendingJump) -> some View {
        Button {
            onOpenInText(jump)
        } label: {
            Label(L("source.openInText"), systemImage: "arrow.up.forward.square")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(theme.primary)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    /// 把这个词在原句里标出来。找不到就整句原样显示——卡片是「勉強する」而原句写作
    /// 「勉強しています」这类活用差异很常见，为了标个色去做词形还原不划算。
    private func highlighted(_ sentence: String) -> AttributedString {
        var result = AttributedString(sentence)
        guard !favorite.word.isEmpty, let range = result.range(of: favorite.word) else {
            return result
        }
        result[range].font = .title3.bold()
        result[range].foregroundColor = theme.primary
        return result
    }
}
#endif
