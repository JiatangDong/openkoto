import Foundation

/// EPUB 包文档（OPF）解析结果。
/// 所有 href 都已解析成**相对书籍根目录**的路径，调用方直接拼目录即可读文件。
public struct EPUBPackage: Sendable, Equatable {
    public struct ManifestItem: Sendable, Equatable {
        public let id: String
        public let href: String
        public let mediaType: String
        public let properties: Set<String>
    }

    public struct SpineItem: Sendable, Equatable {
        public let idref: String
        /// `linear="no"` 的条目是补充内容（版权页、注释），不计入正文阅读顺序。
        public let linear: Bool
        public let properties: Set<String>
    }

    public struct NavPoint: Sendable, Equatable {
        public let title: String
        /// 相对书籍根目录，可能带 `#fragment`。
        public let href: String
        public let depth: Int

        /// 去掉锚点的文件路径，用于和 manifest/spine 对应。
        public var path: String {
            href.split(separator: "#", maxSplits: 1).first.map(String.init) ?? href
        }
    }

    public let opfPath: String
    public let title: String?
    public let author: String?
    public let language: String?
    /// EPUB3 `rendition:layout`：`pre-paginated` = 固定版式（漫画/图文书）。
    public let renditionLayout: String?
    public let manifest: [String: ManifestItem]
    public let spine: [SpineItem]
    public let toc: [NavPoint]
    public let coverHref: String?

    /// 正文阅读顺序：spine 里 `linear != "no"` 且能在 manifest 里找到的 XHTML 条目。
    public var readingOrder: [ManifestItem] {
        spine.compactMap { item in
            guard item.linear, let manifestItem = manifest[item.idref] else { return nil }
            let type = manifestItem.mediaType.lowercased()
            guard type.contains("xhtml") || type.contains("html") || type.isEmpty else {
                return nil
            }
            return manifestItem
        }
    }

    /// 固定版式判定：整书声明，或绝大多数 spine 条目单独声明。
    /// 这类书抽不出可用正文，导入后只给原版模式。
    public var isFixedLayout: Bool {
        if renditionLayout?.lowercased() == "pre-paginated" { return true }
        let linear = spine.filter(\.linear)
        guard linear.count >= 3 else { return false }
        let prePaginated = linear.filter {
            $0.properties.contains("rendition:layout-pre-paginated")
        }
        return Double(prePaginated.count) / Double(linear.count) >= 0.8
    }

    /// 目录标题按文件路径归拢，供分章时给章节命名。
    public func tocTitle(forPath path: String) -> String? {
        toc.first { $0.path == path }?.title
    }
}
