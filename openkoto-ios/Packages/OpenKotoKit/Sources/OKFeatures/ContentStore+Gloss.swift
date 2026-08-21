import Foundation
import OKAIClient
import OKModels
import OKPersistence
import OKSegmentation

// 单词释义。
//
// 阅读时最高频的动作是"这个词啥意思"，而在此之前唯一的路径是点整句做精讲——
// 一次要吐 600–1200 token，而且**同一个词在别的文章里出现还要再付一次**。
// 这里给它一条便宜的路，并且缓存：会话内走 `glossStates`，跨会话走 `word_gloss` 表。
// 缓存失效不靠清理任务：库里的 `context`（prompt 版本 + 模型 + 目标语言）与当前
// 不一致即视为 miss，重查并覆盖。

extension ContentStore {
    /// 一次查词的结果。
    public enum GlossState: Sendable, Equatable {
        case loading
        case loaded(VocabularyItem)
        case failed(AIClientError)
    }

    /// 把一句话切成可查的词。分词是离线的，不花钱也不需要先精讲。
    public func lookupCandidates(in text: String, language: String? = nil) -> [WordToken] {
        WordTokenizer.lookupCandidates(text, locale: language)
    }

    public func glossState(for word: String) -> GlossState? {
        glossStates[normalizedWord(word)]
    }

    /// 查词。**同一个词只会付一次钱**——内存、数据库依次命中都直接返回。
    ///
    /// 落库的是缓存不是收藏：查过的词不进生词本、不参与复习、不同步云端；
    /// 换模型/换目标语言/升级 prompt 后旧缓存自动失效（见 AppDatabase v11）。
    @discardableResult
    public func gloss(word: String, in sentence: String) async -> VocabularyItem? {
        let key = normalizedWord(word)
        guard !key.isEmpty else { return nil }
        if case .loaded(let cached) = glossStates[key] { return cached }
        if case .loading = glossStates[key] { return nil }

        let context = glossCacheContext?()

        // 库里查过了就直接用——重启 App 不该让同一个词再付一次费。
        if let context,
           let hit = try? await repository.fetchWordGloss(normalizedWord: key),
           hit.context == context
        {
            glossStates[key] = .loaded(hit.item)
            return hit.item
        }

        guard let glossProvider else {
            glossStates[key] = .failed(.notConfigured)
            return nil
        }

        glossStates[key] = .loading
        do {
            let item = try await glossProvider(word, sentence)
            glossStates[key] = .loaded(item)
            // 写库失败不告状：这只是缓存，下次再查一次就是了。
            if let context {
                try? await repository.upsertWordGloss(item, context: context)
            }
            return item
        } catch is CancellationError {
            glossStates[key] = nil
            return nil
        } catch let failure as AIRequestFailure {
            glossStates[key] = .failed(failure.error)
            return nil
        } catch let error as AIClientError {
            glossStates[key] = .failed(error)
            return nil
        } catch {
            glossStates[key] = .failed(.malformedResponse(requestID: UUID()))
            return nil
        }
    }

    /// 重试一个失败的查询。
    public func retryGloss(word: String, in sentence: String) async {
        glossStates[normalizedWord(word)] = nil
        await gloss(word: word, in: sentence)
    }

    /// 用已有精讲里的生词表预热缓存——那些词已经付过钱了，不该再付第二次。
    func warmGlossCache(from explanation: SegmentExplanation) {
        for item in explanation.vocabulary {
            let key = normalizedWord(item.word)
            guard !key.isEmpty, glossStates[key] == nil else { continue }
            glossStates[key] = .loaded(item)
        }
        // 精讲里的词同样落库：重新导入一篇精讲过的文章后，点词也不该再花钱。
        if let context = glossCacheContext?() {
            let items = explanation.vocabulary
            Task {
                for item in items {
                    try? await repository.upsertWordGloss(item, context: context)
                }
            }
        }
    }
}
