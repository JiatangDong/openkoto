#if os(iOS)
import SwiftUI

extension View {
    /// 前台阅读计时：收敛 `ReaderView` 与 `BookReaderView` 两份几乎相同的实现。
    ///
    /// 比原先多做两件事：
    /// ① **每 60 秒分段落账**。Mac（Catalyst）上窗口不会进 `.background`，
    ///    只靠 `onDisappear` 的话"直接关窗口"那一整段时长会丢；iOS 上被系统 kill 同理。
    ///    分段之后最多丢最后不满一分钟的零头。
    /// ② **换文章时先结算再起表**。书籍连翻几章时，原实现会把整段阅读全记在
    ///    停下来的那一章上。
    ///
    /// `articleID` 传 nil（书籍章节还没就绪）时不计时。
    func readingClock(articleID: UUID?) -> some View {
        modifier(ReadingClockModifier(articleID: articleID))
    }
}

private struct ReadingClockModifier: ViewModifier {
    @Environment(ContentStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    let articleID: UUID?

    @State private var startedAt: Date?

    /// 分段落账周期。60 秒是个折中：崩溃/关窗口最多丢一分钟，
    /// 又不至于把 reading_session 写成秒级流水账（2 小时阅读 = 120 行，SQLite 无压力）。
    private static let accrualInterval: Duration = .seconds(60)

    /// 单段时长的有效区间：<3s 是误点进来又退出的噪声，
    /// >2h 是把 App 开着睡了一夜的挂机，两头都不该算进阅读时长。
    private static let validRange: ClosedRange<Int> = 3...(2 * 60 * 60)

    func body(content: Content) -> some View {
        content
            .onAppear { startedAt = Date() }
            .onDisappear { flush(articleID) }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    if startedAt == nil { startedAt = Date() }
                case .inactive, .background:
                    flush(articleID)
                @unknown default:
                    break
                }
            }
            // 翻章：先把上一章的时长结算掉，再给新章起表。
            .onChange(of: articleID) { previous, _ in
                flush(previous)
                startedAt = Date()
            }
            .task(id: articleID) {
                // 视图消失或换文章时这条 task 会被自动取消，不会漏记也不会重复记。
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.accrualInterval)
                    guard !Task.isCancelled else { break }
                    flush(articleID, restarting: true)
                }
            }
    }

    /// 结算并落一条会话。`restarting` 为真时立刻重新起表（分段落账用）。
    private func flush(_ id: UUID?, restarting: Bool = false) {
        guard let start = startedAt, let id else { return }
        let now = Date()
        startedAt = restarting ? now : nil
        let elapsed = Int(now.timeIntervalSince(start))
        guard Self.validRange.contains(elapsed) else { return }
        Task { await store.recordReadingSession(articleId: id, seconds: elapsed, startedAt: start) }
    }
}
#endif
