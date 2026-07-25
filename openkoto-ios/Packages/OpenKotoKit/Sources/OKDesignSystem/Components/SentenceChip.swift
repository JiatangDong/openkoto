import SwiftUI

/// 句子 chip 的学习状态（色语义对齐桌面 ArticleReader，设计文档 §6.4）。
public enum SentenceState: Sendable {
    case plain          // 默认：透明边框
    case translated     // 已翻译：黄 30% 边框
    case explained      // 已精讲：绿 30% 边框
}

/// 可点按的内联句子 chip。状态不只靠颜色表达——
/// VoiceOver 通过 accessibilityValue 读出学习状态。
public struct SentenceChip: View {
    @Environment(\.theme) private var theme

    let text: String
    let state: SentenceState
    let isSelected: Bool
    let fontSize: CGFloat
    /// 词级读音。非空时正文改用 CoreText 绘制，注音排在词的上方；
    /// 为空时与不带注音时逐像素一致。边框、选中态、命中区都不受影响。
    let runs: [RubyRun]?
    let action: () -> Void

    public init(
        text: String,
        state: SentenceState,
        isSelected: Bool,
        fontSize: CGFloat = 18,
        runs: [RubyRun]? = nil,
        action: @escaping () -> Void
    ) {
        self.text = text
        self.state = state
        self.isSelected = isSelected
        self.fontSize = fontSize
        self.runs = runs
        self.action = action
    }

    private var borderColor: Color {
        if isSelected { return theme.primary }
        switch state {
        case .plain: return .clear
        case .translated: return theme.translatedHint.opacity(0.4)
        case .explained: return theme.explained.opacity(0.4)
        }
    }

    private var stateDescription: LocalizedStringKey {
        switch state {
        case .plain: "chip.state.plain"
        case .translated: "chip.state.translated"
        case .explained: "chip.state.explained"
        }
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS)
        if let runs, !runs.isEmpty {
            RubyLabel(
                runs: runs, fontSize: fontSize,
                color: theme.foreground, rubyColor: theme.mutedForeground)
        } else {
            Text(text)
                .font(.system(size: fontSize))
                .foregroundStyle(theme.foreground)
        }
        #else
        Text(text)
            .font(.system(size: fontSize))
            .foregroundStyle(theme.foreground)
        #endif
    }

    public var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: OKRadius.chip)
                        .fill(isSelected ? theme.primary.opacity(0.18) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: OKRadius.chip)
                        .strokeBorder(borderColor, lineWidth: 1.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: OKRadius.chip))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(text))
        .accessibilityValue(Text(stateDescription, bundle: .module))
    }
}
