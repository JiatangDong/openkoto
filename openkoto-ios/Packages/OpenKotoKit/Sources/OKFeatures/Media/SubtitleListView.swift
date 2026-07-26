#if os(iOS)
import OKDesignSystem
import OKLocalization
import OKModels
import SwiftUI

/// 字幕列表。自动滚到当前句，但**用户一拖就停止跟随**。
///
/// 桌面端只是忘了调 `scrollIntoView`（`activeSegmentRef` 赋了值却从没用过），
/// 但光把自动滚动加上会造出一个新毛病：用户往回翻看前面的句子时被强行拽回当前句。
/// 所以必须配跟随模式，并且**不做定时自动恢复**——突然被拽走是最惹人烦的交互。
struct SubtitleListView: View {
    @Environment(\.theme) private var theme

    let segments: [ArticleSegment]
    let activeID: UUID?
    let isInGap: Bool
    let selectedID: UUID?
    let loopingID: UUID?
    let readingRuns: [UUID: [ReadingRun]]
    let fontSize: Double
    /// 盲听：文本被遮住，只留时间与循环标记。
    let isBlind: Bool
    /// 盲听中被临时揭晓的那一句。
    let revealedID: UUID?
    let onTap: (ArticleSegment) -> Void
    let onExplain: (ArticleSegment) -> Void
    let onToggleLoop: (ArticleSegment) -> Void

    @State private var isFollowing = true

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(segments) { segment in
                            SubtitleRow(
                                segment: segment,
                                isActive: segment.id == activeID,
                                isDimmed: segment.id == activeID && isInGap,
                                isSelected: segment.id == selectedID,
                                isLooping: segment.id == loopingID,
                                runs: readingRuns[segment.id],
                                fontSize: fontSize,
                                isMasked: isBlind && segment.id != revealedID,
                                onTap: { onTap(segment) },
                                onExplain: { onExplain(segment) },
                                onToggleLoop: { onToggleLoop(segment) }
                            )
                            .id(segment.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                // 手一碰就停止跟随。用 simultaneousGesture 以免吃掉行内的点击。
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12).onChanged { _ in
                        if isFollowing { isFollowing = false }
                    })
                .onChange(of: activeID) { _, id in
                    guard isFollowing, let id else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }

                if !isFollowing {
                    resumeButton(proxy: proxy)
                }
            }
        }
    }

    private func resumeButton(proxy: ScrollViewProxy) -> some View {
        Button {
            isFollowing = true
            if let activeID {
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(activeID, anchor: .center)
                }
            }
        } label: {
            Label(L("media.backToCurrent"), systemImage: "arrow.down.circle")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(theme.card, in: Capsule())
                .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))
                .foregroundStyle(theme.primary)
                .shadow(radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// 单条字幕：时间徽章 + 句子（复用 `SentenceChip`，连带已精讲/已翻译的边框语义与注音）。
struct SubtitleRow: View {
    @Environment(\.theme) private var theme

    let segment: ArticleSegment
    let isActive: Bool
    let isDimmed: Bool
    let isSelected: Bool
    let isLooping: Bool
    let runs: [ReadingRun]?
    let fontSize: Double
    /// 盲听遮罩。用 `.redacted` 而不是把文本换成占位符：
    /// 版式宽高完全不变，揭晓时不会整列跳动。
    var isMasked = false
    let onTap: () -> Void
    let onExplain: () -> Void
    let onToggleLoop: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(Self.timeText(segment.startTime))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isActive ? theme.primary : theme.mutedForeground)
                .frame(width: 46, alignment: .trailing)
                .padding(.top, 6)

            SentenceChip(
                text: segment.text,
                state: segment.explanation != nil
                    ? .explained : segment.translation != nil ? .translated : .plain,
                isSelected: isSelected,
                fontSize: fontSize,
                // 遮住时连注音一起遮——留着读音等于没遮。
                runs: isMasked
                    ? nil : runs?.map { RubyRun(text: $0.text, reading: $0.reading) },
                action: onTap
            )
            .redacted(reason: isMasked ? .placeholder : [])
            // 遮住时把点击从 chip 挪到上面一层透明视图：SwiftUI 对 redacted 子树里的
            // 控件是否还响应点击并没有承诺，而"点一下揭晓"恰恰是盲听的唯一操作，
            // 不能押在这上面。
            .allowsHitTesting(!isMasked)
            .overlay {
                if isMasked {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onTap)
                        // 遮罩是环境值，会往下传给 overlay 的内容；这里清掉，
                        // 让这层纯粹只做"接住点击"。
                        .unredacted()
                }
            }
            .accessibilityLabel(Text(isMasked ? L("media.blind.hidden") : segment.text))
            .accessibilityAddTraits(.isButton)

            Spacer(minLength: 0)

            if isLooping {
                Image(systemName: "repeat.1")
                    .font(.caption)
                    .foregroundStyle(theme.primary)
                    .padding(.top, 6)
            }
        }
        .padding(.vertical, 2)
        .background(
            isActive ? theme.primary.opacity(isDimmed ? 0.05 : 0.12) : .clear,
            in: RoundedRectangle(cornerRadius: OKRadius.chip))
        .contextMenu {
            Button {
                onExplain()
            } label: {
                Label(L("explanation.explanation"), systemImage: "sparkles")
            }
            Button {
                onToggleLoop()
            } label: {
                Label(
                    isLooping ? L("media.loop.stop") : L("media.loop.start"),
                    systemImage: "repeat.1")
            }
        }
    }

    static func timeText(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "--:--" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
#endif
