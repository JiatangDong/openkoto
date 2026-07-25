import Foundation
import OKModels

/// 把原版模式（WKWebView）里选中的文字映射回本章的某一句。
///
/// 这是"原版模式仍然能学习"的关键一环：拿到 `segmentID` 之后，
/// 直接复用**未经修改**的 `ExplanationSheet`——精讲照常写进那一行 segment，
/// SRS、统计、进度全都跟着亮起来。
///
/// 之所以可靠：两种模式的文本出自同一个抽取器（`XHTMLTextExtractor`），
/// 只是渲染方式不同，字是同一批字。
public enum SelectionResolver {
    public struct Match: Sendable, Equatable {
        public let segmentID: UUID
        public let order: Int
        /// 选区在该句内的 Unicode 标量区间（划线用）；跨句时为 nil。
        public let range: Range<Int>?
    }

    /// 归一化：去掉所有空白与不可见字符。
    /// WebView 的选区会带上排版换行和 NBSP，直接比对必然对不上。
    static func normalize(_ text: String) -> [Unicode.Scalar] {
        text.unicodeScalars.filter { scalar in
            !(scalar.properties.isWhitespace || scalar == "\u{200B}" || scalar == "\u{FEFF}")
        }
    }

    /// 在章内句子里找与选区重合度最高的一句。
    /// - 选区落在某句内部 → 该句，并给出句内区间；
    /// - 选区跨若干句 → 取被覆盖最多的那一句（用户点"精讲"时讲整句最有用）。
    public static func resolve(selection: String, in segments: [ArticleSegment]) -> Match? {
        let needle = normalize(selection)
        guard !needle.isEmpty else { return nil }

        var best: Match?
        var bestScore = 0

        for segment in segments {
            let haystack = normalize(segment.text)
            guard !haystack.isEmpty else { continue }

            var score = 0
            var range: Range<Int>?
            if let start = firstIndex(of: needle, in: haystack) {
                // 选区完整落在这句里。
                score = needle.count
                range = start..<(start + needle.count)
            } else if let start = firstIndex(of: haystack, in: needle) {
                // 这句被选区完整覆盖（跨句选择）。
                score = haystack.count
                _ = start
            }
            guard score > bestScore else { continue }
            bestScore = score
            best = Match(segmentID: segment.id, order: segment.order, range: range)
        }
        return best
    }

    private static func firstIndex(of needle: [Unicode.Scalar], in haystack: [Unicode.Scalar])
        -> Int?
    {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        let last = haystack.count - needle.count
        var index = 0
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
