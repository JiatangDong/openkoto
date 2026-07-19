#if os(iOS)
import SwiftUI
import OKModels
import OKAIClient
import OKDesignSystem
import OKLocalization

/// 设置（设计文档 §6.6）：AI 模型 CRUD + Keychain、外观/主题、学习目标语言、
/// 界面语言、批量并发、复习（SRS 每日上限 + 期望保持率）、隐私披露。
struct SettingsView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(AppConfigStore.self) private var appConfig
    @Environment(\.theme) private var theme
    // 由 RootTabView 注入的生效 Locale（跟随界面语言）：用于本地化讲解语言的选项名。
    @Environment(\.locale) private var locale

    @AppStorage("learning.targetLanguage") private var targetLanguage = "zh-CN"
    @AppStorage("app.interfaceLanguage") private var interfaceLanguage = "system"
    @AppStorage("ai.batchConcurrency") private var batchConcurrency = 3
    @AppStorage("srs.dailyNewLimit") private var dailyNewLimit = 20
    @AppStorage("srs.dailyReviewLimit") private var dailyReviewLimit = 100
    @AppStorage("srs.desiredRetention") private var desiredRetention = 0.9

    @State private var editingConfig: ModelConfig?
    @State private var isAddingConfig = false

    private let targetLanguages = [
        "zh-CN", "zh-TW", "en", "ja", "ko", "es", "fr", "de", "ru", "ar",
    ]

    /// 界面语言选项：code → 以该语言自身书写的名字（本地惯例，不本地化）。
    private let interfaceLanguages: [(code: String, name: String)] = [
        ("en", "English"), ("zh-Hans", "简体中文"), ("ja", "日本語"),
    ]

    private let retentionOptions: [Double] = [0.80, 0.85, 0.90, 0.95]

    /// 讲解语言的显示名：中文两项用中性的“简体/繁体中文”（避免系统按地区命名引起争议），
    /// 其余语言用系统按界面语言本地化的纯语言名（无地区）。存储代码 zh-CN/zh-TW 不变（喂 AI prompt）。
    private func targetLanguageName(_ code: String) -> String {
        switch code {
        case "zh-CN": return L("lang.simplifiedChinese")
        case "zh-TW": return L("lang.traditionalChinese")
        default: return locale.localizedString(forIdentifier: code) ?? code
        }
    }

    var body: some View {
        @Bindable var themeManager = themeManager
        NavigationStack {
            Form {
                modelsSection

                Section(L("settings.appearance")) {
                    Picker(L("settings.appearance.theme"), selection: $themeManager.themeID) {
                        ForEach(ThemeID.allCases) { themeID in
                            Text(themeID.displayName).tag(themeID)
                        }
                    }
                    Picker(L("settings.appearance.mode"), selection: $themeManager.appearance) {
                        Text(L("settings.appearance.system")).tag(AppearanceMode.system)
                        Text(L("settings.appearance.light")).tag(AppearanceMode.light)
                        Text(L("settings.appearance.dark")).tag(AppearanceMode.dark)
                    }
                }

                Section {
                    // 界面语言：App 菜单/按钮的显示语言（跟随系统 或 en/zh-Hans/ja）。
                    Picker(L("settings.interfaceLanguage"), selection: $interfaceLanguage) {
                        Text(L("settings.interfaceLanguage.system")).tag("system")
                        ForEach(interfaceLanguages, id: \.code) { item in
                            Text(item.name).tag(item.code)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    // 讲解语言：AI 生成精讲/翻译所用的语言（复用 learning.targetLanguage）。
                    Picker(L("settings.explanationLanguage"), selection: $targetLanguage) {
                        ForEach(targetLanguages, id: \.self) { code in
                            Text(targetLanguageName(code)).tag(code)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    Text(L("settings.language"))
                } footer: {
                    Text(L("settings.language.footer"))
                }

                Section(L("settings.learning")) {
                    Stepper(
                        value: $batchConcurrency, in: 1...6
                    ) {
                        LabeledContent(L("settings.learning.batchConcurrency")) {
                            Text(verbatim: "\(batchConcurrency)")
                        }
                    }
                }

                Section(L("settings.review")) {
                    Stepper(value: $dailyNewLimit, in: 5...100, step: 5) {
                        LabeledContent(L("settings.review.dailyNew")) {
                            Text(verbatim: "\(dailyNewLimit)")
                        }
                    }
                    Stepper(value: $dailyReviewLimit, in: 20...500, step: 10) {
                        LabeledContent(L("settings.review.dailyReview")) {
                            Text(verbatim: "\(dailyReviewLimit)")
                        }
                    }
                    Picker(L("settings.review.retention"), selection: $desiredRetention) {
                        ForEach(retentionOptions, id: \.self) { value in
                            Text(verbatim: "\(Int(value * 100))%").tag(value)
                        }
                    }
                }

                Section(L("settings.privacy")) {
                    Text(L("settings.privacy.note"))
                        .font(.footnote)
                        .foregroundStyle(theme.mutedForeground)
                }

                Section(L("settings.about")) {
                    LabeledContent("OpenKoto iOS") {
                        Text(verbatim: "0.1.0 (prototype)")
                    }
                    Link(
                        "GitHub",
                        destination: URL(string: "https://github.com/hikariming/openkoto")!
                    )
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle(L("tab.settings"))
            .sheet(isPresented: $isAddingConfig) {
                ModelConfigFormView(editing: nil)
            }
            .sheet(item: $editingConfig) { config in
                ModelConfigFormView(editing: config)
            }
        }
    }

    // MARK: - AI 模型配置

    @ViewBuilder
    private var modelsSection: some View {
        Section {
            if appConfig.configs.isEmpty {
                Label {
                    Text(L("settings.models.none"))
                        .font(.footnote)
                        .foregroundStyle(theme.mutedForeground)
                } icon: {
                    Image(systemName: "key").foregroundStyle(theme.primary)
                }
            } else {
                ForEach(appConfig.configs) { config in
                    Button {
                        editingConfig = config
                    } label: {
                        modelRow(config)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            appConfig.delete(config.id)
                        } label: {
                            Label(L("common.delete"), systemImage: "trash")
                        }
                        if !config.isDefault {
                            Button {
                                appConfig.setDefault(config.id)
                            } label: {
                                Label(L("model.form.setDefault"), systemImage: "star")
                            }
                            .tint(theme.primary)
                        }
                    }
                }
            }

            Button {
                isAddingConfig = true
            } label: {
                Label(L("settings.models.add"), systemImage: "plus.circle")
            }
        } header: {
            Text(L("settings.models"))
        }
    }

    private func modelRow(_ config: ModelConfig) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(config.name).foregroundStyle(theme.foreground)
                    if config.isDefault {
                        Text(L("model.form.default"))
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(theme.primary.opacity(0.15))
                            .foregroundStyle(theme.primary)
                            .clipShape(Capsule())
                    }
                }
                Text(verbatim: "\(ProviderCapability.capability(for: config.apiProvider).displayName) · \(config.model)")
                    .font(.caption)
                    .foregroundStyle(theme.mutedForeground)
            }
            Spacer()
            if appConfig.hasKey(for: config.id) {
                Image(systemName: "key.fill")
                    .font(.caption)
                    .foregroundStyle(theme.mutedForeground)
            }
        }
        .contentShape(Rectangle())
    }
}
#endif
