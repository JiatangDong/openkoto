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

    // 首启引导门控。向导状态必须在这里持有（.id 边界之外）：
    // 语言步切界面语言触发子树重建时，步骤进度与已输入内容才能存活。
    @AppStorage(OnboardingGate.completedKey) private var onboardingCompleted = false
    @State private var onboarding = OnboardingState()

    private enum Tab: Hashable { case library, vocabulary, statistics, settings }

    /// URL 是否落在本 App 的 `Documents/Inbox/` 里（系统为"用 XX 打开"留下的副本）。
    static func isInDocumentsInbox(_ url: URL) -> Bool {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first
        else { return false }
        let inbox = documents.appendingPathComponent("Inbox").standardizedFileURL
        return url.standardizedFileURL.path.hasPrefix(inbox.path + "/")
    }

    // 截图/UI 测试用（-startTab*）：启动直接落在指定页；默认书库。
    // 配合 -app.onboarding.completed YES（NSArgumentDomain）可跳过首启引导。
    @State private var selection: Tab = {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-startTabSettings") { return .settings }
        if args.contains("-startTabStatistics") { return .statistics }
        return .library
    }()

    public init() {
        // 老用户（升级前已有模型配置）在首帧求值前直接标记完成，避免向导闪现。
        OnboardingGate.migrateIfNeeded()
    }

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
        Group {
            if onboardingCompleted {
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
                // 生词卡「回到原句」发起的跳转：先把 tab 切过去，
                // 落到哪一句由 LibraryView 消费同一个请求决定。
                .onChange(of: store.pendingJump) {
                    if store.pendingJump != nil { selection = .library }
                }
            } else {
                OnboardingView(state: onboarding) {
                    withAnimation { onboardingCompleted = true }
                }
            }
        }
        // 语言切换时改变身份，强制整棵子树（含各 Feature 视图内部的 L()）按新语言重建。
        .id(interfaceLanguage)
        // 从设置页重看引导：向导状态是长驻的，不重置会直接落在上次的"完成"页。
        .onChange(of: onboardingCompleted) {
            if !onboardingCompleted { onboarding.reset() }
        }
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
            store.glossProvider = { [appConfig] word, sentence in
                try await appConfig.gloss(word: word, sentence: sentence)
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
        // "用 OpenKoto 打开"：LSSupportsOpeningDocumentsInPlace = NO，
        // 所以系统把文件拷进 Documents/Inbox 再交给我们。
        // 必须走 security-scoped 访问，导入完把系统留下的副本删掉。
        .onOpenURL { url in
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                await store.importFile(at: url)
                // 只删自己 Inbox 里的副本。万一哪天 plist 那个键被改成 YES，
                // 这里拿到的就是用户在"文件"App 里的原件——删了就是数据丢失。
                if Self.isInDocumentsInbox(url) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }
}

#Preview {
    RootTabView()
}
#endif
