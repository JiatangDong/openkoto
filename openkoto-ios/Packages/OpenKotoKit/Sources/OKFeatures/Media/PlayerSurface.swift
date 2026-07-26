#if os(iOS)
import AVFoundation
import AVKit
import OKDesignSystem
import OKLocalization
import OKModels
import SwiftUI
import UIKit

/// 视频画面。用 `AVPlayerLayer` 而不是 `VideoPlayer`——后者自带一整套系统控件，
/// 会和我们的传输条打架，也没法把「单句循环」这类学习功能放进去。
struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// 播放区：视频画面 / 音频占位 / 媒体不可用的降级提示。
struct MediaSurface: View {
    @Environment(\.theme) private var theme

    let media: Media
    let player: AVPlayer
    /// 媒体文件是否可用。引用的文件被删/移走/iCloud 未下载时为 false——
    /// 此时文稿与精讲照常可用，只是不能播（同书籍「原始文件丢了但正文还在」的降级形状）。
    let isAvailable: Bool

    var body: some View {
        ZStack {
            if !isAvailable {
                unavailable
            } else if media.kind == .video {
                PlayerSurface(player: player)
            } else {
                audioPlaceholder
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
        .background(media.kind == .video && isAvailable ? Color.black : theme.muted)
        .clipped()
    }

    private var audioPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 40))
                .foregroundStyle(theme.primary)
            Text(media.title)
                .font(.headline)
                .foregroundStyle(theme.foreground)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    private var unavailable: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(theme.mutedForeground)
            Text(L("media.unavailable"))
                .font(.subheadline)
                .foregroundStyle(theme.mutedForeground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }
}
#endif
