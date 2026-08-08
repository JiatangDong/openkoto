#if os(iOS)
import OKAIClient
import OKDesignSystem
import OKLocalization
import SwiftUI
import UIKit

/// 批量任务的进度条：进行中显示进度与取消，跑完若有可重试的失败句则显示重试入口。
///
/// 文章与书籍章节共用一份——它们此前各写了一遍，加"失败数"时正好收敛掉，
/// 免得再漂移出第三份。
struct BatchProgressBar: View {
    @Environment(ContentStore.self) private var store
    @Environment(\.theme) private var theme

    let articleID: UUID

    @State private var diagnosticsCopied = false

    var body: some View {
        if let state = store.batchByArticle[articleID] {
            running(state)
        } else if let failures = store.batchFailures(articleID: articleID),
            !failures.segmentIDs.isEmpty
        {
            // 不可重试的失败（401、余额不足、解析失败……）也必须停留在这里——
            // 旧实现只在"可重试 > 0"时显示，整批 401 全灭时横幅直接消失，
            // 用户只能报告"全都失败了，什么提示都没有"。
            failurePrompt(failures)
        }
    }

    private func running(_ state: ContentStore.BatchState) -> some View {
        let fraction = state.total > 0 ? Double(state.completed) / Double(state.total) : 0
        let isCancelling = state.phase == .cancelling
        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(
                    L(isCancelling
                        ? "reader.batch.cancelling"
                        : state.kind == .explain
                            ? "reader.batch.explaining" : "reader.batch.translating")
                )
                .font(.footnote.weight(.medium))
                .foregroundStyle(theme.foreground)

                // 失败数必须在跑的时候就看得见——否则整批因 401 全灭，
                // 用户看到的只是进度条走满然后消失。
                if state.failed > 0 {
                    Text(L("reader.batch.failed\(state.failed)"))
                        .font(.caption)
                        .foregroundStyle(theme.destructive)
                }
                Spacer()
                Text(verbatim: "\(state.completed)/\(state.total)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(theme.mutedForeground)
                if !isCancelling {
                    Button(L("reader.batch.cancel")) {
                        store.cancelBatch(articleID: articleID)
                    }
                    .font(.footnote)
                }
            }
            ProgressView(value: fraction)
                .tint(isCancelling ? theme.mutedForeground : theme.primary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func failurePrompt(_ failures: ContentStore.BatchFailures) -> some View {
        let retryable = store.retryableFailureCount(articleID: articleID)
        let firstFailure = store.firstBatchFailure(articleID: articleID)
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(theme.destructive)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("reader.batch.failed\(failures.segmentIDs.count)"))
                    .font(.footnote)
                    .foregroundStyle(theme.foreground)
                // 失败原因必须直接可见："余额不足"和"限流"用户要做的事完全不同。
                if let (error, _) = firstFailure {
                    Text(userMessage(for: error))
                        .font(.caption)
                        .foregroundStyle(theme.mutedForeground)
                        .lineLimit(1)
                }
            }
            Spacer()
            if firstFailure != nil {
                Button {
                    copyDiagnostics()
                } label: {
                    Image(systemName: diagnosticsCopied ? "checkmark" : "doc.on.doc")
                }
                .font(.footnote)
                .accessibilityLabel(
                    L(diagnosticsCopied
                        ? "explanation.diagnosticsCopied" : "explanation.copyDiagnostics"))
            }
            if retryable > 0 {
                Button(L("reader.batch.retryFailed")) {
                    store.retryFailedInBatch(articleID: articleID)
                }
                .font(.footnote.weight(.medium))
            }
            Button {
                store.dismissBatchFailures(articleID: articleID)
            } label: {
                Image(systemName: "xmark")
            }
            .font(.footnote)
            .foregroundStyle(theme.mutedForeground)
            .accessibilityLabel(L("reader.batch.dismiss"))
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// 把第一个失败句的完整现场复制给用户转发开发者——批量场景不进精讲面板，
    /// 这里是失败诊断唯一的出口。
    private func copyDiagnostics() {
        guard let (error, diagnostics) = store.firstBatchFailure(articleID: articleID) else {
            return
        }
        Task {
            let report = await AIDiagnosticsReport.make(error: error, diagnostics: diagnostics)
            UIPasteboard.general.string = report
            diagnosticsCopied = true
            try? await Task.sleep(for: .seconds(2))
            diagnosticsCopied = false
        }
    }
}
#endif
