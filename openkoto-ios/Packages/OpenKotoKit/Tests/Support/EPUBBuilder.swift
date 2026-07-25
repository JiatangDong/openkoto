import Foundation

/// 测试用 EPUB 合成器：把各种变体（EPUB3 nav / EPUB2 ncx / 固定版式 / DRM / 纯图）
/// 在测试期造出来，既可以产出 `.epub` 字节，也可以直接铺成解压目录。
public struct EPUBBuilder {
    public init() {}

    public struct Chapter {
        public var href: String
        public var title: String
        public var body: String
        /// 固定版式书的分页属性。
        public var prePaginated = false
    }

    public var title = "テスト書籍"
    public var author = "夏目漱石"
    public var language = "ja"
    public var opfPath = "OEBPS/content.opf"
    public var chapters: [Chapter] = []
    /// EPUB3 nav 文档；关掉则只生成 EPUB2 的 NCX。
    public var includeNav = true
    public var includeNCX = false
    public var renditionLayout: String?
    /// 写入 META-INF/encryption.xml：`.drm` 用真加密算法，`.fonts` 用字体混淆算法。
    public var encryption: Encryption = .none
    public var includeContainer = true
    public var emptySpine = false

    public enum Encryption {
        case none
        case fonts
        case drm
    }

    public mutating func addChapter(_ href: String, title: String, body: String, prePaginated: Bool = false)
    {
        chapters.append(
            Chapter(href: href, title: title, body: body, prePaginated: prePaginated))
    }

    /// 相对 OPF 目录的章节路径（OPF 在 OEBPS/ 时，chapter href 写相对值）。
    private var opfDirectory: String {
        guard let slash = opfPath.lastIndex(of: "/") else { return "" }
        return String(opfPath[opfPath.startIndex..<slash])
    }

    private func relativeToOPF(_ path: String) -> String {
        let directory = opfDirectory
        guard !directory.isEmpty, path.hasPrefix(directory + "/") else { return path }
        return String(path.dropFirst(directory.count + 1))
    }

    // MARK: - 文件集合

    public func files() -> [(path: String, contents: String)] {
        var files: [(String, String)] = [("mimetype", "application/epub+zip")]

        if includeContainer {
            files.append(
                ("META-INF/container.xml", """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                      <rootfiles>
                        <rootfile full-path="\(opfPath)" media-type="application/oebps-package+xml"/>
                      </rootfiles>
                    </container>
                    """))
        }

        switch encryption {
        case .none:
            break
        case .fonts:
            files.append(("META-INF/encryption.xml", encryptionXML(
                algorithm: "http://www.idpf.org/2008/embedding", uri: "OEBPS/fonts/Body.otf")))
        case .drm:
            files.append(("META-INF/encryption.xml", encryptionXML(
                algorithm: "http://www.w3.org/2001/04/xmlenc#aes128-cbc",
                uri: "OEBPS/ch1.xhtml")))
        }

        for chapter in chapters {
            files.append((chapter.href, """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE html>
                <html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(chapter.title)</title></head>
                <body>\(chapter.body)</body></html>
                """))
        }

        files.append((opfPath, opf()))
        if includeNav { files.append((navPath, navDocument())) }
        if includeNCX { files.append((ncxPath, ncxDocument())) }
        return files.map { (path: $0.0, contents: $0.1) }
    }

    private var navPath: String {
        opfDirectory.isEmpty ? "nav.xhtml" : "\(opfDirectory)/nav.xhtml"
    }

    private var ncxPath: String {
        opfDirectory.isEmpty ? "toc.ncx" : "\(opfDirectory)/toc.ncx"
    }

    private func encryptionXML(algorithm: String, uri: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <enc:EncryptedData xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
            <enc:EncryptionMethod Algorithm="\(algorithm)"/>
            <enc:CipherData><enc:CipherReference URI="\(uri)"/></enc:CipherData>
          </enc:EncryptedData>
        </encryption>
        """
    }

    private func opf() -> String {
        var manifest = ""
        var spine = ""
        for (index, chapter) in chapters.enumerated() {
            let id = "ch\(index)"
            manifest += """
                  <item id="\(id)" href="\(relativeToOPF(chapter.href))" media-type="application/xhtml+xml"/>

                """
            let properties = chapter.prePaginated
                ? " properties=\"rendition:layout-pre-paginated\"" : ""
            spine += "    <itemref idref=\"\(id)\"\(properties)/>\n"
        }
        if includeNav {
            manifest += """
                  <item id="nav" href="\(relativeToOPF(navPath))" media-type="application/xhtml+xml" properties="nav"/>

                """
        }
        if includeNCX {
            manifest += """
                  <item id="ncx" href="\(relativeToOPF(ncxPath))" media-type="application/x-dtbncx+xml"/>

                """
        }

        let layoutMeta = renditionLayout.map {
            "    <meta property=\"rendition:layout\">\($0)</meta>\n"
        } ?? ""
        let spineAttributes = includeNCX ? " toc=\"ncx\"" : ""

        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="bookid">urn:uuid:test</dc:identifier>
                <dc:title>\(title)</dc:title>
                <dc:creator>\(author)</dc:creator>
                <dc:language>\(language)</dc:language>
            \(layoutMeta)  </metadata>
              <manifest>
            \(manifest)  </manifest>
              <spine\(spineAttributes)>
            \(emptySpine ? "" : spine)  </spine>
            </package>
            """
    }

    private func navDocument() -> String {
        var items = ""
        for chapter in chapters {
            items += "      <li><a href=\"\(relativeToOPF(chapter.href))\">\(chapter.title)</a></li>\n"
        }
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <head><title>目次</title></head>
            <body>
              <nav epub:type="toc">
                <ol>
            \(items)    </ol>
              </nav>
            </body>
            </html>
            """
    }

    private func ncxDocument() -> String {
        var points = ""
        for (index, chapter) in chapters.enumerated() {
            points += """
                    <navPoint id="np\(index)" playOrder="\(index + 1)">
                      <navLabel><text>\(chapter.title)</text></navLabel>
                      <content src="\(relativeToOPF(chapter.href))"/>
                    </navPoint>

                """
        }
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
              <head><meta name="dtb:uid" content="urn:uuid:test"/></head>
              <docTitle><text>\(title)</text></docTitle>
              <navMap>
            \(points)  </navMap>
            </ncx>
            """
    }

    // MARK: - 产出

    /// 打包成 `.epub` 字节（mimetype 必须是第一条且不压缩）。
    public func epubData() -> Data {
        var writer = ZIPWriter()
        for file in files() {
            writer.addFile(file.path, file.contents, compressed: file.path != "mimetype")
        }
        return writer.build()
    }

    /// 直接铺成解压目录，省掉 ZIP 往返。返回目录 URL，调用方负责删除。
    @discardableResult
    public func writeDirectory() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("okbooks-epub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in files() {
            let url = root.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(file.contents.utf8).write(to: url)
        }
        return root
    }

    /// 常用样板：三章日语小说，带 ruby。
    public static func japaneseNovel() -> EPUBBuilder {
        var builder = EPUBBuilder()
        builder.addChapter(
            "OEBPS/ch1.xhtml", title: "第一章",
            body: "<h1>第一章</h1><p><ruby>吾輩<rt>わがはい</rt></ruby>は猫である。名前はまだ無い。</p>")
        builder.addChapter(
            "OEBPS/ch2.xhtml", title: "第二章",
            body: "<h1>第二章</h1><p>どこで生れたか頓と見当がつかぬ。</p>")
        builder.addChapter(
            "OEBPS/ch3.xhtml", title: "第三章",
            body: "<h1>第三章</h1><p>何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している。</p>")
        return builder
    }
}
