import Foundation
import SwiftUI
import Testing

@testable import OKDesignSystem

/// 宽窄判定的真值表。
///
/// 这些断言就是布局契约本身：`isWide` 一变，全 App 的分栏/多列/限宽同时变。
/// 本机无法脚本旋转模拟器，所以这张表是唯一能自动守住阈值的地方。
@Suite struct OKCanvasWidthTests {
    /// (名称, 宽, 高, 期望 isWide)
    static let devices: [(String, CGFloat, CGFloat, Bool)] = [
        // 窄：iPhone 不论横竖都必须留在 sheet 交互上
        ("iPhone 竖屏", 390, 844, false),
        ("iPhone 16 Pro Max 横屏", 956, 440, false),
        // 窄：小 iPad 竖屏分栏后正文栏太窄，单栏更好读
        ("iPad mini 竖屏", 744, 1133, false),
        ("iPad 11\" 竖屏", 834, 1210, false),
        ("iPad 13\" 横屏 Split 1/2", 683, 1024, false),
        ("iPad 13\" 横屏 Slide Over", 375, 1024, false),
        // 宽
        ("iPad 13\" 竖屏", 1024, 1366, true),
        ("iPad 11\" 横屏", 1133, 834, true),
        ("iPad 13\" 横屏", 1366, 1024, true),
        ("Mac 默认窗口", 1280, 860, true),
        ("Mac 最小窗口", 900, 600, true),
    ]

    @Test(arguments: devices)
    func isWideMatchesTheContract(device: (String, CGFloat, CGFloat, Bool)) {
        let (name, width, height, expected) = device
        let canvas = OKCanvas(width: width, height: height)
        #expect(canvas.isWide == expected, "\(name) \(width)×\(height)")
    }

    /// 高度门槛存在的唯一理由：把 iPhone 横屏挡在分栏之外。
    /// 若哪天有人只保留宽度判定，这条会挂。
    @Test func iPhoneLandscapeIsNarrowDespiteBeingWideEnough() {
        let landscape = OKCanvas(width: 956, height: 440)
        #expect(landscape.width >= OKCanvas.wideWidthThreshold)
        #expect(landscape.isWide == false)
    }

    @Test func extraWideOnlyKicksInAtThreeColumnSizes() {
        #expect(OKCanvas(width: 1133, height: 834).isExtraWide == false)  // iPad 11" 横
        #expect(OKCanvas(width: 1366, height: 1024).isExtraWide == true)  // iPad 13" 横
    }

    /// 兜底值必须是窄的：测量落地前先按宽屏铺会看到一次明显重排。
    @Test func fallbackCanvasIsNarrow() {
        #expect(OKCanvas.compactFallback.isWide == false)
    }
}

@Suite struct OKCanvasMetricsTests {
    @Test func detailPaneWidthIsClamped() {
        // 刚过宽屏门槛：30% = 270，被下限抬到 320
        #expect(OKCanvas(width: 900, height: 600).detailPaneWidth == 320)
        // iPad 13" 横：30% = 409.8，落在区间内
        #expect(OKCanvas(width: 1366, height: 1024).detailPaneWidth == 1366 * 0.30)
        // 超宽外接屏：30% = 720，被上限压到 420，富余全给正文
        #expect(OKCanvas(width: 2400, height: 1400).detailPaneWidth == 420)
    }

    /// 分栏后留给正文的宽度必须还够排一行舒适的 CJK。
    @Test(arguments: [(1024.0, 1366.0), (1133.0, 834.0), (1366.0, 1024.0), (1280.0, 860.0)])
    func widePlusPaneStillLeavesAReadableTextColumn(size: (Double, Double)) {
        let canvas = OKCanvas(width: size.0, height: size.1)
        let textColumn = canvas.width - canvas.detailPaneWidth
        // 18pt 下 30 字/行是 CJK 下限
        #expect(textColumn >= 18 * 30)
    }

    @Test func narrowCanvasAlwaysUsesASingleColumn() {
        let narrow = OKCanvas.compactFallback
        let columns = narrow.adaptiveColumns(minItemWidth: 320, spacing: 10)
        #expect(columns.count == 1)
        if case .adaptive = columns[0].size {
            Issue.record("窄屏必须用 .flexible 单列；.adaptive 在 390pt 下可能意外铺成两列")
        }
    }

    @Test func wideCanvasUsesAdaptiveColumns() {
        let wide = OKCanvas(width: 1366, height: 1024)
        let columns = wide.adaptiveColumns(minItemWidth: 320, spacing: 10)
        guard case .adaptive = columns[0].size else {
            Issue.record("宽屏应使用 .adaptive 让网格自己铺满")
            return
        }
        #expect(wide.columnCount(minItemWidth: 320) == 4)
    }
}

/// 正文可读宽度：这一组是「宽屏下一行 70+ 个汉字」那个 bug 的回归防线。
@Suite struct OKReadableWidthTests {
    @Test(arguments: [12.0, 14, 16, 18, 20, 24, 28, 32])
    func everyFontSizeLandsInTheComfortableBand(fontSize: Double) {
        let width = OKReadableWidth.forFontSize(fontSize)
        let charactersPerLine = width / CGFloat(fontSize)
        // CJK 舒适区 30–45；两端各留一点余量给夹逼后的边界字号
        #expect(charactersPerLine >= 28, "\(fontSize)pt 下每行仅 \(charactersPerLine) 字")
        #expect(charactersPerLine <= 46, "\(fontSize)pt 下每行多达 \(charactersPerLine) 字")
    }

    @Test func clampsAtBothEnds() {
        // 12pt: 12×34=408 → 抬到下限
        #expect(OKReadableWidth.forFontSize(12) == OKReadableWidth.minimum)
        // 32pt: 32×34=1088 → 压到上限
        #expect(OKReadableWidth.forFontSize(32) == OKReadableWidth.maximum)
        // 默认 18pt 落在区间内，按字数线性算
        #expect(OKReadableWidth.forFontSize(18) == 18 * OKReadableWidth.charactersPerLine)
    }

    /// 限宽必须真的比 iPad 横屏的容器宽度窄，否则等于没做。
    @Test func isNarrowerThanAWideContainer() {
        let iPad13Landscape: CGFloat = 1366
        #expect(OKReadableWidth.forFontSize(18) < iPad13Landscape)
        #expect(OKReadableWidth.forFontSize(32) < iPad13Landscape)
    }

    @Test func isMonotonicInFontSize() {
        let widths = [12.0, 16, 18, 24, 32].map(OKReadableWidth.forFontSize)
        #expect(widths == widths.sorted())
    }
}
