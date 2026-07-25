import Foundation

/// 把 AI 精讲挑出的生词（`word` + `reading`）定位回原句。
///
/// 精讲返回的生词表**不带位置**，只能拿词形去原文里找。算法与桌面
/// `KtvExportPage.buildVocabularyReadingParts` 保持一致，免得同一句话两端标出不同结果：
/// - 贪心前向扫描，每轮取**起点最靠前**的候选；
/// - 起点相同取**更长**的词（「行长」优先于「行」）；
/// - 每个词条**只用一次**——同一个词在句中出现两次时只标第一次，
///   因为 AI 给的释义是针对那一次的用法。
///
/// 找不到就静默丢弃：AI 常给词典形（`駆ける`），而原文是活用形（`駆けた`）。
public enum VocabularyReadingMatcher {
    public struct Entry: Sendable, Equatable {
        public var word: String
        public var reading: String

        public init(word: String, reading: String) {
            self.word = word
            self.reading = reading
        }
    }

    public static func spans(for entries: [Entry], in text: String) -> [ReadingOverlay.Span] {
        var candidates = entries.filter {
            !$0.word.isEmpty && !$0.reading.isEmpty && $0.word != $0.reading
        }
        guard !candidates.isEmpty else { return [] }

        let haystack = Array(text.unicodeScalars)
        var result: [ReadingOverlay.Span] = []
        var cursor = 0

        while !candidates.isEmpty, cursor < haystack.count {
            var best: (index: Int, start: Int, length: Int)?
            for (index, candidate) in candidates.enumerated() {
                let needle = Array(candidate.word.unicodeScalars)
                guard let start = firstIndex(of: needle, in: haystack, from: cursor) else { continue }
                let isBetter =
                    best.map { start < $0.start || (start == $0.start && needle.count > $0.length) }
                    ?? true
                if isBetter { best = (index, start, needle.count) }
            }
            guard let best else { break }
            result.append(
                ReadingOverlay.Span(
                    start: best.start, length: best.length,
                    reading: candidates[best.index].reading))
            cursor = best.start + best.length
            candidates.remove(at: best.index)
        }
        return result
    }

    /// 朴素前向子序列查找。句子短、候选少（AI 一般给 3-8 个词），不值得上 KMP。
    private static func firstIndex(
        of needle: [Unicode.Scalar], in haystack: [Unicode.Scalar], from start: Int
    ) -> Int? {
        guard !needle.isEmpty, start >= 0, needle.count <= haystack.count - start else {
            return nil
        }
        for index in start...(haystack.count - needle.count) {
            if Array(haystack[index..<(index + needle.count)]) == needle { return index }
        }
        return nil
    }
}
