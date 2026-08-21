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

    /// 网页素材清洗：让模型指出哪些行属于网页噪音（导航、广告、推荐位、评论、页脚……）。
    ///
    /// 模型只返回行号，不返回改写后的正文——理由见 `WebContentCleaner`。
    /// `lines` 是 (原始行号, 预览文本)；返回 (要删的行号, 模型给出的干净标题)。
    public func detectWebNoiseLines(
        lines: [(index: Int, preview: String)],
        wantTitle: Bool,
        config: ModelConfig,
        apiKey: String?
    ) async throws -> ([Int], String?) {
        guard !lines.isEmpty else { return ([], nil) }
        let request = ChatRequest(
            purpose: .webClean,
            systemPrompt: PromptLibrary.webCleanSystemPrompt(wantTitle: wantTitle),
            userMessage: PromptLibrary.webCleanUserMessage(lines: lines),
            // 判定题不需要发挥。0 温度下同一篇网页两次清洗结果一致，用户重试才有意义。
            temperature: 0,
            timeout: 120
        )
        let content = try await transport.complete(request, config: config, apiKey: apiKey)
        let parsed = try LLMJSONExtractor.parse(
            NoiseLineResponse.self, from: content, requestID: request.requestID)
        return (parsed.dropIndices, parsed.cleanTitle)
    }

    /// 清洗响应。`drop` 偶尔会回成字符串数组（"3" 而非 3），故自定义解码兼容两种形态——
    /// 否则一个引号就让整批清洗白跑。
    private struct NoiseLineResponse: Decodable {
        let dropIndices: [Int]
        let cleanTitle: String?

        private enum CodingKeys: String, CodingKey { case drop, title }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let raw = (try? container.decode([LenientInt].self, forKey: .drop)) ?? []
            dropIndices = raw.compactMap(\.value)
            let title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? nil
            cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
    }

    private struct LenientInt: Decodable {
        let value: Int?
        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let int = try? single.decode(Int.self) {
                value = int
            } else if let string = try? single.decode(String.self) {
                value = Int(string.trimmingCharacters(in: .whitespaces))
            } else {
                value = nil
            }
        }
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
