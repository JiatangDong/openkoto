#if os(iOS)
import SwiftUI
import OKDesignSystem
import OKLocalization

// MARK: - 界面语言（第一步）

/// 引导的第一屏：先把界面语言定下来，后面的欢迎语才有意义。
///
/// 这一屏的文字必须**不依赖用户已经看得懂某种语言**：
/// 标题三语并列且不本地化，选项用各语言自己的写法（English / 简体中文 / 日本語）。
/// 系统语言不在这三种里时整个 App 会退回英文——那正是这一屏要解决的场景。
struct OnboardingAppLanguageStep: View {
    @Bindable var state: OnboardingState
    @Environment(\.theme) private var theme

    @AppStorage("app.interfaceLanguage") private var interfaceLanguage = "system"

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "globe")
                        .font(.system(size: 40))
                        .foregroundStyle(theme.primary)
                        .frame(width: 80, height: 80)
                        .background(
                            theme.primary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: OKRadius.sheet))
                        .padding(.top, 24)

                    // 不本地化：这一屏的读者可能一种都看不懂，只能三语并列。
                    Text(verbatim: "Language · 语言 · 言語")
                        .font(.largeTitle.bold())
                        .foregroundStyle(theme.foreground)

                    VStack(spacing: 0) {
                        ForEach(Array(LanguageOptions.interface.enumerated()), id: \.element.code) {
                            index, item in
                            if index > 0 { Divider() }
                            languageRow(code: item.code, name: item.name)
                        }
                        Divider()
                        // 「跟随系统」只能用当前 bundle 的语言写，所以排在最后：
                        // 上面三个看得懂的选项才是主路径。
                        languageRow(
                            code: "system", name: L("settings.interfaceLanguage.system"))
                    }
                    .background(theme.card, in: RoundedRectangle(cornerRadius: OKRadius.card))
                    .overlay(
                        RoundedRectangle(cornerRadius: OKRadius.card)
                            .strokeBorder(theme.border, lineWidth: 1))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            Button(L("onboarding.step.continue")) {
                state.advance()
            }
            .buttonStyle(.okPrimary)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
        }
    }

    private func languageRow(code: String, name: String) -> some View {
        Button {
            interfaceLanguage = code
        } label: {
            HStack {
                Text(name)
                    .font(.body)
                    .foregroundStyle(theme.foreground)
                Spacer()
                if interfaceLanguage == code {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.primary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(interfaceLanguage == code ? .isSelected : [])
    }
}

// MARK: - 欢迎

struct OnboardingWelcomeStep: View {
    @Bindable var state: OnboardingState
    @Environment(\.theme) private var theme

    /// 一页 = 一个主题 + 三条。图标与文案 key 放在一起，加页就是加一条数组元素。
    private struct Page: Identifiable {
        let id: Int
        let symbol: String
        let titleKey: String.LocalizationValue
        let points: [(symbol: String, key: String.LocalizationValue)]
    }

    private static let pages: [Page] = [
        Page(
            id: 0, symbol: "books.vertical", titleKey: "onboarding.welcome.page1.title",
            points: [
                ("text.book.closed", "onboarding.welcome.page1.point1"),
                ("play.rectangle", "onboarding.welcome.page1.point2"),
                ("square.and.arrow.up", "onboarding.welcome.page1.point3"),
                ("magnifyingglass", "onboarding.welcome.page1.point4"),
            ]),
        Page(
            id: 1, symbol: "text.magnifyingglass", titleKey: "onboarding.welcome.page2.title",
            points: [
                ("text.line.first.and.arrowtriangle.forward", "onboarding.welcome.page2.point1"),
                ("character.phonetic", "onboarding.welcome.page2.point2"),
                ("rectangle.on.rectangle", "onboarding.welcome.page2.point3"),
            ]),
        Page(
            id: 2, symbol: "sparkles", titleKey: "onboarding.welcome.page3.title",
            points: [
                ("text.bubble", "onboarding.welcome.page3.point1"),
                ("character.book.closed", "onboarding.welcome.page3.point2"),
                ("hand.tap", "onboarding.welcome.page3.point3"),
                ("lock.shield", "onboarding.welcome.page3.point4"),
            ]),
        Page(
            id: 3, symbol: "brain.head.profile", titleKey: "onboarding.welcome.page4.title",
            points: [
                ("square.stack.3d.up", "onboarding.welcome.page4.point1"),
                ("repeat.circle", "onboarding.welcome.page4.point2"),
                ("chart.bar.xaxis", "onboarding.welcome.page4.point3"),
            ]),
    ]

    @State private var page = 0

    /// 功能全列出来，但**流程不变长**：仍然是同一个步骤，赶时间的人看完第一页直接点继续，
    /// 好奇的人左滑看完四页。新增点击次数为 0。
    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(Self.pages) { pageContent($0).tag($0.id) }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // 自己画页码点：系统那套在浅色主题背景上对比度极低，几乎看不见。
            HStack(spacing: 7) {
                ForEach(Self.pages) { item in
                    Capsule()
                        .fill(item.id == page ? theme.primary : theme.border)
                        .frame(width: item.id == page ? 18 : 7, height: 7)
                        .animation(.snappy, value: page)
                }
            }
            .padding(.bottom, 12)

            Button(L(page == Self.pages.count - 1
                ? "onboarding.welcome.cta" : "onboarding.step.continue")) {
                if page < Self.pages.count - 1 {
                    withAnimation { page += 1 }
                } else {
                    state.advance()
                }
            }
            .buttonStyle(.okPrimary)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
        }
    }

    private func pageContent(_ content: Page) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: content.symbol)
                    .font(.system(size: 40))
                    .foregroundStyle(theme.primary)
                    .frame(width: 80, height: 80)
                    .background(
                        theme.primary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: OKRadius.sheet))
                    .padding(.top, 24)

                VStack(alignment: .leading, spacing: 8) {
                    // 第一页保留原来的欢迎语，后三页只有主题标题
                    if content.id == 0 {
                        Text(L("onboarding.welcome.title"))
                            .font(.largeTitle.bold())
                            .foregroundStyle(theme.foreground)
                    }
                    Text(L(content.titleKey))
                        .font(content.id == 0 ? .title3 : .largeTitle.bold())
                        .foregroundStyle(
                            content.id == 0 ? theme.mutedForeground : theme.foreground)
                }

                VStack(alignment: .leading, spacing: 16) {
                    ForEach(content.points, id: \.symbol) { point in
                        welcomePoint(point.symbol, L(point.key))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }

    private func welcomePoint(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(theme.primary)
                .frame(width: 28, height: 28)
                .background(theme.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: OKRadius.chip))
            Text(text)
                .font(.callout)
                .foregroundStyle(theme.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 语言

struct OnboardingLanguageStep: View {
    @Bindable var state: OnboardingState
    @Environment(\.theme) private var theme
    @Environment(\.locale) private var locale

    // 界面语言已在第一步定好，这里只挑讲解语言（AI 用哪种语言给你讲）。
    @AppStorage("learning.targetLanguage") private var targetLanguage = "zh-CN"

    var body: some View {
        OnboardingStepLayout(
            title: L("onboarding.language.title"),
            subtitle: L("onboarding.language.subtitle")
        ) {
            ThemedCard {
                HStack {
                    Text(L("settings.explanationLanguage"))
                        .foregroundStyle(theme.foreground)
                    Spacer()
                    Picker(L("settings.explanationLanguage"), selection: $targetLanguage) {
                        ForEach(LanguageOptions.target, id: \.self) { code in
                            Text(LanguageOptions.targetDisplayName(code, locale: locale)).tag(code)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(theme.primary)
                }
            }
            // 不复用 settings.language.footer：那句同时在讲界面语言，
            // 而界面语言已经在第一步选过了，这里再提只会让人以为漏了什么。
        } footer: {
            Button(L("onboarding.step.continue")) {
                state.advance()
            }
            .buttonStyle(.okPrimary)
        }
    }
}

// MARK: - 皮肤

struct OnboardingThemeStep: View {
    @Bindable var state: OnboardingState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var themeManager = themeManager
        OnboardingStepLayout(
            title: L("onboarding.theme.title"),
            subtitle: L("onboarding.theme.subtitle")
        ) {
            HStack(spacing: 12) {
                ForEach(ThemeID.allCases) { themeID in
                    ThemeSwatchView(
                        themeID: themeID,
                        isSelected: themeManager.themeID == themeID
                    ) {
                        themeManager.themeID = themeID
                    }
                }
            }

            Picker(L("settings.appearance.mode"), selection: $themeManager.appearance) {
                Text(L("settings.appearance.system")).tag(AppearanceMode.system)
                Text(L("settings.appearance.light")).tag(AppearanceMode.light)
                Text(L("settings.appearance.dark")).tag(AppearanceMode.dark)
            }
            .pickerStyle(.segmented)
        } footer: {
            Button(L("onboarding.step.continue")) {
                state.advance()
            }
            .buttonStyle(.okPrimary)
        }
    }
}

/// 单个皮肤的预览色板：亮色底 + 主色/强调色圆点 + 暗色底圆点。
struct ThemeSwatchView: View {
    let themeID: ThemeID
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(themeID.palette.light.primary)
                    Circle().fill(themeID.palette.light.accent)
                    Circle().fill(themeID.palette.dark.background)
                }
                .frame(height: 22)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    themeID.palette.light.background,
                    in: RoundedRectangle(cornerRadius: OKRadius.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: OKRadius.card)
                        .strokeBorder(themeID.palette.light.border, lineWidth: 1)
                )

                Text(themeID.displayName)
                    .font(.footnote.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? theme.primary : theme.mutedForeground)
            }
            .padding(6)
            .overlay(
                RoundedRectangle(cornerRadius: OKRadius.sheet)
                    .strokeBorder(isSelected ? theme.ring : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - 完成

struct OnboardingDoneStep: View {
    @Bindable var state: OnboardingState
    let onFinish: () -> Void

    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.theme) private var theme
    @Environment(\.locale) private var locale

    @AppStorage("app.interfaceLanguage") private var interfaceLanguage = "system"
    @AppStorage("learning.targetLanguage") private var targetLanguage = "zh-CN"

    var body: some View {
        OnboardingStepLayout(
            title: L("onboarding.done.title"),
            subtitle: L("onboarding.done.subtitle")
        ) {
            ThemedCard {
                VStack(alignment: .leading, spacing: 12) {
                    summaryRow(L("onboarding.done.summary.language"), languageSummary)
                    Divider()
                    summaryRow(L("onboarding.done.summary.theme"), themeSummary)
                    Divider()
                    summaryRow(L("onboarding.done.summary.model"), modelSummary)
                }
            }

            if state.modelStepSkipped || state.savedConfigID == nil {
                Text(L("onboarding.model.skip.note"))
                    .font(.footnote)
                    .foregroundStyle(theme.mutedForeground)
            }
        } footer: {
            Button(L("onboarding.done.cta")) {
                onFinish()
            }
            .buttonStyle(.okPrimary)
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(theme.mutedForeground)
            Text(value)
                .font(.callout)
                .foregroundStyle(theme.foreground)
        }
    }

    private var languageSummary: String {
        let interfaceName = interfaceLanguage == "system"
            ? L("settings.interfaceLanguage.system")
            : (LanguageOptions.interface.first { $0.code == interfaceLanguage }?.name ?? interfaceLanguage)
        return "\(interfaceName) · \(LanguageOptions.targetDisplayName(targetLanguage, locale: locale))"
    }

    private var themeSummary: String {
        let modeName = switch themeManager.appearance {
        case .system: L("settings.appearance.system")
        case .light: L("settings.appearance.light")
        case .dark: L("settings.appearance.dark")
        }
        return "\(themeManager.themeID.displayName) · \(modeName)"
    }

    private var modelSummary: String {
        if state.savedConfigID != nil, !state.modelStepSkipped, let provider = state.selectedProvider {
            return "\(provider.capability.displayName) · \(state.modelName)"
        }
        return L("onboarding.done.summary.modelSkipped")
    }
}
#endif
