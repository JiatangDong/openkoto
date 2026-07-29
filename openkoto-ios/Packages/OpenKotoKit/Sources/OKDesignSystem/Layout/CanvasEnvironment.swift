import SwiftUI

public extension EnvironmentValues {
    @Entry var okCanvas = OKCanvas.compactFallback
}

public extension View {
    /// 测量自身尺寸并发布到 Environment。**只在根视图调用一次。**
    ///
    /// 全 App 的宽窄判定共用这一个真值，避免各页面自己散着摆 GeometryReader
    /// 各算各的、阈值还会漂。
    func publishingCanvasMetrics() -> some View {
        modifier(CanvasMetricsPublisher())
    }
}

private struct CanvasMetricsPublisher: ViewModifier {
    @State private var measured = OKCanvas.compactFallback

    func body(content: Content) -> some View {
        content
            .environment(\.okCanvas, OKCanvasOverride.value ?? measured)
            // 用 onGeometryChange 而不是 GeometryReader：后者会吃掉父布局的对齐、
            // 强制子视图 topLeading，包住整个 App 会引起大面积布局回归。
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                measured = OKCanvas(width: size.width, height: size.height)
            }
    }
}

/// 截图验证用的画布覆盖。
///
/// 本机没有 cliclick/pyobjc、osascript 也没有辅助功能授权，脚本既点不了 UI
/// 也旋转不了模拟器。靠这两个启动参数就能在任意一台设备上分别截到宽屏、窄屏两条分支。
enum OKCanvasOverride {
    static let value: OKCanvas? = {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-okForceWideCanvas") {
            return OKCanvas(width: 1366, height: 1024)  // iPad 13" 横屏
        }
        if args.contains("-okForceCompactCanvas") {
            return OKCanvas.compactFallback
        }
        return nil
    }()
}
