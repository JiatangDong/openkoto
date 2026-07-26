import Foundation
import Testing

@testable import OKMedia

/// 对齐管线的核心契约。
///
/// 每条断言都对应桌面端一个已确认的缺陷——这个文件存在的意义就是让那些缺陷
/// 在 iOS 上无法复现。改动算法时若这里挂了，先想清楚是不是又把桌面端的坑挖回来了。
@Suite struct TranscriptAlignerTests {
    private let aligner = TranscriptAligner()

    private func cue(_ text: String, _ start: Double, _ end: Double) -> TimedToken {
        TimedToken(text: text, start: start, end: end)
    }

    // MARK: - 跨 cue 合句（桌面端最核心的缺陷）

    /// 字幕行是按显示宽度切的，一句话常被劈成两三条 cue。
    /// 桌面端 1 cue = 1 segment，于是精讲拿到半句话。这里必须合回完整句子。
    @Test func mergesSentenceSplitAcrossCues() {
        let result = aligner.align([
            cue("The quick brown fox", 0, 2),
            cue("jumps over the lazy dog.", 2, 4),
        ])

        #expect(result.sentences.count == 1)
        #expect(result.sentences[0].text == "The quick brown fox jumps over the lazy dog.")
        // 时间由首尾 token 直接给出，不插值不漂移
        #expect(result.sentences[0].start == 0)
        #expect(result.sentences[0].end == 4)
    }

    /// 中日文合并时**不能**加空格。
    @Test func mergesCJKWithoutSpaces() {
        let result = aligner.align([
            cue("これは日本語の", 0, 1.5),
            cue("字幕です。", 1.5, 3),
        ])
        #expect(result.sentences.count == 1)
        #expect(result.sentences[0].text == "これは日本語の字幕です。")
    }

    /// 韩语用空格——别把 CJK 三个字连着念就把韩文也塞进无空格集合。
    @Test func joinsKoreanWithSpaces() {
        #expect(TokenJoiner.joiner(after: "한국말", before: "입니다") == " ")
        #expect(TokenJoiner.joiner(after: "日本語", before: "です") == "")
        #expect(TokenJoiner.joiner(after: "中文", before: "字幕") == "")
    }

    // MARK: - 单 cue 多句：按字符比例插值

    @Test func splitsMultipleSentencesInsideOneCue() {
        let result = aligner.align([cue("First one. Second one.", 0, 10)])

        #expect(result.sentences.count == 2)
        #expect(result.sentences[0].text == "First one.")
        #expect(result.sentences[1].text == "Second one.")
        #expect(result.sentences[0].start == 0)
        // 第二句起点落在 cue 内部，按字符比例插值 → 严格介于 0 和 10 之间
        let secondStart = try! #require(result.sentences[1].start)
        #expect(secondStart > 0 && secondStart < 10)
        #expect(result.sentences[1].end == 10)
        // 前一句的结束不能晚于后一句的开始
        #expect(try! #require(result.sentences[0].end) <= secondStart)
    }

    // MARK: - 时间轴健壮性（桌面端的静默降级在这里必须被修掉）

    /// 乱序、重叠、零时长的输入不能产出乱序或零时长的句子。
    @Test func repairsUnsortedOverlappingAndZeroLengthInput() {
        let result = aligner.align([
            cue("Second sentence here.", 5, 4),  // end < start
            cue("First sentence here.", 1, 6),  // 与后者重叠
        ])

        let starts = result.sentences.compactMap(\.start)
        #expect(starts == starts.sorted())
        for sentence in result.sentences {
            let start = try! #require(sentence.start)
            let end = try! #require(sentence.end)
            #expect(end > start)
        }
    }

    /// 空输入不崩。
    @Test func handlesEmptyInput() {
        let result = aligner.align([])
        #expect(result.sentences.isEmpty)
        #expect(result.text.isEmpty)
    }

    // MARK: - 段落切分（性能正确性，不是美化）

    /// 静音超过阈值要断段落：既是段落边界，也防止把停顿两侧黏成一句。
    @Test func breaksParagraphOnLongSilence() {
        let result = aligner.align([
            cue("Before the pause.", 0, 2),
            cue("After the pause.", 10, 12),  // 8 秒静音
        ])
        #expect(result.sentences.count == 2)
        #expect(result.sentences[1].isNewParagraph)
    }

    /// 段内句数必须有上限——`NativeChapterView` 的 LazyVStack 每行是一个段落，
    /// 一小时视频 600 句全在一段里会让虚拟化失效、直接卡死。
    @Test func capsSentencesPerParagraph() {
        // 200 句连续无停顿的短句
        let tokens = (0..<200).map { index in
            cue("Sentence number \(index).", Double(index), Double(index) + 1)
        }
        let result = aligner.align(tokens)

        #expect(result.sentences.count == 200)
        #expect(result.diagnostics.maxSentencesPerParagraph <= 30)
    }

    // MARK: - 重复句（歌词、口语复述）

    /// 完全相同的句子重复出现时，必须按**出现顺序**分别拿到各自的时间，
    /// 不能都对到第一处。这依赖定位器的单调前向游标。
    @Test func alignsRepeatedSentencesInOrder() {
        let result = aligner.align([
            cue("Say it again.", 0, 2),
            cue("Say it again.", 5, 7),
        ])
        #expect(result.sentences.count == 2)
        #expect(result.sentences[0].start == 0)
        #expect(result.sentences[1].start == 5)
    }

    // MARK: - 诊断

    @Test func reportsDiagnostics() {
        let result = aligner.align([
            cue("One sentence here.", 0, 2),
            cue("Another sentence.", 2, 4),
        ])
        #expect(result.diagnostics.tokenCount == 2)
        #expect(result.diagnostics.sentenceCount == 2)
        #expect(result.diagnostics.unlocatedCount == 0)
    }

    /// 拼接出的全文必须能原样承载所有句子——正文不能被改写。
    @Test func fullTextContainsEverySentence() {
        let result = aligner.align([
            cue("これは最初の文です。", 0, 2),
            cue("そして二番目。", 2, 4),
            cue("Mixed English too.", 4, 6),
        ])
        for sentence in result.sentences {
            #expect(result.text.contains(sentence.text))
        }
    }
}
