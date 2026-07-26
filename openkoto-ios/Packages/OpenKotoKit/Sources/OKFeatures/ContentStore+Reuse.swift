import Foundation
import OKAIClient
import OKModels
import OKPersistence

// 精讲复用。
//
// `explanation_json` 里一直存着 `source_text_hash`，但从来没人读过——于是同一句话
// 在别处出现还要再向 AI 付一次钱。真正常见的不是"同一句出现在两篇文章里"，而是：
//   · 同一本书重新导入（切分后 segment 全换新 UUID，攒下的精讲全丢）
//   · 同一篇文章被分享进来两次
//   · 视频字幕与它的文稿章节重叠
// 这几种情况下用户会为**完全相同的原文**重复付费，而且毫无察觉。

extension ContentStore {
    /// 与当前 prompt 语义兼容的精讲版本。
    ///
    /// 用集合而不是等值比较：将来 prompt 改版时，旧结果只要语义仍兼容就该继续可用，
    /// 不该一改版就让用户攒下的全部精讲对复用逻辑而言瞬间作废。
    static let compatibleExplainVersions: Set<String> = [PromptLibrary.segmentExplainVersion]

    /// 当前讲解语言。与 `AppConfigStore.targetLanguage` 读同一个 key——
    /// 复用判据必须和生成时用的语言一致，否则会拿到一份别的语言的讲解。
    var explanationTargetLanguage: String {
        defaults.string(forKey: "learning.targetLanguage") ?? "zh-CN"
    }

    /// 库里有没有同一句原文已经精讲过的结果。
    func reusableExplanation(for text: String) async -> SegmentExplanation? {
        do {
            let envelope = try await repository.existingExplanation(
                sourceTextHash: SourceTextHash.of(text),
                targetLanguage: explanationTargetLanguage,
                compatiblePromptVersions: Self.compatibleExplainVersions)
            return envelope?.explanation
        } catch {
            // 复用只是省钱的优化，查不动就照常调 AI，不该让它挡住主路径
            Self.logger.error("reuse lookup failed: \(error)")
            return nil
        }
    }

    /// 把一份精讲写进内存与库。新生成与复用命中共用这一条路径。
    @discardableResult
    func applyExplanation(
        _ explanation: SegmentExplanation, articleID: UUID, segmentID: UUID,
        meta: ExplanationMeta?
    ) -> Bool {
        // 写回前重新校验：防止用户切换文章/重切分后旧请求覆盖新数据（设计文档 §4.6）。
        guard var segments = segmentsByArticle[articleID],
            let index = segments.firstIndex(where: { $0.id == segmentID }),
            segments[index].explanation == nil
        else { return false }

        segments[index].explanation = explanation
        segments[index].translation = explanation.translation
        if let reading = explanation.readingText {
            segments[index].readingText = reading
        }
        segmentsByArticle[articleID] = segments
        // 计数同步递增：文章被 LRU 卸载后进度徽章仍要正确。
        segmentCounts[articleID, default: .init(total: segments.count)].explained += 1
        // 精讲带回了生词读音，比离线注音准——立刻盖上去。
        refreshReadings(articleID: articleID, segmentID: segmentID)

        persist("saveExplanation") { [repository] in
            try await repository.saveExplanation(
                segmentID: segmentID, explanation: explanation, meta: meta)
        }
        return true
    }

    /// 章节刚懒切分完时批量回填。
    ///
    /// **这是复用威力最大的时刻**：重新导入一本已精讲过的书，打开章节就全回来了，
    /// 一次 API 调用都不用。放在切分之后是因为那时才有 segment 行可写。
    func backfillReusableExplanations(articleID: UUID) async {
        guard let segments = segmentsByArticle[articleID] else { return }
        let pending = segments.filter { $0.explanation == nil }
        guard !pending.isEmpty else { return }

        var restored = 0
        for segment in pending {
            guard let explanation = await reusableExplanation(for: segment.text) else { continue }
            if applyExplanation(
                explanation, articleID: articleID, segmentID: segment.id, meta: nil)
            {
                restored += 1
            }
        }
        if restored > 0 {
            Self.logger.info("reused \(restored) explanations for article \(articleID)")
        }
    }
}
