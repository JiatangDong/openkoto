import Foundation
import OKModels
import OKPersistence

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
        // 指不到句子就现找一次。两种卡会走到这儿：`source_segment_id` 是 v5 才加的列
        // 且没有回填，升级前收藏的全是空的；书被重新导入过时旧 UUID 也会失效。
        if segment == nil {
            segment = await backfillSourceSegment(for: favorite, articleID: articleID)
        }
        return FavoriteSource(
            label: sourceLabel(articleID: articleID, fallback: favorite.sourceArticleTitle),
            segment: segment,
            // 跳转坐标用现找到的那一句：回填成功后「在原文中查看」就能落到句上，
            // 而不是把人扔到文章开头。
            jump: .init(articleID: articleID, segmentID: segment?.id ?? favorite.sourceSegmentId))
    }

    /// 在来源文章里现找这个词出自哪一句，找到就写回卡片（只找一次）。
    ///
    /// 优先级：
    /// 1. **精讲词汇表里含这个词的句子** —— 卡片本来就是从那份词汇表点出来的，
    ///    这个信号几乎必中，且在一个词于同篇出现多次时能选对那一句；
    /// 2. 正文含这个词、句序最小的那句；
    /// 3. 都没有 —— 记一次未命中，只显示来源名（与回填前的表现一致）。
    ///
    /// 书籍章节从未打开过时库里没有 segment 行，这里自然什么也找不到；
    /// 用户哪天读到那一章，下次复习就补上了。
    func backfillSourceSegment(
        for favorite: FavoriteVocabulary, articleID: UUID
    ) async -> ArticleSegment? {
        guard !sourceBackfillMisses.contains(favorite.id) else { return nil }

        let candidates: [ArticleSegment]
        if let inMemory = segmentsByArticle[articleID] {
            // 正在读的章节直接在内存里找，省一次查询。
            candidates = inMemory.filter { $0.text.localizedCaseInsensitiveContains(favorite.word) }
        } else {
            candidates =
                (try? await repository.segments(articleID: articleID, containing: favorite.word))
                ?? []
        }
        guard !candidates.isEmpty else {
            sourceBackfillMisses.insert(favorite.id)
            return nil
        }

        let target = normalizedWord(favorite.word)
        let matched =
            candidates.first { segment in
                segment.explanation?.vocabulary.contains { normalizedWord($0.word) == target }
                    ?? false
            } ?? candidates[0]

        // 写回卡片：下次翻到它走的就是 `sourceSegmentId` 那条快路径，只查这一次。
        if let index = favorites.firstIndex(where: { $0.id == favorite.id }) {
            favorites[index].sourceSegmentId = matched.id
        }
        sourceSegmentCache[matched.id] = matched
        persist("setSourceSegment") { [repository] in
            try await repository.setSourceSegment(
                vocabularyId: favorite.id, segmentId: matched.id)
        }
        return matched
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
