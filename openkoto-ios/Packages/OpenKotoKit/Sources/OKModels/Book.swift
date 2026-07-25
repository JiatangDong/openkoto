import Foundation

// 书籍领域模型（TXT / EPUB 长文）。
//
// 章节**就是** `Article` 行：学习管线（精讲回填、生词外键、阅读会话、统计）
// 因此对书籍一行不改即可生效。归属关系由 `BookChapter` 关联表表达，
// 与既有的 `word_pack_membership` 同一套模式。

public enum BookFormat: String, Codable, Sendable, CaseIterable {
    case txt
    case epub
}

/// 阅读模式：原生（逐句 chip + 精讲/生词）与原版（WKWebView 还原排版）。
public enum BookRenderMode: String, Codable, Sendable, CaseIterable {
    case native
    case original
}

public struct Book: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var title: String
    public var author: String?
    public var language: String?
    public var format: BookFormat
    /// `Books/<dirName>`。只存相对名——沙盒绝对路径每次安装都会变。
    public var dirName: String
    /// EPUB 的 OPF 相对路径；TXT 为 nil。
    public var opfPath: String?
    public var coverHref: String?
    public var totalChars: Int
    /// 导入期按抽取质量判定的默认模式。
    public var defaultMode: BookRenderMode
    /// 固定版式/纯图书：抽不出正文，只能原版模式。
    public var originalOnly: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        author: String? = nil,
        language: String? = nil,
        format: BookFormat,
        dirName: String,
        opfPath: String? = nil,
        coverHref: String? = nil,
        totalChars: Int = 0,
        defaultMode: BookRenderMode = .native,
        originalOnly: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.language = language
        self.format = format
        self.dirName = dirName
        self.opfPath = opfPath
        self.coverHref = coverHref
        self.totalChars = totalChars
        self.defaultMode = defaultMode
        self.originalOnly = originalOnly
        self.createdAt = createdAt
    }
}

/// 章节归属。`articleId` 既是主键也是外键——一章对应一个 article 行。
public struct BookChapter: Codable, Identifiable, Sendable, Hashable {
    public var articleId: UUID
    public var bookId: UUID
    public var index: Int
    /// 相对书籍目录的原始文件（EPUB 的 XHTML / TXT 的章节切片），供原版模式与注音重建使用。
    public var sourceHref: String?
    /// 是否已切句。导入时为 false，首次打开该章时才切分。
    public var isSegmented: Bool
    public var charCount: Int

    public var id: UUID { articleId }

    public init(
        articleId: UUID,
        bookId: UUID,
        index: Int,
        sourceHref: String? = nil,
        isSegmented: Bool = false,
        charCount: Int = 0
    ) {
        self.articleId = articleId
        self.bookId = bookId
        self.index = index
        self.sourceHref = sourceHref
        self.isSegmented = isSegmented
        self.charCount = charCount
    }
}

/// 阅读位置：每本书一行。
///
/// 原生锚点 `segmentOrder` 与原版锚点 `scrollFraction` **同时维护**，
/// 任何时刻切换模式都有定义（换算见 `resolvedSegmentOrder` / `resolvedFraction`）。
public struct BookProgress: Codable, Sendable, Hashable {
    public var bookId: UUID
    public var chapterArticleId: UUID?
    public var chapterIndex: Int
    public var segmentOrder: Int?
    public var scrollFraction: Double?
    public var mode: BookRenderMode
    public var updatedAt: Date

    public init(
        bookId: UUID,
        chapterArticleId: UUID? = nil,
        chapterIndex: Int = 0,
        segmentOrder: Int? = nil,
        scrollFraction: Double? = nil,
        mode: BookRenderMode = .native,
        updatedAt: Date = .now
    ) {
        self.bookId = bookId
        self.chapterArticleId = chapterArticleId
        self.chapterIndex = chapterIndex
        self.segmentOrder = segmentOrder
        self.scrollFraction = scrollFraction
        self.mode = mode
        self.updatedAt = updatedAt
    }

    /// 切到原生模式时的落点：优先用原生锚点，没有就按比例换算。
    public func resolvedSegmentOrder(segmentCount: Int) -> Int {
        guard segmentCount > 0 else { return 0 }
        if let segmentOrder { return min(max(segmentOrder, 0), segmentCount - 1) }
        guard let scrollFraction else { return 0 }
        let index = Int((scrollFraction * Double(segmentCount)).rounded())
        return min(max(index, 0), segmentCount - 1)
    }

    /// 切到原版模式时的落点：优先用原版锚点，没有就按句序换算。
    public func resolvedFraction(segmentCount: Int) -> Double {
        if let scrollFraction { return min(max(scrollFraction, 0), 1) }
        guard let segmentOrder, segmentCount > 0 else { return 0 }
        return min(max(Double(segmentOrder) / Double(segmentCount), 0), 1)
    }
}

/// 书签与划线。分层锚点：原生用 `segmentOrder`(+句内字符区间)，
/// 原版用 `locator`，`selectedText` 永远保存，作为两种模式共同的兜底重锚依据。
public struct BookMark: Codable, Identifiable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case bookmark
        case highlight
    }

    public var id: UUID
    public var bookId: UUID
    public var chapterArticleId: UUID?
    public var chapterIndex: Int
    public var kind: Kind
    /// 章内句序。不用 segment id 外键——句子可重新切分，序号才是稳定锚。
    public var segmentOrder: Int?
    /// 划线在句内的 Unicode 标量区间。
    public var charStart: Int?
    public var charEnd: Int?
    /// 原版模式锚点（自定义格式，非 EPUB CFI）。
    public var locator: String?
    public var scrollFraction: Double?
    public var selectedText: String?
    public var note: String?
    public var color: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        bookId: UUID,
        chapterArticleId: UUID? = nil,
        chapterIndex: Int,
        kind: Kind,
        segmentOrder: Int? = nil,
        charStart: Int? = nil,
        charEnd: Int? = nil,
        locator: String? = nil,
        scrollFraction: Double? = nil,
        selectedText: String? = nil,
        note: String? = nil,
        color: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.bookId = bookId
        self.chapterArticleId = chapterArticleId
        self.chapterIndex = chapterIndex
        self.kind = kind
        self.segmentOrder = segmentOrder
        self.charStart = charStart
        self.charEnd = charEnd
        self.locator = locator
        self.scrollFraction = scrollFraction
        self.selectedText = selectedText
        self.note = note
        self.color = color
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// 目录用的章节摘要：不含正文，可以整本一次性加载。
public struct BookChapterSummary: Sendable, Hashable, Identifiable {
    public var articleId: UUID
    public var index: Int
    public var title: String
    public var charCount: Int
    public var isSegmented: Bool
    /// 相对书籍目录的原始文件——原版模式直接把它交给 WKWebView。
    public var sourceHref: String?

    public var id: UUID { articleId }

    public init(
        articleId: UUID, index: Int, title: String, charCount: Int, isSegmented: Bool,
        sourceHref: String? = nil
    ) {
        self.articleId = articleId
        self.index = index
        self.title = title
        self.charCount = charCount
        self.isSegmented = isSegmented
        self.sourceHref = sourceHref
    }
}
