import Foundation
import OKBooks
import UniformTypeIdentifiers

/// 文本导入工具：本地文件读取 + 网页抓取正文提取（设计文档 §6.3）。
/// 纯函数 + 无 UI 依赖，便于单测；HTML→纯文本需在主线程（走 NSAttributedString/WebKit）。
enum TextImport {
    enum ImportError: Error, Equatable {
        case invalidURL
        case badStatus(Int)
        case emptyContent
    }

    /// 文件导入允许的类型：纯文本 + Markdown。
    static var readableContentTypes: [UTType] {
        var types: [UTType] = [.plainText, .text, .utf8PlainText]
        if let markdown = UTType(filenameExtension: "md") { types.append(markdown) }
        if let markdown = UTType("net.daringfireball.markdown") { types.append(markdown) }
        return types
    }

    /// 书籍容器类型。刻意**不并入** `readableContentTypes`——
    /// `readTextFile` 会把 EPUB（ZIP 二进制）按文本解码成乱码。
    static var bookContentTypes: [UTType] {
        var types: [UTType] = [.epub]
        if let epub = UTType(filenameExtension: "epub"), !types.contains(epub) {
            types.append(epub)
        }
        return types
    }

    /// 字幕文件类型。`.vtt` 系统自带 `org.w3.webvtt`；
    /// `.srt` **没有**系统 UTType（只会落到动态类型），必须在
    /// `OpenKoto-Info.plist` 的 `UTImportedTypeDeclarations` 里自己声明。
    static var subtitleContentTypes: [UTType] {
        var types: [UTType] = []
        if let vtt = UTType("org.w3.webvtt") { types.append(vtt) }
        for identifier in ["org.openkoto.subrip"] {
            if let declared = UTType(identifier) { types.append(declared) }
        }
        if let srt = UTType(filenameExtension: "srt"), !types.contains(srt) {
            types.append(srt)
        }
        // 兜底：未声明时 .srt 会被识别成纯文本
        types.append(.plainText)
        return types
    }

    /// 视频/音频类型。系统 UTType 齐全，不需要自己声明。
    static var mediaContentTypes: [UTType] {
        [.movie, .video, .audio, .mpeg4Movie, .quickTimeMovie, .mp3, .mpeg4Audio]
    }

    /// 读取本地文本文件（.txt/.md）。标题取无扩展名的文件名。
    static func readTextFile(at url: URL) throws -> (title: String, content: String) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return (url.deletingPathExtension().lastPathComponent, decodeText(data))
    }

    /// 编码嗅探解码（BOM → UTF-16 → 严格 UTF-8 → 候选打分，见 `EncodingDetector`）。
    ///
    /// 旧实现按 `[.utf8, .utf16, gb18030, .isoLatin1]` 取第一个不返回 nil 的结果，
    /// 而 `.utf16` 接受任意偶数长度字节序列——所有非 UTF-8 文本（含它声称支持的
    /// GB18030 中文）都会解成乱码。
    static func decodeText(_ data: Data) -> String {
        EncodingDetector.decode(data).text
    }

    struct FetchResult: Equatable {
        var title: String
        var content: String
    }

    /// 抓取网页并提取正文纯文本。
    @MainActor
    static func fetchArticle(from urlString: String) async throws -> FetchResult {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: normalized), url.host != nil else {
            throw ImportError.invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(
            "Mozilla/5.0 (compatible; OpenKoto/1.0; +https://github.com/hikariming/openkoto)",
            forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ImportError.badStatus(http.statusCode)
        }
        let html = decodeText(data)
        let title = extractTitle(html: html) ?? url.host ?? "Web Article"
        let content = htmlToPlainText(data) ?? stripTags(html)
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.emptyContent
        }
        return FetchResult(title: title, content: content)
    }

    /// 用 NSAttributedString 把 HTML 渲染成纯文本（保留段落换行）。仅主线程可用。
    @MainActor
    private static func htmlToPlainText(_ data: Data) -> String? {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let attributed = try? NSAttributedString(
            data: data, options: options, documentAttributes: nil)
        else { return nil }
        return attributed.string
    }

    /// 从原始 HTML 提取 <title>。
    static func extractTitle(html: String) -> String? {
        guard let match = html.range(
            of: "<title[^>]*>([\\s\\S]*?)</title>",
            options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let inner = html[match]
            .replacingOccurrences(
                of: "<[^>]+>", with: "", options: .regularExpression)
        let decoded = decodeEntities(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }

    /// 兜底：正则剥 script/style/标签 + 折叠空白（NSAttributedString 解析失败时用）。
    static func stripTags(_ html: String) -> String {
        var text = html
        for pattern in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>"] {
            text = text.replacingOccurrences(
                of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "\n", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(
            of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "\\n[ \\t]*\\n[\\s\\n]*", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
        ]
        for (entity, char) in entities {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        return result
    }
}
