import Foundation

/// 阅读会话(append-only)：前台停留在阅读器的一段连续时长为一条会话。
/// 用于阅读时长/天数统计。文章删除后会话仍保留(不建外键)，`articleId` 可空。
public struct ReadingSession: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    /// 来源文章(可空：文章删除或未知时为 nil，但会话仍计入总时长/天数)
    public var articleId: UUID?
    /// 会话开始时的本地日期 "YYYY-MM-DD"(与复习日志同口径，供每日/每月聚合)
    public var dateLocal: String
    /// 会话开始的 UTC 时刻
    public var startedAt: Date
    /// 时长(秒)
    public var seconds: Int

    public init(
        id: UUID = UUID(),
        articleId: UUID?,
        dateLocal: String,
        startedAt: Date,
        seconds: Int
    ) {
        self.id = id
        self.articleId = articleId
        self.dateLocal = dateLocal
        self.startedAt = startedAt
        self.seconds = seconds
    }
}
