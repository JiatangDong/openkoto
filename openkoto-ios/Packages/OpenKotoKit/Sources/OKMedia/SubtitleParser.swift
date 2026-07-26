import Foundation

/// SRT / WebVTT 解析成统一的 `TimedToken` 流。
///
/// 这里只负责「把字幕文件读成干净的 token」，**不做任何切句**——
/// 切句是 `TranscriptAligner` 的事。桌面端把两件事合成一件（1 cue = 1 segment），
/// 于是字幕行宽直接决定了学习单元的粒度。
public enum SubtitleParser {
    public enum Format: Sendable {
        case srt
        case vtt

        public static func infer(fromExtension ext: String) -> Format? {
            switch ext.lowercased() {
            case "srt": .srt
            case "vtt", "webvtt": .vtt
            default: nil
            }
        }
    }

    /// 末条 cue 缺少结束时间时给的兜底时长。
    private static let trailingCueDuration: Double = 8

    public static func parse(_ raw: String, format: Format) -> [TimedToken] {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")

        var cues: [TimedToken] = []
        for block in normalized.components(separatedBy: "\n\n") {
            guard let cue = parseBlock(block, format: format) else { continue }
            cues.append(cue)
        }
        return dedupingRollingRepeats(fillingMissingEnds(cues))
    }

    // MARK: - 单个 block

    private static func parseBlock(_ block: String, format: Format) -> TimedToken? {
        let lines = block.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        // 时间行不写死在第几行：SRT 有序号行，VTT 可能有 cue 标识行，
        // 也可能两者都没有。桌面端 youtube.rs 硬编码 lines[1] 会静默丢 cue。
        guard let timeLineIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
            return nil
        }
        guard let (start, end) = parseTimeLine(lines[timeLineIndex]) else { return nil }

        let body = lines[(timeLineIndex + 1)...].map { stripMarkup($0) }
            .filter { !$0.isEmpty }
        guard !body.isEmpty else { return nil }

        // cue 内换行是**显示折行，不是语义边界** —— 按接缝规则合并，绝不保留成 "\n"。
        // 保留成 "\n" 会让切分器把它当段落边界，句子就无法跨行合并了。
        let text = TokenJoiner.join(body)
        guard !text.isEmpty else { return nil }
        return TimedToken(text: text, start: start, end: end)
    }

    /// `00:00:01,000 --> 00:00:03,500`（SRT）/ `00:01.000 --> 00:03.500 align:start`（VTT）。
    private static func parseTimeLine(_ line: String) -> (Double, Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count >= 2 else { return nil }
        // VTT 的 cue setting（align/position/line…）跟在结束时间后面，用空格隔开
        let endToken = parts[1].trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces).first ?? ""
        guard let start = parseTimestamp(parts[0].trimmingCharacters(in: .whitespaces)),
            let end = parseTimestamp(endToken)
        else { return nil }
        return (start, max(end, start))
    }

    /// 接受 `HH:MM:SS,mmm` / `HH:MM:SS.mmm` / `MM:SS.mmm`。
    ///
    /// 解析失败返回 nil 让整条 cue 被丢弃，**绝不静默降级成 0.0**——
    /// 桌面端 `parse_time_str` 的 `unwrap_or(0.0)` 会让整条字幕跳到 0 秒且毫无提示。
    static func parseTimestamp(_ raw: String) -> Double? {
        let text = raw.replacingOccurrences(of: ",", with: ".")
        let parts = text.components(separatedBy: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let value = Double(part), value.isFinite, value >= 0 else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    /// 剥掉字幕标记：VTT 的 `<c>`/`<v Speaker>`/内联时间戳、HTML 标签、ASS 的 `{\an8}`。
    static func stripMarkup(_ line: String) -> String {
        var result = ""
        var depth = 0
        var braceDepth = 0
        for character in line {
            switch character {
            case "<": depth += 1
            case ">": depth = max(0, depth - 1)
            case "{": braceDepth += 1
            case "}": braceDepth = max(0, braceDepth - 1)
            default:
                if depth == 0 && braceDepth == 0 { result.append(character) }
            }
        }
        return
            result
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 清洗

    /// 结束时间缺失/为零时长的 cue，用下一条的起点补齐。
    private static func fillingMissingEnds(_ cues: [TimedToken]) -> [TimedToken] {
        var result = cues
        for index in result.indices {
            guard result[index].end <= result[index].start else { continue }
            let next = index + 1 < result.count ? result[index + 1].start : nil
            result[index].end = next ?? (result[index].start + trailingCueDuration)
        }
        return result
    }

    /// YouTube 自动字幕的滚动重复：每条 cue 会把上一条的尾部再显示一遍。
    ///
    /// 不去重的话，文稿里会有大量重复句子，精讲和生词全被污染。
    /// 只保留增量部分，时间按字符比例取该 cue 的后半段。
    private static func dedupingRollingRepeats(_ cues: [TimedToken]) -> [TimedToken] {
        var result: [TimedToken] = []
        for cue in cues {
            guard let previous = result.last else {
                result.append(cue)
                continue
            }
            if cue.text == previous.text { continue }
            if cue.text.hasPrefix(previous.text), previous.text.count > 1 {
                let suffix = String(cue.text.dropFirst(previous.text.count))
                    .trimmingCharacters(in: .whitespaces)
                guard !suffix.isEmpty else { continue }
                let ratio = Double(previous.text.count) / Double(cue.text.count)
                let offset = (cue.end - cue.start) * ratio
                result.append(
                    TimedToken(text: suffix, start: cue.start + offset, end: cue.end))
                continue
            }
            result.append(cue)
        }
        return result
    }
}
