#if os(iOS)
import OKDesignSystem
import OKLocalization
import SwiftUI

/// 设置页的「iCloud 同步」区。
struct SyncSection: View {
    @Environment(ContentStore.self) private var store
    @Environment(\.theme) private var theme

    @State private var isEnabled = false

    var body: some View {
        Section {
            Toggle(L("settings.sync.toggle"), isOn: $isEnabled)
                .onChange(of: isEnabled) { _, newValue in
                    Task { await store.setSyncEnabled(newValue) }
                }

            if isEnabled {
                Button {
                    Task { await store.syncNow() }
                } label: {
                    Label(L("settings.sync.now"), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(store.syncStatus == .syncing)

                statusRow
            }
        } header: {
            Text(L("settings.sync"))
        } footer: {
            Text(L("settings.sync.footer"))
        }
        .task { isEnabled = store.isSyncEnabled }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch store.syncStatus {
        case .syncing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("settings.sync.status.syncing"))
                    .foregroundStyle(theme.mutedForeground)
            }
        case .idle(let lastSyncedAt):
            Text(
                lastSyncedAt.map {
                    String(
                        format: L("settings.sync.lastSynced"),
                        $0.formatted(date: .abbreviated, time: .shortened))
                } ?? L("settings.sync.status.never")
            )
            .font(.footnote)
            .foregroundStyle(theme.mutedForeground)
        case .unavailable:
            // 没登录 iCloud 不是故障，别用红色吓用户。
            Text(L("settings.sync.status.unavailable"))
                .font(.footnote)
                .foregroundStyle(theme.mutedForeground)
        case .failed(let detail):
            VStack(alignment: .leading, spacing: 2) {
                Text(L("settings.sync.status.failed"))
                    .font(.footnote)
                    .foregroundStyle(theme.destructive)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(theme.mutedForeground)
            }
        case .disabled:
            EmptyView()
        }
    }
}
#endif
