#if os(iOS)
import SwiftUI
import UserNotifications
import OKDesignSystem
import OKLocalization

/// 每日复习提醒：导览倒数第二步（模型之后、完成之前）。
/// 机制完全复用 `ReviewReminder` 与设置页同一批 UserDefaults key，
/// 这里只是把入口前置到首启，让用户知道有这功能。
struct OnboardingReminderStep: View {
    @Bindable var state: OnboardingState
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ContentStore.self) private var store

    @AppStorage(ReviewReminder.enabledKey) private var reminderEnabled = false
    @AppStorage(ReviewReminder.minutesKey) private var reminderMinutes = ReviewReminder.defaultMinutes

    /// 授权状态可重新拉取，不需要跨重建存活，放本地 @State 即可。
    @State private var reminderAuthorization: UNAuthorizationStatus = .notDetermined

    var body: some View {
        OnboardingStepLayout(
            title: L("onboarding.reminder.title"),
            subtitle: L("onboarding.reminder.subtitle")
        ) {
            ThemedCard {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(L("settings.reminder.enabled"), isOn: $reminderEnabled)
                        .tint(theme.primary)
                    if reminderEnabled {
                        Divider()
                        HStack {
                            Text(L("settings.reminder.time"))
                                .foregroundStyle(theme.foreground)
                            Spacer()
                            DatePicker(
                                L("settings.reminder.time"), selection: reminderTime,
                                displayedComponents: .hourAndMinute
                            )
                            .labelsHidden()
                        }
                    }
                }
            }

            // 开着开关但系统那边被拒了——这时什么都不会弹，必须说清楚。
            // 不拨回开关：用户的意图是明确的，权限一旦放行，回前台那次重排就自动生效。
            if isReminderBlocked {
                Text(L("settings.reminder.denied"))
                    .font(.footnote)
                    .foregroundStyle(theme.mutedForeground)
                // Catalyst 上没有这个 deep link（"app-settings:" 是 iOS 的），与设置页同款处理。
                #if !targetEnvironment(macCatalyst)
                    Button(L("settings.reminder.openSystemSettings")) {
                        guard let url = URL(
                            string: UIApplication.openNotificationSettingsURLString)
                        else { return }
                        openURL(url)
                    }
                    .font(.footnote)
                #endif
            }
        } footer: {
            Button(L("onboarding.step.continue")) {
                state.advance()
            }
            .buttonStyle(.okPrimary)
        }
        .task { reminderAuthorization = await ReviewReminder.authorizationStatus() }
        // 用户可能刚从系统设置里改完通知权限回来。
        .onChange(of: scenePhase) {
            guard scenePhase == .active else { return }
            Task { reminderAuthorization = await ReviewReminder.authorizationStatus() }
        }
        .onChange(of: reminderEnabled) { Task { await applyReminderChange() } }
        .onChange(of: reminderMinutes) {
            Task { await ReviewReminder.reschedule(favorites: store.favorites) }
        }
    }

    /// 提醒时间存的是「距零点的分钟数」，`DatePicker` 要的是 `Date`——这里做转换。
    /// 与 SettingsView.reminderTime 同一套换算。
    private var reminderTime: Binding<Date> {
        Binding {
            Calendar.current.date(
                bySettingHour: reminderMinutes / 60, minute: reminderMinutes % 60,
                second: 0, of: .now) ?? .now
        } set: { newValue in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            reminderMinutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
    }

    private var isReminderBlocked: Bool {
        reminderEnabled && reminderAuthorization == .denied
    }

    /// 与 SettingsView.applyReminderChange 同逻辑：打开开关那一刻才请求权限。
    private func applyReminderChange() async {
        if reminderEnabled, await ReviewReminder.authorizationStatus() == .notDetermined {
            _ = await ReviewReminder.requestAuthorization()
        }
        reminderAuthorization = await ReviewReminder.authorizationStatus()
        // 关掉时同样要走一次：reschedule 内部会把已排的全撤掉。
        // 新用户 favorites 还是空的，这里只是清掉旧排期；等有了单词，
        // 进出前台的重排（RootTabView）会把提醒排上。
        await ReviewReminder.reschedule(favorites: store.favorites)
    }
}
#endif
