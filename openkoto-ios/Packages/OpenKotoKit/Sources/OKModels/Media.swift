import Foundation

// 视频/音频领域模型。
//
// 转写文稿**就是** `Article` 行，字幕句**就是** `ArticleSegment` 行：
// 精讲回填、生词外键、阅读会话、统计、SRS 因此对媒体一行不改即可生效。
// 归属关系由 `MediaPart` 关联表表达，与 `book_chapter` / `word_pack_membership` 同一套模式。
//
// 刻意**不**给 `SourceType` 加 `.video`：`ArticleRecord.domainModel()` 遇到未知
// source_type 会抛 corruptRow，而 `loadAll()` 是全表 map——一行坏数据就是整个书库
// 加载失败，降级安装即触发。身份交给关联表表达，这条严格性约束不必松动。

public enum MediaKind: String, Codable, Sendable, CaseIterable {
    case video
    case audio
}

/// 文稿从哪来。决定「有没有词级时间戳」「能不能重新转写」。
public enum TranscriptSource: String, Codable, Sendable, CaseIterable {
    /// 用户导入的 SRT
    case srt
    /// 用户导入的 WebVTT
    case vtt
    /// 端上语音识别（iOS 26 SpeechAnalyzer），唯一提供词级时间戳的来源
    case onDeviceSpeech = "asr-device"
}

public struct Media: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var title: String
    public var kind: MediaKind
    /// `Media/<dirName>`。只存相对名——沙盒绝对路径每次安装都会变。
    public var dirName: String
    /// 目录内的媒体文件名。nil 表示**引用外部文件**（见 `bookmarkData`），没有拷贝副本。
    public var fileName: String?
    /// security-scoped bookmark：引用模式下用它重新拿到用户选的文件。
    ///
    /// 几十上百 MB 的视频默认不拷贝——拷了就是双倍占盘。文件失效时只有播放不可用，
    /// 文稿与精讲都在库里，降级形状与书籍「原始文件丢失但正文还在」一致。
    public var bookmarkData: Data?
    /// 展示用的来源标签（原文件名）。
    public var sourceLabel: String?
    /// 秒。0 表示未知。
    public var duration: Double
    /// BCP-47。ASR、注音、TTS 共用的语种提示。
    public var language: String?
    public var transcriptSource: TranscriptSource
    /// 是否有词级时间戳（决定能否做逐词高亮）。
    public var hasWordTiming: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        kind: MediaKind,
        dirName: String,
        fileName: String? = nil,
        bookmarkData: Data? = nil,
        sourceLabel: String? = nil,
        duration: Double = 0,
        language: String? = nil,
        transcriptSource: TranscriptSource,
        hasWordTiming: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.dirName = dirName
        self.fileName = fileName
        self.bookmarkData = bookmarkData
        self.sourceLabel = sourceLabel
        self.duration = duration
        self.language = language
        self.transcriptSource = transcriptSource
        self.hasWordTiming = hasWordTiming
        self.createdAt = createdAt
    }

    /// 引用外部文件（未拷贝副本）。
    public var isExternalReference: Bool { fileName == nil }
}

/// 文稿归属：一个 media 对应一条 article。
///
/// `partIndex` 预留给「三小时讲座拆成几段」的场景——加行即可，不改 schema。
public struct MediaPart: Codable, Identifiable, Sendable, Hashable {
    public var articleId: UUID
    public var mediaId: UUID
    public var partIndex: Int

    public var id: UUID { articleId }

    public init(articleId: UUID, mediaId: UUID, partIndex: Int = 0) {
        self.articleId = articleId
        self.mediaId = mediaId
        self.partIndex = partIndex
    }
}

/// 播放位置。每个 media 一行。
public struct MediaProgress: Codable, Sendable, Hashable {
    public var mediaId: UUID
    /// 秒。
    public var position: Double
    public var rate: Double
    public var updatedAt: Date

    public init(mediaId: UUID, position: Double = 0, rate: Double = 1, updatedAt: Date = .now) {
        self.mediaId = mediaId
        self.position = position
        self.rate = rate
        self.updatedAt = updatedAt
    }
}
