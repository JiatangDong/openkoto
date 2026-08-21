import SwiftUI

/// 渲染 AI 返回的 Markdown 文本。
///
/// **为什么不能直接用 `Text(someString)`：** SwiftUI 只对*字面量*
/// （`Text("**粗体**")` 走 `LocalizedStringKey`）解析 Markdown；传变量走的是
/// `Text(_: String)`，原样显示——精讲 prompt 明确要求模型 "Use Markdown formatting"，
/// 于是用户看到的是满屏 `**` 和 `- ` 而不是排版。
///
/// `AttributedString(markdown:)` 也不够：默认解析会把换行和列表结构整个吃掉，
/// 一段带三个要点的讲解会挤成一行。所以这里自己切块（标题/列表/引用/代码块/段落），
/// 每块内部再交给 `AttributedString` 处理行内语法（粗体/斜体/行内代码/链接/删除线）。
public struct MarkdownText: View {
    private let markdown: String
    private let font: Font
    /// 复习卡是居中排版的，默认的 leading 会把答案挤到左边。
    private let alignment: HorizontalAlignment

    public init(
        _ markdown: String, font: Font = .subheadline, alignment: HorizontalAlignment = .leading
    ) {
        self.markdown = markdown
        self.font = font
        self.alignment = alignment
    }

    public var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                blockView(block)
                    .multilineTextAlignment(alignment == .center ? .center : .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text).font(font)

        case .heading(let level, let text):
            inline(text)
                .font(headingFont(for: level))
                .padding(.top, 2)

        case .listItem(let marker, let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(font)
                    .monospacedDigit()
                inline(text).font(font)
            }
            .padding(.leading, CGFloat(depth) * 14)

        case .quote(let text):
            inline(text)
                .font(font)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(.secondary.opacity(0.4))
                        .frame(width: 3)
                }

        case .code(let text):
            Text(text)
                .font(.footnote.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)

        case .divider:
            Divider()
        }
    }

    /// 行内语法交给 Foundation。解析失败（模型偶尔吐出半个链接）退回纯文本——
    /// 显示得朴素一点，也好过整段消失。
    private func inline(_ text: String) -> Text {
        Text(MarkdownInline.attributed(text))
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: .title3.bold()
        case 2: .headline
        default: .subheadline.bold()
        }
    }
}

/// 行内 Markdown → `AttributedString`。抽出来单测，不必起 SwiftUI。
public enum MarkdownInline {
    public static func attributed(_ text: String) -> AttributedString {
        // `.inlineOnlyPreservingWhitespace`：只认行内语法，保留空白。
        // 用 `.full` 的话软换行会被吞掉，而这里的换行是调用方切好块之后**有意**留下的。
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        if let parsed = try? AttributedString(markdown: text, options: options) {
            return parsed
        }
        return AttributedString(text)
    }
}

/// Markdown 块级结构。只覆盖 AI 讲解里真正会出现的那几种。
enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    /// `marker` 已渲染好（"•" 或 "3."）；`depth` 是缩进层级。
    case listItem(marker: String, text: String, depth: Int)
    case quote(String)
    case code(String)
    case divider

    /// 按行切块。段落内的换行保留（模型常用换行分意群），空行分段。
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var inCodeFence = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCodeFence {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                    inCodeFence = false
                } else {
                    flushParagraph()
                    inCodeFence = true
                }
                continue
            }
            if inCodeFence {
                codeLines.append(rawLine)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            // --- / *** / ___ 分隔线。必须在列表判定之前——"---" 也以 "-" 开头。
            if isDivider(trimmed) {
                flushParagraph()
                blocks.append(.divider)
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                continue
            }

            if let item = parseListItem(rawLine) {
                flushParagraph()
                blocks.append(item)
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                blocks.append(
                    .quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                continue
            }

            paragraph.append(trimmed)
        }

        // 模型时不时忘了闭合代码围栏——别把剩下的内容整段吞掉。
        if inCodeFence, !codeLines.isEmpty {
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    private static func isDivider(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        return ["-", "*", "_"].contains { symbol in
            line.allSatisfy { String($0) == symbol }
        }
    }

    private static func parseHeading(_ line: String) -> MarkdownBlock? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }
        guard hashes.count <= 6 else { return nil }
        let rest = line.dropFirst(hashes.count)
        // "#标签" 不是标题——ATX 标题的 # 后必须有空格。
        guard rest.first == " " else { return nil }
        return .heading(
            level: hashes.count, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func parseListItem(_ rawLine: String) -> MarkdownBlock? {
        let indent = rawLine.prefix { $0 == " " || $0 == "\t" }.count
        let depth = min(indent / 2, 3)
        let line = rawLine.trimmingCharacters(in: .whitespaces)

        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
            return .listItem(
                marker: "•", text: String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces),
                depth: depth)
        }

        // 有序列表 "1. " / "2) "
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let after = line.dropFirst(digits.count)
            if let separator = after.first, separator == "." || separator == ")",
                after.dropFirst().first == " "
            {
                return .listItem(
                    marker: "\(digits).",
                    text: String(after.dropFirst(2)).trimmingCharacters(in: .whitespaces),
                    depth: depth)
            }
        }
        return nil
    }
}
