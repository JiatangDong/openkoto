import Foundation
import OKAIClient
import OKModels

// 全文批量任务（精讲 / 翻译）。
//
// 从 ContentStore 主体拆出来：这块的取消语义足够绕，值得单独放一个文件说清楚。

extension ContentStore {
    /// 批量任务进度（供阅读器进度条 + 取消 + 重试）。
    public struct BatchState: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable, Identifiable {
            case explain, translate
            public var id: String { rawValue }
        }
        /// `cancelling`：已请求取消，但在飞的请求还在断开中。
        /// **这个状态必须暴露给 UI**——它是"取消不是瞬时的"这件事的诚实表达，
        /// 也是防止用户在窗口期内重开第二批的依据。
        public enum Phase: Sendable, Equatable { case running, cancelling }

        public var kind: Kind
        public var completed: Int
        public var total: Int
        public var failed: Int
        public var phase: Phase = .running
    }

    /// 上一批跑完后仍失败的句子，供"重试失败项"。批次状态清空后仍保留。
    public struct BatchFailures: Sendable, Equatable {
        public var kind: BatchState.Kind
        public var segmentIDs: [UUID]
    }

    /// 批量处理的范围。
    ///
    /// 书籍早就意识到"整本一次全精讲不是功能是事故"所以按章限制，但**视频文稿是
    /// 一整个 article**——一小时的视频 600 句，`.all` 就是 600 次调用。
    /// 让用户能先划个范围，并且在点之前就知道要处理多少句。
    public enum BatchScope: Sendable, Equatable {
        case all
        /// 从某句开始的 N 句（"从当前句往后做 20 句"）。
        case from(order: Int, count: Int)
        case orderRange(ClosedRange<Int>)

        func contains(_ order: Int) -> Bool {
            switch self {
            case .all: true
            case .from(let start, let count): order >= start && order < start + count
            case .orderRange(let range): range.contains(order)
            }
        }
    }

    /// 给定范围内还有多少句待处理。**UI 要在用户点之前就显示它**——
    /// 让人知道这一下要花多少，比事后看账单强。
    public func pendingCount(
        articleID: UUID, kind: BatchState.Kind, scope: BatchScope = .all
    ) -> Int {
        pendingSegments(articleID: articleID, kind: kind, scope: scope).count
    }

    private func pendingSegments(
        articleID: UUID, kind: BatchState.Kind, scope: BatchScope
    ) -> [UUID] {
        segments(for: articleID)
            .filter { scope.contains($0.order) }
            .filter { segment in
                switch kind {
                case .explain: segment.explanation == nil
                case .translate: segment.explanation == nil && segment.translation == nil
                }
            }
            .map(\.id)
    }

    // MARK: - 查询

    public func isBatchRunning(articleID: UUID) -> Bool { batchTasks[articleID] != nil }

    public func batchFailures(articleID: UUID) -> BatchFailures? {
        lastBatchFailures[articleID]
    }

    /// 可重试的失败句数。余额不足、未授权这类重试也没用的不算进去。
    public func retryableFailureCount(articleID: UUID) -> Int {
        guard let failures = lastBatchFailures[articleID] else { return 0 }
        return failures.segmentIDs.count { generationErrors[$0]?.isRetryable ?? false }
    }

    // MARK: - 启动 / 取消 / 重试

    public func batchExplainAll(articleID: UUID, scope: BatchScope = .all) {
        startBatch(articleID, kind: .explain, scope: scope)
    }

    public func batchTranslateAll(articleID: UUID, scope: BatchScope = .all) {
        startBatch(articleID, kind: .translate, scope: scope)
    }

    /// 请求取消。
    ///
    /// **不清 `batchTasks`**——那正是旧实现的 bug：清掉之后 `isBatchRunning` 立刻返回 false，
    /// `startBatch` 的 guard 随之失效，用户"取消后立刻重开"会让两批请求叠加、账单翻倍
    /// 且毫无察觉。改由 `runBatch` 的 `defer` 在真正收尾时清理。
    public func cancelBatch(articleID: UUID) {
        guard let task = batchTasks[articleID] else { return }
        task.cancel()
        batchByArticle[articleID]?.phase = .cancelling
    }

    /// 只重试**可重试**的失败句。余额不足/未授权重试多少次都不会好，重试它们纯属浪费。
    public func retryFailedInBatch(articleID: UUID) {
        guard batchTasks[articleID] == nil, let failures = lastBatchFailures[articleID] else {
            return
        }
        let retryable = failures.segmentIDs.filter { generationErrors[$0]?.isRetryable ?? false }
        guard !retryable.isEmpty else { return }
        for id in retryable { generationErrors[id] = nil }
        lastBatchFailures[articleID] = nil
        launch(articleID: articleID, kind: failures.kind, ids: retryable)
    }

    private func startBatch(_ articleID: UUID, kind: BatchState.Kind, scope: BatchScope) {
        guard batchTasks[articleID] == nil else { return }
        // 范围裁剪只发生在这里；`runBatch` 只吃一个 id 数组，不必知道范围的存在。
        let pending = pendingSegments(articleID: articleID, kind: kind, scope: scope)
        guard !pending.isEmpty else { return }
        launch(articleID: articleID, kind: kind, ids: pending)
    }

    private func launch(articleID: UUID, kind: BatchState.Kind, ids: [UUID]) {
        // 无对应 provider 时不启动，直接把首句错误暴露给用户（设置未配模型）。
        let hasProvider = kind == .explain ? explanationProvider != nil : translationProvider != nil
        guard hasProvider else {
            if let first = ids.first { generationErrors[first] = .notConfigured }
            return
        }

        lastBatchFailures[articleID] = nil
        batchByArticle[articleID] = BatchState(
            kind: kind, completed: 0, total: ids.count, failed: 0)
        let concurrency = batchConcurrency
        batchTasks[articleID] = Task { [weak self] in
            await self?.runBatch(
                articleID: articleID, kind: kind, ids: ids, concurrency: concurrency)
        }
    }

    /// 分批并发：每批最多 `concurrency` 句同时在飞（各自在 await 网络时让出主线程）。
    ///
    /// 用非结构化 `Task { @MainActor }` 而不是 TaskGroup，是为绕开 Swift 6 的 sending 约束。
    /// 代价是**父任务的取消不会自动传播到子任务**——旧实现就栽在这：取消之后在飞的请求
    /// 照样跑完并计费。这里用 `withTaskCancellationHandler` 显式把取消转给本批的子任务，
    /// 子任务里的 `URLSession` 请求随即真的断开。
    private func runBatch(
        articleID: UUID, kind: BatchState.Kind, ids: [UUID], concurrency: Int
    ) async {
        var failed: [UUID] = []
        defer {
            batchTasks[articleID] = nil
            batchByArticle[articleID] = nil
            lastBatchFailures[articleID] =
                failed.isEmpty ? nil : BatchFailures(kind: kind, segmentIDs: failed)
        }

        var index = 0
        while index < ids.count {
            if Task.isCancelled { break }
            let chunk = Array(ids[index..<min(index + concurrency, ids.count)])
            index += concurrency

            let tasks = chunk.map { segmentID in
                Task { @MainActor [weak self] () -> Bool in
                    guard let self, !Task.isCancelled else { return false }
                    return kind == .explain
                        ? await self.generateExplanation(articleID: articleID, segmentID: segmentID)
                        : await self.generateTranslation(articleID: articleID, segmentID: segmentID)
                }
            }

            await withTaskCancellationHandler {
                for (offset, task) in tasks.enumerated() {
                    let ok = await task.value
                    let segmentID = chunk[offset]
                    // 只有真的记了错因才算失败——`generate*` 在"已精讲""正在生成"
                    // 这类良性跳过时也返回 false，计进去会让失败数虚高。
                    let isFailure = !ok && generationErrors[segmentID] != nil
                    if isFailure { failed.append(segmentID) }
                    if var state = batchByArticle[articleID] {
                        state.completed += 1
                        if isFailure { state.failed += 1 }
                        batchByArticle[articleID] = state
                    }
                }
            } onCancel: {
                for task in tasks { task.cancel() }
            }
        }
    }
}
