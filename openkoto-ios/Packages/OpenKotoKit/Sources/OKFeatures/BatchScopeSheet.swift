#if os(iOS)
import OKDesignSystem
import OKLocalization
import SwiftUI

/// 批量精讲/翻译的范围选择。
///
/// 存在的理由：书籍早就按章限制（注释原话"整本上万句一次全精讲不是功能是事故"），
/// 但**视频文稿是一整个 article**——一小时视频 600 句，一键全做就是 600 次调用。
/// 这里让用户先划范围，并且**在点之前就看到要处理多少句**。
///
/// 刻意不做 token 预估：估不准，显示一个错的数字比不显示更糟。
struct BatchScopeSheet: View {
    @Environment(ContentStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let articleID: UUID
    let kind: ContentStore.BatchState.Kind
    /// 当前选中的句序，作为"从这里开始"的默认起点。
    let currentOrder: Int

    private static let counts = [10, 20, 50, 100]

    @State private var count = 20
    @State private var wholeArticle = false

    private var scope: ContentStore.BatchScope {
        wholeArticle ? .all : .from(order: currentOrder, count: count)
    }

    private var pending: Int {
        store.pendingCount(articleID: articleID, kind: kind, scope: scope)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(L("batch.scope.whole"), isOn: $wholeArticle)
                    if !wholeArticle {
                        Picker(L("batch.scope.count"), selection: $count) {
                            ForEach(Self.counts, id: \.self) { value in
                                Text(L("batch.scope.sentences\(value)")).tag(value)
                            }
                        }
                        LabeledContent(L("batch.scope.startAt")) {
                            Text(L("batch.scope.sentenceNo\(currentOrder + 1)"))
                                .foregroundStyle(theme.mutedForeground)
                        }
                    }
                } footer: {
                    Text(L("batch.scope.footer"))
                }

                Section {
                    LabeledContent(L("batch.scope.pending")) {
                        Text(verbatim: "\(pending)")
                            .font(.body.monospacedDigit().weight(.medium))
                            .foregroundStyle(pending > 0 ? theme.primary : theme.mutedForeground)
                    }
                }
            }
            .navigationTitle(
                L(kind == .explain ? "reader.batch.explainAll" : "reader.batch.translateAll")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("batch.scope.start")) {
                        switch kind {
                        case .explain: store.batchExplainAll(articleID: articleID, scope: scope)
                        case .translate:
                            store.batchTranslateAll(articleID: articleID, scope: scope)
                        }
                        dismiss()
                    }
                    .disabled(pending == 0)
                }
            }
        }
    }
}
#endif
