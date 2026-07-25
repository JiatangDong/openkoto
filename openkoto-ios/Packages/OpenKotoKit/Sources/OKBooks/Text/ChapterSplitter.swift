import Foundation

/// 纯文本小说分章。
///
/// 桌面端按固定 2000 字硬切页，翻页与章节无关；这里按标题行切真章节，
/// 章节才能对应目录、续读位置和逐章精讲。
///
/// 切分在**原始文本**上做（保留青空文庫的 `｜《》` 标记），
/// 由调用方决定每章正文如何转成 `RubyText`。
public enum ChapterSplitter {
    public struct Chapter: Sendable, Equatable {
        public var title: String
        public var rawText: String

        public init(title: String, rawText: String) {
            self.title = title
            self.rawText = rawText
        }
    }

    public struct Options: Sendable {
        /// 低于此字数不当书处理——短文按原有单篇文章路径导入即可。
        public var minBookChars = 20_000
        /// 标题行长度上限。正文里出现的"第三章讲的是…"通常在长行中间，靠长度挡掉。
        public var maxHeadingLength = 40
        /// 找不到标题时的兜底分块大小。
        public var fallbackChunkChars = 6_000
        /// 单章超过此长度视为标题识别失败，整体退回兜底分块。
        public var maxChapterChars = 60_000
        /// 少于这么多标题就不认为分章成功。
        public var minHeadings = 2

        public init() {}
    }

    /// - Returns: 章节列表；文本太短返回空数组（调用方按普通文章导入）。
    public static func split(_ text: String, options: Options = Options()) -> [Chapter] {
        guard text.count >= options.minBookChars else { return [] }

        let lines = text.components(separatedBy: "\n")
        let headings = headingIndices(in: lines, options: options)

        if headings.count >= options.minHeadings {
            let chapters = assemble(lines: lines, headingIndices: headings)
            // 有章过长 = 标题多半认错了（比如只匹配到"序"和"后记"），整体退回分块。
            if !chapters.contains(where: { $0.rawText.count > options.maxChapterChars }) {
                return chapters
            }
        }
        return chunk(lines: lines, options: options)
    }

    // MARK: - 标题识别

    /// 标题模式：整行匹配，数字覆盖阿拉伯数字、全角数字与中日文数字。
    ///
    /// 关键在标记之后的**分隔符要求**：章号后面要么直接结束，要么隔一个空白/标点再跟短标题。
    /// 少了这一条，"第三章说的是关于猫的事"和"第一話的第0段正文"都会被当成标题——
    /// 只靠行长度限制挡不住短句子。
    private static let headingPatterns: [NSRegularExpression] = {
        let digits = "0-9０-９〇零一二三四五六七八九十百千两"
        let separators = "\\s：:、，,．。・\\-—–~～「『【（("
        /// 行尾：直接结束，或分隔符 + 至多 25 字的标题。
        let tail = "(?:\\s*$|[\(separators)]\\s*\\S{0,25}\\s*$)"
        let sources = [
            // 第一章 / 第1回 / 第十二話 / 第三卷
            "^\\s*第\\s*[\(digits)]+\\s*[章回節节卷巻篇話话幕折部]\(tail)",
            // Chapter 1 / CHAPTER IV / Ch. 3
            "^\\s*(?:chapter|ch\\.)\\s+(?:[0-9]+|[ivxlcdm]+)\(tail)",
            // 独立成行的序章/楔子/番外一类
            "^\\s*(?:序章|序|楔子|前言|引子|尾声|尾聲|后记|後記|番外|终章|終章"
                + "|プロローグ|エピローグ|序文|あとがき|まえがき|prologue|epilogue)\(tail)",
        ]
        return sources.map {
            try! NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
    }()

    static func isHeading(_ line: String, options: Options = Options()) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= options.maxHeadingLength else { return false }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        return headingPatterns.contains { $0.firstMatch(in: trimmed, range: range) != nil }
    }

    private static func headingIndices(in lines: [String], options: Options) -> [Int] {
        lines.indices.filter { isHeading(lines[$0], options: options) }
    }

    private static func assemble(lines: [String], headingIndices: [Int]) -> [Chapter] {
        var chapters: [Chapter] = []

        // 第一个标题之前的内容（书名、作者、说明）单独成章，不丢弃。
        if let first = headingIndices.first, first > 0 {
            let preface = lines[0..<first].joined(separator: "\n")
            if !preface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chapters.append(Chapter(title: title(from: preface), rawText: preface))
            }
        }

        for (position, start) in headingIndices.enumerated() {
            let end = position + 1 < headingIndices.count ? headingIndices[position + 1] : lines.count
            let body = lines[start..<end].joined(separator: "\n")
            let heading = lines[start].trimmingCharacters(in: .whitespacesAndNewlines)
            chapters.append(Chapter(title: heading, rawText: body))
        }
        return chapters
    }

    // MARK: - 兜底分块

    /// 没有标题的小说也必须能读：按目标大小在空行处断开。
    /// 标题取块首非空行——比"第 N 部分"这种合成标签更有信息，也不用管界面语言。
    private static func chunk(lines: [String], options: Options) -> [Chapter] {
        var chapters: [Chapter] = []
        var buffer: [String] = []
        var count = 0

        func flush() {
            let text = buffer.joined(separator: "\n")
            buffer.removeAll()
            count = 0
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            chapters.append(Chapter(title: title(from: text), rawText: text))
        }

        for line in lines {
            buffer.append(line)
            count += line.count + 1
            let atBoundary = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if count >= options.fallbackChunkChars && atBoundary { flush() }
            // 整块没有空行时也不能无限增长。
            if count >= options.fallbackChunkChars * 2 { flush() }
        }
        flush()
        return chapters
    }

    /// 从正文首个非空行取标题，过长则截断。
    static func title(from text: String, limit: Int = 30) -> String {
        let line = text
            .components(separatedBy: "\n")
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard line.count > limit else { return line }
        return String(line.prefix(limit)) + "…"
    }
}
