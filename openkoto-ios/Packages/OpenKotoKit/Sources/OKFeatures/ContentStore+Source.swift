import Foundation
import OKModels

// 生词卡的出处。
//
// 卡片只存了 articleID / segmentID，没存句子本身——句子会被重新切分（重导入同一本书，
// UUID 全换），冗余一份文本就成了永远不会更新的过期快照。要显示原句就查一次库：
// 一行 SELECT 的代价远小于维护一份会失真的副本。
//
// 带回整句（含译文与精讲）而不只是文本：出处弹窗的意义就是**不进阅读器也能把这句看懂**，
// 而这些字段本来就在同一行里。

extension ContentStore {
    /// 一张生词卡的出处：显示用的来源名 + 那一句 + 跳回去要用的坐标。
    public struct FavoriteSource: Equatable, Sendable {
        /// 「挪威的森林 · 第三章」/ 视频名 / 文章标题。
        public var label: String
        /// 收藏时所在的那一句，连同它的译文与精讲。存量卡片（0.3.0 之前收藏的
        /// 没有 segmentID）与被重新切分过的章节取不到，此时只显示来源名。
        public var segment: ArticleSegment?
        public var jump: PendingJump

        public var sentence: String? { segment?.text }
    }

    /// 解析出处。没有出处返回 nil，UI 据此整块隐藏。
    ///
    /// 两种情况会没有：生词本里手工新建的卡从来就没有来源；来源文章/书被删除时
    /// `sourceArticleId` 会被清成 nil——不留一个点了会 404 的入口。
    public func resolveSource(for favorite: FavoriteVocabulary) async -> FavoriteSource? {
        guard let articleID = favorite.sourceArticleId else { return nil }
        var segment: ArticleSegment?
        if let segmentID = favorite.sourceSegmentId {
            segment = await sourceSegment(segmentID: segmentID)
        }
        return FavoriteSource(
            label: sourceLabel(articleID: articleID, fallback: favorite.sourceArticleTitle),
            segment: segment,
            jump: .init(articleID: articleID, segmentID: favorite.sourceSegmentId))
    }

    /// 单独一句，带会话内缓存。
    func sourceSegment(segmentID: UUID) async -> ArticleSegment? {
        // 命中的可能是 `.some(nil)`——查过且确实没有。这一层 `if let` 只剥掉
        // "查没查过"，剥完的 nil 原样返回，不会再查一次必然落空的库。
        if let cached = sourceSegmentCache[segmentID] { return cached }
        // 正在读的章节直接从内存拿：刚在阅读器里收藏完就去复习是最常见的路径，
        // 而且内存里那份比库里新（精讲刚写回时还没落盘）。
        if let inMemory = segmentsByArticle.values.lazy
            .compactMap({ segments in segments.first { $0.id == segmentID } })
            .first
        {
            sourceSegmentCache[segmentID] = inMemory
            return inMemory
        }
        let segment = try? await repository.segment(id: segmentID)
        sourceSegmentCache[segmentID] = segment
        return segment
    }

    /// 来源名。书籍必须带上书名——只显示章标题的话，同一本书里的几十张卡长得一模一样。
    func sourceLabel(articleID: UUID, fallback: String?) -> String {
        switch container(forArticle: articleID) {
        case .book(let book, _):
            if let fallback, !fallback.isEmpty { return "\(book.title) · \(fallback)" }
            return book.title
        case .media(let media):
            return media.title
        case .article(let article):
            return article.title
        case .unknown:
            return fallback ?? ""
        }
    }
}
