#if os(iOS)
import SwiftUI
import OKModels
import OKBooks
import OKDesignSystem
import OKLocalization

/// 书签与划线面板：按章分组、点击跳转、可加备注、滑动删除。
struct BookmarksSheet: View {
    @Environment(ContentStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let book: Book
    /// 跳转回调：章节序号 + 章内句序。
    let onSelect: (Int, Int?) -> Void

    @State private var editingMark: BookMark?

    private var chapters: [BookChapterSummary] {
        store.chapterSummaries(of: book.id)
    }

    private var grouped: [(index: Int, title: String, marks: [BookMark])] {
        let marks = store.marks(ofBook: book.id)
        let indices = Set(marks.map(\.chapterIndex)).sorted()
        return indices.map { index in
            (
                index,
                chapters.indices.contains(index) ? chapters[index].title : "\(index + 1)",
                marks.filter { $0.chapterIndex == index }
            )
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if grouped.isEmpty {
                    ContentUnavailableView(
                        L("bookmark.empty.title"), systemImage: "bookmark",
                        description: Text(L("bookmark.empty.message")))
                } else {
                    list
                }
            }
            .navigationTitle(L("bookmark.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.done")) { dismiss() }
                }
            }
            .sheet(item: $editingMark) { mark in
                MarkNoteSheet(mark: mark)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var list: some View {
        List {
            ForEach(grouped, id: \.index) { group in
                Section(group.title) {
                    ForEach(group.marks) { mark in
                        row(mark)
                    }
                    .onDelete { offsets in
                        for offset in offsets { store.deleteMark(group.marks[offset]) }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    /// 只有该章句子已在内存里才判断得了；没加载就先不声张。
    private func isApproximate(_ mark: BookMark) -> Bool {
        guard chapters.indices.contains(mark.chapterIndex) else { return false }
        let segments = store.segments(for: chapters[mark.chapterIndex].articleId)
        guard !segments.isEmpty else { return false }
        return MarkAnchor.resolve(mark, in: segments).isApproximate
    }

    private func row(_ mark: BookMark) -> some View {
        Button {
            onSelect(mark.chapterIndex, mark.segmentOrder)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: mark.kind == .highlight ? "highlighter" : "bookmark.fill")
                    .font(.caption)
                    .foregroundStyle(mark.kind == .highlight ? theme.vocabAccent : theme.primary)
                VStack(alignment: .leading, spacing: 4) {
                    if let text = mark.selectedText, !text.isEmpty {
                        Text(text)
                            .font(.callout)
                            .foregroundStyle(theme.foreground)
                            .lineLimit(3)
                    }
                    if let note = mark.note, !note.isEmpty {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(theme.mutedForeground)
                            .lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        Text(mark.createdAt, style: .date)
                        // 原文已经找不到、只能按比例落点时明说，别让用户以为跳错了。
                        if isApproximate(mark) {
                            Label(L("bookmark.approximate"), systemImage: "questionmark.circle")
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(theme.mutedForeground)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) {
            Button {
                editingMark = mark
            } label: {
                Label(L("bookmark.note"), systemImage: "square.and.pencil")
            }
            .tint(theme.primary)
        }
    }
}

/// 备注编辑。
private struct MarkNoteSheet: View {
    @Environment(ContentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let mark: BookMark
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                if let text = mark.selectedText, !text.isEmpty {
                    Section { Text(text).font(.callout) }
                }
                Section(L("bookmark.note")) {
                    TextField(L("bookmark.note"), text: $note, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle(L("bookmark.note"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { note = mark.note ?? "" }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.save")) {
                        var updated = mark
                        updated.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.updatedAt = .now
                        store.saveMark(updated)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
#endif
