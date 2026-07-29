import Foundation

/// 「引用模式」外部媒体文件的书签存取。
///
/// iOS 上普通书签就够用；**Mac（Catalyst / 原生）在沙盒里必须用 app-scoped 书签**
/// （`.withSecurityScope`），并且需要 `com.apple.security.files.bookmarks.app-scope`
/// entitlement。不加的话解析会失败、`mediaFileURL(for:)` 返回 nil，
/// 用户看到的是"媒体不可用"——文件明明还在原处，也没有任何报错。
enum MediaBookmark {
    static func data(for url: URL) -> Data? {
        #if targetEnvironment(macCatalyst) || os(macOS)
        return try? url.bookmarkData(options: .withSecurityScope)
        #else
        return try? url.bookmarkData()
        #endif
    }

    static func resolve(_ data: Data, isStale: inout Bool) -> URL? {
        #if targetEnvironment(macCatalyst) || os(macOS)
        return try? URL(
            resolvingBookmarkData: data, options: .withSecurityScope,
            bookmarkDataIsStale: &isStale)
        #else
        return try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale)
        #endif
    }
}
