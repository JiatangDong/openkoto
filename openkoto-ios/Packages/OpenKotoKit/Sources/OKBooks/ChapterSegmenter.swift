import Foundation
import OKModels
import OKSegmentation

/// 章节延迟切分：首次打开某章时把正文切成句子。
///
/// 优先读**原始文件**（EPUB 的 XHTML / 青空的原始切片）——只有它带注音标记，
/// 切出来的句子才能填上 `ArticleSegment.readingText`。
/// 文件不在了（换机恢复后 `Books/` 未随备份回来）就退回 `article.content`：
/// 丢注音、丢原版模式，但**不丢书**。
public struct ChapterSegmenter: Sendable {
    private let segmenter: any SegmentationStrategy

    public init(segmenter: any SegmentationStrategy = SentenceSegmenter()) {
        self.segmenter = segmenter
    }

    public func segments(
        articleID: UUID,
        plainTextFallback: String,
        sourceFile: URL?,
        format: BookFormat,
        now: Date = .now
    ) -> [ArticleSegment] {
        let ruby = Self.rubyText(
            sourceFile: sourceFile, format: format, fallback: plainTextFallback)
        let drafts = segmenter.segment(ruby.plainText)
        let readings = ruby.readingLines(forSentencesIn: drafts.map(\.text))

        return drafts.enumerated().map { index, draft in
            ArticleSegment(
                articleId: articleID,
                order: index,
                text: draft.text,
                readingText: index < readings.count ? readings[index] : nil,
                isNewParagraph: draft.isNewParagraph,
                createdAt: now)
        }
    }

    /// 从原始文件解析带注音的文本。
    ///
    /// 切句结果落库，但 run 级注音不落库——阅读页要词级注音时在这里重新解析一次
    /// （一章几十毫秒），换来的是不必为一个还会演进的数据结构加 schema。
    public static func rubyText(sourceFile: URL?, format: BookFormat, fallback: String) -> RubyText {
        guard let sourceFile, let data = try? Data(contentsOf: sourceFile) else {
            return RubyText(plainText: fallback)
        }
        let text = EncodingDetector.decode(data).text
        switch format {
        case .epub:
            return XHTMLTextExtractor.extract(xhtml: text)
        case .txt:
            return AozoraParser.looksLikeAozora(text)
                ? AozoraParser.parse(text) : RubyText(plainText: text)
        }
    }
}
