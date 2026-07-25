#if os(iOS)
import SwiftUI
import OKModels
import OKDesignSystem
import OKLocalization

/// 章节目录：跳转 + 每章精讲进度。
struct ChapterListSheet: View {
    @Environment(ContentStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let book: Book
    let currentIndex: Int
    let onSelect: (Int) -> Void

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(store.chapterSummaries(of: book.id).enumerated()), id: \.offset) {
                        index, chapter in
                        row(index: index, chapter: chapter)
                            .id(index)
                    }
                }
                .listStyle(.plain)
                .onAppear { proxy.scrollTo(currentIndex, anchor: .center) }
            }
            .navigationTitle(L("book.toc"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(index: Int, chapter: BookChapterSummary) -> some View {
        let progress = store.progress(for: chapter.articleId)
        return Button {
            onSelect(index)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Text(verbatim: "\(index + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.mutedForeground)
                    .frame(minWidth: 28, alignment: .trailing)
                VStack(alignment: .leading, spacing: 3) {
                    Text(chapter.title)
                        .font(.callout.weight(index == currentIndex ? .semibold : .regular))
                        .foregroundStyle(index == currentIndex ? theme.primary : theme.foreground)
                        .lineLimit(2)
                    Text(L("book.chapter.charCount\(chapter.charCount)"))
                        .font(.caption2)
                        .foregroundStyle(theme.mutedForeground)
                }
                Spacer()
                // 未切分的章节还没有句子，不显示 0/0 这种误导性进度。
                if progress.total > 0, progress.explained > 0 {
                    Text(verbatim: "\(progress.explained)/\(progress.total)")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(theme.explained.opacity(0.12), in: Capsule())
                        .foregroundStyle(theme.explained)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
#endif
