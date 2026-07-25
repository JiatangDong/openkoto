import Foundation
import OKModels
import Testing

@testable import OKBooks

/// 离线注音器的黄金用例。
///
/// **这组测试同时是平台探针**：日语形态素分析由系统提供，
/// macOS 上确认可用不等于 iOS 上可用，所以 CI/验收必须在模拟器上也跑一遍
/// （`xcodebuild test -destination 'platform=iOS Simulator,...'`）。
@Suite struct LocalReadingAnnotatorTests {
    private let annotator = LocalReadingAnnotator()

    /// 把 runs 渲染成 `词(读音)` 便于断言与阅读。
    private func annotated(_ text: String, _ language: ReadingLanguage) -> String {
        annotator.annotate(text, language: language)
            .map { run in run.reading.map { "\(run.text)(\($0))" } ?? run.text }
            .joined()
    }

    // MARK: - 日语

    @Test func annotatesJapaneseKanjiWithKana() {
        #expect(annotated("東京", .japanese) == "東京(とうきょう)")
        #expect(annotated("大阪", .japanese) == "大阪(おおさか)")
        #expect(annotated("学校", .japanese) == "学校(がっこう)")
    }

    /// 送假名不该被圈进注音范围：`駆ける` 要标成 `駆(か)ける` 而不是 `駆ける(かける)`。
    @Test func splitsOkuriganaOutOfReading() {
        #expect(annotated("駆ける", .japanese) == "駆(か)ける")
        #expect(annotated("聞こえる", .japanese) == "聞(き)こえる")
        #expect(annotated("大きい", .japanese) == "大(おお)きい")
    }

    /// 假名词、标点、空白原样保留，拼接必须等于原文。
    @Test func leavesKanaAndPunctuationUntouched() {
        let text = "こんな ゆめ を みた。"
        let runs = annotator.annotate(text, language: .japanese)
        #expect(runs.plainText == text)
        #expect(!runs.hasReadings)
    }

    @Test func annotatesFullSentencePreservingPlainText() {
        let text = "吾輩は猫である。名前はまだ無い。"
        let runs = annotator.annotate(text, language: .japanese)
        #expect(runs.plainText == text)
        #expect(annotated(text, .japanese).hasPrefix("吾輩(わがはい)は猫(ねこ)である。"))
    }

    // MARK: - 中文

    /// 多音字靠分词器的词典按上下文选音——这是逐字转拼音做不到的。
    @Test func annotatesChinesePinyinWithContext() {
        let text = "银行行长说这首歌的长度不够"
        let runs = annotator.annotate(text, language: .chinese)
        #expect(runs.plainText == text)

        let readings = runs.compactMap { run in run.reading.map { (run.text, $0) } }
        #expect(readings.contains { $0.0 == "银行" && $0.1 == "yínháng" })
        #expect(readings.contains { $0.0 == "行长" && $0.1 == "hángzhǎng" })
        #expect(readings.contains { $0.0 == "长度" && $0.1 == "chángdù" })
    }

    // MARK: - 语种判错的负向用例

    /// 中文喂日语 locale 会得到日语音读（`银行 → ぎんこう` 之类），是灾难性错误。
    /// 判定器必须在没有 hint 时拒绝猜测，让这条路根本走不到。
    @Test func refusesToGuessBetweenChineseAndJapanese() {
        #expect(ReadingLanguageDetector.detect(text: "银行行长说这首歌") == .unsupported)
        #expect(ReadingLanguageDetector.detect(text: "日本語の勉強") == .japanese)  // 假名是确凿证据
    }

    @Test func usesHintOnlyForHanOnlyText() {
        #expect(ReadingLanguageDetector.detect(text: "银行", hint: "zh-Hans") == .chinese)
        #expect(ReadingLanguageDetector.detect(text: "東京", hint: "ja") == .japanese)
        #expect(ReadingLanguageDetector.detect(text: "東京", hint: "ko") == .unsupported)
        #expect(ReadingLanguageDetector.detect(text: "Hello world", hint: "en") == .unsupported)
    }

    /// 假名优先于 hint：书的 language 字段填错时不该把日文正文当中文注拼音。
    @Test func kanaBeatsWrongHint() {
        #expect(ReadingLanguageDetector.detect(text: "東京へ行く", hint: "zh-Hans") == .japanese)
    }

    @Test func unsupportedLanguageReturnsTextUnchanged() {
        let runs = annotator.annotate("Hello world", language: .unsupported)
        #expect(runs == [ReadingRun(text: "Hello world")])
    }

    // MARK: - 结构不变量

    /// 无论输入什么，runs 顺序拼接必须等于原文——否则正文会被改写。
    @Test(arguments: [
        "夜に駆ける君の声が聞こえる",
        "こんにちは、世界！",
        "ABC 123 混在テキスト",
        "银行行长，你好。",
        "",
    ])
    func alwaysReconstructsOriginalText(_ text: String) {
        for language in [ReadingLanguage.japanese, .chinese, .unsupported] {
            #expect(annotator.annotate(text, language: language).plainText == text)
        }
    }

    /// 相邻的无注音片段应被合并，避免 run 数量爆炸。
    @Test func mergesAdjacentUnannotatedRuns() {
        let runs = annotator.annotate("ABC 123 !!", language: .japanese)
        #expect(runs.count == 1)
    }
}
