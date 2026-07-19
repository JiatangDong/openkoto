import Foundation
import Testing
@testable import OKAIClient
import OKModels

/// JSON 提取/修复对齐测试（对齐桌面 extract_json / repair_json）。
@Suite struct LLMJSONExtractorTests {

    @Test func extractsFencedJSONBlock() {
        let content = "Here you go:\n```json\n{\"a\": 1}\n```\nDone."
        #expect(LLMJSONExtractor.extractJSON(content) == "{\"a\": 1}")
    }

    @Test func extractsGenericCodeBlock() {
        let content = "```\n{\"a\": 1}\n```"
        #expect(LLMJSONExtractor.extractJSON(content) == "{\"a\": 1}")
    }

    @Test func extractsByBraceBalance() {
        let content = "prose {\"outer\": {\"inner\": 2}} trailing }"
        #expect(LLMJSONExtractor.extractJSON(content) == "{\"outer\": {\"inner\": 2}}")
    }

    @Test func repairsUnescapedNewlineInString() throws {
        let broken = "{\"explanation\": \"line one\nline two\"}"
        let repaired = LLMJSONExtractor.repairJSON(broken)
        let obj = try JSONSerialization.jsonObject(with: Data(repaired.utf8)) as? [String: Any]
        #expect((obj?["explanation"] as? String) == "line one\nline two")
    }

    @Test func repairsTrailingComma() throws {
        let broken = "{\"a\": 1, \"b\": 2,}"
        let repaired = LLMJSONExtractor.repairJSON(broken)
        let obj = try JSONSerialization.jsonObject(with: Data(repaired.utf8)) as? [String: Any]
        #expect(obj?["a"] as? Int == 1)
        #expect(obj?["b"] as? Int == 2)
    }

    @Test func parsesSnakeCaseExplanation() throws {
        // 模型返回 snake_case key + 代码块包裹，应正确解析为领域模型
        let content = """
        ```json
        {
          "translation": "你好世界",
          "explanation": "问候语",
          "vocabulary": [
            {"word": "hello", "reading": "həˈloʊ", "meaning": "你好", "usage": "打招呼", "example": "Hello!"}
          ],
          "grammar_points": [
            {"point": "感叹", "explanation": "用于问候", "example": "Hello!"}
          ],
          "cultural_context": "通用问候",
          "difficulty_level": "beginner",
          "learning_tips": "多练习"
        }
        ```
        """
        let explanation = try LLMJSONExtractor.parseSegmentExplanation(
            from: content, requestID: UUID())
        #expect(explanation.translation == "你好世界")
        #expect(explanation.vocabulary.first?.word == "hello")
        #expect(explanation.grammarPoints.first?.point == "感叹")
        #expect(explanation.culturalContext == "通用问候")
        #expect(explanation.difficultyLevel == "beginner")
    }

    @Test func parsesViaRepairWhenFirstParseFails() throws {
        // 未转义换行导致首次解析失败，修复后应成功
        let content = """
        {"translation": "多行
        译文", "explanation": "说明", "vocabulary": [], "grammar_points": []}
        """
        let explanation = try LLMJSONExtractor.parseSegmentExplanation(
            from: content, requestID: UUID())
        #expect(explanation.translation.contains("多行"))
    }

    @Test func throwsMalformedOnUnrecoverableJSON() {
        let requestID = UUID()
        #expect(throws: AIClientError.malformedResponse(requestID: requestID)) {
            try LLMJSONExtractor.parseSegmentExplanation(
                from: "not json at all, sorry", requestID: requestID)
        }
    }
}
