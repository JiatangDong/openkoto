import Foundation
import OKModels

/// 导入素材的 AI 清洗（对齐桌面 `commands.rs::clean_web_content_cmd`）。
///
/// **只删行，不重写。** 模型收到的是带行号的预览文本，返回的是"哪些行是噪音"的行号列表；
/// 保留下来的每一行都还是原文那一行的字节。让模型整篇重写既费 token，又会静默改写原文——
/// 而这些文本正是用户接下来要逐句精讲、背单词的素材，一个字都不能变。
///
/// 分批是必须的：一篇网页转纯文本常有几百上千行，整篇塞进去要么超上下文，要么模型
/// 只认真看了前面几十行。批与批之间互不依赖，故可并发。
public struct WebContentCleaner: Sendable {
    /// 送审时单行预览的最大字符数。超长行截断并标注真实长度——
    /// 长行几乎一定是正文，不需要让模型读完才能判断。
    static let previewChars = 120
    /// 单批预览文本的字符预算。
    static let batchChars = 4000
    /// 单批最多多少行。
    static let batchLines = 80
    /// 并发批数。再高容易撞供应商限流，收益也有限。
    static let concurrency = 3
    /// 清洗后正文低于这个字数就认为模型删过头了。UI 用同一个阈值决定按钮能不能点——
    /// 短到清洗完必然报 `.tooShort` 的正文，一开始就不该让用户花这次调用。
    public static let minResultChars = 10

    /// 清洗结果。`partial` 表示有批次失败——那些行按原文保留了。
    public struct Result: Sendable, Equatable {
        public var title: String?
        public var content: String
        public var removedLines: Int
        public var removedChars: Int
        public var keptLines: Int
        public var partial: Bool

        public init(
            title: String?, content: String, removedLines: Int, removedChars: Int,
            keptLines: Int, partial: Bool
        ) {
            self.title = title
            self.content = content
            self.removedLines = removedLines
            self.removedChars = removedChars
            self.keptLines = keptLines
            self.partial = partial
        }
    }

    public enum CleanError: Error, Sendable, Equatable {
        /// 没有任何非空行可送审。
        case noContent
        /// 清洗后正文过短，多半是模型误删；调用方应保留原文。
        case tooShort
        /// 所有批次都失败（模型没配好 / 没网 / Key 失效）。
        case allBatchesFailed(underlying: AIClientError?)
    }

    private let service: ExplanationService

    public init(service: ExplanationService = ExplanationService()) {
        self.service = service
    }

    // MARK: - 纯逻辑（可单测，不碰网络）

    /// 按行切开。
    ///
    /// **不能写 `split(separator: "\n")`。** Swift 的 `Character` 是字素簇，`"\r\n"` 是
    /// **一个**字符，不等于 `"\n"`——于是 CRLF 的网页（一大票中文站点）会被当成
    /// 一整行，整篇要么全删要么全留，清洗完全失效。`isNewline` 认识 CRLF、单独的 `\r`
    /// 以及 U+2028/2029。
    ///
    /// 重新拼接时统一用 `\n`（与桌面 `lines()` + `join("\n")` 一致）：行尾符会被归一化，
    /// 但每一行的文字仍与原文逐字相同。
    static func splitLines(_ text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    }

    /// 单行送审预览：trim + 超长截断并标注真实字符数。
    static func linePreview(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = trimmed.count
        guard count > previewChars else { return trimmed }
        let head = String(trimmed.prefix(previewChars))
        return "\(head)…(len=\(count))"
    }

    /// 把待审行按「行数 + 字符预算」切批。
    static func splitBatches(
        _ candidates: [(index: Int, preview: String)]
    ) -> [[(index: Int, preview: String)]] {
        var batches: [[(index: Int, preview: String)]] = []
        var current: [(index: Int, preview: String)] = []
        var currentChars = 0

        for item in candidates {
            // +8 ≈ 行号前缀 "[123] " 与换行的开销
            let cost = item.preview.count + 8
            if !current.isEmpty
                && (current.count >= batchLines || currentChars + cost > batchChars)
            {
                batches.append(current)
                current = []
                currentChars = 0
            }
            currentChars += cost
            current.append(item)
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    /// 折叠连续空行（删掉整段后往往留下一片空白）。
    static func collapseBlankLines(_ lines: [Substring]) -> String {
        var out: [Substring] = []
        var blankRun = 0
        for line in lines {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blankRun += 1
                if blankRun > 1 { continue }
            } else {
                blankRun = 0
            }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 按模型给出的删除行号重组正文。分出来是为了不用联网就能测装配逻辑。
    static func assemble(
        content: String, dropping drop: Set<Int>, suggestedTitle: String?,
        fallbackTitle: String?, partial: Bool
    ) throws -> Result {
        let lines = Self.splitLines(content)
        var kept: [Substring] = []
        var removedLines = 0
        var removedChars = 0
        var keptLines = 0

        for (idx, line) in lines.enumerated() {
            if drop.contains(idx) {
                removedLines += 1
                removedChars += line.trimmingCharacters(in: .whitespacesAndNewlines).count
                continue
            }
            if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { keptLines += 1 }
            kept.append(line)
        }

        let cleaned = collapseBlankLines(kept)
        guard cleaned.count >= minResultChars else { throw CleanError.tooShort }

        let title = suggestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? fallbackTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        return Result(
            title: title, content: cleaned, removedLines: removedLines,
            removedChars: removedChars, keptLines: keptLines, partial: partial)
    }

    // MARK: - 联网清洗

    /// 清洗整段正文。`onProgress(done, total)` 在主线程之外调用，UI 侧自行跳回主线程。
    public func clean(
        title: String?,
        content: String,
        targetLanguage _: String = "zh-CN",
        config: ModelConfig,
        apiKey: String?,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> Result {
        let lines = Self.splitLines(content)
        // 空行不送审，原样保留用来维持段落结构
        let candidates: [(index: Int, preview: String)] = lines.enumerated()
            .filter { !$0.element.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { (index: $0.offset, preview: Self.linePreview(String($0.element))) }

        guard !candidates.isEmpty else { throw CleanError.noContent }

        let batches = Self.splitBatches(candidates)
        let total = batches.count
        let progress = ProgressCounter(total: total, report: onProgress)

        var drop = Set<Int>()
        var suggestedTitle: String?
        var failures = 0
        var lastError: AIClientError?

        // 有界并发：一次最多 `concurrency` 批在飞。
        try await withThrowingTaskGroup(
            of: (Swift.Result<([Int], String?), Error>).self
        ) { group in
            var next = 0
            func submit(_ i: Int) {
                let batch = batches[i]
                // 只让第一批顺带给出干净标题，避免每批都重复要一次
                let wantTitle = i == 0
                group.addTask { [service] in
                    let outcome: Swift.Result<([Int], String?), Error>
                    do {
                        outcome = .success(
                            try await service.detectWebNoiseLines(
                                lines: batch, wantTitle: wantTitle, config: config, apiKey: apiKey))
                    } catch {
                        outcome = .failure(error)
                    }
                    await progress.advance()
                    return outcome
                }
            }

            while next < min(Self.concurrency, total) {
                submit(next)
                next += 1
            }

            while let outcome = try await group.next() {
                switch outcome {
                case .success(let (dropped, batchTitle)):
                    if suggestedTitle == nil { suggestedTitle = batchTitle }
                    drop.formUnion(dropped)
                case .failure(let error):
                    failures += 1
                    lastError = error as? AIClientError ?? (error as? AIRequestFailure)?.error
                }
                if next < total {
                    submit(next)
                    next += 1
                }
            }
        }

        // 全军覆没多半是模型没配好或网络不通——报错，让调用方原样保留抓取结果。
        guard failures < total else { throw CleanError.allBatchesFailed(underlying: lastError) }

        return try Self.assemble(
            content: content, dropping: drop, suggestedTitle: suggestedTitle,
            fallbackTitle: title, partial: failures > 0)
    }
}

/// 跨并发任务的完成计数。actor 而非 counter+lock：进度只是 UI 提示，不值得手写同步。
private actor ProgressCounter {
    private var done = 0
    private let total: Int
    private let report: (@Sendable (Int, Int) -> Void)?

    init(total: Int, report: (@Sendable (Int, Int) -> Void)?) {
        self.total = total
        self.report = report
    }

    func advance() {
        done += 1
        report?(done, total)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
