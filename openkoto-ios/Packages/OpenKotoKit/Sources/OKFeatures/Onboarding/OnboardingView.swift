#if os(iOS)
import SwiftUI
import OKDesignSystem
import OKLocalization

/// 首启引导容器（设计文档 §6.2）：返回箭头 + 进度点 + 五个步骤。
/// 状态全在 `OnboardingState`（RootTabView 持有），语言切换重建后自动恢复原步骤。
struct OnboardingView: View {
    @Bindable var state: OnboardingState
    /// 完成页 CTA 触发：由 RootTabView 置 `app.onboarding.completed`。
    let onFinish: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(state.step)
                .transition(.push(from: state.movingForward ? .trailing : .leading))
        }
        .animation(.default, value: state.step)
        .background(theme.background)
    }

    private var header: some View {
        ZStack {
            progressDots
            HStack {
                if state.step != .first {
                    Button {
                        state.goBack()
                    } label: {
                        Image(systemName: "chevron.backward")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(theme.foreground)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(L("onboarding.step.back"))
                }
                Spacer()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 52)
    }

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingState.Step.allCases, id: \.rawValue) { step in
                Circle()
                    .fill(step.rawValue <= state.step.rawValue ? theme.primary : theme.border)
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(
                format: L("onboarding.step.progress"),
                state.step.rawValue + 1, OnboardingState.Step.allCases.count
            )
        )
    }

    @ViewBuilder
    private var stepContent: some View {
        switch state.step {
        case .appLanguage:
            OnboardingAppLanguageStep(state: state)
        case .welcome:
            OnboardingWelcomeStep(state: state)
        case .language:
            OnboardingLanguageStep(state: state)
        case .theme:
            OnboardingThemeStep(state: state)
        case .model:
            OnboardingModelStep(state: state)
        case .done:
            OnboardingDoneStep(state: state, onFinish: onFinish)
        }
    }
}

/// 步骤通用骨架：滚动正文 + 底部固定 CTA 区。
struct OnboardingStepLayout<Content: View, Footer: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.largeTitle.bold())
                            .foregroundStyle(theme.foreground)
                        Text(subtitle)
                            .font(.body)
                            .foregroundStyle(theme.mutedForeground)
                    }
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            VStack(spacing: 12) {
                footer
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
    }
}
#endif
