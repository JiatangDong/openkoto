#if os(iOS)
import Foundation
import AVFoundation
import NaturalLanguage

/// 系统 TTS 朗读（iOS 增强项，桌面版没有）。基于 `AVSpeechSynthesizer`。
///
/// **多音字处理**：发音时优先用「读音字段」而非原文，从而把多音字读对——
/// - 日语：有假名读音则念假名（表音、无歧义），彻底解决音读/训读歧义；
/// - 中文：拼音 → IPA（`PinyinIPA`），用 IPA 注音属性强制指定音节+声调；
/// - 英语：读音本身即 IPA，同样走 IPA 注音属性；
/// - 无读音或解析失败：回退为原文朗读（引擎按上下文/默认读音）。
///
/// 长句中文不走 IPA（引擎自带上下文韵律更自然，多音字问题主要出在脱离上下文的单字/词）。
@MainActor
@Observable
final class SpeechService {
    private let synthesizer = AVSpeechSynthesizer()

    /// 中文走 IPA 强制读音的最长汉字数；超过则用原文（保留句子韵律）。
    private let chineseIPACharLimit = 12

    /// - Parameters:
    ///   - text: 要朗读的原文（词/句）。
    ///   - reading: 读音字段（日语=假名 / 中文=拼音 / 英语=IPA），用于多音字纠音。
    ///   - language: 语种提示（BCP-47，如 `ja` / `zh` / `en`）。缺省时从文本+读音推断；
    ///     对单字尤其重要（孤立汉字难以自动区分中/日）。
    func speak(_ text: String, reading: String? = nil, language: String? = nil) {
        synthesizer.stopSpeaking(at: .immediate)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let lang = resolveLanguage(text: trimmed, reading: reading, hint: language)
        let reading = reading?.trimmingCharacters(in: .whitespacesAndNewlines)

        let utterance: AVSpeechUtterance
        let voiceCode: String

        switch lang {
        case .japanese:
            voiceCode = "ja-JP"
            if let kana = reading, isMostlyKana(kana) {
                utterance = AVSpeechUtterance(string: kana)   // 念假名 → 音/训读永远对
            } else {
                utterance = AVSpeechUtterance(string: trimmed)
            }

        case .chinese:
            voiceCode = "zh-CN"
            if let pinyin = reading, hanCount(trimmed) <= chineseIPACharLimit,
               let ipa = PinyinIPA.convert(pinyin) {
                utterance = AVSpeechUtterance(attributedString: ipaAttributed(trimmed, ipa: ipa))
            } else {
                utterance = AVSpeechUtterance(string: trimmed)
            }

        case .english:
            voiceCode = "en-US"
            if let ipa = normalizedIPA(reading) {
                utterance = AVSpeechUtterance(attributedString: ipaAttributed(trimmed, ipa: ipa))
            } else {
                utterance = AVSpeechUtterance(string: trimmed)
            }

        case .other(let code):
            voiceCode = code
            utterance = AVSpeechUtterance(string: trimmed)
        }

        if let voice = AVSpeechSynthesisVoice(language: voiceCode) {
            utterance.voice = voice
        }
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: - 语种判定

    private enum SpeechLanguage {
        case japanese, chinese, english, other(String)
    }

    private func resolveLanguage(text: String, reading: String?, hint: String?) -> SpeechLanguage {
        if let base = hint?.lowercased() {
            if base.hasPrefix("ja") { return .japanese }
            if base.hasPrefix("zh") || base.hasPrefix("cmn") || base.hasPrefix("yue") { return .chinese }
            if base.hasPrefix("en") { return .english }
        }
        // 读音/字形推断（对单字比 NL 检测更可靠）
        if let reading, isMostlyKana(reading) { return .japanese }
        if containsKana(text) { return .japanese }
        if containsHan(text) {
            if let reading, looksLikePinyin(reading) { return .chinese }
            if let base = hint?.lowercased() {
                if base.hasPrefix("ja") { return .japanese }
                if base.hasPrefix("zh") { return .chinese }
            }
            return mapDetected(text) ?? .chinese
        }
        if let detected = mapDetected(text) { return detected }
        if let base = hint?.lowercased(), !base.isEmpty { return .other(base) }
        return .english
    }

    private func mapDetected(_ text: String) -> SpeechLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let lang = recognizer.dominantLanguage else { return nil }
        switch lang {
        case .japanese: return .japanese
        case .simplifiedChinese, .traditionalChinese: return .chinese
        case .english: return .english
        default: return .other(lang.rawValue)
        }
    }

    // MARK: - 文本判定

    private func containsKana(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || $0.value == 0x30FC }
    }

    private func containsHan(_ s: String) -> Bool {
        s.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value)
                || (0x20000...0x2A6DF).contains($0.value)
        }
    }

    private func hanCount(_ s: String) -> Int {
        s.unicodeScalars.reduce(into: 0) { acc, u in
            if (0x4E00...0x9FFF).contains(u.value) || (0x3400...0x4DBF).contains(u.value) { acc += 1 }
        }
    }

    /// 假名占比过半（含长音符），用于判定「日语读音行」。
    private func isMostlyKana(_ s: String) -> Bool {
        var kana = 0, letters = 0
        for u in s.unicodeScalars {
            if (0x3040...0x30FF).contains(u.value) || u.value == 0x30FC { kana += 1 }
            else if CharacterSet.letters.contains(u) { letters += 1 }
        }
        return kana > 0 && kana >= letters
    }

    /// 读音看起来像拼音（拉丁字母 + 可选声调符号/数字）。
    private func looksLikePinyin(_ s: String) -> Bool {
        s.range(of: "[A-Za-zāáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜü]", options: .regularExpression) != nil
    }

    /// 归一化英语 IPA 读音：去掉包裹的 / [ ] ( ) 空白；仅在确含 IPA 记号时采用，
    /// 否则返回 nil（读音可能是普通拼写，交给引擎按单词读更稳）。
    private func normalizedIPA(_ reading: String?) -> String? {
        guard let reading else { return nil }
        let cleaned = reading
            .trimmingCharacters(in: CharacterSet(charactersIn: "/[]() \t"))
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        let markers = CharacterSet(charactersIn: "ˈˌːˑəɪʊæɑɒɔʌʃʒθðŋɜɝɚɡɹɫɾʔɐ")
        let hasIPA = cleaned.unicodeScalars.contains { markers.contains($0) || $0.value > 0x02B0 }
        return hasIPA ? cleaned : nil
    }

    private func ipaAttributed(_ text: String, ipa: String) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: text)
        let range = NSRange(location: 0, length: (text as NSString).length)
        attributed.addAttribute(
            NSAttributedString.Key(rawValue: AVSpeechSynthesisIPANotationAttribute),
            value: ipa, range: range)
        return attributed
    }
}
#endif
