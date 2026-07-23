#if os(iOS)
import SwiftUI
import OKModels
import OKAIClient
import OKDesignSystem
import OKLocalization

/// 模型步（可跳过）：精选 Provider + 推荐模型预填 + 取 Key 指引 + 测试连接。
/// 与设置页完整表单（`ModelConfigFormView`）不同：不选 Base URL、不改默认开关，
/// 保存即 `isDefault: true`（首个配置）。
struct OnboardingModelStep: View {
    @Bindable var state: OnboardingState
    @Environment(AppConfigStore.self) private var appConfig
    @Environment(\.theme) private var theme

    private var canContinue: Bool {
        state.selectedProviderID != nil
            && !state.modelName.trimmingCharacters(in: .whitespaces).isEmpty
            && !state.apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        OnboardingStepLayout(
            title: L("onboarding.model.title"),
            subtitle: L("onboarding.model.subtitle")
        ) {
            providerGrid

            if let provider = state.selectedProvider {
                configCard
                guideCard(provider)
            }
        } footer: {
            Button(L("onboarding.step.continue")) {
                save()
            }
            .buttonStyle(.okPrimary)
            .disabled(!canContinue)

            Button(L("onboarding.model.skip")) {
                state.modelStepSkipped = true
                state.advance()
            }
            .font(.callout)
            .foregroundStyle(theme.mutedForeground)

            Text(L("onboarding.model.skip.note"))
                .font(.caption2)
                .foregroundStyle(theme.mutedForeground)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .onChange(of: state.modelName) { state.testState = .idle }
        .onChange(of: state.apiKeyInput) { state.testState = .idle }
    }

    // MARK: - Provider 精选

    private var providerGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(OnboardingProvider.curated) { provider in
                providerChip(provider)
            }
        }
    }

    private func providerChip(_ provider: OnboardingProvider) -> some View {
        let isSelected = state.selectedProviderID == provider.id
        return Button {
            state.select(provider)
        } label: {
            Text(provider.capability.displayName)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? theme.primary : theme.foreground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    isSelected ? theme.primary.opacity(0.12) : theme.card,
                    in: RoundedRectangle(cornerRadius: OKRadius.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: OKRadius.card)
                        .strokeBorder(isSelected ? theme.primary : theme.border, lineWidth: isSelected ? 1.5 : 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - 模型与 Key

    private var configCard: some View {
        ThemedCard {
            VStack(spacing: 12) {
                HStack {
                    Text(L("model.form.model"))
                        .foregroundStyle(theme.mutedForeground)
                    TextField(L("model.form.model"), text: $state.modelName)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Divider()
                SecureField(L("model.form.apiKey"), text: $state.apiKeyInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Divider()
                testRow
            }
        }
    }

    @ViewBuilder
    private var testRow: some View {
        Button {
            Task { await test() }
        } label: {
            HStack {
                Label(L("model.form.test"), systemImage: "bolt.horizontal")
                Spacer()
                switch state.testState {
                case .idle: EmptyView()
                case .testing: ProgressView()
                case .success:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failure:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(theme.destructive)
                }
            }
        }
        .disabled(!canContinue || state.testState == .testing)

        if case let .failure(message) = state.testState {
            Text(message)
                .font(.footnote)
                .foregroundStyle(theme.destructive)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if state.testState == .success {
            Text(L("model.form.test.success"))
                .font(.footnote)
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 取 Key 指引

    private func guideCard(_ provider: OnboardingProvider) -> some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(L("onboarding.model.guide.title"), systemImage: "questionmark.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.foreground)

                guideStep(1, String(format: L("onboarding.model.guide.step1"), provider.capability.displayName))
                guideStep(2, L("onboarding.model.guide.step2"))
                guideStep(3, L("onboarding.model.guide.step3"))

                if let noteKey = provider.noteKey {
                    Label(L(String.LocalizationValue(noteKey)), systemImage: "lightbulb")
                        .font(.footnote)
                        .foregroundStyle(theme.primary)
                }

                Link(destination: provider.keyConsoleURL) {
                    Label(L("onboarding.model.guide.openConsole"), systemImage: "arrow.up.right.square")
                        .font(.callout.weight(.medium))
                }
                .tint(theme.primary)

                if let policy = provider.capability.privacyPolicyURL {
                    Link(destination: policy) {
                        Label(L("model.form.privacy"), systemImage: "hand.raised")
                            .font(.footnote)
                    }
                    .tint(theme.mutedForeground)
                }
            }
        }
    }

    private func guideStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: "\(number)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.primaryForeground)
                .frame(width: 18, height: 18)
                .background(theme.primary, in: Circle())
            Text(text)
                .font(.footnote)
                .foregroundStyle(theme.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 动作

    private func draftConfig() -> ModelConfig {
        let capability = ProviderCapability.capability(for: state.selectedProviderID ?? .deepseek)
        return ModelConfig(
            id: state.savedConfigID ?? UUID(),
            name: capability.displayName,
            apiProvider: capability.id,
            model: state.modelName.trimmingCharacters(in: .whitespaces),
            baseURL: nil,
            isDefault: true
        )
    }

    private func test() async {
        state.testState = .testing
        do {
            try await appConfig.testConnection(draftConfig(), apiKey: state.apiKeyInput)
            state.testState = .success
        } catch let error as AIClientError {
            state.testState = .failure(userMessage(for: error))
        } catch {
            state.testState = .failure(userMessage(for: .malformedResponse(requestID: UUID())))
        }
    }

    /// 保存并前进。测试成功不是前置条件——网络波动不应卡住首启流程。
    private func save() {
        let config = draftConfig()
        appConfig.addOrUpdate(config, apiKey: state.apiKeyInput)
        state.savedConfigID = config.id
        state.modelStepSkipped = false
        state.advance()
    }
}
#endif
