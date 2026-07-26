import Foundation

/// 把切分出的句子定位回原文，返回每句的 **Unicode 标量区间**。
///
/// 切分器只认纯文本、只吐 `{text, isNewParagraph}`（它与 Rust 端共享 golden fixture，
/// 输出结构不能动）。而调用方手里往往还有一份"附着在原文位置上"的信息——
/// 注音 run、字幕时间戳、书签锚点——要把两者对上，就需要知道每句落在原文的哪一段。
///
/// **成立前提**：`sentences` 是 `haystack` 的**有序、去首尾空白的子串序列**
/// （`SentenceSegmenter` 的输出正是如此，见 `SentenceSegmenter.splitParagraphs`）。
/// 因此用一个前向游标依次定位即可，不会错位。
///
/// 用标量而不是 `String.Index`：附着信息（run 长度、cue 长度）天然是按标量计的，
/// 换算成 `String.Index` 只会多一层坑。这与 `MarkAnchor` 的偏移语义一致。
public enum SentenceLocator {
    /// - Returns: 与 `sentences` 等长的数组；定位失败的位置为 nil。
    ///
    /// 失败时**不推进游标**——重复句（歌词、口语复述、字幕滚动重复）靠单调游标按序消费，
    /// 一旦让某次失败把游标带偏，后面全错。
    public static func scalarRanges(
        of sentences: [String], in haystack: String
    ) -> [Range<Int>?] {
        scalarRanges(of: sentences, in: Array(haystack.unicodeScalars))
    }

    /// 调用方已经展开过标量数组时用这个重载，避免重复展开（长文本上不是小钱）。
    public static func scalarRanges(
        of sentences: [String], in haystack: [Unicode.Scalar]
    ) -> [Range<Int>?] {
        var result: [Range<Int>?] = []
        result.reserveCapacity(sentences.count)
        var cursor = 0

        for sentence in sentences {
            let needle = Array(sentence.unicodeScalars)
            guard let start = firstIndex(of: needle, in: haystack, from: cursor) else {
                result.append(nil)
                continue
            }
            let end = start + needle.count
            cursor = end
            result.append(start..<end)
        }
        return result
    }

    /// 朴素前向子序列查找。句子几乎总是紧跟游标出现，实际是常数级。
    public static func firstIndex(
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
