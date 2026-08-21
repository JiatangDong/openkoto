#if os(iOS)
import SwiftUI
import OKDesignSystem
import OKLocalization

/// 视频下载导引。
///
/// App Store 不允许应用内直接下载 YouTube / Bilibili 视频（guideline 5.2.3），
/// 内置 yt-dlp 的方案审核必拒——所以这里只推一条最简单的路：cobalt.tools 网页解析，
/// 免费、无需注册、两个平台都支持。不给第二选择，选择多了用户反而不知道点哪个。
struct MediaDownloadGuideSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    private static let cobaltURL = URL(string: "https://cobalt.tools")!

    var body: some View {
        NavigationStack {
            List {
                Section {
                    stepRow(1, text: L("import.media.guide.step1"))
                    stepRow(2, text: L("import.media.guide.step2"))
                    stepRow(3, text: L("import.media.guide.step3"))
                }

                Section {
                    Link(destination: Self.cobaltURL) {
                        Label(L("import.media.guide.open"), systemImage: "safari")
                    }
                }

                Section {
                    Text(L("import.media.guide.note"))
                        .font(.footnote)
                        .foregroundStyle(theme.mutedForeground)
                }
            }
            .background(theme.background)
            .navigationTitle(L("import.media.guide.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.close")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .okSheetSizing(.page)
    }

    private func stepRow(_ number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number, format: .number)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.accentForeground)
                .frame(width: 24, height: 24)
                .background(Circle().fill(theme.accent))
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}
#endif
