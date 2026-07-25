import Foundation
import OKTestSupport
import Testing

@testable import OKBooks

@Suite struct EPUBParserTests {
    /// 用完即删的解压目录。
    private func withBook<T>(
        _ builder: EPUBBuilder, _ body: (URL) throws -> T
    ) throws -> T {
        let root = try builder.writeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        return try body(root)
    }

    // MARK: - 包文档

    @Test func parsesMetadataManifestAndSpine() throws {
        try withBook(.japaneseNovel()) { root in
            let package = try EPUBParser.parse(bookDirectory: root)
            #expect(package.title == "テスト書籍")
            #expect(package.author == "夏目漱石")
            #expect(package.language == "ja")
            #expect(package.opfPath == "OEBPS/content.opf")
            #expect(package.spine.count == 3)
            // href 已解析成相对书籍根目录，可直接拼目录读取。
            #expect(package.readingOrder.map(\.href) == [
                "OEBPS/ch1.xhtml", "OEBPS/ch2.xhtml", "OEBPS/ch3.xhtml",
            ])
        }
    }

    @Test func parsesEPUB3NavigationDocument() throws {
        try withBook(.japaneseNovel()) { root in
            let package = try EPUBParser.parse(bookDirectory: root)
            #expect(package.toc.map(\.title) == ["第一章", "第二章", "第三章"])
            #expect(package.toc.first?.href == "OEBPS/ch1.xhtml")
            #expect(package.tocTitle(forPath: "OEBPS/ch2.xhtml") == "第二章")
        }
    }

    /// EPUB2：没有 nav 文档，目录来自 NCX。
    @Test func fallsBackToNCXWhenNavMissing() throws {
        var builder = EPUBBuilder.japaneseNovel()
        builder.includeNav = false
        builder.includeNCX = true
        try withBook(builder) { root in
            let package = try EPUBParser.parse(bookDirectory: root)
            #expect(package.toc.map(\.title) == ["第一章", "第二章", "第三章"])
            #expect(package.toc.map(\.href) == [
                "OEBPS/ch1.xhtml", "OEBPS/ch2.xhtml", "OEBPS/ch3.xhtml",
            ])
        }
    }

    /// OPF 不在根目录时，manifest 里的相对 href 必须按 OPF 所在目录解析。
    @Test func resolvesHrefsRelativeToOPFDirectory() throws {
        var builder = EPUBBuilder()
        builder.opfPath = "content/book.opf"
        builder.addChapter("content/text/ch1.xhtml", title: "一", body: "<p>正文</p>")
        try withBook(builder) { root in
            let package = try EPUBParser.parse(bookDirectory: root)
            #expect(package.readingOrder.map(\.href) == ["content/text/ch1.xhtml"])
            #expect(package.toc.first?.href == "content/text/ch1.xhtml")
        }
    }

    @Test func resolvesParentDirectoryHrefs() {
        #expect(PathResolver.resolve("../images/a.jpg", relativeTo: "OEBPS/text")
            == "OEBPS/images/a.jpg")
        #expect(PathResolver.resolve("ch1.xhtml", relativeTo: "OEBPS") == "OEBPS/ch1.xhtml")
        #expect(PathResolver.resolve("ch1.xhtml", relativeTo: "") == "ch1.xhtml")
        #expect(PathResolver.resolve("./a/./b.xhtml", relativeTo: "x") == "x/a/b.xhtml")
        // 百分号转义要还原，否则拼出来的路径读不到文件。
        #expect(PathResolver.resolve("text/%E7%AC%AC1%E7%AB%A0.xhtml", relativeTo: "OEBPS")
            == "OEBPS/text/第1章.xhtml")
        // 锚点保留，供目录跳转定位。
        #expect(PathResolver.resolve("ch1.xhtml#s2", relativeTo: "OEBPS")
            == "OEBPS/ch1.xhtml#s2")
    }

    @Test func navPointPathDropsFragment() {
        let point = EPUBPackage.NavPoint(title: "一", href: "OEBPS/ch1.xhtml#s2", depth: 0)
        #expect(point.path == "OEBPS/ch1.xhtml")
    }

    /// `linear="no"` 的补充内容不进正文阅读顺序。
    @Test func excludesNonLinearSpineItems() throws {
        try withBook(.japaneseNovel()) { root in
            let package = try EPUBParser.parse(bookDirectory: root)
            let modified = EPUBPackage(
                opfPath: package.opfPath, title: package.title, author: package.author,
                language: package.language, renditionLayout: package.renditionLayout,
                manifest: package.manifest,
                spine: [
                    package.spine[0],
                    EPUBPackage.SpineItem(idref: "ch1", linear: false, properties: []),
                ],
                toc: package.toc, coverHref: package.coverHref)
            #expect(modified.readingOrder.map(\.href) == ["OEBPS/ch1.xhtml"])
        }
    }

    // MARK: - 固定版式

    @Test func detectsPrePaginatedFromPackageMetadata() throws {
        var builder = EPUBBuilder.japaneseNovel()
        builder.renditionLayout = "pre-paginated"
        try withBook(builder) { root in
            let package = try EPUBParser.parse(bookDirectory: root)
            #expect(package.renditionLayout == "pre-paginated")
            #expect(package.isFixedLayout)
        }
    }

    /// 整书没声明，但绝大多数 spine 条目自己声明——漫画常见。
    @Test func detectsPrePaginatedFromSpineMajority() throws {
        var builder = EPUBBuilder()
        for index in 1...5 {
            builder.addChapter(
                "OEBPS/p\(index).xhtml", title: "P\(index)",
                body: "<div><img src=\"p\(index).jpg\"/></div>", prePaginated: true)
        }
        try withBook(builder) { root in
            let package = try EPUBParser.parse(bookDirectory: root)
            #expect(package.isFixedLayout)
        }
    }

    @Test func regularNovelIsNotFixedLayout() throws {
        try withBook(.japaneseNovel()) { root in
            let package = try EPUBParser.parse(bookDirectory: root)
            #expect(package.isFixedLayout == false)
        }
    }

    // MARK: - 加密

    /// 真 DRM：明确报错，绝不"导入成功"后正文变占位符（桌面端的行为）。
    @Test func rejectsDRMProtectedBook() throws {
        var builder = EPUBBuilder.japaneseNovel()
        builder.encryption = .drm
        try withBook(builder) { root in
            #expect(throws: EPUBParser.Failure.drmProtected) {
                try EPUBParser.parse(bookDirectory: root)
            }
        }
    }

    /// 只混淆嵌入字体的书正文是明文，必须放行。
    @Test func allowsFontObfuscatedBook() throws {
        var builder = EPUBBuilder.japaneseNovel()
        builder.encryption = .fonts
        try withBook(builder) { root in
            let package = try EPUBParser.parse(bookDirectory: root)
            #expect(package.readingOrder.count == 3)
            #expect(
                EncryptionInspector.inspect(bookDirectory: root)
                    == .fontObfuscation(paths: ["OEBPS/fonts/Body.otf"]))
        }
    }

    @Test func treatsUnparsableEncryptionXMLAsDRM() {
        #expect(EncryptionInspector.inspect(encryptionXML: Data("<not xml".utf8)) == .drm)
        #expect(EncryptionInspector.inspect(encryptionXML: Data("<encryption/>".utf8)) == .clean)
    }

    // MARK: - 错误

    @Test func failsWithoutContainerXML() throws {
        var builder = EPUBBuilder.japaneseNovel()
        builder.includeContainer = false
        try withBook(builder) { root in
            #expect(throws: EPUBParser.Failure.missingContainerXML) {
                try EPUBParser.parse(bookDirectory: root)
            }
        }
    }

    @Test func failsOnEmptySpine() throws {
        var builder = EPUBBuilder.japaneseNovel()
        builder.emptySpine = true
        try withBook(builder) { root in
            #expect(throws: EPUBParser.Failure.emptySpine) {
                try EPUBParser.parse(bookDirectory: root)
            }
        }
    }

    @Test func failsWhenOPFMissing() throws {
        var builder = EPUBBuilder.japaneseNovel()
        builder.opfPath = "OEBPS/content.opf"
        let root = try builder.writeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("OEBPS/content.opf"))
        #expect(throws: EPUBParser.Failure.missingOPF("OEBPS/content.opf")) {
            try EPUBParser.parse(bookDirectory: root)
        }
    }

    // MARK: - 与 ZIP 联动

    /// 端到端：合成 .epub 字节 → ZIPArchive 解压 → 解析 → 抽章节正文。
    @Test func parsesBookExtractedFromZIPArchive() throws {
        let archive = try ZIPArchive(data: EPUBBuilder.japaneseNovel().epubData())
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("okbooks-e2e-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try archive.extractAll(to: root)

        let package = try EPUBParser.parse(bookDirectory: root)
        #expect(package.title == "テスト書籍")
        #expect(package.readingOrder.count == 3)

        let chapter = package.readingOrder[0]
        let data = try Data(contentsOf: root.appendingPathComponent(chapter.href))
        let ruby = XHTMLTextExtractor.extract(xhtml: EncodingDetector.decode(data).text)
        #expect(ruby.plainText == "第一章\n吾輩は猫である。名前はまだ無い。")
        #expect(ruby.runs.contains(RubyText.Run(text: "吾輩", reading: "わがはい")))
    }
}
