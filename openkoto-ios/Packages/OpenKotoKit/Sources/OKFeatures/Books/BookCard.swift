#if os(iOS)
import SwiftUI
import OKModels
import OKDesignSystem
import OKLocalization

/// 书库里的书籍卡片：书名、作者、章节数、续读位置。
struct BookCard: View {
    @Environment(ContentStore.self) private var store
    @Environment(\.theme) private var theme

    let book: Book

    var body: some View {
        let chapters = store.chapterSummaries(of: book.id)
        ThemedCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: book.format == .epub ? "book.closed" : "doc.text")
                        .font(.caption)
                        .foregroundStyle(theme.mutedForeground)
                    Text(book.title)
                        .font(.headline)
                        .foregroundStyle(theme.cardForeground)
                        .lineLimit(2)
                }
                if let author = book.author, !author.isEmpty {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(theme.mutedForeground)
                        .lineLimit(1)
                }
                HStack(spacing: 12) {
                    Text(book.createdAt, style: .date)
                    Label("\(chapters.count)", systemImage: "list.bullet")
                    Spacer()
                    resumeBadge(chapters: chapters)
                }
                .font(.caption)
                .foregroundStyle(theme.mutedForeground)
            }
        }
        // 整张卡片作为一个可读单元，否则 VoiceOver 会把书名/作者/章节数拆成四条。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(chapters: chapters))
    }

    private func accessibilityLabel(chapters: [BookChapterSummary]) -> String {
        var parts = [book.title]
        if let author = book.author, !author.isEmpty { parts.append(author) }
        parts.append(L("book.chapterCount\(chapters.count)"))
        if let progress = store.progress(ofBook: book.id), !chapters.isEmpty {
            let number = min(progress.chapterIndex + 1, chapters.count)
            parts.append(L("book.resumeSpoken\(number)"))
        }
        return parts.joined(separator: "，")
    }

    /// 续读位置。没读过就不显示——空进度条比没有更碍事。
    @ViewBuilder
    private func resumeBadge(chapters: [BookChapterSummary]) -> some View {
        if let progress = store.progress(ofBook: book.id), !chapters.isEmpty {
            let chapterNumber = min(progress.chapterIndex + 1, chapters.count)
            let percent = Int((Double(chapterNumber) / Double(chapters.count) * 100).rounded())
            Text(L("book.resume\(chapterNumber)\(percent)"))
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(theme.primary.opacity(0.12), in: Capsule())
                .foregroundStyle(theme.primary)
        }
    }
}
#endif
