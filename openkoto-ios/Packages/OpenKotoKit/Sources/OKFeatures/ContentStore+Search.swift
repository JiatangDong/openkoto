import Foundation
import OKModels
import OKPersistence

// 全库搜索。
//
// 生词本一直有搜索，书库没有——而书库才是会长到上万句的那个。
// 一本 50 万字的小说读到一半想找"我记得在哪见过这个词"，此前完全没有办法。

extension ContentStore {
    public typealias SearchHit = ContentRepository.SearchHit

    /// 搜索。空查询返回空，不做任何请求。
    public func search(_ query: String) async -> [SearchHit] {
        do {
            return try await repository.search(query)
        } catch {
            Self.logger.error("search failed: \(error)")
            return []
        }
    }

    /// 还有多少篇没进索引。> 0 时 UI 显示"正在建立索引"，
    /// 免得用户以为搜索坏了——升级后第一次打开确实会有一小段时间搜不全。
    public func refreshIndexingProgress() async {
        pendingIndexCount = (try? await repository.pendingIndexCount()) ?? 0
    }

    /// 命中的文章里，第一个包含查询词的句子的**句序**。
    ///
    /// 直接在句子里找查询词，而不是把 snippet 的偏移映射回去——后者要处理省略号、
    /// 高亮标记、trigram 的匹配边界，而用户的预期本来就是"跳到第一次出现的地方"。
    ///
    /// 会触发懒切分（书籍章节首开时才有 segment），所以是 async 的。
    public func locateSegmentOrder(articleID: UUID, matching query: String) async -> Int? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        await openArticle(articleID)
        return segments(for: articleID).first { $0.text.contains(needle) }?.order
    }

    /// 这条命中属于哪本书/哪个视频——搜索结果要显示来源，点进去也要落到正确的阅读器。
    public func container(forArticle articleID: UUID) -> SearchContainer {
        if let media = media(forArticle: articleID) { return .media(media) }
        for book in books {
            if let summaries = chapterSummariesByBook[book.id],
                let chapter = summaries.first(where: { $0.articleId == articleID })
            {
                return .book(book, chapterIndex: chapter.index)
            }
        }
        if let article = articles.first(where: { $0.id == articleID })
            ?? chapterArticle(id: articleID)
        {
            return .article(article)
        }
        return .unknown
    }

    /// 跨 tab 的跳转请求：生词本点「回到原句」时放下，书库 tab 取走。
    ///
    /// 用共享状态而不是 NotificationCenter：`RootTabView` 要靠它切 tab，
    /// `LibraryView` 要靠它推导航，两处都在观察同一个 `ContentStore`，
    /// 而通知会在书库 tab 尚未构建时丢掉。
    public struct PendingJump: Equatable, Sendable {
        public var articleID: UUID
        public var segmentID: UUID?
    }

    public enum SearchContainer: Sendable {
        case article(Article)
        case book(Book, chapterIndex: Int)
        case media(Media)
        case unknown
    }
}
