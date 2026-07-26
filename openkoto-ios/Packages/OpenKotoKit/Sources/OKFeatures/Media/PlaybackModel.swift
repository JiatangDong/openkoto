#if os(iOS)
import AVFoundation
import Foundation
import OKMedia
import OKModels
import Observation

/// 播放状态与字幕同步。
///
/// 这里是把「时间」翻译成「当前学到哪一句」的唯一地方。两个关键约束：
///
/// 1. **只在当前句真的变了的时候才写 `activeID`**。10Hz 的 observer 每秒回调十次，
///    每次都写 `@Observable` 属性会让整个字幕列表重新 diff。二分查找是免费的，
///    SwiftUI 失效不是。`currentTime` 单独一个属性——只有进度条读它，
///    字幕列表不读，所以它高频变化也不会拖累列表。
/// 2. **当前句 = 最后一个 start ≤ t 的句子**（见 `TimelineIndex`），
///    静音间隙里保留上一句而不是清空。
@MainActor
@Observable
final class PlaybackModel {
    /// 时间观察频率。10Hz 足够让高亮跟手，也不至于让进度条抖动。
    private static let observeInterval = CMTime(value: 1, timescale: 10)
    /// 点句跳转时的提前量：词级起点常压在第一个音素上，直接 seek 会听不清头一个字。
    private static let seekLeadIn: Double = 0.25

    private(set) var isPlaying = false
    /// 秒。高频变化，只有进度条与时间标签读它。
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    /// 当前句。只在真的换句时才写。
    private(set) var activeID: UUID?
    /// 播放位置已越过当前句结尾——UI 把高亮调暗，但不换句。
    private(set) var isInGap = false

    var rate: Float = 1 {
        didSet {
            guard rate != oldValue else { return }
            if isPlaying { player.rate = rate }
        }
    }

    /// 单句循环：播到句尾自动跳回句首。影子跟读的核心功能。
    private(set) var loopingSegmentID: UUID?

    let player = AVPlayer()

    private var timeObserver: Any?
    private var index = TimelineIndex(entries: [])
    private var segmentsByID: [UUID: ArticleSegment] = [:]
    private var loopRange: (start: Double, end: Double)?

    init() {}

    // 不写 deinit：它不在 MainActor 上，碰不了隔离属性。
    // 观察者由 `teardown()` 摘除，调用点是视图的 `onDisappear`——
    // 且 observer token 由 player 持有，player 随本对象一起释放，不会泄漏。

    // MARK: - 装载

    func load(url: URL?, segments: [ArticleSegment], startAt position: Double) {
        index = TimelineIndex(
            entries: segments.compactMap { segment in
                guard let start = segment.startTime, let end = segment.endTime else { return nil }
                return (id: segment.id, start: start, end: end)
            })
        segmentsByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })

        guard let url else {
            // 没有媒体文件（只导了字幕，或引用失效）：文稿照常能读，只是不能播。
            duration = segments.compactMap(\.endTime).max() ?? 0
            return
        }

        // 让声音不受静音开关影响——学习类音频被静音键掐掉是纯粹的困惑来源。
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let item = AVPlayerItem(url: url)
        // 变速不变调：0.5× 慢放时音高不能塌下去，否则跟读没法用。
        item.audioTimePitchAlgorithm = .timeDomain
        player.replaceCurrentItem(with: item)
        observeTime()
        Task { [weak self] in
            let loaded = try? await item.asset.load(.duration)
            guard let self, let loaded, loaded.isNumeric else { return }
            self.duration = loaded.seconds
        }
        if position > 0 { seek(to: position) }
    }

    func teardown() {
        pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player.replaceCurrentItem(with: nil)
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    private func observeTime() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: Self.observeInterval, queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(at: time.seconds) }
        }
    }

    /// 每次时间回调只做两件事：更新进度、必要时换句。
    private func tick(at time: Double) {
        guard time.isFinite else { return }
        currentTime = time

        if let loopRange, time >= loopRange.end {
            seek(to: loopRange.start)
            return
        }

        let resolved = index.resolve(at: time)
        // ★ 只在真的变了的时候才写——否则每秒十次让整个列表重新 diff
        if resolved?.id != activeID { activeID = resolved?.id }
        if resolved?.isInGap != isInGap { isInGap = resolved?.isInGap ?? false }
    }

    // MARK: - 传输控制

    var canPlay: Bool { player.currentItem != nil }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard canPlay else { return }
        isPlaying = true
        player.rate = rate
    }

    func pause() {
        isPlaying = false
        player.pause()
    }

    func seek(to time: Double) {
        let clamped = max(0, duration > 0 ? min(time, duration) : time)
        currentTime = clamped
        // 高亮立刻跟上，不等下一次 observer 回调（拖进度条时最明显）
        let resolved = index.resolve(at: clamped)
        if resolved?.id != activeID { activeID = resolved?.id }
        isInGap = resolved?.isInGap ?? false
        guard canPlay else { return }
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    /// 跳到某句开头。带一点提前量，否则第一个字听不清。
    func seek(toSegment id: UUID, autoPlay: Bool = true) {
        guard let start = segmentsByID[id]?.startTime else { return }
        seek(to: max(0, start - Self.seekLeadIn))
        activeID = id
        if autoPlay, canPlay, !isPlaying { play() }
    }

    // MARK: - 单句循环

    func toggleLoop(segmentID: UUID) {
        if loopingSegmentID == segmentID {
            loopingSegmentID = nil
            loopRange = nil
            return
        }
        guard let segment = segmentsByID[segmentID],
            let start = segment.startTime, let end = segment.endTime
        else { return }
        loopingSegmentID = segmentID
        loopRange = (max(0, start - Self.seekLeadIn), end)
        seek(to: max(0, start - Self.seekLeadIn))
        if canPlay, !isPlaying { play() }
    }

    func stopLooping() {
        loopingSegmentID = nil
        loopRange = nil
    }
}
#endif
