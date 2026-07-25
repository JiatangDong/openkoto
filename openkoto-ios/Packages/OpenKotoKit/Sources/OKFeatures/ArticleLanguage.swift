import Foundation
import NaturalLanguage

/// 正文语种检测（BCP-47）。
///
/// 孤立汉字无法区分中/日，所以一律**从整篇正文取样检测一次**，再把结果当提示往下传：
/// 发音（`SpeechService`）与词级注音（`LocalReadingAnnotator`）共用同一个判断。
enum ArticleLanguage {
    /// 取样长度。再长对判定几乎没有增益，只是白跑。
    private static let sampleLimit = 400

    static func detect(_ text: String) -> String? {
        let sample = String(text.prefix(sampleLimit))
        guard !sample.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        return recognizer.dominantLanguage?.rawValue
    }
}
