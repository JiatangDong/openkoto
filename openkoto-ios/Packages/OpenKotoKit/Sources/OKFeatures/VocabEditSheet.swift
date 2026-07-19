#if os(iOS)
import SwiftUI
import OKModels
import OKDesignSystem
import OKLocalization

/// 手动添加 / 编辑单词的共用表单(词形、释义、读音、用法、例句)。
struct VocabEditSheet: View {
    @Environment(ContentStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// 编辑既有卡片时传入;新增为 nil
    let favorite: FavoriteVocabulary?

    @State private var word = ""
    @State private var meaning = ""
    @State private var reading = ""
    @State private var usage = ""
    @State private var example = ""
    @State private var selectedPackIds: Set<UUID> = []
    @State private var showDuplicateError = false

    private var isEdit: Bool { favorite != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("vocabulary.fieldWord"), text: $word)
                    TextField(L("vocabulary.fieldMeaning"), text: $meaning)
                    TextField(L("vocabulary.fieldReading"), text: $reading)
                    TextField(L("vocabulary.fieldUsage"), text: $usage)
                    TextField(L("vocabulary.fieldExample"), text: $example, axis: .vertical)
                } footer: {
                    if showDuplicateError {
                        Text(L("vocabulary.duplicateWord"))
                            .foregroundStyle(theme.destructive)
                    }
                }
                Section(L("vocabulary.fieldPacks")) {
                    ForEach(store.packs) { pack in
                        packRow(pack)
                    }
                }
            }
            .navigationTitle(isEdit ? L("vocabulary.editWord") : L("vocabulary.addWord"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEdit ? L("common.save") : L("common.add")) { submit() }
                        .disabled(
                            word.trimmingCharacters(in: .whitespaces).isEmpty
                                || meaning.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let favorite {
                    word = favorite.word
                    meaning = favorite.meaning
                    reading = favorite.reading ?? ""
                    usage = favorite.usage ?? ""
                    example = favorite.example ?? ""
                    selectedPackIds = Set(favorite.packIds)
                } else {
                    // 新增默认归入当前选中的合集(未选中时归"未分组")
                    selectedPackIds = [store.activePackId ?? WordPack.systemUngroupedID]
                }
            }
        }
    }

    private func packRow(_ pack: WordPack) -> some View {
        Button {
            if selectedPackIds.contains(pack.id) {
                selectedPackIds.remove(pack.id)
            } else {
                selectedPackIds.insert(pack.id)
            }
        } label: {
            HStack {
                Text(PackDisplay.name(pack))
                    .foregroundStyle(theme.foreground)
                Spacer()
                if selectedPackIds.contains(pack.id) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(theme.primary)
                }
            }
        }
    }

    private func submit() {
        let succeeded: Bool
        if let favorite {
            succeeded = store.updateFavorite(
                id: favorite.id, word: word, meaning: meaning,
                reading: reading, usage: usage, example: example)
            if succeeded {
                store.setPackIds(favorite.id, packIds: Array(selectedPackIds))
            }
        } else {
            succeeded = store.addManualWord(
                word: word, meaning: meaning,
                reading: reading, usage: usage, example: example,
                packIds: Array(selectedPackIds))
        }
        if succeeded {
            dismiss()
        } else {
            showDuplicateError = true
        }
    }
}
#endif
