import Foundation
import OKModels

// 生词卡的出处。
//
// 卡片只存了 articleID / segmentID，没存句子本身——句子会被重新切分（重导入同一本书，
// UUID 全换），冗余一份文本就成了永远不会更新的过期快照。要显示原句就查一次库：
// 一行 SELECT 的代价远小于维护一份会失真的副本。

extension ContentStore {
    /// 一张生词卡的出处：显示用的来源名 + 原句 + 跳回去要用的坐标。
    public struct FavoriteSource: Equatable, Sendable {
        /// 「挪威的森林 · 第三章」/ 视频名 / 文章标题。
        public var label: String
        /// 收藏时所在的那一句。存量卡片（0.3.0 之前收藏的没有 segmentID）
        /// 与被重新切分过的章节取不到，此时只显示来源名。
        public var sentence: String?
        public var jump: PendingJump
    }

    /// 解析出处。没有出处返回 nil，UI 据此整块隐藏。
    ///
    /// 两种情况会没有：生词本里手工新建的卡从来就没有来源；来源文章/书被删除时
    /// `sourceArticleId` 会被清成 nil——不留一个点了会 404 的入口。
    public func resolveSource(for favorite: FavoriteVocabulary) async -> FavoriteSource? {
        guard let articleID = favorite.sourceArticleId else { return nil }
        var sentence: String?
        if let segmentID = favorite.sourceSegmentId {
            sentence = await sourceSentence(segmentID: segmentID)
        }
        return FavoriteSource(
            label: sourceLabel(articleID: articleID, fallback: favorite.sourceArticleTitle),
            sentence: sentence,
            jump: .init(articleID: articleID, segmentID: favorite.sourceSegmentId))
    }

    /// 单句正文，带会话内缓存。
    func sourceSentence(segmentID: UUID) async -> String? {
        // 命中的可能是 `.some(nil)`——查过且确实没有。这一层 `if let` 只剥掉
        // "查没查过"，剥完的 nil 原样返回，不会再查一次必然落空的库。
        if let cached = sourceSentenceCache[segmentID] { return cached }
        // 正在读的章节直接从内存拿：刚在阅读器里收藏完就去复习是最常见的路径。
        if let inMemory = segmentsByArticle.values.lazy
            .compactMap({ segments in segments.first { $0.id == segmentID } })
            .first
        {
            sourceSentenceCache[segmentID] = inMemory.text
            return inMemory.text
        }
        let text = try? await repository.segmentText(id: segmentID)
        sourceSentenceCache[segmentID] = text
        return text
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
