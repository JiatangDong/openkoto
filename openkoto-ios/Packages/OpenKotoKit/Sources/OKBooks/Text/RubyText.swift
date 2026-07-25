import Foundation
import OKModels

/// 带注音的文本：`runs` 顺序拼接即纯文本，`reading` 非空的 run 是被 ruby / 《》 标注的部分。
///
/// 用 run 序列而不是"字符偏移 + 注音表"，是为了绕开 `String.Index` 换算和切分后重定位的坑：
/// 切分器只认纯文本，拿回句子后再按 run 边界重建注音行即可。
public struct RubyText: Sendable, Equatable {
    /// 与离线注音器、AI 精讲共用同一个片段类型（定义在 OKModels）。
    public typealias Run = ReadingRun

    public var runs: [Run]

    public init(runs: [Run]) {
        self.runs = runs
    }

    public init(plainText: String) {
        self.runs = plainText.isEmpty ? [] : [Run(text: plainText)]
    }

    public var plainText: String {
        runs.map(\.text).joined()
    }

    public var hasReadings: Bool {
        runs.contains { $0.reading?.isEmpty == false }
    }

    /// 为切分出的每个句子生成注音行：把带注音的部分替换成读音，其余原样保留。
    /// 例：`吾輩(わがはい)は猫である。` → `わがはいは猫である。`
    ///
    /// 句子里没有任何注音时返回 `nil`——`ArticleSegment.readingText` 为空即不显示注音行，
    /// 原样复读一遍正文没有意义。
    ///
    /// 成立前提：`sentences` 是 `plainText` 的**有序、去首尾空白的子串序列**
    /// （`SentenceSegmenter` 的输出正是如此，见 SentenceSegmenter.swift:38-49），
    /// 因此可以用一个前向游标依次定位，不会错位。
    public func readingLines(forSentencesIn sentences: [String]) -> [String?] {
        guard hasReadings else { return Array(repeating: nil, count: sentences.count) }

        let plain = Array(plainText.unicodeScalars)
        var bounds: [(start: Int, end: Int, reading: String?)] = []
        var offset = 0
        for run in runs {
            let count = run.text.unicodeScalars.count
            bounds.append((offset, offset + count, run.reading))
            offset += count
        }

        var lines: [String?] = []
        lines.reserveCapacity(sentences.count)
        var cursor = 0

        for sentence in sentences {
            let needle = Array(sentence.unicodeScalars)
            guard let start = Self.firstIndex(of: needle, in: plain, from: cursor) else {
                lines.append(nil)
                continue
            }
            let end = start + needle.count
            cursor = end
            lines.append(Self.readingLine(from: start, to: end, bounds: bounds, plain: plain))
        }
        return lines
    }

    /// 同 `readingLines`，但**保留 run 边界**——阅读页的词级注音要靠它把
    /// 「哪几个字对应哪个读音」还原出来，压平成一整行字符串就没法对齐了。
    ///
    /// 句子里没有任何注音时返回 nil（与 `readingLines` 一致）。
    public func runs(forSentencesIn sentences: [String]) -> [[Run]?] {
        guard hasReadings else { return Array(repeating: nil, count: sentences.count) }

        let plain = Array(plainText.unicodeScalars)
        var bounds: [(start: Int, end: Int, reading: String?)] = []
        var offset = 0
        for run in runs {
            let count = run.text.unicodeScalars.count
            bounds.append((offset, offset + count, run.reading))
            offset += count
        }

        var result: [[Run]?] = []
        result.reserveCapacity(sentences.count)
        var cursor = 0

        for sentence in sentences {
            let needle = Array(sentence.unicodeScalars)
            guard let start = Self.firstIndex(of: needle, in: plain, from: cursor) else {
                result.append(nil)
                continue
            }
            let end = start + needle.count
            cursor = end
            result.append(Self.sentenceRuns(from: start, to: end, bounds: bounds, plain: plain))
        }
        return result
    }

    private static func sentenceRuns(
        from start: Int, to end: Int,
        bounds: [(start: Int, end: Int, reading: String?)],
        plain: [Unicode.Scalar]
    ) -> [Run]? {
        var result: [Run] = []
        var annotated = false

        for bound in bounds where bound.start < end && bound.end > start {
            let from = max(bound.start, start)
            let to = min(bound.end, end)
            guard from < to else { continue }
            var view = String.UnicodeScalarView()
            view.append(contentsOf: plain[from..<to])
            // 注音块被句边界切开时只保留正文：半个词配整串读音是错的。
            // ruby 跨句本就是病态排版，不为它做部分裁切。
            let isWhole = from == bound.start && to == bound.end
            let reading = isWhole ? bound.reading.flatMap { $0.isEmpty ? nil : $0 } : nil
            if reading != nil { annotated = true }
            result.append(Run(text: String(view), reading: reading))
        }
        return annotated ? result : nil
    }

    private static func readingLine(
        from start: Int, to end: Int,
        bounds: [(start: Int, end: Int, reading: String?)],
        plain: [Unicode.Scalar]
    ) -> String? {
        var line = String.UnicodeScalarView()
        var annotated = false

        for bound in bounds where bound.start < end && bound.end > start {
            if let reading = bound.reading, !reading.isEmpty {
                // 注音整体替换：ruby 跨句边界属于病态排版，不做部分裁切。
                line.append(contentsOf: reading.unicodeScalars)
                annotated = true
            } else {
                let from = max(bound.start, start)
                let to = min(bound.end, end)
                if from < to { line.append(contentsOf: plain[from..<to]) }
            }
        }
        return annotated ? String(line) : nil
    }

    /// 朴素前向子序列查找。句子几乎总是紧跟游标出现，实际是常数级。
    private static func firstIndex(
        of needle: [Unicode.Scalar], in haystack: [Unicode.Scalar], from start: Int
    ) -> Int? {
        guard !needle.isEmpty, start >= 0, needle.count <= haystack.count - start else {
            return nil
        }
        let last = haystack.count - needle.count
        var index = start
        while index <= last {
            var matched = true
            for offset in 0..<needle.count where haystack[index + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return index }
            index += 1
        }
        return nil
    }
}
