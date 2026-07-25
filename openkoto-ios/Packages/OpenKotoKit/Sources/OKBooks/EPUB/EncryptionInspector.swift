import Foundation

/// `META-INF/encryption.xml` 判定：区分**字体混淆**与**真 DRM**。
///
/// 两者都写在同一个文件里，但意义完全不同：
/// - 字体混淆（IDPF / Adobe 两种算法）只打乱嵌入字体的前若干字节，正文是明文，能正常读；
/// - 真 DRM（Adobe ADEPT、Apple FairPlay 等）会加密正文，我们解不开也不该去解。
///
/// 桌面端对这两种情况一视同仁地"导入成功"，正文变成占位符字符串——
/// 这里改成对真 DRM 明确报错。
public enum EncryptionInspector {
    public enum Verdict: Sendable, Equatable {
        /// 没有 encryption.xml，或它是空的。
        case clean
        /// 只有字体混淆；正文可读，混淆的资源路径一并带出。
        case fontObfuscation(paths: Set<String>)
        /// 正文被加密，无法阅读。
        case drm
    }

    /// 只做字体混淆的两种算法。
    static let obfuscationAlgorithms: Set<String> = [
        "http://www.idpf.org/2008/embedding",
        "http://ns.adobe.com/pdf/enc#RC4SHA1",
    ]

    public static func inspect(bookDirectory: URL) -> Verdict {
        let url = bookDirectory.appendingPathComponent("META-INF/encryption.xml")
        guard let data = try? Data(contentsOf: url) else { return .clean }
        return inspect(encryptionXML: data)
    }

    static func inspect(encryptionXML data: Data) -> Verdict {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        let delegate = EncryptionDelegate()
        parser.delegate = delegate
        // 解析失败按最保守处理：有 encryption.xml 又读不懂，不能假设正文可读。
        guard parser.parse() else { return .drm }

        guard !delegate.entries.isEmpty else { return .clean }
        let algorithms = Set(delegate.entries.map(\.algorithm))
        guard algorithms.subtracting(obfuscationAlgorithms).isEmpty else { return .drm }
        return .fontObfuscation(paths: Set(delegate.entries.map(\.uri)))
    }

    private final class EncryptionDelegate: NSObject, XMLParserDelegate {
        struct Entry {
            var algorithm: String
            var uri: String
        }

        private(set) var entries: [Entry] = []
        private var currentAlgorithm: String?

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]
        ) {
            switch elementName.split(separator: ":").last.map(String.init) {
            case "EncryptedData":
                currentAlgorithm = nil
            case "EncryptionMethod":
                currentAlgorithm = attributes["Algorithm"]
            case "CipherReference":
                let uri = attributes["URI"] ?? ""
                entries.append(Entry(algorithm: currentAlgorithm ?? "", uri: uri))
            default:
                break
            }
        }
    }
}
