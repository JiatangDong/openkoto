import Foundation
import OKSegmentation
import Testing

@testable import OKBooks

@Suite struct XHTMLTextExtractorTests {
    private func extract(_ xhtml: String) -> RubyText {
        XHTMLTextExtractor.extract(xhtml: xhtml)
    }

    // MARK: - 基本抽取

    @Test func extractsParagraphsAsNewlineSeparatedText() {
        let xhtml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>第一章</title></head>
            <body>
              <h1>第一章</h1>
              <p>吾輩は猫である。</p>
              <p>名前はまだ無い。</p>
            </body>
            </html>
            """
        #expect(extract(xhtml).plainText == "第一章\n吾輩は猫である。\n名前はまだ無い。")
    }

    /// 块级换行是切分段落的唯一依据，漏了整章会挤成一段。
    @Test func emitsLineBreakForBlockElementsAndBR() {
        let xhtml = "<body><div>一</div><p>二<br/>三</p><li>四</li></body>"
        #expect(extract(xhtml).plainText == "一\n二\n三\n四")
    }

    @Test func dropsScriptStyleAndSVGContent() {
        let xhtml = """
            <body><script>var a = 1 < 2;</script><style>p { color: red }</style>
            <p>正文</p><svg><text>图里的字</text></svg></body>
            """
        #expect(extract(xhtml).plainText == "正文")
    }

    @Test func collapsesSourceIndentationWhitespace() {
        let xhtml = """
            <body>
              <p>
                吾輩は
                猫である。
              </p>
            </body>
            """
        // 源码换行折叠出的空格夹在日文之间，应被去掉。
        #expect(extract(xhtml).plainText == "吾輩は猫である。")
    }

    @Test func keepsSpacesBetweenLatinWords() {
        let xhtml = "<body><p>I am\n  a cat.</p></body>"
        #expect(extract(xhtml).plainText == "I am a cat.")
    }

    // MARK: - ruby

    @Test func convertsRubyToAnnotatedRun() {
        let xhtml = "<body><p><ruby>吾輩<rt>わがはい</rt></ruby>は猫である。</p></body>"
        let ruby = extract(xhtml)
        #expect(ruby.plainText == "吾輩は猫である。")
        #expect(ruby.runs == [
            RubyText.Run(text: "吾輩", reading: "わがはい"),
            RubyText.Run(text: "は猫である。"),
        ])
    }

    @Test func dropsRPFallbackParentheses() {
        let xhtml = "<body><p><ruby>漢字<rp>（</rp><rt>かんじ</rt><rp>）</rp></ruby>です</p></body>"
        let ruby = extract(xhtml)
        #expect(ruby.plainText == "漢字です")
        #expect(ruby.runs.first?.reading == "かんじ")
    }

    @Test func supportsExplicitRBElement() {
        let xhtml = "<body><p><ruby><rb>東京</rb><rt>とうきょう</rt></ruby>へ</p></body>"
        let ruby = extract(xhtml)
        #expect(ruby.plainText == "東京へ")
        #expect(ruby.runs.first == RubyText.Run(text: "東京", reading: "とうきょう"))
    }

    @Test func handlesMultipleRubyRunsInOneParagraph() {
        let xhtml = """
            <body><p><ruby>吾輩<rt>わがはい</rt></ruby>は<ruby>猫<rt>ねこ</rt></ruby>である。</p></body>
            """
        let ruby = extract(xhtml)
        #expect(ruby.plainText == "吾輩は猫である。")
        #expect(ruby.runs.count == 4)
        #expect(ruby.runs.compactMap(\.reading) == ["わがはい", "ねこ"])
    }

    // MARK: - 实体

    @Test func decodesNamedEntities() {
        let xhtml = "<body><p>A&nbsp;B&mdash;C&hellip;</p></body>"
        #expect(extract(xhtml).plainText == "A\u{00A0}B—C…")
    }

    @Test func keepsXMLPredefinedEntities() {
        let xhtml = "<body><p>a &lt; b &amp;&amp; c &gt; d</p></body>"
        #expect(extract(xhtml).plainText == "a < b && c > d")
    }

    /// 表外的未知实体既不能让解析失败，也不能丢字符。
    @Test func escapesUnknownEntitiesInsteadOfFailing() {
        let xhtml = "<body><p>x&unknownthing;y</p></body>"
        #expect(extract(xhtml).plainText == "x&unknownthing;y")
    }

    @Test func stripsDoctype() {
        let xhtml = """
            <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11.dtd">
            <html><body><p>正文</p></body></html>
            """
        #expect(extract(xhtml).plainText == "正文")
    }

    // MARK: - 容错回退

    /// 标签不闭合 → XMLParser 失败 → 扫描器接管，正文不能丢。
    @Test func fallsBackToScannerOnMalformedMarkup() {
        let xhtml = "<body><p>第一章<p>第二章<p>第三章</body>"
        let text = extract(xhtml).plainText
        #expect(text.contains("第一章"))
        #expect(text.contains("第二章"))
        #expect(text.contains("第三章"))
    }

    @Test func scannerHandlesRubyAndSkippedElements() {
        let xhtml = """
            <body><script>if (a < b) {}</script><p><ruby>猫<rt>ねこ</rt></ruby>だ<p>次
            """
        let ruby = XHTMLTextExtractor.scan(XHTMLTextExtractor.preprocess(xhtml))
        #expect(ruby.plainText == "猫だ\n次")
        #expect(ruby.runs.first == RubyText.Run(text: "猫", reading: "ねこ"))
    }

    @Test func scannerSkipsCommentsContainingAngleBrackets() {
        let xhtml = "<body><!-- a > b, <p>fake</p> --><p>真正文</p></body>"
        #expect(XHTMLTextExtractor.scan(xhtml).plainText == "真正文")
    }

    @Test func returnsEmptyForImageOnlyChapter() {
        let xhtml = "<body><div><img src=\"p1.jpg\" alt=\"\"/></div></body>"
        #expect(extract(xhtml).plainText.isEmpty)
    }

    // MARK: - 与切分器联动

    /// 注音行的最终用途：切分成句后逐句生成 `ArticleSegment.readingText`。
    @Test func producesReadingLinesAlignedWithSegmentedSentences() {
        let xhtml = """
            <body><p><ruby>吾輩<rt>わがはい</rt></ruby>は猫である。<ruby>名前<rt>なまえ</rt></ruby>はまだ無い。</p>
            <p>どこで生れたか頓と見当がつかぬ。</p></body>
            """
        let ruby = extract(xhtml)
        let sentences = SentenceSegmenter().segment(ruby.plainText).map(\.text)
        #expect(sentences == ["吾輩は猫である。", "名前はまだ無い。", "どこで生れたか頓と見当がつかぬ。"])

        let readings = ruby.readingLines(forSentencesIn: sentences)
        #expect(readings == ["わがはいは猫である。", "なまえはまだ無い。", nil])
    }

    @Test func readingLinesAreAllNilWithoutRuby() {
        let ruby = extract("<body><p>没有注音的中文。第二句。</p></body>")
        let sentences = SentenceSegmenter().segment(ruby.plainText).map(\.text)
        #expect(ruby.readingLines(forSentencesIn: sentences).allSatisfy { $0 == nil })
    }
}
