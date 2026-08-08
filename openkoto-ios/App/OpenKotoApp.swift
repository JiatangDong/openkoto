import SwiftUI
import OKFeatures

@main
struct OpenKotoApp: App {
    // 菜单项直接读写与阅读器同一个 @AppStorage 键。
    //
    // 之所以不引入命令总线：字号与精讲栏本来就是 AppStorage 支撑的全局阅读偏好，
    // 菜单在 App 层改、阅读器在下面读，天然就通了，不需要多一层转发。
    @AppStorage("reader.fontSize") private var fontSize: Double = 18
    @AppStorage("reader.paneCollapsed") private var paneCollapsed = false

    // 每日复习提醒的通知代理。纯 SwiftUI 生命周期没有「点通知进来」的入口，
    // 而 UNUserNotificationCenter.delegate 又必须在 didFinishLaunching 就位，
    // 所以这里补一个 UIKit 代理——它只做挂载与转发，逻辑都在 OKFeatures。
    @UIApplicationDelegateAdaptor(OKNotificationAppDelegate.self) private var notificationDelegate

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        // Mac 窗口默认开得下"正文限宽 + 精讲右栏"两栏（612 + 420 + 边距）。
        .defaultSize(width: 1280, height: 860)
        // 最小尺寸卡在宽屏门槛以上；再窄 OKCanvas 会自动降级回 sheet，不会坏，
        // 只是用户会莫名其妙看到版式跳变。
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu(MenuStrings.reading) {
                Button(MenuStrings.togglePane) { paneCollapsed.toggle() }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                Divider()
                Button(MenuStrings.increaseFontSize) { fontSize = min(fontSize + 2, 32) }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(fontSize >= 32)
                Button(MenuStrings.decreaseFontSize) { fontSize = max(fontSize - 2, 12) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(fontSize <= 12)
            }
        }
    }
}
