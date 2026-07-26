import CryptoKit
import Foundation

/// 原文哈希——精讲复用的键。
///
/// 归一化只做 **trim + NFKC**：
/// - trim：`"こんにちは。"` 与 `"こんにちは。 "` 应算同一句
/// - NFKC：全角/半角、兼容字形归一
/// - **刻意不 lowercase**：句级大小写有语义（"Turkey" 与 "turkey"、德语 "Sie" 与 "sie"），
///   撞哈希会复用到意思完全不同的精讲。生词去重用的 `normalizedWord` 带 lowercase，
///   那是词形归一，与这里不是一回事。
///
/// 存量行是旧算法（raw text，无 trim 无 NFKC）算的，表现为"不命中 → 照常调 API"，
/// 退化到改之前的行为、零损失；回填要重写几千行 JSON，风险不对称，所以不回填。
///
/// 放在这里而不是 `AppConfigStore`：后者整体在 `#if os(iOS)` 里，
/// 而复用逻辑要在 macOS 上跑单测。
enum SourceTextHash {
    static func of(_ text: String) -> String {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCompatibilityMapping
        return SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
