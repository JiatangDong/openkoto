import Foundation
import GRDB
import OKModels

/// 数据库入口。全部写操作经由单一 repository 入口协调；
/// 建库/迁移只由主 App 执行，Share Extension 不加载本模块（设计文档 §3.2 / §6.3）。
public struct AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    public static func onDisk(at url: URL) throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try AppDatabase(DatabasePool(path: url.path, configuration: config))
    }

    /// v1 schema（设计文档 §3.2 + SRS 规范 docs/specs/vocabulary-srs-spec.md）。
    /// - id 一律存小写 UUID 字符串；时间列由 GRDB 以 UTC datetime 文本存储。
    /// - 嵌套精讲按 JSON 列（`explanation_json`）存储，内含溯源元数据。
    /// - 不预埋 `dirty` / `deleted_at`（同步字段待二期 RFC 后迁移）。
    /// - 本次为 FSRS 统一改造对 v1 的原地改写：无 TestFlight 存量用户,不做迁移。
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // 不启用 eraseDatabaseOnSchemaChange：本地数据(文章/生词/复习/阅读会话)须跨版本持久，
        // 与发布版一致。schema 演进只追加新 migration(如 v2 加 reading_session)，GRDB 增量应用；
        // 若将来需破坏性变更，写显式迁移或手动重装，绝不静默清库。
        migrator.registerMigration("v0-placeholder") { _ in }
        migrator.registerMigration("v1") { db in
            try db.create(table: "article") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("content", .text).notNull()
                t.column("source_type", .text)
                t.column("source_url", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(table: "segment") { t in
                t.primaryKey("id", .text)
                t.column("article_id", .text).notNull().indexed()
                    .references("article", onDelete: .cascade)
                t.column("order_index", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("reading_text", .text)
                t.column("translation", .text)
                t.column("explanation_json", .text)
                t.column("is_new_paragraph", .boolean).notNull().defaults(to: false)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.uniqueKey(["article_id", "order_index"])
            }
            try db.create(table: "favorite_vocabulary") { t in
                t.primaryKey("id", .text)
                t.column("word", .text).notNull()
                t.column("normalized_word", .text).notNull()
                t.column("meaning", .text).notNull()
                t.column("usage", .text)
                t.column("explanation", .text)
                t.column("example", .text)
                t.column("reading", .text)
                // 文章删除时置空，标题快照保留（§3.2）
                t.column("source_article_id", .text).indexed()
                    .references("article", onDelete: .setNull)
                t.column("source_article_title", .text)
                t.column("srs_state", .text).notNull()
                // FSRS 记忆状态(规范 §1.1);0 = 未初始化(new 卡)
                t.column("stability", .double).notNull().defaults(to: 0)
                t.column("difficulty", .double).notNull().defaults(to: 0)
                t.column("scheduler_version", .text)
                // 非空 = 已掌握/暂停复习;队列排除(规范 §3)
                t.column("suspended_at", .datetime)
                // 本地日期 "YYYY-MM-DD"；空串 = 未排期
                t.column("due_date", .text).notNull().defaults(to: "")
                t.column("last_reviewed_at", .datetime)
                t.column("review_count", .integer).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                // 收藏去重规则（一期）：同一来源文章内按规范化词形唯一
                t.uniqueKey(["normalized_word", "source_article_id"])
            }
            try db.create(table: "word_pack") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("description", .text)
                t.column("cover_url", .text)
                t.column("author", .text)
                t.column("language_from", .text)
                t.column("language_to", .text)
                t.column("tags_json", .text).notNull().defaults(to: "[]")
                t.column("version", .text)
                t.column("is_system", .boolean).notNull().defaults(to: false)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            // 词包成员关系表(规范 §8:多端并发编辑友好,取代 pack_ids JSON)
            try db.create(table: "word_pack_membership") { t in
                t.column("vocabulary_id", .text).notNull()
                    .references("favorite_vocabulary", onDelete: .cascade)
                t.column("pack_id", .text).notNull()
                    .references("word_pack", onDelete: .cascade)
                t.column("created_at", .datetime).notNull()
                t.primaryKey(["vocabulary_id", "pack_id"])
            }
            // 复习事件日志(规范 §1.3):append-only、不可变。
            // vocabulary_id 不建外键——事件必须在卡片删除后存活(同步单元)。
            try db.create(table: "review_log") { t in
                t.primaryKey("id", .text)
                t.column("vocabulary_id", .text).notNull().indexed()
                t.column("reviewed_at", .datetime).notNull()
                t.column("date_local", .text).notNull().indexed()
                t.column("grade", .integer).notNull()
                t.column("elapsed_days", .integer).notNull()
                t.column("previous_state", .text).notNull()
                t.column("scheduler_version", .text).notNull()
                t.column("desired_retention", .double).notNull()
                t.column("result_stability", .double).notNull()
                t.column("result_difficulty", .double).notNull()
                t.column("result_interval_days", .integer).notNull()
                t.column("result_state", .text).notNull()
            }
        }
        // v2：阅读会话日志(append-only)——阅读时长/天数统计用。
        // article_id 不建外键：文章删除后会话仍计入总时长(与 review_log 同理)。
        migrator.registerMigration("v2") { db in
            try db.create(table: "reading_session") { t in
                t.primaryKey("id", .text)
                t.column("article_id", .text)
                t.column("date_local", .text).notNull().indexed()
                t.column("started_at", .datetime).notNull()
                t.column("seconds", .integer).notNull()
            }
        }
        return migrator
    }
}
