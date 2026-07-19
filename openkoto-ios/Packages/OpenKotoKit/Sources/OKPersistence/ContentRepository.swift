import Foundation
import GRDB
import OKModels

/// 内容仓库：文章 / 逐句 / 生词收藏的单一读写入口（设计文档 §3.2）。
/// 每个写方法都是一个事务；调用方（ContentStore）负责串行化提交顺序。
public struct ContentRepository: Sendable {
    public struct LibrarySnapshot: Sendable {
        public var articles: [Article]
        public var segmentsByArticle: [UUID: [ArticleSegment]]
        public var favorites: [FavoriteVocabulary]
        public var packs: [WordPack]

        public init(
            articles: [Article] = [],
            segmentsByArticle: [UUID: [ArticleSegment]] = [:],
            favorites: [FavoriteVocabulary] = [],
            packs: [WordPack] = []
        ) {
            self.articles = articles
            self.segmentsByArticle = segmentsByArticle
            self.favorites = favorites
            self.packs = packs
        }
    }

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - 读

    /// 一期数据量（本地个人库）一次性全量加载；分页/搜索按需再加。
    public func loadAll() async throws -> LibrarySnapshot {
        try await database.writer.read { db in
            let articles = try ArticleRecord
                .order(Column("created_at").desc, Column("id"))
                .fetchAll(db)
                .map { try $0.domainModel() }
            var segmentsByArticle: [UUID: [ArticleSegment]] = [:]
            for record in try SegmentRecord.order(Column("order_index")).fetchAll(db) {
                let segment = try record.domainModel()
                segmentsByArticle[segment.articleId, default: []].append(segment)
            }
            let favorites = try Self.fetchFavorites(db)
            let packs = try WordPackRecord
                .order(Column("created_at"))
                .fetchAll(db)
                .map { try $0.domainModel() }
            return LibrarySnapshot(
                articles: articles,
                segmentsByArticle: segmentsByArticle,
                favorites: favorites,
                packs: packs
            )
        }
    }

    /// 读取全部生词(含词包成员),按 created_at 降序。
    static func fetchFavorites(_ db: Database) throws -> [FavoriteVocabulary] {
        var packIdsByVocabulary: [String: [UUID]] = [:]
        for membership in try WordPackMembershipRecord.fetchAll(db) {
            let packId = try parseUUID(membership.packId, table: "word_pack_membership")
            packIdsByVocabulary[membership.vocabularyId, default: []].append(packId)
        }
        return try FavoriteVocabularyRecord
            .order(Column("created_at").desc)
            .fetchAll(db)
            .map { try $0.domainModel(packIds: packIdsByVocabulary[$0.id] ?? []) }
    }

    // MARK: - 文章

    /// 导入：文章 + 全部切分句在同一事务写入（任一失败整体回滚）。
    public func insertArticle(
        _ article: Article, segments: [ArticleSegment], now: Date = .now
    ) async throws {
        try await database.writer.write { db in
            try ArticleRecord(article, now: now).insert(db)
            for segment in segments {
                try SegmentRecord(segment, meta: nil, now: now).insert(db)
            }
        }
    }

    /// 删除文章；segment 级联删除、收藏 source_article_id 置空由 FK 完成。
    public func deleteArticle(id: UUID) async throws {
        _ = try await database.writer.write { db in
            try ArticleRecord.deleteOne(db, key: uuidString(id))
        }
    }

    // MARK: - 精讲回填

    /// 只在该句尚未精讲时写入（不覆盖已有结果，对齐内存层写回校验）。
    /// - Returns: 是否实际写入（句子已删除或已精讲时为 false）。
    @discardableResult
    public func saveExplanation(
        segmentID: UUID,
        explanation: SegmentExplanation,
        meta: ExplanationMeta?,
        now: Date = .now
    ) async throws -> Bool {
        let envelope = ExplanationEnvelope(explanation: explanation, meta: meta)
        let json = String(decoding: try WireJSON.encoder.encode(envelope), as: UTF8.self)
        return try await database.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE segment
                    SET explanation_json = :json,
                        translation = :translation,
                        reading_text = COALESCE(:reading, reading_text),
                        updated_at = :now
                    WHERE id = :id AND explanation_json IS NULL
                    """,
                arguments: [
                    "json": json,
                    "translation": explanation.translation,
                    "reading": explanation.readingText,
                    "now": now,
                    "id": uuidString(segmentID),
                ])
            return db.changesCount > 0
        }
    }

    /// 只写译文（快翻/全文翻译），不写 explanation_json；已精讲的句子不覆盖。
    /// - Returns: 是否实际写入。
    @discardableResult
    public func saveTranslation(
        segmentID: UUID, translation: String, now: Date = .now
    ) async throws -> Bool {
        try await database.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE segment
                    SET translation = :translation, updated_at = :now
                    WHERE id = :id AND explanation_json IS NULL
                    """,
                arguments: ["translation": translation, "now": now, "id": uuidString(segmentID)])
            return db.changesCount > 0
        }
    }

    // MARK: - 生词收藏

    /// 违反去重约束（normalized_word + source_article_id）时抛错，由调用方先查重。
    /// 卡片与词包成员在同一事务写入。
    public func insertFavorite(_ favorite: FavoriteVocabulary, now: Date = .now) async throws {
        let record = FavoriteVocabularyRecord(favorite, now: now)
        let memberships = favorite.packIds.map {
            WordPackMembershipRecord(
                vocabularyId: record.id, packId: uuidString($0), createdAt: now)
        }
        try await database.writer.write { db in
            try record.insert(db)
            for membership in memberships {
                try membership.insert(db)
            }
        }
    }

    /// 更新卡片(编辑词形/释义等;词形变化时 normalized_word 由 Record 重新计算)。
    /// 词包成员不在此处变更——用 `setPackIds`。
    public func updateFavorite(_ favorite: FavoriteVocabulary, now: Date = .now) async throws {
        let record = FavoriteVocabularyRecord(favorite, now: now)
        try await database.writer.write { db in
            try record.update(db)
        }
    }

    /// 标记已掌握/恢复复习(规范 §3):只写 suspended_at,FSRS 状态不动。
    public func setSuspended(id: UUID, suspended: Bool, now: Date = .now) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE favorite_vocabulary
                    SET suspended_at = :suspended, updated_at = :now
                    WHERE id = :id
                    """,
                arguments: [
                    "suspended": suspended ? now : nil,
                    "now": now,
                    "id": uuidString(id),
                ])
        }
    }

    /// 词包成员整体替换(diff 写 membership 表)。
    public func setPackIds(vocabularyId: UUID, packIds: [UUID], now: Date = .now) async throws {
        let vocabId = uuidString(vocabularyId)
        let target = Set(packIds.map(uuidString))
        try await database.writer.write { db in
            let existing = Set(
                try WordPackMembershipRecord
                    .filter(Column("vocabulary_id") == vocabId)
                    .fetchAll(db)
                    .map(\.packId))
            for removed in existing.subtracting(target) {
                try db.execute(
                    sql: "DELETE FROM word_pack_membership WHERE vocabulary_id = ? AND pack_id = ?",
                    arguments: [vocabId, removed])
            }
            for added in target.subtracting(existing) {
                try WordPackMembershipRecord(
                    vocabularyId: vocabId, packId: added, createdAt: now
                ).insert(db)
            }
        }
    }

    public func deleteFavorite(id: UUID) async throws {
        _ = try await database.writer.write { db in
            try FavoriteVocabularyRecord.deleteOne(db, key: uuidString(id))
        }
    }

    // MARK: - 复习(FSRS 更新由调用方经 OKSRS 计算;仓库只负责事务落盘)

    /// 复习落盘:同一事务内更新卡片 + 追加一条不可变复习事件(规范 §1.3)。
    public func applyReview(
        _ favorite: FavoriteVocabulary, event: ReviewEvent, now: Date = .now
    ) async throws {
        let record = FavoriteVocabularyRecord(favorite, now: now)
        let logRecord = ReviewLogRecord(event)
        try await database.writer.write { db in
            try record.update(db)
            try logRecord.insert(db)
        }
    }

    // MARK: - 阅读会话(统计用；append-only)

    public func recordReadingSession(_ session: ReadingSession) async throws {
        let record = ReadingSessionRecord(session)
        try await database.writer.write { db in
            try record.insert(db)
        }
    }

    #if DEBUG
    /// 截图/QA 用(-seedStatsDemo)：一次性写入合成生词 + 复习日志 + 阅读会话。仅 DEBUG。
    public func seedDemo(
        favorites: [FavoriteVocabulary],
        events: [ReviewEvent],
        sessions: [ReadingSession],
        now: Date = .now
    ) async throws {
        try await database.writer.write { db in
            for favorite in favorites {
                try FavoriteVocabularyRecord(favorite, now: now).insert(db)
            }
            for event in events {
                try ReviewLogRecord(event).insert(db)
            }
            for session in sessions {
                try ReadingSessionRecord(session).insert(db)
            }
        }
    }
    #endif

    /// 今日到期队列(规范 §3,镜像桌面 build_due_vocabulary_queue):
    /// 排除 suspended → 词包过滤 → due_date <= 今日(坏日期视为到期)
    /// → new/learning 优先于 review → 各按 (due_date, last_reviewed_at) 升序 → 每日上限截断。
    public func dueQueue(
        packId: UUID?, dateLocal: String, newLimit: Int, reviewLimit: Int
    ) async throws -> [FavoriteVocabulary] {
        let favorites = try await database.writer.read { db in
            try Self.fetchFavorites(db)
        }
        var candidates = favorites.filter { $0.suspendedAt == nil }
        if let packId {
            candidates = candidates.filter { $0.packIds.contains(packId) }
        }
        candidates = candidates.filter { Self.isDueOnOrBefore($0.dueDate, target: dateLocal) }

        var newLearning = candidates.filter { $0.srsState == .new || $0.srsState == .learning }
        var review = candidates.filter { $0.srsState == .review }
        newLearning.sort(by: Self.dueThenLastReview)
        review.sort(by: Self.dueThenLastReview)

        return Array(newLearning.prefix(max(newLimit, 0)))
            + Array(review.prefix(max(reviewLimit, 0)))
    }

    /// 与桌面 is_due_on_or_before 一致:无法解析的 due_date 视为到期。
    static func isDueOnOrBefore(_ dueDate: String, target: String) -> Bool {
        guard isValidLocalDate(dueDate) else { return true }
        return dueDate <= target
    }

    static func isValidLocalDate(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        var components = DateComponents()
        let parts = value.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return false }
        components.year = year
        components.month = month
        components.day = day
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return components.isValidDate(in: calendar)
    }

    /// 与桌面 sort_by_due_then_last_review 一致(nil 的 last_reviewed_at 排前)。
    static func dueThenLastReview(_ a: FavoriteVocabulary, _ b: FavoriteVocabulary) -> Bool {
        if a.dueDate != b.dueDate { return a.dueDate < b.dueDate }
        switch (a.lastReviewedAt, b.lastReviewedAt) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case let (lhs?, rhs?): return lhs < rhs
        }
    }

    // MARK: - 统计(规范 §6)

    public func reviewStats(packId: UUID?, dateLocal: String) async throws -> ReviewStats {
        let (favorites, events) = try await database.writer.read { db in
            (
                try Self.fetchFavorites(db),
                try ReviewLogRecord.fetchAll(db).map { try $0.domainModel() }
            )
        }
        return Self.buildReviewStats(
            favorites: favorites, events: events, packId: packId, dateLocal: dateLocal)
    }

    /// 纯函数,与桌面 build_review_stats 同一口径(规范 §6)。
    static func buildReviewStats(
        favorites: [FavoriteVocabulary],
        events: [ReviewEvent],
        packId: UUID?,
        dateLocal: String
    ) -> ReviewStats {
        let inPack: (FavoriteVocabulary) -> Bool = { favorite in
            packId.map { favorite.packIds.contains($0) } ?? true
        }
        let cardIds = Set(favorites.filter(inPack).map(\.id))

        // 今日新学/复习:按卡去重,新学优先
        var newCards: Set<UUID> = []
        var reviewCards: Set<UUID> = []
        for event in events where event.dateLocal == dateLocal {
            guard cardIds.contains(event.vocabularyId) else { continue }
            if event.previousState == .new {
                newCards.insert(event.vocabularyId)
            } else {
                reviewCards.insert(event.vocabularyId)
            }
        }
        let reviewToday = reviewCards.subtracting(newCards).count

        // 连续打卡:全局(不过滤词包),从今日(或昨日)向前连续有事件的天数
        let eventDays = Set(events.map(\.dateLocal))
        var streak = 0
        if let today = parseLocalDate(dateLocal) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            var cursor = eventDays.contains(dateLocal)
                ? today
                : calendar.date(byAdding: .day, value: -1, to: today)!
            while eventDays.contains(formatLocalDate(cursor, calendar: calendar)) {
                streak += 1
                cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
            }
        }

        var stats = ReviewStats(
            newToday: newCards.count, reviewToday: reviewToday, streakDays: streak)
        for favorite in favorites where inPack(favorite) {
            stats.total += 1
            if favorite.suspendedAt != nil {
                stats.countSuspended += 1
            } else {
                switch favorite.srsState {
                case .learning: stats.countLearning += 1
                case .review: stats.countReview += 1
                case .new: stats.countNew += 1
                }
            }
        }
        return stats
    }

    // MARK: - 统计分析(图表序列)

    public func statistics(
        packId: UUID?, dateLocal: String, rangeDays: Int, forecastDays: Int
    ) async throws -> StudyStatistics {
        let (favorites, events, sessions) = try await database.writer.read { db in
            (
                try Self.fetchFavorites(db),
                try ReviewLogRecord.fetchAll(db).map { try $0.domainModel() },
                try ReadingSessionRecord.fetchAll(db).map { try $0.domainModel() }
            )
        }
        return Self.buildStudyStatistics(
            favorites: favorites, events: events, readingSessions: sessions,
            packId: packId, dateLocal: dateLocal,
            rangeDays: rangeDays, forecastDays: forecastDays)
    }

    /// 纯函数：从卡片 / 复习事件 / 阅读会话推导全部图表序列。
    /// 口径与 `buildReviewStats` 一致(UTC 公历)；时间序列均零填充(缺失日补 0)。
    static func buildStudyStatistics(
        favorites: [FavoriteVocabulary],
        events: [ReviewEvent],
        readingSessions: [ReadingSession],
        packId: UUID?,
        dateLocal: String,
        rangeDays: Int,
        forecastDays: Int
    ) -> StudyStatistics {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        // 状态分布 / 连续打卡 / 今日计数复用既有口径。
        let reviewStats = buildReviewStats(
            favorites: favorites, events: events, packId: packId, dateLocal: dateLocal)

        let inPack: (FavoriteVocabulary) -> Bool = { favorite in
            packId.map { favorite.packIds.contains($0) } ?? true
        }
        let cardIds = Set(favorites.filter(inPack).map(\.id))
        let scopedEvents = events.filter { cardIds.contains($0.vocabularyId) }

        // 每日复习活跃度：按天聚合，new 优先去重(同 buildReviewStats 今日口径)。
        var newByDay: [String: Set<UUID>] = [:]
        var reviewByDay: [String: Set<UUID>] = [:]
        for event in scopedEvents {
            if event.previousState == .new {
                newByDay[event.dateLocal, default: []].insert(event.vocabularyId)
            } else {
                reviewByDay[event.dateLocal, default: []].insert(event.vocabularyId)
            }
        }
        var dailyActivity: [StudyStatistics.DailyActivity] = []
        if let today = parseLocalDate(dateLocal), rangeDays > 0 {
            for offset in stride(from: rangeDays - 1, through: 0, by: -1) {
                guard let day = calendar.date(byAdding: .day, value: -offset, to: today)
                else { continue }
                let key = formatLocalDate(day, calendar: calendar)
                let newCards = newByDay[key] ?? []
                let reviewCards = (reviewByDay[key] ?? []).subtracting(newCards)
                dailyActivity.append(.init(
                    dateLocal: key, newCount: newCards.count, reviewCount: reviewCards.count))
            }
        }

        // 评分分布(全期，固定 4 桶)。
        var gradeMap: [Int: Int] = [1: 0, 2: 0, 3: 0, 4: 0]
        for event in scopedEvents where (1...4).contains(event.grade) {
            gradeMap[event.grade, default: 0] += 1
        }
        let gradeCounts = (1...4).map {
            StudyStatistics.GradeCount(grade: $0, count: gradeMap[$0] ?? 0)
        }

        // 复习预测：未 suspend 且 due_date 合法的卡；逾期(<=今日)并入首日；未排期排除。
        var forecast: [StudyStatistics.ForecastDay] = []
        let dueCandidates = favorites.filter {
            inPack($0) && $0.suspendedAt == nil && isValidLocalDate($0.dueDate)
        }
        if let today = parseLocalDate(dateLocal), forecastDays > 0 {
            for offset in 0..<forecastDays {
                guard let day = calendar.date(byAdding: .day, value: offset, to: today)
                else { continue }
                let key = formatLocalDate(day, calendar: calendar)
                let count = offset == 0
                    ? dueCandidates.filter { $0.dueDate <= dateLocal }.count
                    : dueCandidates.filter { $0.dueDate == key }.count
                forecast.append(.init(dateLocal: key, dueCount: count))
            }
        }

        // 阅读聚合。
        let monthPrefix = String(dateLocal.prefix(7))
        var readingByDate: [String: Int] = [:]
        var readingSecondsTotal = 0
        var readingSecondsToday = 0
        var readingSecondsThisMonth = 0
        var readingMonthDays: Set<String> = []
        for session in readingSessions {
            readingByDate[session.dateLocal, default: 0] += session.seconds
            readingSecondsTotal += session.seconds
            if session.dateLocal == dateLocal { readingSecondsToday += session.seconds }
            if session.dateLocal.hasPrefix(monthPrefix) {
                readingSecondsThisMonth += session.seconds
                readingMonthDays.insert(session.dateLocal)
            }
        }
        var readingByDay: [StudyStatistics.DailyReading] = []
        if let today = parseLocalDate(dateLocal), rangeDays > 0 {
            for offset in stride(from: rangeDays - 1, through: 0, by: -1) {
                guard let day = calendar.date(byAdding: .day, value: -offset, to: today)
                else { continue }
                let key = formatLocalDate(day, calendar: calendar)
                readingByDay.append(.init(dateLocal: key, seconds: readingByDate[key] ?? 0))
            }
        }

        return StudyStatistics(
            reviewStats: reviewStats,
            dailyActivity: dailyActivity,
            gradeCounts: gradeCounts,
            forecast: forecast,
            readingByDay: readingByDay,
            totalReviews: scopedEvents.count,
            activeDays: Set(scopedEvents.map(\.dateLocal)).count,
            readingSecondsToday: readingSecondsToday,
            readingSecondsThisMonth: readingSecondsThisMonth,
            readingDaysThisMonth: readingMonthDays.count,
            readingSecondsTotal: readingSecondsTotal,
            readingDaysTotal: Set(readingSessions.map(\.dateLocal)).count
        )
    }

    static func parseLocalDate(_ value: String) -> Date? {
        guard isValidLocalDate(value) else { return nil }
        let parts = value.split(separator: "-")
        var components = DateComponents()
        components.year = Int(parts[0])
        components.month = Int(parts[1])
        components.day = Int(parts[2])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)
    }

    static func formatLocalDate(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    // MARK: - 词包

    /// 新建词包。
    public func insertPack(_ pack: WordPack, now: Date = .now) async throws {
        let record = try WordPackRecord(pack, now: now)
        try await database.writer.write { db in
            try record.insert(db)
        }
    }

    /// 更新词包(重命名/改描述等;成员不在此处变更)。
    public func updatePack(_ pack: WordPack, now: Date = .now) async throws {
        let record = try WordPackRecord(pack, now: now)
        try await database.writer.write { db in
            try record.update(db)
        }
    }

    /// 删除词包(系统包不可删,镜像桌面 delete_word_pack_cmd):
    /// membership 由 FK 级联清除;删除后不属于任何词包的卡片归入"未分组"。
    public func deletePack(id: UUID, now: Date = .now) async throws {
        guard id != WordPack.systemUngroupedID else {
            throw DatabaseError(message: "system pack cannot be deleted")
        }
        let packId = uuidString(id)
        let defaultId = uuidString(WordPack.systemUngroupedID)
        try await database.writer.write { db in
            let memberIds = try WordPackMembershipRecord
                .filter(Column("pack_id") == packId)
                .fetchAll(db)
                .map(\.vocabularyId)
            _ = try WordPackRecord.deleteOne(db, key: packId)
            for vocabularyId in memberIds {
                let remaining = try WordPackMembershipRecord
                    .filter(Column("vocabulary_id") == vocabularyId)
                    .fetchCount(db)
                if remaining == 0 {
                    try WordPackMembershipRecord(
                        vocabularyId: vocabularyId, packId: defaultId, createdAt: now
                    ).insert(db)
                }
            }
        }
    }

    /// 确保系统默认词包("未分组")存在;不可删除(规范 §1.2)。
    @discardableResult
    public func ensureDefaultPack(now: Date = .now) async throws -> WordPack {
        let defaultPack = WordPack(
            id: WordPack.systemUngroupedID,
            name: "未分组",
            packDescription: "系统默认合集",
            author: "OpenKoto",
            tags: ["system"],
            version: "1.0.0",
            isSystem: true,
            createdAt: now,
            updatedAt: now
        )
        let record = try WordPackRecord(defaultPack, now: now)
        return try await database.writer.write { db in
            if let existing = try WordPackRecord.fetchOne(
                db, key: uuidString(WordPack.systemUngroupedID))
            {
                return try existing.domainModel()
            }
            try record.insert(db)
            return defaultPack
        }
    }

    // MARK: - 首启种子

    /// 仅在 article 表为空时写入内置示例内容（同一事务）。
    /// - Returns: 是否实际种子写入。
    @discardableResult
    public func seedIfEmpty(
        articles: [Article],
        segmentsByArticle: [UUID: [ArticleSegment]],
        now: Date = .now
    ) async throws -> Bool {
        try await database.writer.write { db in
            guard try ArticleRecord.fetchCount(db) == 0 else { return false }
            for article in articles {
                try ArticleRecord(article, now: now).insert(db)
                for segment in segmentsByArticle[article.id] ?? [] {
                    try SegmentRecord(segment, meta: nil, now: now).insert(db)
                }
            }
            return true
        }
    }
}
