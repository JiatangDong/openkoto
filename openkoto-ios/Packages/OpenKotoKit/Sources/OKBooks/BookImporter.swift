import Foundation
import OKModels

/// 书籍导入：文件 → 解压/分章 → 章节纯文本 + 元数据。
///
/// **不切句**——一本 50 万字小说约 1.5 万句，导入时全切会卡住主线程也撑爆内存；
/// 切分推迟到首次打开该章（`ChapterSegmenter`）。
///
/// 全程不碰 UIKit/WebKit，可在后台线程跑，也能在 macOS 上完整单测。
public struct BookImporter: Sendable {
    public enum Failure: Error, Equatable {
        /// 正文被 DRM 加密。明确报错，绝不"导入成功"后正文变占位符（桌面端的行为）。
        case drmProtected
        case corruptArchive(String)
        case emptyContent
        case unsupportedFormat(String)
    }

    public struct Chapter: Sendable, Equatable {
        public var title: String
        public var plainText: String
        /// 相对书籍目录的原始文件，供注音重建与原版模式使用。
        public var sourceHref: String?

        public var charCount: Int { plainText.count }
    }

    public struct Result: Sendable, Equatable {
        public var book: Book
        public var chapters: [Chapter]
    }

    private let storage: BookStorage
    private let splitterOptions: ChapterSplitter.Options

    public init(storage: BookStorage, splitterOptions: ChapterSplitter.Options = .init()) {
        self.storage = storage
        self.splitterOptions = splitterOptions
    }

    /// 按扩展名分发。
    /// - Returns: TXT 内容太短时返回 nil，调用方按普通文章导入（保持既有行为）。
    public func importBook(from fileURL: URL, title: String? = nil) throws -> Result? {
        let name = title ?? fileURL.deletingPathExtension().lastPathComponent
        switch fileURL.pathExtension.lowercased() {
        case "epub":
            return try importEPUB(from: fileURL, fallbackTitle: name)
        case "txt", "text", "md", "markdown", "":
            return try importTXT(from: fileURL, title: name)
        case let other:
            throw Failure.unsupportedFormat(other)
        }
    }

    // MARK: - EPUB

    public func importEPUB(from fileURL: URL, fallbackTitle: String) throws -> Result {
        let bookID = UUID()
        let staging = try storage.stagingDirectory(for: bookID)
        var committed = false
        defer { if !committed { storage.discardStaging(for: bookID) } }

        do {
            let archive = try ZIPArchive(url: fileURL)
            try archive.extractAll(to: staging)
        } catch let failure as ZIPArchive.Failure {
            throw Failure.corruptArchive(String(describing: failure))
        }

        let package: EPUBPackage
        do {
            package = try EPUBParser.parse(bookDirectory: staging)
        } catch EPUBParser.Failure.drmProtected {
            throw Failure.drmProtected
        } catch let failure {
            throw Failure.corruptArchive(String(describing: failure))
        }

        var chapters: [Chapter] = []
        for item in package.readingOrder {
            let url = staging.appendingPathComponent(item.href)
            guard let data = try? Data(contentsOf: url) else { continue }
            let ruby = XHTMLTextExtractor.extract(xhtml: EncodingDetector.decode(data).text)
            let plain = ruby.plainText
            let title = package.tocTitle(forPath: item.href)
                ?? ChapterSplitter.title(from: plain)
            chapters.append(
                Chapter(
                    title: title.isEmpty ? item.href : title,
                    plainText: plain,
                    sourceHref: item.href))
        }
        guard !chapters.isEmpty else { throw Failure.emptyContent }

        let quality = Self.assessQuality(chapters: chapters, isFixedLayout: package.isFixedLayout)
        try storage.commit(staging: staging, to: bookID)
        committed = true

        let book = Book(
            id: bookID,
            title: package.title?.isEmpty == false ? package.title! : fallbackTitle,
            author: package.author,
            language: package.language,
            format: .epub,
            dirName: storage.directoryName(for: bookID),
            opfPath: package.opfPath,
            coverHref: package.coverHref,
            totalChars: chapters.reduce(0) { $0 + $1.charCount },
            defaultMode: quality.defaultMode,
            originalOnly: quality.originalOnly)
        return Result(book: book, chapters: chapters)
    }

    // MARK: - TXT

    public func importTXT(from fileURL: URL, title: String) throws -> Result? {
        guard let data = try? Data(contentsOf: fileURL) else { throw Failure.emptyContent }
        return try importText(EncodingDetector.decode(data).text, title: title)
    }

    /// 已解码文本的导入路径（分享/粘贴进来的长文也走这里）。
    public func importText(_ raw: String, title: String) throws -> Result? {
        let isAozora = AozoraParser.looksLikeAozora(raw)
        let body = isAozora ? AozoraParser.stripFrontMatter(raw) : raw
        let pieces = ChapterSplitter.split(body, options: splitterOptions)
        // 太短：不建书，交回普通文章路径。
        guard !pieces.isEmpty else { return nil }

        let bookID = UUID()
        let staging = try storage.stagingDirectory(for: bookID)
        var committed = false
        defer { if !committed { storage.discardStaging(for: bookID) } }

        let chaptersDirectory = staging.appendingPathComponent("chapters", isDirectory: true)
        try FileManager.default.createDirectory(
            at: chaptersDirectory, withIntermediateDirectories: true)

        var chapters: [Chapter] = []
        for (index, piece) in pieces.enumerated() {
            let href = String(format: "chapters/%04d.txt", index)
            // 原始切片落盘：注音（青空 ｜《》）要靠它重建，纯文本里已经没有标记了。
            try Data(piece.rawText.utf8).write(
                to: staging.appendingPathComponent(href), options: .atomic)
            let plain = isAozora ? AozoraParser.parse(piece.rawText).plainText : piece.rawText
            chapters.append(
                Chapter(title: piece.title, plainText: plain, sourceHref: href))
        }

        try storage.commit(staging: staging, to: bookID)
        committed = true

        let book = Book(
            id: bookID,
            title: title,
            language: isAozora ? "ja" : nil,
            format: .txt,
            dirName: storage.directoryName(for: bookID),
            totalChars: chapters.reduce(0) { $0 + $1.charCount },
            defaultMode: .native,
            originalOnly: false)
        return Result(book: book, chapters: chapters)
    }

    // MARK: - 抽取质量判定

    struct Quality: Equatable {
        var defaultMode: BookRenderMode
        var originalOnly: Bool
    }

    /// `originalOnly` 会**彻底禁用**原生模式，只在有结构性证据时才给：
    /// 声明了固定版式，或整本几乎抽不出字（纯图漫画）。
    /// 光靠"字少"不作数——短篇集、绘本同样字少，但正文是真的，不该被锁死。
    ///
    /// 字少只影响**默认**模式：先给原版，用户随时能切回原生。
    static func assessQuality(chapters: [Chapter], isFixedLayout: Bool) -> Quality {
        let total = chapters.reduce(0) { $0 + $1.charCount }
        if isFixedLayout || total < 100 {
            return Quality(defaultMode: .original, originalOnly: true)
        }
        let counts = chapters.map(\.charCount).sorted()
        let median = counts[counts.count / 2]
        return Quality(defaultMode: median < 200 ? .original : .native, originalOnly: false)
    }
}
