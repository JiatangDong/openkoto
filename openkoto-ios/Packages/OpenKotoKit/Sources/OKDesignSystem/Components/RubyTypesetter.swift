import CoreText
import Foundation

/// 带读音的文本片段。设计系统保持零依赖，所以这里是本地值类型，
/// 由 `OKFeatures` 从领域模型（`ReadingRun`）映射过来。
public struct RubyRun: Sendable, Equatable, Hashable {
    public var text: String
    public var reading: String?

    public init(text: String, reading: String? = nil) {
        self.text = text
        self.reading = reading
    }
}

/// 一次排版的结果：整体尺寸 + 每行的 CTLine 与度量。测量与绘制共用同一份，
/// 否则两次断行可能不一致（同样的字符串、同样的宽度也可能因为参数差异断在不同位置）。
public struct RubyLayout {
    public struct Line {
        let line: CTLine
        let ascent: CGFloat
        let descent: CGFloat
        let leading: CGFloat
    }

    public var size: CGSize
    var lines: [Line]
}

/// CoreText 振假名排版。
///
/// **为什么不用 UILabel/TextKit**：它会*画*出 ruby，但布局度量完全无视 ruby——
/// 约束宽 200 时 TextKit 报高度 80，CoreText 实际需要 150。单行 demo 正常，
/// 多行立刻上下相撞、注音溢出到 chip 边框外。必须 `CTTypesetter` 手动逐行 + `CTLineDraw` 自绘。
///
/// 好消息是 `CTLineGetTypographicBounds` 的 ascent 是 ruby-aware 的
/// （24pt「漢字です」无 ruby ascent=21.12，带 ruby=33.12，差值正好 = 字号 × sizeFactor），
/// 所以按 ascent+descent+leading 累加就是正确高度，不需要任何手工留白。
public enum RubyTypesetter {
    /// 注音相对正文的字号比例。
    public static let sizeFactor: CGFloat = 0.5

    /// 断行时的宽度上限兜底：CoreText 对 `.infinity` 表现不稳，用一个足够大的有限值。
    private static let unboundedWidth: CGFloat = 1_000_000

    public static func systemFont(ofSize size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    public static func attributed(
        runs: [RubyRun], font: CTFont, color: CGColor, rubyColor: CGColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in runs where !run.text.isEmpty {
            var attributes: [NSAttributedString.Key: Any] = [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: color,
            ]
            if let reading = run.reading, !reading.isEmpty {
                // overhang 用 .auto：允许注音探到相邻的**无注音**字上方，这是日文排版惯例。
                // 用 .none 的话每个带注音的词都会被撑宽，正文看起来一格一格的很松散。
                let annotation = CTRubyAnnotationCreateWithAttributes(
                    .center, .auto, .before, reading as CFString,
                    [
                        kCTRubyAnnotationSizeFactorAttributeName: sizeFactor,
                        kCTForegroundColorAttributeName: rubyColor,
                    ] as CFDictionary)
                attributes[kCTRubyAnnotationAttributeName as NSAttributedString.Key] = annotation
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }

    /// 逐行排版。`maxWidth` 传 nil 表示不限宽（取自然宽度）。
    ///
    /// 不用 `CTFramesetterSuggestFrameSizeWithConstraints`——它有已知的少算一行问题。
    public static func layout(_ attributed: NSAttributedString, maxWidth: CGFloat?) -> RubyLayout {
        guard attributed.length > 0 else { return RubyLayout(size: .zero, lines: []) }

        let limit = maxWidth.map { min(max($0, 1), unboundedWidth) } ?? unboundedWidth
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var lines: [RubyLayout.Line] = []
        var start = 0
        var height: CGFloat = 0
        var width: CGFloat = 0

        while start < attributed.length {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(limit))
            // 宽度小到放不下一个字时 count 会是 0，硬取一个字符避免死循环。
            let length = count > 0 ? count : 1
            let line = CTTypesetterCreateLine(typesetter, CFRangeMake(start, length))
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let lineWidth = CGFloat(
                CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            lines.append(.init(line: line, ascent: ascent, descent: descent, leading: leading))
            width = max(width, lineWidth)
            height += ascent + descent + leading
            start += length
        }

        return RubyLayout(size: CGSize(width: ceil(width), height: ceil(height)), lines: lines)
    }

    /// 在**已翻转为 y 轴向上**的上下文里从顶部开始逐行绘制。
    public static func draw(_ layout: RubyLayout, in context: CGContext, height: CGFloat) {
        context.textMatrix = .identity
        var y = height
        for line in layout.lines {
            y -= line.ascent
            context.textPosition = CGPoint(x: 0, y: y)
            CTLineDraw(line.line, context)
            y -= line.descent + line.leading
        }
    }
}
