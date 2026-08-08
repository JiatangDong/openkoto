import Foundation
import OKLocalization
import OKModels
import UserNotifications
import os

/// 每日复习提醒（纯本地通知，不经服务器）。
///
/// **为什么不是一条 `repeats: true` 的固定提醒**：那种通知每天同一时刻说同一句话，
/// 今天到期 3 张和 80 张长得一模一样，连今天已经全清空了也照弹。
/// 用户学会忽略它只要三四天，之后这个功能就等于不存在。
///
/// 这里改成**每次进出前台按当前 FSRS 到期日重排未来 7 天**：一天一条、带真实数字，
/// 那天没有到期的就不排。复习完再回前台会立刻重算，所以「刚做完还被催」不会发生。
///
/// 为什么是 7 天：iOS 给每个 App 的待发本地通知上限是 64 条，7 条远在限额内；
/// 而只要用户一周内打开过一次 App 就会续期，铺更远只是给不回来的用户多排几条。
enum ReviewReminder {
    static let logger = Logger(subsystem: "app.openkoto", category: "ReviewReminder")

    // MARK: - 设置项（@AppStorage 与本文件共用同一批 key）

    static let enabledKey = "reminder.enabled"
    /// 存「距零点的分钟数」而不是 `Date`：跨时区、跨夏令时都还是用户设的那个墙上时间。
    static let minutesKey = "reminder.minutesFromMidnight"
    /// 默认 20:00。
    static let defaultMinutes = 20 * 60

    /// 一次铺多少天。
    static let horizonDays = 7

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// 未设置过时返回默认值——不能用 `integer(forKey:)`，那会把「没设过」读成 0（0:00）。
    static var minutesFromMidnight: Int {
        UserDefaults.standard.object(forKey: minutesKey) as? Int ?? defaultMinutes
    }

    // MARK: - 通知路由

    /// 通知点开后往哪走。带在 userInfo 里而不是靠 identifier 前缀：
    /// 以后加别的通知类型时，这里不用再改一次判定逻辑。
    static let routeKey = "okRoute"
    static let routeReview = "review"

    /// 这条通知是不是「去复习」。`nonisolated` + 只回 Bool：
    /// userInfo 不是 Sendable，判定必须在跨 actor 之前做完。
    static func isReviewRoute(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo[routeKey] as? String == routeReview
    }

    // MARK: - 排期计算（纯函数，可在 macOS 上单测）

    struct Plan: Equatable, Sendable {
        /// 距今天几天。0 = 今天。
        var dayOffset: Int
        var fireDate: Date
        /// 那天累计到期多少张（含逾期未做的）。
        var dueCount: Int
    }

    /// 算出未来 `horizonDays` 天里每天该弹什么。只返回真的要排的那几天。
    ///
    /// 计数用的是**累计**口径（到期日 ≤ 那天），不是「那天新到期」：
    /// 用户如果一周不开 App，第 3 天该被提醒的是攒下来的全部欠账，而不是那天新增的几张。
    /// 他一旦开了 App 就会重排，所以不存在两种口径打架。
    ///
    /// 不按当前选中词包过滤：通知是全 App 级别的，只提醒当前词包会让另一个包默默烂掉。
    /// 也不按每日上限截断——与生词页「今日到期」显示的是同一个数，两处对不上更糟。
    static func plan(
        favorites: [FavoriteVocabulary],
        minutesFromMidnight: Int,
        now: Date,
        calendar: Calendar = .current
    ) -> [Plan] {
        // 已掌握/暂停的卡不进队列，也就不该催。
        let active = favorites.filter { $0.suspendedAt == nil }
        guard !active.isEmpty else { return [] }

        let clamped = min(max(minutesFromMidnight, 0), 24 * 60 - 1)
        let startOfToday = calendar.startOfDay(for: now)

        var plans: [Plan] = []
        for offset in 0..<horizonDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday),
                let fire = calendar.date(
                    bySettingHour: clamped / 60, minute: clamped % 60, second: 0, of: day),
                // 今天的点已经过了就跳过：日期分量写死到「年月日时分」的日历触发器
                // 没有下一次匹配，排了也只是一条永不触发的僵尸。
                fire > now
            else { continue }

            let key = dayKey(day, calendar: calendar)
            let count = active.count { isDue($0, onOrBefore: key) }
            guard count > 0 else { continue }
            plans.append(Plan(dayOffset: offset, fireDate: fire, dueCount: count))
        }
        return plans
    }

    /// 与 `dueQueue` / 生词页「今日到期」同口径：坏日期（含空串）一律视为已到期。
    /// 三处对不上的话，用户会收到「有 5 个待复习」却点进去只看到 3 张。
    private static func isDue(_ favorite: FavoriteVocabulary, onOrBefore key: String) -> Bool {
        favorite.dueDate.count != 10 || favorite.dueDate <= key
    }

    /// 与 `ContentStore.localDateString` 同格式（本地日期 "YYYY-MM-DD"）。
    /// 那边写死 `Calendar.current`，这里留出注入口只为让测试不看运行机器的时区脸色。
    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    // MARK: - 落到通知中心

    private static func identifier(dayOffset: Int) -> String { "review.reminder.d\(dayOffset)" }

    private static var allIdentifiers: [String] {
        (0..<horizonDays).map { identifier(dayOffset: $0) }
    }

    /// 重排。关了、没授权、或未来 7 天都没有到期卡时，就只是把旧的清干净。
    ///
    /// 每次都先全撤再重排（而不是增量对比）：待办数据每一次复习都在变，
    /// 增量的正确性完全依赖「上次排了什么」的记账，而那本账一旦和系统里的实际状态
    /// 错位，用户看到的就是过期的数字，且没有任何自愈路径。7 条通知重排的开销可以忽略。
    @MainActor
    static func reschedule(favorites: [FavoriteVocabulary], now: Date = .now) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: allIdentifiers)
        // 连已送达的一起撤：昨天那条「有 5 个待复习」还躺在通知中心里，
        // 而人早就做完了——留着就是在展示假数字。
        center.removeDeliveredNotifications(withIdentifiers: allIdentifiers)

        guard isEnabled else { return }
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }

        let plans = plan(
            favorites: favorites, minutesFromMidnight: minutesFromMidnight, now: now)
        for plan in plans {
            let content = UNMutableNotificationContent()
            // 文案在**排期时**定型，所以走的是 L10n 的界面语言覆盖。
            // 用户改了界面语言必须重排，否则通知还是旧语言（见 RootTabView）。
            content.title = L("reminder.title")
            content.body = L("reminder.body\(plan.dueCount)")
            content.sound = .default
            content.userInfo = [routeKey: routeReview]

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: plan.fireDate)
            let request = UNNotificationRequest(
                identifier: identifier(dayOffset: plan.dayOffset),
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
            do {
                try await center.add(request)
            } catch {
                logger.error("add reminder d\(plan.dayOffset) failed: \(error)")
            }
        }
        logger.info("rescheduled \(plans.count) reminder(s)")
    }

    // MARK: - 授权

    /// 弹系统授权框。在设置页**打开开关那一刻**调用，不在启动时——
    /// 一上来就要通知权限的 App，用户的默认反应是「不允许」，而那是不可逆的：
    /// 之后只能引导他去系统设置里手动开。
    @MainActor
    static func requestAuthorization() async -> Bool {
        do {
            // 现在不打角标，但一并申请：授权后再加 option 是不会二次弹框的，
            // 那时 `.badge` 就要不到了。
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            logger.error("requestAuthorization failed: \(error)")
            return false
        }
    }

    @MainActor
    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

/// 「点了提醒 → 去生词本」的跨层信箱。
///
/// 通知代理住在 App 壳里（`UNUserNotificationCenter.delegate` 必须在 didFinishLaunching
/// 就挂上），要切的 tab 却是 `RootTabView` 的私有 `@State`，中间需要一个共享的落点。
@MainActor
@Observable
public final class ReviewReminderRouter {
    public static let shared = ReviewReminderRouter()
    private init() {}

    /// 单调递增的令牌，不是 Bool：连着点两次通知时 Bool 前后都是 true，
    /// `onChange` 不会再触发，第二次点击就丢了。
    public private(set) var openRequests = 0

    public func requestOpen() { openRequests += 1 }

    /// 取走一次待处理跳转。冷启动时通知回调先到、视图后建，
    /// `onChange` 收不到那一次，所以视图首次出现时也要主动来取一次。
    public func consumeOpenRequest() -> Bool {
        guard openRequests > 0 else { return false }
        openRequests = 0
        return true
    }
}

#if os(iOS)
import UIKit

/// App 壳用 `@UIApplicationDelegateAdaptor` 挂上的通知代理。
///
/// 放在包里而不是壳里：判定与路由都在这一层，壳只需要一行声明。
public final class OKNotificationAppDelegate: NSObject, UIApplicationDelegate {
    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 必须在这里就挂上：冷启动时系统紧接着就投递「用户点了通知」那一次回调，
        // 挂晚一步（比如挪到某个 View 的 .task 里）就永远收不到，
        // 表现为「从通知点进来只是普通启动」。
        UNUserNotificationCenter.current().delegate = self
        return true
    }
}

/// 这两个方法必须 `nonisolated`：`UIApplicationDelegate` 是 `@MainActor`，
/// 类成员会被推断成主 actor 隔离，而 `UNUserNotificationCenterDelegate` 的要求不是，
/// 于是 `UNNotification` 这些非 Sendable 参数过不了边界（Swift 6 直接编译失败）。
extension OKNotificationAppDelegate: UNUserNotificationCenterDelegate {
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // userInfo 不是 Sendable，判定必须在跨 actor 之前做完，只让 Bool 过界。
        guard ReviewReminder.isReviewRoute(response.notification.request.content.userInfo)
        else { return }
        await MainActor.run { ReviewReminderRouter.shared.requestOpen() }
    }

    /// App 正开着时不弹自己的复习提醒——人就在应用里，横幅只是打断。
    /// 回前台会重排，所以这条不弹也不会漏：该提醒的明天还在。
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        ReviewReminder.isReviewRoute(notification.request.content.userInfo) ? [] : [.banner, .sound]
    }
}
#endif
