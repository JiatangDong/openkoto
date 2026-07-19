import Foundation
import Testing
@testable import OKSegmentation

/// 切分器针对桌面 Rust 算法（commands.rs L64-200）的对齐测试。
/// 主体用例来自 `Fixtures/segmentation_golden.json`——该文件与 Rust 侧共享，
/// 任一端切分行为变化都必须同步更新 fixture 并让两套测试通过（设计文档 §5）。
@Suite struct SentenceSegmenterTests {
    let segmenter = SentenceSegmenter()

    // MARK: - Golden fixtures（与 Rust 共享）

    struct GoldenExpectation: Decodable {
        let text: String
        let newParagraph: Bool
    }
    struct GoldenCase: Decodable {
        let name: String
        let input: String
        let expected: [GoldenExpectation]
    }
    struct GoldenFile: Decodable {
        let version: Int
        let cases: [GoldenCase]
    }

    static func loadGolden() throws -> GoldenFile {
        let url = try #require(
            Bundle.module.url(forResource: "segmentation_golden", withExtension: "json"),
            "缺少 golden fixture 资源；检查 Package.swift testTarget 的 resources 声明"
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(GoldenFile.self, from: data)
    }

    @Test func matchesSharedGoldenFixtures() throws {
        let golden = try Self.loadGolden()
        #expect(golden.cases.isEmpty == false)

        for testCase in golden.cases {
            let drafts = segmenter.segment(testCase.input)
            let actualTexts = drafts.map(\.text)
            let expectedTexts = testCase.expected.map(\.text)
            #expect(
                actualTexts == expectedTexts,
                "[\(testCase.name)] 句子边界不一致：\n  期望 \(expectedTexts)\n  实际 \(actualTexts)"
            )
            let actualParagraph = drafts.map(\.isNewParagraph)
            let expectedParagraph = testCase.expected.map(\.newParagraph)
            #expect(
                actualParagraph == expectedParagraph,
                "[\(testCase.name)] 段落标记不一致：期望 \(expectedParagraph)，实际 \(actualParagraph)"
            )
        }
    }

    // MARK: - 单元级回归（针对具体启发式）

    @Test func abbreviationMrIsNotSplit() {
        let drafts = segmenter.segment("Dr. Smith and Mr. Lee met vs. the team.")
        #expect(drafts.map(\.text) == ["Dr. Smith and Mr. Lee met vs. the team."])
    }

    @Test func singleUppercaseInitialIsNotSplit() {
        let drafts = segmenter.segment("Written by A. B. Cooper.")
        #expect(drafts.map(\.text) == ["Written by A. B. Cooper."])
    }

    @Test func trailingCurlyQuoteMerges() {
        // 弯右双引号 U+201D 也应归并入句
        let drafts = segmenter.segment("She said \u{201C}Hello.\u{201D} Bye.")
        #expect(drafts.map(\.text) == ["She said \u{201C}Hello.\u{201D}", "Bye."])
    }

    @Test func emptyInputProducesNothing() {
        #expect(segmenter.segment("").isEmpty)
        #expect(segmenter.segment("   \n\n  ").isEmpty)
    }
}
