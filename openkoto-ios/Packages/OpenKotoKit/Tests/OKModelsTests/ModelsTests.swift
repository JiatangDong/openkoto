import Foundation
import Testing
@testable import OKModels

@Suite struct ModelsTests {
    @Test func segmentExplanationRoundTrip() throws {
        let explanation = SegmentExplanation(
            translation: "我做了这样一个梦。",
            explanation: "「夢を見る」是固定搭配。",
            readingText: "こんな ゆめ を みた。",
            vocabulary: [VocabularyItem(word: "夢", meaning: "梦", reading: "ゆめ")],
            grammarPoints: [GrammarPoint(point: "〜を見る", explanation: "惯用搭配")],
            difficultyLevel: "beginner"
        )
        let data = try JSONEncoder().encode(explanation)
        let decoded = try JSONDecoder().decode(SegmentExplanation.self, from: data)
        #expect(decoded == explanation)
    }

    @Test func providerIDRawValuesMatchDesktop() {
        // 与桌面 ModelConfig.api_provider 的字符串取值对齐（types.rs）
        #expect(ProviderID.ai302.rawValue == "302ai")
        #expect(ProviderID.openAICompatible.rawValue == "openai-compatible")
        #expect(ProviderID(rawValue: "deepseek") == .deepseek)
    }
}
