#if os(iOS)
import OKDesignSystem
import OKLocalization
import OKModels
import SwiftUI

/// 设置页的「数据」区：导入 / 导出传输包。
///
/// Apple 三平台之间由 CloudKit 自动同步，这里主要解决两件事：
/// 1. 把 Tauri 桌面版（另一个 App，进不了同一个 CloudKit 容器）加工好的素材送进来；
/// 2. 让用户能把自己的数据带走。
struct DataTransferSection: View {
    @Environment(ContentStore.self) private var store
    @Environment(\.theme) private var theme

    @AppStorage("transfer.exportIncludesContent") private var includeContent = true

    @State private var isImporting = false
    @State private var isExporting = false
    @State private var exportDocument: TransferDocument?
    @State private var outcome: ContentStore.TransferOutcome?
    @State private var isBusy = false

    var body: some View {
        Section {
            Button {
                isImporting = true
            } label: {
                Label(L("settings.data.import"), systemImage: "square.and.arrow.down")
            }
            .disabled(isBusy)

            Button {
                Task { await prepareExport() }
            } label: {
                Label(L("settings.data.export"), systemImage: "square.and.arrow.up")
            }
            .disabled(isBusy)

            Toggle(L("settings.data.includeContent"), isOn: $includeContent)
        } header: {
            Text(L("settings.data"))
        } footer: {
            Text(L("settings.data.footer"))
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: TransferFile.readableContentTypes
        ) { result in
            guard case .success(let url) = result else { return }
            Task {
                isBusy = true
                outcome = await store.importTransferFile(at: url)
                isBusy = false
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: TransferFile.exportContentType,
            defaultFilename: TransferBundle.fileName(for: .now)
        ) { _ in
            exportDocument = nil
        }
        // 不用 `.constant(outcome != nil)`：那样系统自己关闭弹窗时状态不会回落，
        // 之后再导入就永远弹不出来了。
        .alert(
            alertTitle,
            isPresented: Binding(
                get: { outcome != nil },
                set: { if !$0 { outcome = nil } }),
            presenting: outcome
        ) { _ in
            Button(L("common.ok")) { outcome = nil }
        } message: { outcome in
            Text(Self.message(for: outcome))
        }
    }

    private var alertTitle: String {
        if case .failed = outcome { return L("settings.data.import.failed") }
        return L("settings.data.import.done")
    }

    private func prepareExport() async {
        isBusy = true
        defer { isBusy = false }
        switch await store.exportTransferData(includeContent: includeContent) {
        case .success(let data):
            exportDocument = TransferDocument(data: data)
            isExporting = true
        case .failure(let failure):
            outcome = .failed(failure)
        }
    }

    // MARK: - 文案

    /// 导入结果必须**把跳过也说清楚**：用户导 100 个词只进来 60 个，
    /// 不给理由的话他只会认为导入坏了。
    static func message(for outcome: ContentStore.TransferOutcome) -> String {
        switch outcome {
        case .imported(let result):
            guard result.changedAnything else { return L("settings.data.import.nothingNew") }
            var lines: [String] = []
            append(&lines, L("tab.vocabulary"), result.vocabulary)
            append(&lines, L("settings.data.entity.packs"), result.packs)
            append(&lines, L("settings.data.entity.articles"), result.articles)
            append(&lines, L("settings.data.entity.explanations"), result.segments)
            append(&lines, L("settings.data.entity.reviews"), result.reviewEvents)
            return lines.joined(separator: "\n")
        case .failed(let failure):
            switch failure {
            case .unreadable: return L("settings.data.error.unreadable")
            case .notATransferBundle: return L("settings.data.error.notBundle")
            case .appTooOld: return L("settings.data.error.appTooOld")
            case .malformed(let detail): return detail
            case .writeFailed(let detail): return detail
            }
        }
    }

    private static func append(_ lines: inout [String], _ name: String, _ counts: ImportCounts) {
        guard counts.total > 0 else { return }
        var parts = ["\(name):"]
        if counts.inserted > 0 {
            parts.append("\(L("settings.data.count.added")) \(counts.inserted)")
        }
        if counts.updated > 0 {
            parts.append("\(L("settings.data.count.updated")) \(counts.updated)")
        }
        // 两种跳过分开说：「已删除」和「本地更新」是完全不同的原因，
        // 合并成一个"跳过 N"用户仍然不知道该不该担心。
        if counts.skippedDeleted > 0 {
            parts.append("\(L("settings.data.count.skippedDeleted")) \(counts.skippedDeleted)")
        }
        if counts.skippedLocalNewer > 0 {
            parts.append(
                "\(L("settings.data.count.skippedLocalNewer")) \(counts.skippedLocalNewer)")
        }
        lines.append(parts.joined(separator: " · "))
    }
}
#endif
