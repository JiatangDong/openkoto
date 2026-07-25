import Foundation

/// 青空文庫格式解析（日语 TXT 小说最常见的格式）。
///
/// 处理三件事：
/// - 振り仮名 `｜漢字《かんじ》` / `漢字《かんじ》` → `RubyText` 的注音 run；
/// - 注记 `［＃ここから2字下げ］`、外字 `※［＃…］` → 整体删除（是排版指令，不是正文）；
/// - 页眉说明块与「底本：」之后的书志信息 → 剥离。
///
/// 底本原文见 https://www.aozora.gr.jp/annotation/ 。
public enum AozoraParser {
    /// 判定是否值得按青空格式解析。宁可漏判——普通日语小说被误判会丢掉《》里的内容。
    public static func looksLikeAozora(_ text: String) -> Bool {
        let head = String(text.prefix(4000))
        if head.contains("青空文庫") || text.contains("\n底本：") || text.hasPrefix("底本：") {
            return true
        }
        // ｜…《…》 是青空独有的显式注音标记
        if text.contains("｜") && text.contains("《") && text.contains("》") { return true }
        // ［＃…］ 注记
        return text.contains("［＃")
    }

    /// 剥离页眉说明块与书志信息。
    public static func stripFrontMatter(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")

        // 页眉：两条分隔线之间是【テキスト中に現れる記号について】说明，整块删掉。
        let searchLimit = min(lines.count, 60)
        var separators: [Int] = []
        for index in 0..<searchLimit where isSeparatorLine(lines[index]) {
            separators.append(index)
        }
        if separators.count >= 2 {
            lines.removeSubrange(separators[0]...separators[1])
        }

        // 页脚：「底本：」及其之后全部是书志信息。
        if let colophon = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("底本：")
        }) {
            lines.removeSubrange(colophon..<lines.count)
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 分隔线：10 个以上的连字符/横线，整行没有别的内容。
    private static func isSeparatorLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return false }
        return trimmed.allSatisfy { $0 == "-" || $0 == "─" || $0 == "―" || $0 == "－" }
    }

    /// 注记与外字标记：`※［＃…］` / `［＃…］`。
    private static let annotationPattern = try! NSRegularExpression(pattern: "※?［＃[^］]*］")

    public static func stripAnnotations(_ text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return annotationPattern.stringByReplacingMatches(
            in: text, range: range, withTemplate: "")
    }

    /// 正文 → 带注音文本。按行处理：换行是段落边界，必须保留给切分器。
    public static func parse(_ text: String) -> RubyText {
        var builder = RubyTextBuilder()
        let lines = stripAnnotations(text).components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            parseLine(line, into: &builder)
            if index < lines.count - 1 { builder.appendLineBreak() }
        }
        return builder.build()
    }

    private static func parseLine(_ line: String, into builder: inout RubyTextBuilder) {
        var pending = String.UnicodeScalarView()
        /// `｜` 标记的注音起点在 pending 中的偏移。
        var markerOffset: Int?
        let scalars = Array(line.unicodeScalars)
        var index = 0

        func flushPending() {
            guard !pending.isEmpty else { return }
            builder.appendText(String(pending))
            pending = String.UnicodeScalarView()
        }

        while index < scalars.count {
            let scalar = scalars[index]

            if scalar == "｜" {
                markerOffset = pending.count
                index += 1
                continue
            }

            if scalar == "《" {
                // 读到 》 为止的注音内容
                var reading = String.UnicodeScalarView()
                var cursor = index + 1
                var closed = false
                while cursor < scalars.count {
                    if scalars[cursor] == "》" {
                        closed = true
                        break
                    }
                    reading.append(scalars[cursor])
                    cursor += 1
                }
                guard closed else {
                    // 没有闭合的 《 当普通字符，不丢字。
                    pending.append(scalar)
                    index += 1
                    continue
                }

                let baseStart = markerOffset ?? autoBaseStart(in: pending)
                markerOffset = nil
                let pendingArray = Array(pending)
                let base = String(String.UnicodeScalarView(pendingArray[baseStart...]))
                pending = String.UnicodeScalarView(pendingArray[..<baseStart])

                if base.isEmpty {
                    // 找不到注音对象（如行首直接出现《》），按普通括号内容保留。
                    pending.append("《")
                    pending.append(contentsOf: reading)
                    pending.append("》")
                } else {
                    flushPending()
                    builder.appendAnnotated(base: base, reading: String(reading))
                }
                index = cursor + 1
                continue
            }

            pending.append(scalar)
            index += 1
        }
        flushPending()
    }

    /// 无 `｜` 时的注音对象：紧邻 `《` 之前、与末字**同类**的最长连续串
    /// （汉字含 々ヶ；片假名、平假名、拉丁字母各自成类）。见青空注记规范。
    static func autoBaseStart(in pending: String.UnicodeScalarView) -> Int {
        let scalars = Array(pending)
        guard let last = scalars.last, let baseCategory = category(of: last) else {
            return scalars.count
        }
        var start = scalars.count - 1
        while start > 0, category(of: scalars[start - 1]) == baseCategory {
            start -= 1
        }
        return start
    }

    private enum ScalarCategory {
        case kanji
        case katakana
        case hiragana
        case latin
    }

    private static func category(of scalar: Unicode.Scalar) -> ScalarCategory? {
        let value = scalar.value
        if (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value)
            || (0xF900...0xFAFF).contains(value) || scalar == "々" || scalar == "ヶ"
            || scalar == "ヵ"
        {
            return .kanji
        }
        if (0x30A0...0x30FF).contains(value) || (0xFF66...0xFF9F).contains(value) {
            return .katakana
        }
        if (0x3040...0x309F).contains(value) { return .hiragana }
        if (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value) { return .latin }
        return nil
    }
}
