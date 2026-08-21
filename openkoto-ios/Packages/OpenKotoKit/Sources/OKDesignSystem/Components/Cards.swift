import SwiftUI

/// 主题化卡片容器（桌面 bg-card + border 的对应物）。
public struct ThemedCard<Content: View>: View {
    @Environment(\.theme) private var theme
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(theme.card, in: RoundedRectangle(cornerRadius: OKRadius.card))
            .overlay(
                RoundedRectangle(cornerRadius: OKRadius.card)
                    .strokeBorder(theme.border, lineWidth: 1)
            )
    }
}

/// 词汇卡：amber 底 + 星标收藏（对齐桌面讲解面板 Vocabulary 区，设计文档 §6.4）。
public struct VocabCard: View {
    @Environment(\.theme) private var theme

    let word: String
    let reading: String?
    let meaning: String
    let isFavorite: Bool
    /// 朗读回调（由 OKFeatures 注入，避免 OKDesignSystem 依赖 AVFoundation）。nil = 不显示喇叭。
    let onSpeak: (() -> Void)?
    let onToggleFavorite: () -> Void

    public init(
        word: String, reading: String?, meaning: String,
        isFavorite: Bool, onSpeak: (() -> Void)? = nil,
        onToggleFavorite: @escaping () -> Void
    ) {
        self.word = word
        self.reading = reading
        self.meaning = meaning
        self.isFavorite = isFavorite
        self.onSpeak = onSpeak
        self.onToggleFavorite = onToggleFavorite
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(word).font(.headline.bold())
                    if let reading {
                        Text(reading)
                            .font(.caption.monospaced())
                            .foregroundStyle(theme.mutedForeground)
                    }
                    if let onSpeak {
                        Button(action: onSpeak) {
                            Image(systemName: "speaker.wave.2")
                                .font(.caption)
                                .foregroundStyle(theme.mutedForeground)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("vocab.speak", bundle: .module))
                    }
                }
                MarkdownText(meaning)
            }
            Spacer(minLength: 0)
            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? theme.vocabAccent : theme.mutedForeground)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("vocab.favorite", bundle: .module))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            theme.vocabAccent.opacity(0.1),
            in: RoundedRectangle(cornerRadius: OKRadius.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: OKRadius.card)
                .strokeBorder(theme.vocabAccent.opacity(0.2), lineWidth: 1)
        )
    }
}

/// 语法卡：紫色左边线（对齐桌面讲解面板 Grammar 区）。
public struct GrammarCard: View {
    @Environment(\.theme) private var theme

    let point: String
    let explanation: String
    let example: String?

    public init(point: String, explanation: String, example: String? = nil) {
        self.point = point
        self.explanation = explanation
        self.example = example
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(point).font(.subheadline.bold())
            MarkdownText(explanation)
            if let example {
                MarkdownText(example, font: .footnote)
                    .foregroundStyle(theme.mutedForeground)
            }
        }
        .padding(.leading, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(theme.grammarAccent.opacity(0.5))
                .frame(width: 3)
        }
    }
}

/// 译文框：muted 底圆角框（对齐桌面 bg-muted/30 detail box）。
public struct TranslationBox: View {
    @Environment(\.theme) private var theme
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        MarkdownText(text, font: .body)
            .foregroundStyle(theme.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(theme.muted.opacity(0.5), in: RoundedRectangle(cornerRadius: OKRadius.card))
    }
}
