import Foundation
import Testing
@testable import OKFeatures

@Suite struct TextImportTests {
    @Test func extractsTitleFromHTML() {
        let html = "<html><head><TITLE>  夏目漱石 &amp; 夢十夜  </TITLE></head><body>x</body></html>"
        #expect(TextImport.extractTitle(html: html) == "夏目漱石 & 夢十夜")
    }

    @Test func extractTitleReturnsNilWhenMissing() {
        #expect(TextImport.extractTitle(html: "<html><body>no title</body></html>") == nil)
    }

    @Test func stripTagsRemovesScriptStyleAndTags() {
        let html = """
        <html><head><style>.x{color:red}</style></head>
        <body><script>alert(1)</script><h1>标题</h1><p>第一段。</p><p>第二段。</p></body></html>
        """
        let text = TextImport.stripTags(html)
        #expect(!text.contains("alert"))
        #expect(!text.contains("color:red"))
        #expect(text.contains("标题"))
        #expect(text.contains("第一段。"))
        #expect(text.contains("第二段。"))
        #expect(!text.contains("<"))
    }

    @Test func decodeTextHandlesUTF8() {
        let data = Data("こんにちは世界".utf8)
        #expect(TextImport.decodeText(data) == "こんにちは世界")
    }

    @Test func fetchArticleRejectsInvalidURL() async {
        await #expect(throws: TextImport.ImportError.invalidURL) {
            _ = try await TextImport.fetchArticle(from: "not a url")
        }
    }

    @Test func readableContentTypesIncludePlainText() {
        let types = TextImport.readableContentTypes
        #expect(types.contains(.plainText))
    }
}
