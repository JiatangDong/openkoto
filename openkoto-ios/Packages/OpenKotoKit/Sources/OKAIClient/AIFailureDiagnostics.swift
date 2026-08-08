import Foundation

/// 一次失败 AI 请求的现场快照。
///
/// `AIClientError` 只有分类（"网络不可用"），用户照着提示做却修不好时，
/// 排查真正需要的是这份快照：HTTP 状态码、响应体摘录、URLError 原始码、
/// 端点、耗时、带没带 Key。UI 的「复制诊断信息」把它拼成报告发给开发者。
///
/// 脱敏红线：**绝不包含 API Key 本体**。`apiKeyAttached` 只记录这次请求
/// 带没带 Key——没带 Key 的裸请求必然 401，这本身就是关键线索
/// （Keychain 读出失败 vs 配置错误的分水岭）。
public struct AIFailureDiagnostics: Sendable, Equatable {
    /// 请求发出的时刻（也是耗时的起点）。
    public var timestamp: Date
    /// 从发起到失败的秒数。和请求的 timeout 对一下就知道是不是真超时。
    public var duration: TimeInterval
    /// 调用用途（explain / translate / wordGloss / connectionTest）。
    public var purpose: String
    public var requestID: UUID
    public var providerID: String
    public var providerName: String
    public var model: String
    /// 实际请求的完整 URL。三种协议形态的 Key 都只走请求头，URL 里不含秘密。
    public var endpoint: String
    /// 这次请求有没有附 API Key。`false` + 401 = Key 没读出来，不是 Key 错了。
    public var apiKeyAttached: Bool
    /// `AIClientError` 的分类名（如 `networkUnreachable`、`serverError(status: 503)`）。
    public var errorKind: String
    public var httpStatus: Int?
    /// 失败响应体摘录（截断；Key 已剔除）。余额耗尽/限流/模型不存在的区别全写在里面。
    public var responseBodyExcerpt: String?
    /// URLError 原始码与名字（如 -1005 networkConnectionLost）。
    /// "网络不可用"的文案盖住了一整族错误，区分只能靠这个码。
    public var urlErrorCode: Int?
    public var urlErrorName: String?
    public var urlErrorMessage: String?

    public init(
        timestamp: Date,
        duration: TimeInterval,
        purpose: String,
        requestID: UUID,
        providerID: String,
        providerName: String,
        model: String,
        endpoint: String,
        apiKeyAttached: Bool,
        errorKind: String,
        httpStatus: Int? = nil,
        responseBodyExcerpt: String? = nil,
        urlErrorCode: Int? = nil,
        urlErrorName: String? = nil,
        urlErrorMessage: String? = nil
    ) {
        self.timestamp = timestamp
        self.duration = duration
        self.purpose = purpose
        self.requestID = requestID
        self.providerID = providerID
        self.providerName = providerName
        self.model = model
        self.endpoint = endpoint
        self.apiKeyAttached = apiKeyAttached
        self.errorKind = errorKind
        self.httpStatus = httpStatus
        self.responseBodyExcerpt = responseBodyExcerpt
        self.urlErrorCode = urlErrorCode
        self.urlErrorName = urlErrorName
        self.urlErrorMessage = urlErrorMessage
    }
}

/// 把 `AIClientError` + 现场快照一起沿调用链抛上去的包装错误。
///
/// 为什么不直接给 `AIClientError` 加关联值：它在 UI / 批量任务 / 测试里
/// 有大量 switch 与相等比较，包装类型让分类保持纯净，各 catch 点只做一次解包。
public struct AIRequestFailure: Error, Sendable, Equatable {
    public let error: AIClientError
    public let diagnostics: AIFailureDiagnostics

    public init(error: AIClientError, diagnostics: AIFailureDiagnostics) {
        self.error = error
        self.diagnostics = diagnostics
    }
}
