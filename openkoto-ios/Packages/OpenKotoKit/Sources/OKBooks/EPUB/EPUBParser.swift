import Foundation

/// EPUB 包解析：`META-INF/container.xml` → OPF → manifest / spine / 元数据 / 目录。
///
/// 输入是**已解压的目录**（导入流程先解到 staging 再解析）：原版模式要靠 WKWebView
/// 直接加载章节文件，这些文件本来就得落盘，没必要为解析再在内存里存一份。
public enum EPUBParser {
    public enum Failure: Error, Equatable {
        case missingContainerXML
        case missingOPF(String)
        case malformedOPF(String)
        case emptySpine
        case drmProtected
    }

    public static func parse(bookDirectory: URL) throws -> EPUBPackage {
        if EncryptionInspector.inspect(bookDirectory: bookDirectory) == .drm {
            throw Failure.drmProtected
        }

        let opfPath = try locateOPFPath(in: bookDirectory)
        let opfURL = bookDirectory.appendingPathComponent(opfPath)
        guard let opfData = try? Data(contentsOf: opfURL) else {
            throw Failure.missingOPF(opfPath)
        }

        let parser = XMLParser(data: opfData)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        let delegate = OPFDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw Failure.malformedOPF(parser.parserError?.localizedDescription ?? "unknown")
        }

        let opfDirectory = PathResolver.directory(of: opfPath)
        var manifest: [String: EPUBPackage.ManifestItem] = [:]
        for raw in delegate.manifestItems {
            let href = PathResolver.resolve(raw.href, relativeTo: opfDirectory)
            manifest[raw.id] = EPUBPackage.ManifestItem(
                id: raw.id, href: href, mediaType: raw.mediaType, properties: raw.properties)
        }

        let spine = delegate.spineItems.map {
            EPUBPackage.SpineItem(idref: $0.idref, linear: $0.linear, properties: $0.properties)
        }
        guard !spine.isEmpty else { throw Failure.emptySpine }

        let toc = loadTOC(
            bookDirectory: bookDirectory, manifest: manifest,
            spineTocID: delegate.spineTocID)

        return EPUBPackage(
            opfPath: opfPath,
            title: delegate.title?.trimmed,
            author: delegate.author?.trimmed,
            language: delegate.language?.trimmed,
            renditionLayout: delegate.renditionLayout,
            manifest: manifest,
            spine: spine,
            toc: toc,
            coverHref: resolveCover(manifest: manifest, metaCoverID: delegate.metaCoverID))
    }

    // MARK: - container.xml

    static func locateOPFPath(in bookDirectory: URL) throws -> String {
        let containerURL = bookDirectory.appendingPathComponent("META-INF/container.xml")
        guard let data = try? Data(contentsOf: containerURL) else {
            throw Failure.missingContainerXML
        }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        let delegate = ContainerDelegate()
        parser.delegate = delegate
        guard parser.parse(), let path = delegate.rootfilePath, !path.isEmpty else {
            throw Failure.missingContainerXML
        }
        return PathResolver.resolve(path, relativeTo: "")
    }

    private final class ContainerDelegate: NSObject, XMLParserDelegate {
        private(set) var rootfilePath: String?

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]
        ) {
            guard elementName.localXMLName == "rootfile", rootfilePath == nil else { return }
            // 多个 rootfile 时取第一个（规范允许多渲染版本，第一个是默认）。
            rootfilePath = attributes["full-path"]
        }
    }

    // MARK: - OPF

    private final class OPFDelegate: NSObject, XMLParserDelegate {
        struct RawManifestItem {
            var id: String
            var href: String
            var mediaType: String
            var properties: Set<String>
        }
        struct RawSpineItem {
            var idref: String
            var linear: Bool
            var properties: Set<String>
        }

        private(set) var title: String?
        private(set) var author: String?
        private(set) var language: String?
        private(set) var renditionLayout: String?
        private(set) var manifestItems: [RawManifestItem] = []
        private(set) var spineItems: [RawSpineItem] = []
        private(set) var spineTocID: String?
        private(set) var metaCoverID: String?

        private var textBuffer = ""
        private var capturing: String?
        /// EPUB3 的 `<meta property="rendition:layout">pre-paginated</meta>`：值在元素内容里。
        private var capturingMetaProperty: String?

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]
        ) {
            let name = elementName.localXMLName
            textBuffer = ""
            switch name {
            case "title" where title == nil, "creator" where author == nil, "language":
                capturing = name
            case "item":
                guard let id = attributes["id"], let href = attributes["href"] else { return }
                manifestItems.append(
                    RawManifestItem(
                        id: id, href: href,
                        mediaType: attributes["media-type"] ?? "",
                        properties: Self.tokens(attributes["properties"])))
            case "itemref":
                guard let idref = attributes["idref"] else { return }
                spineItems.append(
                    RawSpineItem(
                        idref: idref,
                        linear: (attributes["linear"] ?? "yes").lowercased() != "no",
                        properties: Self.tokens(attributes["properties"])))
            case "spine":
                spineTocID = attributes["toc"]
            case "meta":
                // EPUB2 风格：<meta name="cover" content="cover-image"/>
                if let metaName = attributes["name"]?.lowercased() {
                    if metaName == "cover" { metaCoverID = attributes["content"] }
                    if metaName == "rendition:layout" { renditionLayout = attributes["content"] }
                }
                // EPUB3 风格：属性名在 property，值在元素内容或 content 属性。
                if let property = attributes["property"]?.lowercased(),
                    property == "rendition:layout"
                {
                    if let content = attributes["content"] {
                        renditionLayout = content
                    } else {
                        capturingMetaProperty = property
                    }
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard capturing != nil || capturingMetaProperty != nil else { return }
            textBuffer += string
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            let value = textBuffer.trimmed
            defer {
                textBuffer = ""
                capturing = nil
                capturingMetaProperty = nil
            }
            guard !value.isEmpty else { return }
            switch capturing {
            case "title": title = value
            case "creator": author = value
            case "language": language = value
            default:
                if capturingMetaProperty == "rendition:layout" { renditionLayout = value }
            }
        }

        private static func tokens(_ raw: String?) -> Set<String> {
            guard let raw else { return [] }
            return Set(raw.split(whereSeparator: \.isWhitespace).map { $0.lowercased() })
        }
    }

    private static func resolveCover(
        manifest: [String: EPUBPackage.ManifestItem], metaCoverID: String?
    ) -> String? {
        if let item = manifest.values.first(where: { $0.properties.contains("cover-image") }) {
            return item.href
        }
        if let id = metaCoverID, let item = manifest[id] { return item.href }
        return manifest.values
            .first { $0.id.lowercased().contains("cover") && $0.mediaType.hasPrefix("image/") }?
            .href
    }

    // MARK: - 目录

    /// EPUB3 的 nav 文档优先；没有再退回 EPUB2 的 NCX。
    static func loadTOC(
        bookDirectory: URL, manifest: [String: EPUBPackage.ManifestItem], spineTocID: String?
    ) -> [EPUBPackage.NavPoint] {
        if let nav = manifest.values.first(where: { $0.properties.contains("nav") }),
            let data = try? Data(contentsOf: bookDirectory.appendingPathComponent(nav.href))
        {
            let points = parseNavDocument(data, baseDirectory: PathResolver.directory(of: nav.href))
            if !points.isEmpty { return points }
        }

        let ncx = spineTocID.flatMap { manifest[$0] }
            ?? manifest.values.first { $0.mediaType == "application/x-dtbncx+xml" }
        if let ncx, let data = try? Data(contentsOf: bookDirectory.appendingPathComponent(ncx.href))
        {
            return parseNCX(data, baseDirectory: PathResolver.directory(of: ncx.href))
        }
        return []
    }

    static func parseNavDocument(_ data: Data, baseDirectory: String) -> [EPUBPackage.NavPoint] {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        let delegate = NavDelegate(baseDirectory: baseDirectory)
        parser.delegate = delegate
        guard parser.parse() else { return [] }
        return delegate.points
    }

    private final class NavDelegate: NSObject, XMLParserDelegate {
        private(set) var points: [EPUBPackage.NavPoint] = []
        private let baseDirectory: String
        private var navDepth = 0
        private var insideTOC = false
        private var listDepth = 0
        private var anchorHref: String?
        private var textBuffer = ""

        init(baseDirectory: String) {
            self.baseDirectory = baseDirectory
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]
        ) {
            switch elementName.localXMLName {
            case "nav":
                navDepth += 1
                // epub:type="toc" 是正文目录；landmarks / page-list 不要。
                let type = (attributes["epub:type"] ?? attributes["type"] ?? "").lowercased()
                if type.contains("toc") || (type.isEmpty && points.isEmpty) { insideTOC = true }
            case "ol", "ul":
                if insideTOC { listDepth += 1 }
            case "a":
                guard insideTOC else { return }
                anchorHref = attributes["href"]
                textBuffer = ""
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard insideTOC, anchorHref != nil else { return }
            textBuffer += string
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            switch elementName.localXMLName {
            case "nav":
                navDepth -= 1
                if navDepth == 0 { insideTOC = false }
            case "ol", "ul":
                if insideTOC { listDepth = max(0, listDepth - 1) }
            case "a":
                guard insideTOC, let href = anchorHref else { return }
                let title = textBuffer.trimmed
                anchorHref = nil
                textBuffer = ""
                guard !title.isEmpty, !href.isEmpty else { return }
                points.append(
                    EPUBPackage.NavPoint(
                        title: title,
                        href: PathResolver.resolve(href, relativeTo: baseDirectory),
                        depth: max(0, listDepth - 1)))
            default:
                break
            }
        }
    }

    static func parseNCX(_ data: Data, baseDirectory: String) -> [EPUBPackage.NavPoint] {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        let delegate = NCXDelegate(baseDirectory: baseDirectory)
        parser.delegate = delegate
        guard parser.parse() else { return [] }
        return delegate.points
    }

    private final class NCXDelegate: NSObject, XMLParserDelegate {
        private(set) var points: [EPUBPackage.NavPoint] = []
        private let baseDirectory: String
        private var navPointDepth = 0
        private var insideNavMap = false
        private var insideLabel = false
        private var textBuffer = ""
        /// navPoint 的 label 与 content 顺序固定（先 label 后 content），按层暂存标题。
        private var pendingTitles: [Int: String] = [:]

        init(baseDirectory: String) {
            self.baseDirectory = baseDirectory
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]
        ) {
            switch elementName.localXMLName {
            case "navMap":
                insideNavMap = true
            case "navPoint":
                guard insideNavMap else { return }
                navPointDepth += 1
            case "navLabel":
                insideLabel = insideNavMap
                textBuffer = ""
            case "text":
                textBuffer = ""
            case "content":
                guard insideNavMap, navPointDepth > 0,
                    let src = attributes["src"], !src.isEmpty
                else { return }
                let title = pendingTitles[navPointDepth]?.trimmed ?? ""
                guard !title.isEmpty else { return }
                points.append(
                    EPUBPackage.NavPoint(
                        title: title,
                        href: PathResolver.resolve(src, relativeTo: baseDirectory),
                        depth: navPointDepth - 1))
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard insideLabel else { return }
            textBuffer += string
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            switch elementName.localXMLName {
            case "navMap":
                insideNavMap = false
            case "navPoint":
                pendingTitles[navPointDepth] = nil
                navPointDepth = max(0, navPointDepth - 1)
            case "navLabel":
                if insideLabel { pendingTitles[navPointDepth] = textBuffer.trimmed }
                insideLabel = false
                textBuffer = ""
            default:
                break
            }
        }
    }
}

/// EPUB 内部的相对路径解析（href 相对 OPF/NCX 所在目录，可能含 `..`、百分号转义）。
enum PathResolver {
    static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<slash])
    }

    static func resolve(_ href: String, relativeTo directory: String) -> String {
        var raw = href.split(separator: "#", maxSplits: 1).first.map(String.init) ?? href
        let fragment = href.contains("#") ? String(href[href.firstIndex(of: "#")!...]) : ""
        raw = raw.removingPercentEncoding ?? raw
        if raw.hasPrefix("/") { raw.removeFirst() }

        var components: [String] = raw.hasPrefix("/") || directory.isEmpty
            ? [] : directory.split(separator: "/").map(String.init)
        for component in raw.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(String(component))
            }
        }
        return components.joined(separator: "/") + fragment
    }
}

extension String {
    /// 去掉命名空间前缀的元素/属性名（解析时关闭了命名空间处理）。
    var localXMLName: String {
        split(separator: ":").last.map(String.init) ?? self
    }

    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
