import Foundation
import OKSegmentation
import Testing

@testable import OKBooks

@Suite struct AozoraParserTests {
    // MARK: - 振り仮名

    /// 显式标记：`｜` 指定注音对象的起点。
    @Test func parsesExplicitRubyMarker() {
        let ruby = AozoraParser.parse("｜吾輩《わがはい》は猫である。")
        #expect(ruby.plainText == "吾輩は猫である。")
        #expect(ruby.runs.first == RubyText.Run(text: "吾輩", reading: "わがはい"))
    }

    /// 无 `｜` 时，注音对象是紧邻的同类字符串（这里是汉字串）。
    @Test func infersKanjiBaseWithoutMarker() {
        let ruby = AozoraParser.parse("吾輩《わがはい》は猫である。")
        #expect(ruby.plainText == "吾輩は猫である。")
        #expect(ruby.runs.first == RubyText.Run(text: "吾輩", reading: "わがはい"))
    }

    /// 前面是假名时不能把假名一起吞进注音对象。
    @Test func stopsInferredBaseAtCategoryBoundary() {
        let ruby = AozoraParser.parse("その日、彼は東京《とうきょう》へ行った。")
        #expect(ruby.plainText == "その日、彼は東京へ行った。")
        let annotated = ruby.runs.first { $0.reading != nil }
        #expect(annotated == RubyText.Run(text: "東京", reading: "とうきょう"))
    }

    @Test func handlesMultipleRubyPerLine() {
        let ruby = AozoraParser.parse("｜吾輩《わがはい》は｜猫《ねこ》である。")
        #expect(ruby.plainText == "吾輩は猫である。")
        #expect(ruby.runs.compactMap(\.reading) == ["わがはい", "ねこ"])
    }

    /// 未闭合的 《 不能吃掉后面的正文。
    @Test func keepsUnclosedBracketAsLiteralText() {
        let ruby = AozoraParser.parse("これは《未完成の文です")
        #expect(ruby.plainText == "これは《未完成の文です")
    }

    /// 行首直接出现 《》 时没有注音对象，按普通括号保留。
    @Test func keepsBracketsWithoutBaseText() {
        let ruby = AozoraParser.parse("《引用》とは何か")
        #expect(ruby.plainText == "《引用》とは何か")
        #expect(ruby.hasReadings == false)
    }

    // MARK: - 注记

    @Test func stripsAnnotationsAndGaiji() {
        let text = "［＃ここから2字下げ］彼は※［＃「彳＋亍」、第3水準1-84-28］った。［＃ここで字下げ終わり］"
        #expect(AozoraParser.parse(text).plainText == "彼はった。")
    }

    @Test func stripsAnnotationButKeepsSurroundingRuby() {
        let ruby = AozoraParser.parse("［＃3字下げ］｜吾輩《わがはい》は猫である。")
        #expect(ruby.plainText == "吾輩は猫である。")
        #expect(ruby.runs.first?.reading == "わがはい")
    }

    // MARK: - 页眉页脚

    @Test func stripsHeaderBlockAndColophon() {
        let text = """
            吾輩は猫である
            夏目漱石

            -------------------------------------------------------
            【テキスト中に現れる記号について】

            《》：ルビ
            ｜：ルビの付く文字列の始まりを特定する記号
            -------------------------------------------------------

            ｜吾輩《わがはい》は猫である。名前はまだ無い。

            底本：「吾輩は猫である」岩波文庫、岩波書店
            1990（平成2）年1月16日第1刷発行
            """
        let stripped = AozoraParser.stripFrontMatter(text)
        #expect(stripped.contains("【テキスト中に現れる記号について】") == false)
        #expect(stripped.contains("底本：") == false)
        #expect(stripped.contains("岩波文庫") == false)
        #expect(stripped.contains("吾輩《わがはい》は猫である。"))
        // 书名与作者保留。
        #expect(stripped.hasPrefix("吾輩は猫である\n夏目漱石"))
    }

    @Test func leavesPlainTextUntouched() {
        let text = "普通の日本語のテキストです。\n記号はありません。"
        #expect(AozoraParser.stripFrontMatter(text) == text)
    }

    // MARK: - 识别

    @Test func detectsAozoraFormat() {
        #expect(AozoraParser.looksLikeAozora("｜吾輩《わがはい》は猫である。"))
        #expect(AozoraParser.looksLikeAozora("本文\n底本：「吾輩は猫である」"))
        #expect(AozoraParser.looksLikeAozora("［＃3字下げ］本文"))
        #expect(AozoraParser.looksLikeAozora("ただの日本語の文章です。") == false)
        #expect(AozoraParser.looksLikeAozora("普通的中文小说内容。") == false)
    }

    // MARK: - 段落与切分联动

    /// 换行必须活到切分器手里，否则整章挤成一段。
    @Test func preservesParagraphBreaks() {
        let ruby = AozoraParser.parse("一行目です。\n二行目です。\n\n三行目です。")
        #expect(ruby.plainText == "一行目です。\n二行目です。\n三行目です。")
    }

    @Test func producesReadingLinesForSegmentedSentences() {
        let ruby = AozoraParser.parse("｜吾輩《わがはい》は猫である。｜名前《なまえ》はまだ無い。")
        let sentences = SentenceSegmenter().segment(ruby.plainText).map(\.text)
        #expect(sentences == ["吾輩は猫である。", "名前はまだ無い。"])
        #expect(ruby.readingLines(forSentencesIn: sentences) == [
            "わがはいは猫である。", "なまえはまだ無い。",
        ])
    }

    /// 端到端：青空正文 → 剥页眉 → 分章 → 逐章解析注音。
    @Test func splitsAozoraNovelIntoChaptersWithRuby() {
        let paragraphs = (0..<40)
            .map { "｜吾輩《わがはい》は猫である。第\($0)段の本文がここに続きます。名前はまだ無い。" }
            .joined(separator: "\n")
        let text = """
            吾輩は猫である
            夏目漱石

            第一章
            \(paragraphs)

            第二章
            \(paragraphs)

            底本：「吾輩は猫である」岩波文庫、岩波書店
            """

        var options = ChapterSplitter.Options()
        options.minBookChars = 200
        let chapters = ChapterSplitter.split(
            AozoraParser.stripFrontMatter(text), options: options)
        #expect(chapters.map(\.title) == ["吾輩は猫である", "第一章", "第二章"])

        let ruby = AozoraParser.parse(chapters[1].rawText)
        #expect(ruby.plainText.hasPrefix("第一章\n吾輩は猫である。"))
        #expect(ruby.runs.contains(RubyText.Run(text: "吾輩", reading: "わがはい")))
        #expect(ruby.plainText.contains("底本：") == false)
    }
}
