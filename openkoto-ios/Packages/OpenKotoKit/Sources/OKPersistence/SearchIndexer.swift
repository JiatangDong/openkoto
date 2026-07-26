import Foundation
import GRDB

/// 全文索引的后台回填。
///
/// migration 只把待办 rowid 记进 `fts_backfill`（几毫秒），真正的索引构建放在这里。
/// 这样老用户升级时首启不会卡——一本 50 万字的书建索引是秒级的事，不该发生在
/// `AppDatabase.init` 的同步路径上（`ContentStore.live()` 在主线程构造它）。
///
/// 两条刻意的设计：
/// - **小事务分批**：`DatabasePool` 只有一个写者，长事务会把用户的收藏、精讲写入全卡住。
/// - **可中断可续跑**：进度就是 `fts_backfill` 表本身。中途杀掉 App，下次启动接着做，
///   不需要额外的进度记录。排空后**只是空表，不删表**——触发器引用它，
///   删掉会让之后每一次文章写入都失败。
public actor SearchIndexer {
    /// 每个事务处理多少篇。太大占写锁太久，太小事务开销占比过高。
    private static let batchSize = 200

    private let database: AppDatabase
    private var task: Task<Void, Never>?

    public init(database: AppDatabase) {
        self.database = database
    }

    /// 启动回填（幂等：已在跑就不重复启动）。
    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run()
            await self?.clearTask()
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }

    private func clearTask() { task = nil }

    private func run() async {
        while !Task.isCancelled {
            do {
                if try await processBatch() == 0 { return }
            } catch {
                // 索引失败不该影响 App 的其它部分：搜索退化成暂时不可用，下次启动重试
                return
            }
            // 让出一下，别把写锁占满
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// 处理一批。返回实际处理的篇数，0 表示已排空。
    private func processBatch() async throws -> Int {
        try await database.writer.write { db in
            let rowIDs = try Int64.fetchAll(
                db, sql: "SELECT rowid FROM fts_backfill LIMIT ?",
                arguments: [Self.batchSize])
            guard !rowIDs.isEmpty else { return 0 }

            for rowID in rowIDs {
                // 文章可能在排队期间被删了，join 不到就只清待办
                if let row = try Row.fetchOne(
                    db, sql: "SELECT title, content FROM article WHERE rowid = ?",
                    arguments: [rowID])
                {
                    try db.execute(
                        sql: """
                            INSERT INTO article_fts(rowid, title, content) VALUES (?, ?, ?)
                            """,
                        arguments: [rowID, row["title"] as String? ?? "", row["content"] as String? ?? ""])
                }
                try db.execute(sql: "DELETE FROM fts_backfill WHERE rowid = ?", arguments: [rowID])
            }
            return rowIDs.count
        }
    }

}
