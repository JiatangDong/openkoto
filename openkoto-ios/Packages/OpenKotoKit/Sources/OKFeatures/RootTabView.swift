#if os(iOS)
import SwiftUI
import OKDesignSystem
import OKLocalization

/// 根导航：书库 / 生词本 / 设置 三个 tab（设计文档 §6.1）。
/// 负责把 ThemeManager 计算出的 ThemeTokens 注入 Environment。
public struct RootTabView: View {
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var themeManager = ThemeManager()
    @State private var store = ContentStore.live()
    @State private var appConfig = AppConfigStore()
    @AppStorage("app.interfaceLanguage") private var interfaceLanguage = "system"

    private enum Tab: Hashable { case library, vocabulary, statistics, settings }

    // 截图/UI 测试用（-startTab*）：启动直接落在指定页；默认书库。
    @State private var selection: Tab = {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-startTabSettings") { return .settings }
        if args.contains("-startTabStatistics") { return .statistics }
        return .library
    }()

    public init() {}

    private var theme: ThemeTokens {
        themeManager.tokens(for: systemScheme)
    }

    /// 生效的界面 Locale（跟随系统时用当前系统 Locale）。
    private var activeLocale: Locale {
        interfaceLanguage == "system" ? .current : Locale(identifier: interfaceLanguage)
    }

    public var body: some View {
        // 在任何子视图的 L() 求值之前同步应用界面语言覆盖，保证实时切换当帧生效、无残留旧语言。
        // 放在 body 顶部（而非 .onChange）可消除“子树先按旧 bundle 渲染、onChange 才改全局”的求值顺序竞态。
        let _ = L10n.setOverrideLanguage(interfaceLanguage == "system" ? nil : interfaceLanguage)
        TabView(selection: $selection) {
            LibraryView()
                .tabItem { Label(L("tab.library"), systemImage: "books.vertical") }
                .tag(Tab.library)
            VocabularyView()
                .tabItem { Label(L("tab.vocabulary"), systemImage: "star.square.on.square") }
                .tag(Tab.vocabulary)
            StatisticsView()
                .tabItem { Label(L("tab.statistics"), systemImage: "chart.bar.xaxis") }
                .tag(Tab.statistics)
            SettingsView()
                .tabItem { Label(L("tab.settings"), systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        // 语言切换时改变身份，强制整棵子树（含各 Feature 视图内部的 L()）按新语言重建。
        .id(interfaceLanguage)
        .environment(\.locale, activeLocale)
        .environment(store)
        .environment(appConfig)
        .environment(themeManager)
        .environment(\.theme, theme)
        .tint(theme.primary)
        .preferredColorScheme(themeManager.appearance.colorScheme)
        .task {
            // 先注入真实精讲/翻译入口（未配置模型时抛 .notConfigured），再加载持久化数据。
            store.explanationProvider = { [appConfig] text in
                try await appConfig.explain(text: text)
            }
            store.translationProvider = { [appConfig] text in
                try await appConfig.translate(text: text)
            }
            await store.load()
            await store.importFromInbox()
        }
        // 从后台返回时也排空收件箱（用户可能刚从别处分享内容进来）
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                Task { await store.importFromInbox() }
            }
        }
    }
}

#Preview {
    RootTabView()
}
#endif
