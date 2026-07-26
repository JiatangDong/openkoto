import Foundation
import Testing

@testable import OKMedia

/// 字幕解析。桌面端有**两套不等价的 SRT 解析器**（`subtitle_import.rs` 与 `youtube.rs`），
/// 后者写死时间行在第 2 行、只认逗号毫秒、不归一 CRLF，会静默丢 cue。这里只有一套。
@Suite struct SubtitleParserTests {
    @Test func parsesBasicSRT() {
        let srt = """
            1
            00:00:01,000 --> 00:00:03,500
            First line here.

            2
            00:00:04,000 --> 00:00:06,000
            Second line here.
            """
        let tokens = SubtitleParser.parse(srt, format: .srt)
        #expect(tokens.count == 2)
        #expect(tokens[0].text == "First line here.")
        #expect(tokens[0].start == 1.0)
        #expect(tokens[0].end == 3.5)
        #expect(tokens[1].start == 4.0)
    }

    /// CRLF、点号毫秒、缺序号行、时间行不在第 2 行——全都要能吃下。
    @Test func toleratesFormatVariations() {
        let srt = "00:00:01.000 --> 00:00:02.000\r\nNo index line.\r\n\r\n"
        let tokens = SubtitleParser.parse(srt, format: .srt)
        #expect(tokens.count == 1)
        #expect(tokens[0].text == "No index line.")
    }

    /// cue 内换行是**显示折行不是语义边界**，必须按接缝规则合并而不是留成 "\n"，
    /// 否则切分器会把它当段落边界，句子就无法跨行合并。
    @Test func mergesCueInternalLineBreaks() {
        let srt = """
            1
            00:00:01,000 --> 00:00:04,000
            The quick brown fox
            jumps over the lazy dog.
            """
        let tokens = SubtitleParser.parse(srt, format: .srt)
        #expect(tokens.count == 1)
        #expect(tokens[0].text == "The quick brown fox jumps over the lazy dog.")
        #expect(!tokens[0].text.contains("\n"))
    }

    @Test func mergesCJKCueLinesWithoutSpaces() {
        let srt = """
            1
            00:00:01,000 --> 00:00:04,000
            これは日本語の
            字幕です。
            """
        let tokens = SubtitleParser.parse(srt, format: .srt)
        #expect(tokens[0].text == "これは日本語の字幕です。")
    }

    // MARK: - VTT

    @Test func parsesVTTWithHeaderAndCueSettings() {
        let vtt = """
            WEBVTT

            00:01.000 --> 00:03.000 align:start position:0%
            Hello from VTT.
            """
        let tokens = SubtitleParser.parse(vtt, format: .vtt)
        #expect(tokens.count == 1)
        #expect(tokens[0].text == "Hello from VTT.")
        #expect(tokens[0].start == 1.0)
        #expect(tokens[0].end == 3.0)
    }

    /// VTT 内联标记与时间戳标签要剥干净。
    @Test func stripsMarkup() {
        #expect(SubtitleParser.stripMarkup("<c.colorE5E5E5>Hello</c>") == "Hello")
        #expect(SubtitleParser.stripMarkup("<v Speaker>Hi there</v>") == "Hi there")
        #expect(SubtitleParser.stripMarkup("<00:00:01.000>Word") == "Word")
        #expect(SubtitleParser.stripMarkup("{\\an8}Positioned") == "Positioned")
        #expect(SubtitleParser.stripMarkup("A &amp; B") == "A & B")
    }

    // MARK: - 清洗

    /// YouTube 自动字幕每条 cue 会把上一条的尾部再滚一遍。
    /// 不去重的话文稿全是重复句，精讲和生词都被污染。
    @Test func dedupesRollingRepeats() {
        let srt = """
            1
            00:00:01,000 --> 00:00:03,000
            Hello world

            2
            00:00:03,000 --> 00:00:05,000
            Hello world and more
            """
        let tokens = SubtitleParser.parse(srt, format: .srt)
        #expect(tokens.count == 2)
        #expect(tokens[0].text == "Hello world")
        #expect(tokens[1].text == "and more")
        // 增量部分的起点应落在第二条 cue 内部，不是它的开头
        #expect(tokens[1].start > 3.0)
    }

    @Test func dropsExactDuplicates() {
        let srt = """
            1
            00:00:01,000 --> 00:00:03,000
            Same text

            2
            00:00:03,000 --> 00:00:05,000
            Same text
            """
        #expect(SubtitleParser.parse(srt, format: .srt).count == 1)
    }

    /// 零时长 cue 在桌面端会永不显示（`currentTime >= start && < end` 恒假）。
    /// 这里必须用下一条的起点补齐。
    @Test func fillsZeroLengthCueFromNextStart() {
        let srt = """
            1
            00:00:01,000 --> 00:00:01,000
            Zero length

            2
            00:00:05,000 --> 00:00:07,000
            Next one
            """
        let tokens = SubtitleParser.parse(srt, format: .srt)
        #expect(tokens[0].end == 5.0)
    }

    /// 时间戳解析失败必须丢弃整条 cue，**绝不静默降级成 0.0**——
    /// 桌面端 `parse_time_str` 的 `unwrap_or(0.0)` 会让字幕毫无提示地跳到 0 秒。
    @Test func rejectsMalformedTimestampsInsteadOfZeroing() {
        #expect(SubtitleParser.parseTimestamp("00:00:01,000") == 1.0)
        #expect(SubtitleParser.parseTimestamp("1m23s") == nil)
        #expect(SubtitleParser.parseTimestamp("83.4") == nil)
        #expect(SubtitleParser.parseTimestamp("") == nil)

        let srt = """
            1
            1m23s --> 2m00s
            Bad timing
            """
        #expect(SubtitleParser.parse(srt, format: .srt).isEmpty)
    }

    @Test func infersFormatFromExtension() {
        #expect(SubtitleParser.Format.infer(fromExtension: "SRT") == .srt)
        #expect(SubtitleParser.Format.infer(fromExtension: "vtt") == .vtt)
        #expect(SubtitleParser.Format.infer(fromExtension: "ass") == nil)
    }

    // MARK: - 端到端

    /// 解析 → 对齐：一段被字幕行切碎的英文，最终要还原成完整句子。
    @Test func parseThenAlignRestoresWholeSentences() {
        let srt = """
            1
            00:00:00,000 --> 00:00:02,000
            When I was younger

            2
            00:00:02,000 --> 00:00:04,000
            I studied abroad for a year.

            3
            00:00:04,500 --> 00:00:06,000
            It changed everything.
            """
        let result = TranscriptAligner().align(SubtitleParser.parse(srt, format: .srt))
        #expect(result.sentences.count == 2)
        #expect(result.sentences[0].text == "When I was younger I studied abroad for a year.")
        #expect(result.sentences[0].start == 0)
        #expect(result.sentences[1].text == "It changed everything.")
    }
}
