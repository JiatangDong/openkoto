import SwiftUI

/// 正文可读宽度。
///
/// 不限宽的后果：iPad 13" 横屏一行 70+ 个汉字，眼睛扫回行首会跳行。
/// 这是一个阅读 App 最不该犯的错，也是宽屏适配里收益最大的一处改动。
public enum OKReadableWidth {
    /// 一行放多少个全角字。
    ///
    /// CJK 排版舒适区是 30–45 字/行，取 34 偏保守一侧；换算到拉丁文约 68 个字符，
    /// 落在 45–75 字符舒适区的上沿——中日文和英文用同一个值即可两头都不难看。
    public static let charactersPerLine: CGFloat = 34

    /// 下限：12pt 最小字号下 12×34=408，抬到 420，免得窄成一条。
    public static let minimum: CGFloat = 420

    /// 上限：32pt 最大字号下 32×34=1088 会超出 13" iPad 横屏分栏后的正文栏（~956pt），
    /// 压到 960。超过这个宽度，继续放宽只会让行更难扫。
    public static let maximum: CGFloat = 960

    /// 全角字宽 ≈ 1em = fontSize，所以行宽 ≈ fontSize × 字数。
    public static func forFontSize(_ fontSize: Double) -> CGFloat {
        min(max(CGFloat(fontSize) * charactersPerLine, minimum), maximum)
    }
}

public extension View {
    /// 正文限宽 + 居中。
    ///
    /// 两层 frame 是标准写法：内层夹住内容宽度，外层撑满容器让它居中。
    /// 只写内层内容会贴左，只写外层则没有限宽效果。
    func readableTextWidth(fontSize: Double) -> some View {
        frame(maxWidth: OKReadableWidth.forFontSize(fontSize))
            .frame(maxWidth: .infinity)
    }
}
