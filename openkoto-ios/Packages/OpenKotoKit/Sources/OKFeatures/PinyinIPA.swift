import Foundation

/// 普通话拼音 → IPA（宽式）转换。
///
/// 用途：把生词/单字的**拼音读音字段**转成 IPA，喂给 `AVSpeechSynthesizer` 的
/// `AVSpeechSynthesisIPANotationAttribute`，从而让**多音字按读音字段读对**，
/// 而不是听任 TTS 引擎按默认（最高频）读音朗读（如「行」háng/xíng、「重」chóng/zhòng）。
///
/// 支持输入：带声调符号的拼音（`yīn yuè` / `yīnyuè`）、数字声调（`yin1 yue4`）、`ü`/`v`、
/// 以空格/隔音符分隔或连写的多音节。声调用 IPA 五度声调字母（˥ ˧˥ ˨˩˦ ˥˩）标注，轻声不标。
///
/// 设计原则：**宁可回退，不可读错**——遇到无法解析的音节直接返回 `nil`，
/// 调用方回退为原文朗读，绝不产出臆造音节。纯函数，无平台依赖，便于 golden 测试。
enum PinyinIPA {

    /// 转换整串拼音。失败（含非拼音字符、无法切分的连写）返回 `nil`。
    static func convert(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()

        let syllables: [(String, Int)]
        if lower.unicodeScalars.contains(where: { (0x31...0x35).contains($0.value) }) {
            guard let parsed = parseNumbered(lower) else { return nil }
            syllables = parsed
        } else {
            guard let parsed = parseDiacritic(lower) else { return nil }
            syllables = parsed
        }
        guard !syllables.isEmpty else { return nil }

        var out: [String] = []
        for (syl, tone) in syllables {
            guard let ipa = syllableIPA(syl, tone: tone) else { return nil }
            out.append(ipa)
        }
        return out.joined(separator: " ")
    }

    // MARK: - 解析：数字声调（yin1 yue4 / yin1yue4）

    private static func parseNumbered(_ s: String) -> [(String, Int)]? {
        var result: [(String, Int)] = []
        var cur = ""
        func flush(tone: Int) {
            if !cur.isEmpty { result.append((cur.replacingOccurrences(of: "v", with: "ü"), tone)) }
            cur = ""
        }
        for ch in s {
            if isSeparator(ch) { flush(tone: 5); continue }
            if let d = ch.wholeNumberValue, (1...5).contains(d) { flush(tone: d); continue }
            if ch == "ü" || (ch.isLetter && ch.isASCII) { cur.append(ch); continue }
            return nil
        }
        flush(tone: 5)
        return result.filter { !$0.0.isEmpty }
    }

    // MARK: - 解析：声调符号（yīn yuè / yīnyuè）

    private static func parseDiacritic(_ s: String) -> [(String, Int)]? {
        var plain: [Character] = []
        var toneAt: [Int: Int] = [:]   // plain 下标 → 声调（该音节主元音处）
        for ch in s {
            if isSeparator(ch) { plain.append(" "); continue }
            if let (base, tone) = toneMap[ch] {
                if tone != 5 { toneAt[plain.count] = tone }
                plain.append(base); continue
            }
            if ch == "v" { plain.append("ü"); continue }
            if ch == "ü" || ch == "ê" { plain.append(ch); continue }
            if ch.isLetter && ch.isASCII { plain.append(ch); continue }
            return nil
        }

        var result: [(String, Int)] = []
        var i = 0
        let n = plain.count
        while i < n {
            if plain[i] == " " { i += 1; continue }
            var j = i
            while j < n && plain[j] != " " { j += 1 }
            let chunk = Array(plain[i..<j])
            guard let spans = splitSyllables(chunk) else { return nil }
            for span in spans {
                let syl = String(chunk[span])
                var tone = 5
                for k in span where toneAt[i + k] != nil { tone = toneAt[i + k]!; break }
                result.append((syl, tone))
            }
            i = j
        }
        return result
    }

    /// 把连写音节块贪心（长度优先 + 回溯）切分为合法音节区间。整块无法切分返回 `nil`。
    private static func splitSyllables(_ chars: [Character]) -> [Range<Int>]? {
        let n = chars.count
        if n == 0 { return [] }
        for len in stride(from: min(6, n), through: 1, by: -1) {
            let head = String(chars[0..<len])
            guard syllableIPA(head, tone: 5) != nil else { continue }
            if len == n { return [0..<len] }
            if let rest = splitSyllables(Array(chars[len...])) {
                return [0..<len] + rest.map { ($0.lowerBound + len)..<($0.upperBound + len) }
            }
        }
        return nil
    }

    // MARK: - 单音节 → IPA

    private static func syllableIPA(_ raw: String, tone: Int) -> String? {
        var s = raw
        if s.contains("v") { s = s.replacingOccurrences(of: "v", with: "ü") }
        guard !s.isEmpty else { return nil }

        var initialKey = ""
        var initialIPA = ""
        var final: String

        if s.first == "y" || s.first == "w" {
            final = normalizeGlide(s)
        } else if let (key, ipa) = matchInitial(s) {
            initialKey = key
            initialIPA = ipa
            final = String(s.dropFirst(key.count))
            if ["j", "q", "x"].contains(key) { final = uToUmlaut(final) }
            final = expandFinal(final)
        } else {
            final = expandFinal(s)   // 零声母（a/o/e/ai/ang/er…）
        }
        guard !final.isEmpty else { return nil }

        let finalIPA: String
        if final == "i" && ["z", "c", "s"].contains(initialKey) {
            finalIPA = "ɹ̩"
        } else if final == "i" && ["zh", "ch", "sh", "r"].contains(initialKey) {
            finalIPA = "ɻ̩"
        } else if let mapped = finals[final] {
            finalIPA = mapped
        } else {
            return nil
        }
        return initialIPA + finalIPA + toneLetter(tone)
    }

    /// y/w 开头零声母音节 → 底层韵母写法（yin→in, yue→üe, wa→ua…）。
    private static func normalizeGlide(_ s: String) -> String {
        let rest = String(s.dropFirst())
        guard let first = rest.first else { return "" }
        if s.first == "y" {
            if first == "u" { return "ü" + String(rest.dropFirst()) }   // yu→ü, yue→üe, yuan→üan, yun→ün
            if first == "i" { return rest }                              // yi→i, yin→in, ying→ing
            return "i" + rest                                            // ya→ia, ye→ie, you→iou, yong→iong…
        } else {   // w
            if rest == "u" { return "u" }                               // wu→u
            return "u" + rest                                           // wa→ua, wei→uei, wen→uen…
        }
    }

    /// j/q/x 之后书写的 u 实为 ü。
    private static func uToUmlaut(_ final: String) -> String {
        if final.first == "u" { return "ü" + String(final.dropFirst()) }
        return final
    }

    /// 韵母正字法缩写还原：iu→iou, ui→uei, un→uen。
    private static func expandFinal(_ final: String) -> String {
        switch final {
        case "iu": return "iou"
        case "ui": return "uei"
        case "un": return "uen"
        default: return final
        }
    }

    private static func matchInitial(_ s: String) -> (String, String)? {
        for (key, ipa) in initials where s.hasPrefix(key) { return (key, ipa) }
        return nil
    }

    private static func isSeparator(_ ch: Character) -> Bool {
        ch == " " || ch == "'" || ch == "\u{2019}" || ch == "-" || ch == "·" || ch == "/" || ch == "."
    }

    private static func toneLetter(_ tone: Int) -> String {
        switch tone {
        case 1: return "˥"
        case 2: return "˧˥"
        case 3: return "˨˩˦"
        case 4: return "˥˩"
        default: return ""   // 轻声
        }
    }

    // MARK: - 映射表

    /// 声母（长匹配优先：zh/ch/sh 在 z/c/s 之前）。
    private static let initials: [(String, String)] = [
        ("zh", "ʈʂ"), ("ch", "ʈʂʰ"), ("sh", "ʂ"),
        ("b", "p"), ("p", "pʰ"), ("m", "m"), ("f", "f"),
        ("d", "t"), ("t", "tʰ"), ("n", "n"), ("l", "l"),
        ("g", "k"), ("k", "kʰ"), ("h", "x"),
        ("j", "tɕ"), ("q", "tɕʰ"), ("x", "ɕ"),
        ("r", "ʐ"), ("z", "ts"), ("c", "tsʰ"), ("s", "s"),
    ]

    /// 韵母（键为底层写法，经 normalizeGlide/uToUmlaut/expandFinal 归一后查表）。
    private static let finals: [String: String] = [
        "a": "a", "o": "o", "e": "ɤ", "ê": "ɛ", "er": "ɚ",
        "ai": "ai", "ei": "ei", "ao": "au", "ou": "ou",
        "an": "an", "en": "ən", "ang": "aŋ", "eng": "əŋ", "ong": "ʊŋ",
        "i": "i", "ia": "ja", "ie": "jɛ", "iao": "jau", "iou": "jou",
        "ian": "jɛn", "in": "in", "iang": "jaŋ", "ing": "iŋ", "iong": "jʊŋ", "io": "jo",
        "u": "u", "ua": "wa", "uo": "wo", "uai": "wai", "uei": "wei",
        "uan": "wan", "uen": "wən", "uang": "waŋ", "ueng": "wəŋ",
        "ü": "y", "üe": "ɥɛ", "üan": "ɥɛn", "ün": "yn",
    ]

    /// 带声调元音 → (基元音, 声调)。轻声无标记。
    private static let toneMap: [Character: (Character, Int)] = [
        "ā": ("a", 1), "á": ("a", 2), "ǎ": ("a", 3), "à": ("a", 4),
        "ē": ("e", 1), "é": ("e", 2), "ě": ("e", 3), "è": ("e", 4),
        "ī": ("i", 1), "í": ("i", 2), "ǐ": ("i", 3), "ì": ("i", 4),
        "ō": ("o", 1), "ó": ("o", 2), "ǒ": ("o", 3), "ò": ("o", 4),
        "ū": ("u", 1), "ú": ("u", 2), "ǔ": ("u", 3), "ù": ("u", 4),
        "ǖ": ("ü", 1), "ǘ": ("ü", 2), "ǚ": ("ü", 3), "ǜ": ("ü", 4),
    ]
}
