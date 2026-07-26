import Foundation
import Testing

/// 文案键的覆盖检查。
///
/// 漏加一个 key 不会崩、不会有编译错误——屏幕上直接显示 `"media.blind.on"` 这样的
/// 原始键名，而且只在切到那个语言、走到那个界面时才看得见。这类 bug 靠人工点是抓不住的，
/// 但用一次全量扫描就能钉死。
@Suite struct LocalizationCoverageTests {
    /// 三种界面语言都必须有值——少一种就是那个语言的用户看到英文（或键名）。
    private static let languages = ["en", "zh-Hans", "ja"]

    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OKFeaturesTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // OpenKotoKit
    }

    private static var catalog: [String: [String: String]] {
        let url = packageRoot
            .appending(path: "Sources/OKLocalization/Resources/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let strings = json["strings"] as? [String: Any]
        else { return [:] }

        var result: [String: [String: String]] = [:]
        for (key, value) in strings {
            let localizations =
                (value as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
            var byLanguage: [String: String] = [:]
            for (language, entry) in localizations {
                if let unit = (entry as? [String: Any])?["stringUnit"] as? [String: Any],
                    let text = unit["value"] as? String
                {
                    byLanguage[language] = text
                }
            }
            result[key] = byLanguage
        }
        return result
    }

    /// 扫源码里所有 `L("…")`。
    ///
    /// 带插值的（`L("reader.batch.failed\(count)")`）只取 `\(` 之前的前缀，
    /// 对应目录里的 `reader.batch.failed%lld` —— 参数的格式说明符不在这里判定。
    private static func referencedKeys() throws -> Set<String> {
        let sources = packageRoot.appending(path: "Sources")
        let pattern = try NSRegularExpression(pattern: #"\bL\("([^"]+)"\)"#)
        var keys: Set<String> = []

        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            // 跳过注释行：文档注释里写 `L("library.title")` 当例子是常事，
            // 那不是真的引用。
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let code = String(line)
                guard !code.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                let range = NSRange(code.startIndex..., in: code)
                for match in pattern.matches(in: code, range: range) {
                    guard let captured = Range(match.range(at: 1), in: code) else { continue }
                    keys.insert(String(code[captured]))
                }
            }
        }
        return keys
    }

    /// 目录里能满足这个引用吗？完全相同，或是带参数版本的前缀。
    private static func isSatisfied(_ reference: String, by catalog: [String: [String: String]])
        -> Bool
    {
        if catalog[reference] != nil { return true }
        guard let interpolation = reference.range(of: "\\(") else { return false }
        let prefix = String(reference[reference.startIndex..<interpolation.lowerBound])
        guard !prefix.isEmpty else { return false }
        return catalog.keys.contains { $0.hasPrefix(prefix) && $0.contains("%") }
    }

    @Test func everyReferencedKeyExists() throws {
        let catalog = Self.catalog
        #expect(!catalog.isEmpty, "读不到字符串目录，这个测试就什么也没检查")

        let missing = try Self.referencedKeys()
            .filter { !Self.isSatisfied($0, by: catalog) }
            .sorted()
        #expect(missing.isEmpty, "源码引用了目录里没有的 key：\(missing)")
    }

    @Test func everyKeyIsTranslatedInAllThreeLanguages() {
        let catalog = Self.catalog
        #expect(!catalog.isEmpty)

        let incomplete = catalog
            .filter { _, byLanguage in
                Self.languages.contains { (byLanguage[$0] ?? "").isEmpty }
            }
            .keys.sorted()
        #expect(incomplete.isEmpty, "这些 key 缺少某种语言的译文：\(incomplete)")
    }
}
