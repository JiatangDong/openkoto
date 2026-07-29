#if os(iOS)
import OKDesignSystem
import OKLocalization
import SwiftUI

/// 传输条：进度 + 播放/暂停 + ±5 秒 + 变速 + 盲听。
///
/// 变速与盲听都放在这一层而不是藏进菜单——跟读练习会频繁在 0.75× 与 1× 之间切，
/// 也会频繁开关字幕（先盲听、听不懂再看）。藏进菜单等于让人每句点三下。
struct TransportBar: View {
    @Environment(\.theme) private var theme
    @Environment(\.okCanvas) private var canvas

    let currentTime: Double
    let duration: Double
    let isPlaying: Bool
    let isEnabled: Bool
    /// 盲听：遮住字幕文本，只留时间轴与循环。
    let isBlind: Bool
    @Binding var rate: Float
    let onTogglePlay: () -> Void
    let onSkip: (Double) -> Void
    let onScrub: (Double) -> Void
    let onToggleBlind: () -> Void

    /// 拖动进度条时不让播放位置回弹：拖动期间用本地值，松手才提交。
    @State private var scrubbing: Double?

    private static let rates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        VStack(spacing: 6) {
            slider
            HStack {
                Text(Self.timeText(scrubbing ?? currentTime))
                Spacer()
                Text(Self.timeText(duration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(theme.mutedForeground)

            HStack(spacing: 28) {
                // 两侧固定同宽，播放键才真的在中间——否则变速文案从 "1×" 变成
                // "0.75×" 时整排按钮会跟着挪。
                rateMenu.frame(width: 56, alignment: .leading)
                Spacer()
                skipButton(-5, symbol: "gobackward.5")
                playButton
                skipButton(5, symbol: "goforward.5")
                Spacer()
                blindButton.frame(width: 56, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // 控件本身的固定宽度是刻意的（见上），但整条 bar 要限宽居中：
        // 不限的话进度条会横跨 1300pt，两端的时间戳离播放键有半个屏幕远。
        .frame(maxWidth: canvas.isWide ? 640 : .infinity)
        .frame(maxWidth: .infinity)
        .background(theme.card)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }

    private var slider: some View {
        Slider(
            value: Binding(
                get: { scrubbing ?? min(currentTime, max(duration, 0.001)) },
                set: { scrubbing = $0 }),
            in: 0...max(duration, 0.001),
            onEditingChanged: { editing in
                if !editing, let value = scrubbing {
                    onScrub(value)
                    scrubbing = nil
                }
            }
        )
        .tint(theme.primary)
    }

    private var playButton: some View {
        Button(action: onTogglePlay) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 30))
                .foregroundStyle(theme.primary)
                .frame(width: 52, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L(isPlaying ? "media.pause" : "media.play")))
    }

    private func skipButton(_ seconds: Double, symbol: String) -> some View {
        Button {
            onSkip(seconds)
        } label: {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(theme.foreground)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
    }

    private var blindButton: some View {
        Button(action: onToggleBlind) {
            Image(systemName: isBlind ? "eye.slash.fill" : "eye")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isBlind ? theme.primary.opacity(0.18) : theme.muted, in: Capsule())
                .foregroundStyle(isBlind ? theme.primary : theme.foreground)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L(isBlind ? "media.blind.off" : "media.blind.on")))
    }

    private var rateMenu: some View {
        Menu {
            Picker(L("media.rate"), selection: $rate) {
                ForEach(Self.rates, id: \.self) { value in
                    Text(verbatim: Self.rateText(value)).tag(value)
                }
            }
        } label: {
            Text(verbatim: Self.rateText(rate))
                .font(.footnote.weight(.medium).monospacedDigit())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(theme.muted, in: Capsule())
                .foregroundStyle(theme.foreground)
        }
        .accessibilityLabel(Text(L("media.rate")))
    }

    static func rateText(_ rate: Float) -> String {
        rate == rate.rounded()
            ? String(format: "%.0f×", rate) : String(format: "%.2g×", rate)
    }

    static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, (total % 3600) / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
#endif
