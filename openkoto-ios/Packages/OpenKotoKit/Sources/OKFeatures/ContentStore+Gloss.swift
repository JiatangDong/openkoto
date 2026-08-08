import Foundation
import OKAIClient
import OKModels
import OKPersistence
import OKSegmentation

// 单词释义。
//
// 阅读时最高频的动作是"这个词啥意思"，而在此之前唯一的路径是点整句做精讲——
// 一次要吐 600–1200 token，而且**同一个词在别的文章里出现还要再付一次**。
// 这里给它一条便宜的路，并且在会话内缓存。

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

    /// 查词。**同一个词在本次会话里只会付一次钱**——缓存命中直接返回。
    ///
    /// 不落库：落库要新表、新 migration、以及"换模型/换目标语言后缓存怎么失效"
    /// 这一整套策略；而用户真正在意的词本来就会被收藏进生词本。
    /// 没收藏的那些，说明看过就算了。
    @discardableResult
    public func gloss(word: String, in sentence: String) async -> VocabularyItem? {
        let key = normalizedWord(word)
        guard !key.isEmpty else { return nil }
        if case .loaded(let cached) = glossStates[key] { return cached }
        if case .loading = glossStates[key] { return nil }

        guard let glossProvider else {
            glossStates[key] = .failed(.notConfigured)
            return nil
        }

        glossStates[key] = .loading
        do {
            let item = try await glossProvider(word, sentence)
            glossStates[key] = .loaded(item)
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
    }
}
