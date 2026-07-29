import SwiftUI

/// 画布尺寸：根视图测一次，全 App 从 Environment 读。
///
/// 为什么不用 `horizontalSizeClass`：
/// ① 它在 macOS 上根本不存在，放进跨平台的 OKDesignSystem 会污染出一堆条件编译；
/// ② Mac Catalyst 下恒为 `.regular`，等于没有信息量；
/// ③ iPad 的 `.regular` 从 744pt（mini 竖屏）一路覆盖到 1366pt（13" 横屏），
///    差 1.8 倍，同一个布局分支没法两头都好看。
///
/// 换成纯宽高判定还有个额外好处：所有决策都是纯函数，能在 macOS 上跑 `swift test`，
/// 与本包"算法层零平台耦合、单测全覆盖"的既有做法一致。
public struct OKCanvas: Sendable, Equatable {
    public var width: CGFloat
    public var height: CGFloat

    public init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }

    /// iPhone 竖屏兜底：根视图测量落地之前的环境初值。
    /// 取窄值而非宽值——测量还没到就先按宽屏铺，会看到一次明显的重排。
    public static let compactFallback = OKCanvas(width: 390, height: 844)

    // MARK: - 宽窄判定

    /// 宽屏的宽度门槛。
    ///
    /// 取 900 而不是 820：iPad 11" / 10 代竖屏是 820–834pt，分栏后正文栏只剩 ~480pt，
    /// 18pt 字号下一行 26 个汉字，低于 CJK 排版下限（30–45）。那些尺寸保持单栏 + sheet
    /// 更好读，真想要分栏把 iPad 横过来就有。
    public static let wideWidthThreshold: CGFloat = 900

    /// 宽屏的高度门槛。
    ///
    /// 专门把 iPhone 横屏（如 956×440）挡在外面。iPhone 上不论怎么转都必须保持今天的
    /// 半屏 sheet 交互——分栏在 440pt 的高度里放不下两栏内容。
    public static let wideHeightThreshold: CGFloat = 500

    public static func isWide(width: CGFloat, height: CGFloat) -> Bool {
        width >= wideWidthThreshold && height >= wideHeightThreshold
    }

    public var isWide: Bool { Self.isWide(width: width, height: height) }

    /// 够不够排三栏（视频 + 字幕 + 精讲）。1200 以下三栏各 400pt 都局促。
    public var isExtraWide: Bool { width >= 1200 }

    // MARK: - 派生尺寸

    /// 精讲右栏宽度：随画布缩放，夹在 320…420。
    ///
    /// 下限 320 是精讲内容（词汇卡 + 语法卡）不被挤成一条竖串的最小宽度；
    /// 上限 420 保证画布再宽，多出来的空间都归正文。
    public var detailPaneWidth: CGFloat { min(max(width * 0.30, 320), 420) }

    /// 自适应网格列定义：宽屏按 `minItemWidth` 自动铺满，窄屏恒单列。
    ///
    /// 窄屏显式用 `.flexible()` 而不是也走 `.adaptive`——后者在 390pt 宽下
    /// 若 minItemWidth 偏小会意外铺成两列，把 iPhone 的单列卡片流改坏。
    public func adaptiveColumns(minItemWidth: CGFloat, spacing: CGFloat) -> [GridItem] {
        isWide
            ? [GridItem(.adaptive(minimum: minItemWidth), spacing: spacing)]
            : [GridItem(.flexible(), spacing: spacing)]
    }

    /// 按最小项宽能铺几列。给需要自己算数量的地方用（如空态占位）。
    public func columnCount(minItemWidth: CGFloat) -> Int {
        max(1, Int(width / max(minItemWidth, 1)))
    }

    /// 书库/搜索结果的卡片列。两处共用同一个定义，免得列宽在两个页面之间漂。
    /// 320 是卡片放得下「标题 + 日期 + 句数徽章」而不换行的下限。
    public var libraryColumns: [GridItem] {
        adaptiveColumns(minItemWidth: 320, spacing: 10)
    }

    /// 统计看板的列数。窄屏恒为 1 列。
    ///
    /// 最小列宽 460 是实测出来的：330pt 宽的卡里放 30 根柱子 + 日期轴，
    /// Swift Charts 会把 X 轴标签截成没有信息量的「0…」。460 起才读得出日期。
    /// 上限 3 列是防超宽外接屏铺出一排细长条。
    public var statisticsColumnCount: Int {
        isWide ? min(columnCount(minItemWidth: 460), 3) : 1
    }
}
