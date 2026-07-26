import Foundation
import OKModels

/// LLM 结构化输出的提取与修复（设计文档 §4.4，可用性关键）。
/// 1:1 移植桌面 `ai_service.rs` 的 `extract_json` / `repair_json`。
/// repair 全程在 `Unicode.Scalar` 上迭代，对齐 Rust `Vec<char>`。
public enum LLMJSONExtractor {

    /// 从模型响应中提取 JSON 候选串（对齐 `extract_json`）。
    public static func extractJSON(_ content: String) -> String {
        // 1. 显式 ```json 代码块（闭合 ``` 取最后一个，对齐 Rust rfind）。
        if let start = content.range(of: "```json") {
            let after = content[start.upperBound...]
            if let end = after.range(of: "```", options: .backwards) {
                return content[start.upperBound..<end.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // 2. 通用 ``` 代码块（闭合 ``` 取第一个，对齐 Rust find）。
        if let start = content.range(of: "```") {
            let after = content[start.upperBound...]
            if let end = after.range(of: "```") {
                return content[start.upperBound..<end.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // 3. 花括号配平扫描，定位主 JSON 对象。
        if let braceStart = content.firstIndex(of: "{") {
            var balance = 0
            var idx = braceStart
            while idx < content.endIndex {
                switch content[idx] {
                case "{": balance += 1
                case "}":
                    balance -= 1
                    if balance == 0 {
                        return String(content[braceStart...idx])
                    }
                default: break
                }
                idx = content.index(after: idx)
            }
        }

        // 4. 兜底：trim + 去除首尾代码块围栏。
        var trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```json") {
            trimmed.removeFirst("```json".count)
        } else if trimmed.hasPrefix("```") {
            trimmed.removeFirst("```".count)
        }
        if trimmed.hasSuffix("```") {
            trimmed.removeLast("```".count)
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 修复 LLM 常见 JSON 错误（对齐 `repair_json`）：
    /// 字符串内未转义换行→`\n`、智能引号归一、闭引号启发式转义内部引号、去尾逗号。
    public static func repairJSON(_ jsonStr: String) -> String {
        let scalars = Array(jsonStr.unicodeScalars)
        let len = scalars.count
        var repaired = String.UnicodeScalarView()
        var inString = false
        var i = 0

        while i < len {
            let ch = scalars[i]

            if inString {
                if ch == "\\" {
                    // 转义序列——原样复制。
                    repaired.append(ch)
                    i += 1
                    if i < len { repaired.append(scalars[i]) }
                } else if ch == "\"" || ch == "\u{201D}" {
                    // 启发式：这是结构性闭引号还是内容引号？
                    // 合法 JSON 中闭引号后的下一个非空白必须是 , : } ] 或 EOF。
                    var j = i + 1
                    while j < len,
                          scalars[j] == " " || scalars[j] == "\t"
                            || scalars[j] == "\r" || scalars[j] == "\n" {
                        j += 1
                    }
                    if j >= len
                        || scalars[j] == "," || scalars[j] == ":"
                        || scalars[j] == "}" || scalars[j] == "]" {
                        inString = false
                        repaired.append("\"")
                    } else {
                        // 字符串值内部的内容引号——转义之。
                        repaired.append("\\")
                        repaired.append("\"")
                    }
                } else if ch == "\n" {
                    repaired.append("\\")
                    repaired.append("n")
                } else if ch == "\r" {
                    // 跳过
                } else {
                    repaired.append(ch)
                }
            } else {
                // 字符串外：ASCII " 或智能左引号视为开引号。
                if ch == "\"" || ch == "\u{201C}" {
                    inString = true
                    repaired.append("\"")
                } else {
                    repaired.append(ch)
                }
            }

            i += 1
        }

        var result = String(repaired)
        // 去尾逗号
        result = result.replacingOccurrences(
            of: ",(\\s*\\})", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(
            of: ",(\\s*\\])", with: "$1", options: .regularExpression)
        return result
    }

    /// AI 精讲响应的 snake_case JSON key（grammar_points/cultural_context/...）→ 领域模型。
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// 提取 → 解析 → 修复 → 再解析；两次失败抛带 requestID 的脱敏错误
    /// （对齐 `segment_translate_explain` 的解析回退管线）。
    /// 原始模型响应只允许出现在用户主动开启的诊断导出，不进入常规日志（设计文档 §4.4）。
    ///
    /// 泛型化是为了让单词释义复用同一条回退管线——JSON 修复逻辑只该有一份。
    public static func parse<T: Decodable>(
        _ type: T.Type, from content: String, requestID: UUID
    ) throws -> T {
        let candidate = extractJSON(content)

        if let data = candidate.data(using: .utf8),
            let value = try? decoder.decode(type, from: data)
        {
            return value
        }

        let repaired = repairJSON(candidate)
        if let data = repaired.data(using: .utf8),
            let value = try? decoder.decode(type, from: data)
        {
            return value
        }

        throw AIClientError.malformedResponse(requestID: requestID)
    }

    public static func parseSegmentExplanation(
        from content: String, requestID: UUID
    ) throws -> SegmentExplanation {
        try parse(SegmentExplanation.self, from: content, requestID: requestID)
    }
}
