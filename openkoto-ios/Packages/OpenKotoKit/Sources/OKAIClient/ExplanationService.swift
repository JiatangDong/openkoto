import Foundation
import OKModels

/// 逐句精讲的高层入口：组合 Transport + PromptLibrary + LLMJSONExtractor（设计文档 §4）。
/// 一期结构化任务全部非流式 `complete`。
public struct ExplanationService: Sendable {
    private let transport: any ChatTransport

    public init(transport: any ChatTransport = LiveChatTransport()) {
        self.transport = transport
    }

    /// 对一句原文做翻译+精讲，返回结构化结果（对齐 `segment_translate_explain`）。
    public func explain(
        text: String,
        targetLanguage: String,
        config: ModelConfig,
        apiKey: String?
    ) async throws -> SegmentExplanation {
        let request = ChatRequest(
            purpose: .explain,
            systemPrompt: PromptLibrary.segmentExplainSystemPrompt(
                text: text, targetLanguage: targetLanguage),
            userMessage: PromptLibrary.analyzeUserMessage(text: text),
            temperature: 0.3,
            timeout: 120
        )
        let content = try await transport.complete(request, config: config, apiKey: apiKey)
        return try LLMJSONExtractor.parseSegmentExplanation(
            from: content, requestID: request.requestID)
    }

    /// 对一句原文只做翻译（快翻/全文翻译），返回纯译文（对齐 `translate`）。
    public func translate(
        text: String,
        targetLanguage: String,
        config: ModelConfig,
        apiKey: String?
    ) async throws -> String {
        let request = ChatRequest(
            purpose: .translate,
            systemPrompt: PromptLibrary.segmentTranslateSystemPrompt(targetLanguage: targetLanguage),
            userMessage: text,
            temperature: 0.3,
            timeout: 60
        )
        let content = try await transport.complete(request, config: config, apiKey: apiKey)
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 查一个词在**当前句子里**的意思。
    ///
    /// 与 `explain` 的区别不只是"少要点东西"：精讲一次要吐 600–1200 token，
    /// 而阅读时最高频的动作只是"这个词啥意思"。这条路径的 schema 与输出都压到极小，
    /// 便宜一个数量级。返回 `VocabularyItem` 而不是新类型——它能直接进生词本。
    public func gloss(
        word: String,
        sentence: String,
        targetLanguage: String,
        config: ModelConfig,
        apiKey: String?
    ) async throws -> VocabularyItem {
        let request = ChatRequest(
            purpose: .wordGloss,
            systemPrompt: PromptLibrary.wordGlossSystemPrompt(targetLanguage: targetLanguage),
            userMessage: PromptLibrary.wordGlossUserMessage(word: word, sentence: sentence),
            temperature: 0.2,
            maxOutputTokens: 300,
            timeout: 30
        )
        let content = try await transport.complete(request, config: config, apiKey: apiKey)
        var item = try LLMJSONExtractor.parse(
            VocabularyItem.self, from: content, requestID: request.requestID)
        // 模型偶尔会把 word 改写成别的形态；保底用用户点的那个词，
        // 否则收藏进生词本后与原文对不上。
        if item.word.trimmingCharacters(in: .whitespaces).isEmpty { item.word = word }
        return item
    }

    /// 设置页“测试连接”：发一条最小 chat 请求，成功即返回，失败抛
    /// `AIRequestFailure`（内含 `AIClientError` 分类与诊断快照）。
    public func testConnection(config: ModelConfig, apiKey: String?) async throws {
        let request = ChatRequest(
            purpose: .connectionTest,
            systemPrompt: "",
            userMessage: "ping",
            temperature: 0.3,
            maxOutputTokens: 16,
            timeout: 30
        )
        _ = try await transport.complete(request, config: config, apiKey: apiKey)
    }
}
