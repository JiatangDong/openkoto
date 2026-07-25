import Foundation
import OKModels

/// 把高置信度的读音盖到低置信度的读音上。
///
/// 读音有四个来源，可靠性差很多：
/// 1. AI 精讲返回的 `reading_runs`（暂未启用）
/// 2. 原书自带的 `<ruby>` / 青空 `《》`——作者标的，权威
/// 3. AI 精讲挑出的生词 `vocabulary[].reading`
/// 4. 离线注音器——覆盖全，但约 10% 会错
///
/// 做法是先用第 4 层铺满，再按优先级从低到高依次盖上去，后盖的赢。
public enum ReadingOverlay {
    /// 一段要覆盖的读音。偏移与长度以 **Unicode 标量**为单位
    /// （与 `RubyText` 一致；用 Character 会在 run 边界切开字素簇时对不齐）。
    public struct Span: Sendable, Equatable {
        public var start: Int
        public var length: Int
        public var reading: String

        public init(start: Int, length: Int, reading: String) {
            self.start = start
            self.length = length
            self.reading = reading
        }

        var end: Int { start + length }
    }

    /// 把 `spans` 盖到 `base` 上。`base` 顺序拼接即原文，返回值同样满足这一点。
    public static func apply(_ spans: [Span], to base: [ReadingRun]) -> [ReadingRun] {
        let overrides = normalized(spans)
        guard !overrides.isEmpty else { return base }

        var scalars: [Unicode.Scalar] = []
        var bounds: [(range: Range<Int>, reading: String?)] = []
        for run in base {
            let runScalars = Array(run.text.unicodeScalars)
            bounds.append((scalars.count..<(scalars.count + runScalars.count), run.reading))
            scalars.append(contentsOf: runScalars)
        }
        let total = scalars.count

        var result: [ReadingRun] = []
        var cursor = 0
        for span in overrides {
            let start = min(span.start, total)
            let end = min(span.end, total)
            guard end > start, start >= cursor else { continue }
            result += slice(bounds, scalars: scalars, from: cursor, to: start)
            result.append(
                ReadingRun(text: text(scalars, start..<end), reading: span.reading))
            cursor = end
        }
        result += slice(bounds, scalars: scalars, from: cursor, to: total)
        return result.mergingUnannotated()
    }

    /// 从一串已带读音的 runs 里提取 span（用于把原书 ruby 当作覆盖源）。
    public static func spans(of runs: [ReadingRun]) -> [Span] {
        var result: [Span] = []
        var offset = 0
        for run in runs {
            let length = run.text.unicodeScalars.count
            if let reading = run.reading, !reading.isEmpty, length > 0 {
                result.append(Span(start: offset, length: length, reading: reading))
            }
            offset += length
        }
        return result
    }

    /// 按起点排序并丢弃重叠的后来者——同一段文字不可能有两个读音。
    private static func normalized(_ spans: [Span]) -> [Span] {
        var result: [Span] = []
        for span in spans.filter({ $0.length > 0 && !$0.reading.isEmpty })
            .sorted(by: { $0.start == $1.start ? $0.length > $1.length : $0.start < $1.start })
        {
            if let last = result.last, span.start < last.end { continue }
            result.append(span)
        }
        return result
    }

    /// 取 `[from, to)` 窗口内的 runs。
    ///
    /// 只有**完整落在窗口内**的 run 才保留读音：被切开的 run 说明它与覆盖段交叠，
    /// 此时读音已经对不上那半截文字了，宁可只留正文。
    private static func slice(
        _ bounds: [(range: Range<Int>, reading: String?)], scalars: [Unicode.Scalar],
        from: Int, to: Int
    ) -> [ReadingRun] {
        guard to > from else { return [] }
        var result: [ReadingRun] = []
        for bound in bounds where bound.range.lowerBound < to && bound.range.upperBound > from {
            let start = max(bound.range.lowerBound, from)
            let end = min(bound.range.upperBound, to)
            guard end > start else { continue }
            let isWhole = start == bound.range.lowerBound && end == bound.range.upperBound
            result.append(
                ReadingRun(text: text(scalars, start..<end), reading: isWhole ? bound.reading : nil))
        }
        return result
    }

    private static func text(_ scalars: [Unicode.Scalar], _ range: Range<Int>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[range])
        return String(view)
    }
}
