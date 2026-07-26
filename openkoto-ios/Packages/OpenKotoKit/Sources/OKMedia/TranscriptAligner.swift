import Foundation
import OKSegmentation

/// 一条带时间的句子——**学习单元**。
///
/// 与 token（显示单元）严格分开：精讲、翻译、生词、SRS 全部走这一层。
/// 桌面端把两者混成同一个 `ArticleSegment`（1 cue = 1 segment），
/// 于是 LLM 拿到的是被字幕行宽切碎的半句话，翻译和语法讲解从源头就错。
public struct TimedSentence: Sendable, Equatable {
    public var text: String
    public var isNewParagraph: Bool
    /// 秒。定位失败时为 nil（正文照常显示，只是点它不能跳转）。
    public var start: Double?
    public var end: Double?

    public init(text: String, isNewParagraph: Bool, start: Double?, end: Double?) {
        self.text = text
        self.isNewParagraph = isNewParagraph
        self.start = start
        self.end = end
    }
}

/// 对齐结果。`text` 是拼接后的全文（落库进 `Article.content`），`sentences` 是切好的学习单元。
public struct AlignedTranscript: Sendable, Equatable {
    public var text: String
    public var sentences: [TimedSentence]
    public var diagnostics: Diagnostics

    /// 质量诊断。**必须暴露到调试视图**——桌面端三次「修时间戳漂移」的提交
    /// 都在改分片参数而从不看这些数字，因为它们根本没被算出来过。
    public struct Diagnostics: Sendable, Equatable {
        /// 定位失败、只能靠前后句插值或留空的句数。
        public var unlocatedCount = 0
        /// 触发过时间修复（start>=end / 非单调）的句数。
        public var repairedCount = 0
        /// 最大段内句数——`NativeChapterView` 的 LazyVStack 每行是一个段落，
        /// 这个数太大会让虚拟化失效。
        public var maxSentencesPerParagraph = 0
        public var sentenceCount = 0
        public var tokenCount = 0
    }
}

/// 把带时间的 token 流对齐成带时间的句子。
public struct TranscriptAligner: Sendable {
    public struct Options: Sendable {
        /// token 间静音超过这个秒数就断段落。既是段落边界，也是硬句边界
        /// （防止把停顿两侧不相关的两句话黏成一句，尤其是无标点的自动字幕）。
        public var paragraphGap: Double = 1.5
        /// 段内句数上限。**这是性能正确性要求，不是美化**：
        /// `NativeChapterView` 的 LazyVStack 每一行是一个段落，一小时视频 600 句
        /// 若全在一个段落里，虚拟化完全失效，`FlowLayout` 一次布局 600 个 chip 会卡死。
        public var maxSentencesPerParagraph = 30
        public var minDuration: Double = 0.08

        public init() {}
    }

    private let segmenter: any SegmentationStrategy
    private let options: Options

    public init(segmenter: any SegmentationStrategy = SentenceSegmenter(), options: Options = .init())
    {
        self.segmenter = segmenter
        self.options = options
    }

    public func align(_ rawTokens: [TimedToken]) -> AlignedTranscript {
        let tokens = rawTokens.normalized(minDuration: options.minDuration)
        guard !tokens.isEmpty else {
            return AlignedTranscript(text: "", sentences: [], diagnostics: .init())
        }

        // ① 拼接成全文，同时记住每个 token 占据的标量区间
        let (plain, spans) = assemble(tokens)
        let text = String(String.UnicodeScalarView(plain))

        // ② 切句 → ③ 定位回标量区间
        let drafts = segmenter.segment(text)
        let ranges = SentenceLocator.scalarRanges(of: drafts.map(\.text), in: plain)

        // ④ 区间 → 时间（双指针，O(n)）
        var diagnostics = AlignedTranscript.Diagnostics()
        diagnostics.tokenCount = tokens.count
        var sentences: [TimedSentence] = []
        sentences.reserveCapacity(drafts.count)
        var spanCursor = 0

        for (index, draft) in drafts.enumerated() {
            guard let range = ranges[index], !range.isEmpty else {
                diagnostics.unlocatedCount += 1
                sentences.append(
                    TimedSentence(
                        text: draft.text, isNewParagraph: draft.isNewParagraph,
                        start: nil, end: nil))
                continue
            }
            while spanCursor < spans.count, spans[spanCursor].range.upperBound <= range.lowerBound {
                spanCursor += 1
            }
            var last = spanCursor
            while last + 1 < spans.count, spans[last + 1].range.lowerBound < range.upperBound {
                last += 1
            }
            guard spanCursor < spans.count, spans[spanCursor].range.lowerBound < range.upperBound
            else {
                diagnostics.unlocatedCount += 1
                sentences.append(
                    TimedSentence(
                        text: draft.text, isNewParagraph: draft.isNewParagraph,
                        start: nil, end: nil))
                continue
            }
            let start = interpolate(spans[spanCursor], at: range.lowerBound, tokens: tokens)
            let end = interpolate(spans[last], at: range.upperBound, tokens: tokens)
            sentences.append(
                TimedSentence(
                    text: draft.text, isNewParagraph: draft.isNewParagraph,
                    start: start, end: end))
        }

        repair(&sentences, diagnostics: &diagnostics)
        applyParagraphBreaks(&sentences, diagnostics: &diagnostics)
        diagnostics.sentenceCount = sentences.count
        return AlignedTranscript(text: text, sentences: sentences, diagnostics: diagnostics)
    }

    // MARK: - ① 拼接

    private struct Span {
        var range: Range<Int>
        var tokenIndex: Int
    }

    /// 拼接全文并建立标量区间表。
    ///
    /// 静音超过 `paragraphGap` 时插入 `"\n"`：切分器按 `\n` 切段落、段内才切句
    /// （`SentenceSegmenter.splitParagraphs`），所以这既是段落标记也是硬句边界。
    ///
    /// ⚠️ 反过来说：**普通接缝绝不能用 `"\n"`**，否则每条 cue 都成独立段落，
    /// 句子永远不会跨 cue 合并——那正是桌面端 1 cue = 1 segment 的等价物，
    /// 重新切句就白做了。
    private func assemble(_ tokens: [TimedToken]) -> ([Unicode.Scalar], [Span]) {
        var plain: [Unicode.Scalar] = []
        var spans: [Span] = []
        spans.reserveCapacity(tokens.count)

        for (index, token) in tokens.enumerated() {
            if index > 0 {
                let previous = tokens[index - 1]
                if token.start - previous.end >= options.paragraphGap {
                    plain.append("\n")
                } else {
                    let separator = TokenJoiner.joiner(
                        after: previous.text, before: token.text)
                    plain.append(contentsOf: separator.unicodeScalars)
                }
            }
            let start = plain.count
            plain.append(contentsOf: token.text.unicodeScalars)
            spans.append(Span(range: start..<plain.count, tokenIndex: index))
        }
        return (plain, spans)
    }

    // MARK: - ④ 插值

    /// 位置 `position` 在 token 内部的时间，按字符比例线性插值。
    ///
    /// 对 cue 级输入这是必要的（一条 cue 可能含两句话）；对词级输入这是无害的
    /// （在 0.3 秒的词内部插值，误差远小于人耳可辨）。所以不分支。
    private func interpolate(_ span: Span, at position: Int, tokens: [TimedToken]) -> Double {
        let token = tokens[span.tokenIndex]
        let length = span.range.count
        guard length > 0 else { return token.start }
        let offset = min(max(position - span.range.lowerBound, 0), length)
        let ratio = Double(offset) / Double(length)
        return token.start + (token.end - token.start) * ratio
    }

    // MARK: - ⑤ 修复

    /// 补齐定位失败的句子、保证时长为正、保证全局单调。
    private func repair(
        _ sentences: inout [TimedSentence], diagnostics: inout AlignedTranscript.Diagnostics
    ) {
        // 定位失败的句子用前后邻居兜住：前句 end 到后句 start 之间给它一个区间。
        for index in sentences.indices where sentences[index].start == nil {
            let previousEnd = sentences[..<index].last(where: { $0.end != nil })?.end
            let nextStart = sentences[(index + 1)...].first(where: { $0.start != nil })?.start
            switch (previousEnd, nextStart) {
            case let (previous?, next?):
                sentences[index].start = previous
                sentences[index].end = max(previous, next)
            case let (previous?, nil):
                sentences[index].start = previous
                sentences[index].end = previous + options.minDuration
            case let (nil, next?):
                sentences[index].start = max(0, next - options.minDuration)
                sentences[index].end = next
            case (nil, nil):
                break  // 整篇都没定位上，保持 nil：正文照常显示，只是不能跳转
            }
        }

        var previousStart = -Double.greatestFiniteMagnitude
        for index in sentences.indices {
            guard var start = sentences[index].start else { continue }
            var end = sentences[index].end ?? start
            var repaired = false
            if start < previousStart {
                start = previousStart
                repaired = true
            }
            if end < start + options.minDuration {
                end = start + options.minDuration
                repaired = true
            }
            if repaired { diagnostics.repairedCount += 1 }
            sentences[index].start = start
            sentences[index].end = end
            previousStart = start
        }
    }

    /// 补足段落切分：静音断段在拼接阶段已经做了，这里再按句数强制切，
    /// 保证段内句数有上限（LazyVStack 的虚拟化依赖它）。
    ///
    /// 句数上限没法在切句之前判断（不切完不知道有几句），所以放在这里做后处理。
    private func applyParagraphBreaks(
        _ sentences: inout [TimedSentence], diagnostics: inout AlignedTranscript.Diagnostics
    ) {
        var inParagraph = 0
        var maxInParagraph = 0
        for index in sentences.indices {
            if index == 0 {
                sentences[index].isNewParagraph = true
            } else if inParagraph >= options.maxSentencesPerParagraph {
                sentences[index].isNewParagraph = true
            }
            if sentences[index].isNewParagraph {
                maxInParagraph = max(maxInParagraph, inParagraph)
                inParagraph = 1
            } else {
                inParagraph += 1
            }
        }
        diagnostics.maxSentencesPerParagraph = max(maxInParagraph, inParagraph)
    }
}
