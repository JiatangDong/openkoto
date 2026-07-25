#if os(iOS)
import CoreText
import SwiftUI
import UIKit

/// 用 CoreText 自绘的振假名文本视图。
///
/// 三个必须项（少一个都会出问题）：
/// - `isUserInteractionEnabled = false`：否则 UIView 的 hitTest 会吃掉外层 SwiftUI Button 的点击；
/// - `isAccessibilityElement = false`：让外层 chip 的 accessibilityLabel（原文）生效，
///   VoiceOver 不会读出「漢字かんじ」这种正文与注音夹杂的串；
/// - `sizeThatFits` 必须支持"不限宽"与"限宽"两种问法，这正是 `FlowLayout` 的询问契约。
final class RubyUIView: UIView {
    private var attributed = NSAttributedString()
    /// 按宽度记住排版结果。`FlowLayout` 每次布局会对同一个 subview 问多次尺寸，
    /// 再加上一次绘制——没有这层记忆，一屏 50 个句子就是上百次重复排版。
    private var layouts: [CGFloat: RubyLayout] = [:]
    /// 比较输入而不是比较 `NSAttributedString`：CTRubyAnnotation 的相等性是按对象身份判的，
    /// 拿它比会永远不等，缓存等于白做。
    private var appliedInput: Input?

    private struct Input: Equatable {
        var runs: [RubyRun]
        var fontSize: CGFloat
        var color: UIColor
        var rubyColor: UIColor
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(runs: [RubyRun], fontSize: CGFloat, color: UIColor, rubyColor: UIColor) {
        let input = Input(runs: runs, fontSize: fontSize, color: color, rubyColor: rubyColor)
        guard input != appliedInput else { return }
        appliedInput = input
        attributed = RubyTypesetter.attributed(
            runs: runs, font: RubyTypesetter.systemFont(ofSize: fontSize),
            color: color.cgColor, rubyColor: rubyColor.cgColor)
        layouts.removeAll()
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
    }

    /// `width` 为 nil 或非有限值表示不限宽（取自然宽度）。
    func layout(maxWidth: CGFloat?) -> RubyLayout {
        let bounded = maxWidth.flatMap { $0.isFinite ? $0 : nil }
        let key = bounded.map { ($0 * 2).rounded() / 2 } ?? -1
        if let cached = layouts[key] { return cached }
        let layout = RubyTypesetter.layout(attributed, maxWidth: bounded)
        layouts[key] = layout
        return layout
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), attributed.length > 0 else { return }
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)  // CoreText 是 y 轴向上的坐标系
        RubyTypesetter.draw(layout(maxWidth: bounds.width), in: context, height: bounds.height)
    }
}

/// SwiftUI 包装。颜色与字号由调用方从 `@Environment(\.theme)` 取好传进来——
/// `UIViewRepresentable` 的 environment 传播时机比 `updateUIView` 绕，不要在这里读。
struct RubyLabel: UIViewRepresentable {
    let runs: [RubyRun]
    let fontSize: CGFloat
    let color: Color
    let rubyColor: Color

    init(runs: [RubyRun], fontSize: CGFloat, color: Color, rubyColor: Color) {
        self.runs = runs
        self.fontSize = fontSize
        self.color = color
        self.rubyColor = rubyColor
    }

    func makeUIView(context: Context) -> RubyUIView {
        let view = RubyUIView()
        view.apply(
            runs: runs, fontSize: fontSize,
            color: UIColor(color), rubyColor: UIColor(rubyColor))
        return view
    }

    func updateUIView(_ view: RubyUIView, context: Context) {
        view.apply(
            runs: runs, fontSize: fontSize,
            color: UIColor(color), rubyColor: UIColor(rubyColor))
    }

    /// `.unspecified`（width == nil）给自然宽度，限宽给折行后的高度——
    /// `FlowLayout.measuredSize` 正是这两次问法。
    func sizeThatFits(
        _ proposal: ProposedViewSize, uiView: RubyUIView, context: Context
    ) -> CGSize? {
        uiView.layout(maxWidth: proposal.width).size
    }
}
#endif
