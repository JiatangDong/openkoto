#if os(iOS)
import OKDesignSystem
import OKLocalization
import OKModels
import SwiftUI

/// 书库里的媒体卡片。
struct MediaCard: View {
    @Environment(ContentStore.self) private var store
    @Environment(\.theme) private var theme

    let media: Media

    var body: some View {
        let progress = store.mediaArticleID(for: media.id).map { store.progress(for: $0) }
        ThemedCard {
            HStack(spacing: 12) {
                Image(systemName: media.kind == .video ? "film" : "waveform")
                    .font(.title3)
                    .foregroundStyle(theme.primary)
                    .frame(width: 40, height: 40)
                    .background(
                        theme.primary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: OKRadius.chip))
                VStack(alignment: .leading, spacing: 6) {
                    Text(media.title)
                        .font(.headline)
                        .foregroundStyle(theme.cardForeground)
                        .lineLimit(2)
                    HStack(spacing: 12) {
                        Text(media.createdAt, style: .date)
                        if media.duration > 0 {
                            Label(
                                Self.durationText(media.duration),
                                systemImage: "clock")
                        }
                        if let progress, progress.total > 0 {
                            Label("\(progress.total)", systemImage: "text.alignleft")
                        }
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(theme.mutedForeground)
                }
            }
        }
    }

    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
#endif
