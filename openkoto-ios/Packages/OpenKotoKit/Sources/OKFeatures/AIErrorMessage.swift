#if os(iOS)
import Foundation
import OKAIClient
import OKLocalization

/// 把 transport 级 `AIClientError` 映射为面向用户的本地化文案。
/// 不暴露 requestID / 正文 / 原始响应（设计文档 §4.4 脱敏要求）。
func userMessage(for error: AIClientError) -> String {
    switch error {
    case .notConfigured: return L("ai.error.notConfigured")
    case .networkUnreachable: return L("ai.error.network")
    case .timeout: return L("ai.error.timeout")
    case .unauthorized: return L("ai.error.unauthorized")
    case .rateLimited: return L("ai.error.rateLimited")
    case .insufficientBalance: return L("ai.error.insufficientBalance")
    case .serverError: return L("ai.error.server")
    case .malformedResponse: return L("ai.error.malformed")
    case .contentBlocked: return L("ai.error.contentBlocked")
    case .cancelled: return L("ai.error.cancelled")
    }
}
#endif
