#if os(iOS)
import SwiftUI
import OKDesignSystem
import OKLocalization

// MARK: - 欢迎

struct OnboardingWelcomeStep: View {
    @Bindable var state: OnboardingState
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "book.pages")
                        .font(.system(size: 44))
                        .foregroundStyle(theme.primary)
                        .frame(width: 88, height: 88)
                        .background(theme.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: OKRadius.sheet))
                        .padding(.top, 32)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("onboarding.welcome.title"))
                            .font(.largeTitle.bold())
                            .foregroundStyle(theme.foreground)
                        Text(L("onboarding.welcome.subtitle"))
                            .font(.title3)
                            .foregroundStyle(theme.mutedForeground)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        welcomePoint("text.book.closed", L("onboarding.welcome.point1"))
                        welcomePoint("sparkles", L("onboarding.welcome.point2"))
                        welcomePoint("square.stack.3d.up", L("onboarding.welcome.point3"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
            }
            Button(L("onboarding.welcome.cta")) {
                state.advance()
            }
            .buttonStyle(.okPrimary)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
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

    // 直接绑持久化 key：改界面语言 → RootTabView 按新语言重建整棵子树，
    // 步骤进度由 OnboardingState（在 .id 边界之外）保住。
    @AppStorage("app.interfaceLanguage") private var interfaceLanguage = "system"
    @AppStorage("learning.targetLanguage") private var targetLanguage = "zh-CN"

    var body: some View {
        OnboardingStepLayout(
            title: L("onboarding.language.title"),
            subtitle: L("onboarding.language.subtitle")
        ) {
            ThemedCard {
                VStack(spacing: 12) {
                    HStack {
                        Text(L("settings.interfaceLanguage"))
                            .foregroundStyle(theme.foreground)
                        Spacer()
                        Picker(L("settings.interfaceLanguage"), selection: $interfaceLanguage) {
                            Text(L("settings.interfaceLanguage.system")).tag("system")
                            ForEach(LanguageOptions.interface, id: \.code) { item in
                                Text(item.name).tag(item.code)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(theme.primary)
                    }
                    Divider()
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
            }

            Text(L("settings.language.footer"))
                .font(.footnote)
                .foregroundStyle(theme.mutedForeground)
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
