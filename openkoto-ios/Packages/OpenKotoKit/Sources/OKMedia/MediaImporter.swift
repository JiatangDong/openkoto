import Foundation
import OKModels

/// 把「媒体文件 + 字幕」组装成可入库的一整套：`Media` / `Article` / `MediaPart` / `[ArticleSegment]`。
///
/// 纯值转换，不碰文件系统也不碰数据库——好让整条组装逻辑在 macOS 上单测。
/// 拷贝/引用的取舍、bookmark 生成留给 `ContentStore`（那里才知道 URL 是怎么来的）。
public struct MediaImporter: Sendable {
    public enum Failure: Error, Equatable {
        /// 字幕解析后一条 cue 都没有（空文件、格式不对、时间戳全坏）。
        case emptyTranscript
        case unsupportedSubtitleFormat(String)
    }

    public struct Result: Sendable {
        public var media: Media
        public var article: Article
        public var part: MediaPart
        public var segments: [ArticleSegment]
        public var diagnostics: AlignedTranscript.Diagnostics
    }

    private let aligner: TranscriptAligner

    public init(aligner: TranscriptAligner = TranscriptAligner()) {
        self.aligner = aligner
    }

    /// 从字幕文本组装。
    ///
    /// - Parameters:
    ///   - subtitle: 字幕文件原文
    ///   - format: 由扩展名推断，调用方负责
    ///   - dirName: `MediaStorage.directoryName(for:)` 的结果
    ///   - fileName: 拷贝模式下目录内的媒体文件名；引用模式传 nil
    public func makeImport(
        title: String,
        kind: MediaKind,
        subtitle: String,
        format: SubtitleParser.Format,
        dirName: String,
        fileName: String? = nil,
        bookmarkData: Data? = nil,
        sourceLabel: String? = nil,
        duration: Double = 0,
        language: String? = nil,
        mediaID: UUID = UUID(),
        now: Date = .now
    ) throws -> Result {
        let tokens = SubtitleParser.parse(subtitle, format: format)
        guard !tokens.isEmpty else { throw Failure.emptyTranscript }
        return assemble(
            title: title, kind: kind, tokens: tokens,
            source: format == .srt ? .srt : .vtt, hasWordTiming: false,
            dirName: dirName, fileName: fileName, bookmarkData: bookmarkData,
            sourceLabel: sourceLabel,
            duration: duration > 0 ? duration : (tokens.last?.end ?? 0),
            language: language, mediaID: mediaID, now: now)
    }

    /// 从已经拿到的 token 流组装（端上转写走这条）。
    public func makeImport(
        title: String,
        kind: MediaKind,
        tokens: [TimedToken],
        source: TranscriptSource,
        hasWordTiming: Bool,
        dirName: String,
        fileName: String? = nil,
        bookmarkData: Data? = nil,
        sourceLabel: String? = nil,
        duration: Double = 0,
        language: String? = nil,
        mediaID: UUID = UUID(),
        now: Date = .now
    ) throws -> Result {
        guard !tokens.isEmpty else { throw Failure.emptyTranscript }
        return assemble(
            title: title, kind: kind, tokens: tokens, source: source,
            hasWordTiming: hasWordTiming, dirName: dirName, fileName: fileName,
            bookmarkData: bookmarkData, sourceLabel: sourceLabel,
            duration: duration > 0 ? duration : (tokens.last?.end ?? 0),
            language: language, mediaID: mediaID, now: now)
    }

    /// 只导入媒体、还没有文稿时的占位。文稿留空，等端上转写填。
    ///
    /// 仍然建 article 行——这样「等待转写」的媒体和已有文稿的媒体在库里是同一个形状，
    /// 转写完成时只需替换 segment，不必再补建关联。
    public func makePlaceholder(
        title: String, kind: MediaKind, dirName: String, fileName: String? = nil,
        bookmarkData: Data? = nil, sourceLabel: String? = nil, duration: Double = 0,
        language: String? = nil, mediaID: UUID = UUID(), now: Date = .now
    ) -> Result {
        let article = Article(title: title, content: "", sourceType: .article, createdAt: now)
        let media = Media(
            id: mediaID, title: title, kind: kind, dirName: dirName, fileName: fileName,
            bookmarkData: bookmarkData, sourceLabel: sourceLabel, duration: duration,
            language: language, transcriptSource: .onDeviceSpeech, hasWordTiming: false,
            createdAt: now)
        return Result(
            media: media, article: article,
            part: MediaPart(articleId: article.id, mediaId: media.id),
            segments: [], diagnostics: .init())
    }

    /// 重新转写后生成新的句子，并**按原文文本继承已有精讲**。
    ///
    /// 不继承的话，换一次 ASR 就把用户攒下的两百句精讲全作废了——
    /// 桌面端 `resegment_article` 正是这个毛病。一次重转写通常 80%+ 的句子文本不变。
    public func realign(
        tokens: [TimedToken], articleID: UUID, inheritingFrom existing: [ArticleSegment],
        now: Date = .now
    ) throws -> (
        text: String, segments: [ArticleSegment], diagnostics: AlignedTranscript.Diagnostics
    ) {
        guard !tokens.isEmpty else { throw Failure.emptyTranscript }
        let aligned = aligner.align(tokens)

        var inherited: [String: ArticleSegment] = [:]
        for segment in existing where segment.explanation != nil || segment.translation != nil {
            inherited[segment.text] = segment
        }

        let segments = aligned.sentences.enumerated().map { index, sentence in
            var segment = ArticleSegment(
                articleId: articleID,
                order: index,
                text: sentence.text,
                isNewParagraph: sentence.isNewParagraph,
                startTime: sentence.start,
                endTime: sentence.end,
                createdAt: now)
            if let old = inherited[sentence.text] {
                // 保住 id：收藏的生词、复习记录都是按 source_article_id + 句子引用的
                segment.id = old.id
                segment.explanation = old.explanation
                segment.translation = old.translation
                segment.readingText = old.readingText
            }
            return segment
        }
        return (aligned.text, segments, aligned.diagnostics)
    }

    // MARK: - 组装

    private func assemble(
        title: String, kind: MediaKind, tokens: [TimedToken], source: TranscriptSource,
        hasWordTiming: Bool, dirName: String, fileName: String?, bookmarkData: Data?,
        sourceLabel: String?, duration: Double, language: String?, mediaID: UUID, now: Date
    ) -> Result {
        let aligned = aligner.align(tokens)
        let article = Article(
            title: title, content: aligned.text, sourceType: .article, createdAt: now)
        let segments = aligned.sentences.enumerated().map { index, sentence in
            ArticleSegment(
                articleId: article.id,
                order: index,
                text: sentence.text,
                isNewParagraph: sentence.isNewParagraph,
                startTime: sentence.start,
                endTime: sentence.end,
                createdAt: now)
        }
        let media = Media(
            id: mediaID, title: title, kind: kind, dirName: dirName, fileName: fileName,
            bookmarkData: bookmarkData, sourceLabel: sourceLabel, duration: duration,
            language: language, transcriptSource: source, hasWordTiming: hasWordTiming,
            createdAt: now)
        return Result(
            media: media,
            article: article,
            part: MediaPart(articleId: article.id, mediaId: media.id),
            segments: segments,
            diagnostics: aligned.diagnostics)
    }
}
