#if os(iOS)
import SwiftUI
import OKModels
import OKDesignSystem
import OKLocalization

/// 词包(合集)管理:新建 / 重命名 / 删除(系统"未分组"不可改删)。
/// 删除语义镜像桌面端:包内不再属于任何合集的单词归入"未分组"。
struct PackManagerSheet: View {
    @Environment(ContentStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var isCreatePresented = false
    @State private var renamingPack: WordPack?
    @State private var deletingPack: WordPack?
    @State private var nameInput = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.packs) { pack in
                    row(pack)
                        .listRowBackground(theme.card)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle(L("vocabulary.packListTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.close")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        nameInput = ""
                        isCreatePresented = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(L("vocabulary.newPack"))
                }
            }
            .alert(L("vocabulary.newPack"), isPresented: $isCreatePresented) {
                TextField(L("vocabulary.packName"), text: $nameInput)
                Button(L("common.cancel"), role: .cancel) {}
                Button(L("common.add")) { store.createPack(name: nameInput) }
            } message: {
                Text(L("vocabulary.newPackPrompt"))
            }
            .alert(
                L("vocabulary.renamePack"),
                isPresented: Binding(
                    get: { renamingPack != nil },
                    set: { if !$0 { renamingPack = nil } })
            ) {
                TextField(L("vocabulary.packName"), text: $nameInput)
                Button(L("common.cancel"), role: .cancel) {}
                Button(L("common.save")) {
                    if let pack = renamingPack {
                        store.renamePack(pack.id, name: nameInput)
                    }
                }
            } message: {
                Text(L("vocabulary.renamePackPrompt"))
            }
            .confirmationDialog(
                L("vocabulary.deletePackConfirm"),
                isPresented: Binding(
                    get: { deletingPack != nil },
                    set: { if !$0 { deletingPack = nil } }),
                titleVisibility: .visible
            ) {
                Button(L("vocabulary.deletePackAction"), role: .destructive) {
                    if let pack = deletingPack {
                        store.deletePack(pack.id)
                    }
                }
            } message: {
                Text(L("vocabulary.deletePackMessage"))
            }
        }
    }

    private func wordCount(in pack: WordPack) -> Int {
        store.favorites.count { $0.packIds.contains(pack.id) }
    }

    private func row(_ pack: WordPack) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(PackDisplay.name(pack))
                    .font(.body)
                Text(L("vocabulary.wordCount\(wordCount(in: pack))"))
                    .font(.caption)
                    .foregroundStyle(theme.mutedForeground)
            }
            Spacer()
            if pack.isSystem {
                Image(systemName: "lock")
                    .font(.caption)
                    .foregroundStyle(theme.mutedForeground)
            }
        }
        .swipeActions(edge: .trailing) {
            if !pack.isSystem {
                Button(role: .destructive) {
                    deletingPack = pack
                } label: {
                    Label(L("vocabulary.deletePackAction"), systemImage: "trash")
                }
                Button {
                    nameInput = pack.name
                    renamingPack = pack
                } label: {
                    Label(L("vocabulary.renamePack"), systemImage: "pencil")
                }
                .tint(theme.primary)
            }
        }
    }
}

/// 词包显示名:系统"未分组"包按当前语言本地化,用户包用存储名。
enum PackDisplay {
    static func name(_ pack: WordPack) -> String {
        pack.isSystem ? L("vocabulary.packUngrouped") : pack.name
    }
}
#endif
