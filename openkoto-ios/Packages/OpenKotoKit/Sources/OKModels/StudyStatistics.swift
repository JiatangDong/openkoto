import Foundation

/// 学习统计聚合(复习 + 阅读；规范 §6 扩展)。
/// 由 `ContentRepository.buildStudyStatistics` 纯函数从卡片 / 复习事件 / 阅读会话推导，
/// 各时间序列均已零填充(缺失日补 0)，便于图表等距渲染。
public struct StudyStatistics: Sendable, Equatable {
    /// 每日复习活跃度(每条一天，旧→新)。new/review 拆分沿用 `ReviewStats` 的“新学优先去重”口径。
    public struct DailyActivity: Sendable, Equatable, Identifiable {
        public var dateLocal: String
        public var newCount: Int
        public var reviewCount: Int
        public var id: String { dateLocal }
        public var total: Int { newCount + reviewCount }
        public init(dateLocal: String, newCount: Int, reviewCount: Int) {
            self.dateLocal = dateLocal
            self.newCount = newCount
            self.reviewCount = reviewCount
        }
    }

    /// 评分分布(grade 1=Again..4=Easy)。始终 4 桶。
    public struct GradeCount: Sendable, Equatable, Identifiable {
        public var grade: Int
        public var count: Int
        public var id: Int { grade }
        public init(grade: Int, count: Int) {
            self.grade = grade
            self.count = count
        }
    }

    /// 复习预测(未来某天到期卡片数)。逾期并入首日。
    public struct ForecastDay: Sendable, Equatable, Identifiable {
        public var dateLocal: String
        public var dueCount: Int
        public var id: String { dateLocal }
        public init(dateLocal: String, dueCount: Int) {
            self.dateLocal = dateLocal
            self.dueCount = dueCount
        }
    }

    /// 每日阅读时长(秒)。
    public struct DailyReading: Sendable, Equatable, Identifiable {
        public var dateLocal: String
        public var seconds: Int
        public var id: String { dateLocal }
        public var minutes: Int { seconds / 60 }
        public init(dateLocal: String, seconds: Int) {
            self.dateLocal = dateLocal
            self.seconds = seconds
        }
    }

    /// 状态分布 / 连续打卡 / 今日计数(复用既有口径，内嵌以保自洽)。
    public var reviewStats: ReviewStats
    public var dailyActivity: [DailyActivity]
    public var gradeCounts: [GradeCount]
    public var forecast: [ForecastDay]
    public var readingByDay: [DailyReading]
    /// 全期复习事件数(词包过滤后)。
    public var totalReviews: Int
    /// 有过复习的去重天数。
    public var activeDays: Int
    public var readingSecondsToday: Int
    public var readingSecondsThisMonth: Int
    public var readingDaysThisMonth: Int
    public var readingSecondsTotal: Int
    /// 有过阅读的去重天数(全期)。
    public var readingDaysTotal: Int

    public init(
        reviewStats: ReviewStats = ReviewStats(),
        dailyActivity: [DailyActivity] = [],
        gradeCounts: [GradeCount] = [],
        forecast: [ForecastDay] = [],
        readingByDay: [DailyReading] = [],
        totalReviews: Int = 0,
        activeDays: Int = 0,
        readingSecondsToday: Int = 0,
        readingSecondsThisMonth: Int = 0,
        readingDaysThisMonth: Int = 0,
        readingSecondsTotal: Int = 0,
        readingDaysTotal: Int = 0
    ) {
        self.reviewStats = reviewStats
        self.dailyActivity = dailyActivity
        self.gradeCounts = gradeCounts
        self.forecast = forecast
        self.readingByDay = readingByDay
        self.totalReviews = totalReviews
        self.activeDays = activeDays
        self.readingSecondsToday = readingSecondsToday
        self.readingSecondsThisMonth = readingSecondsThisMonth
        self.readingDaysThisMonth = readingDaysThisMonth
        self.readingSecondsTotal = readingSecondsTotal
        self.readingDaysTotal = readingDaysTotal
    }
}
