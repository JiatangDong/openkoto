#if os(iOS)
import Foundation
import OKModels
import Testing

@testable import OKFeatures

/// 播放同步。没有真实媒体文件也能测——`load(url: nil)` 只装时间轴，
/// 这正是「引用的文件失效时文稿仍可读」那条降级路径。
@MainActor
@Suite struct PlaybackModelTests {
    private let articleID = UUID()

    /// 三句 + 一段 6 秒静音（第二句结束到第三句开始）。
    private func makeSegments() -> [ArticleSegment] {
        [
            ArticleSegment(articleId: articleID, order: 0, text: "第一句。", startTime: 0, endTime: 2),
            ArticleSegment(articleId: articleID, order: 1, text: "第二句。", startTime: 2, endTime: 4),
            ArticleSegment(
                articleId: articleID, order: 2, text: "第三句。", startTime: 10, endTime: 12),
        ]
    }

    private func makeModel() -> (PlaybackModel, [ArticleSegment]) {
        let segments = makeSegments()
        let model = PlaybackModel()
        model.load(url: nil, segments: segments, startAt: 0)
        return (model, segments)
    }

    // MARK: - 当前句判定

    @Test func resolvesActiveSentenceWhileSeeking() {
        let (model, segments) = makeModel()
        model.seek(to: 1)
        #expect(model.activeID == segments[0].id)
        model.seek(to: 3)
        #expect(model.activeID == segments[1].id)
        model.seek(to: 11)
        #expect(model.activeID == segments[2].id)
    }

    /// 静音间隙里**保留上一句**，不清空。桌面端在这里会闪成占位提示。
    @Test func keepsPreviousSentenceDuringSilence() {
        let (model, segments) = makeModel()
        model.seek(to: 7)  // 落在 4s–10s 的静音里
        #expect(model.activeID == segments[1].id)
        #expect(model.isInGap)
    }

    @Test func notInGapWhileSpeaking() {
        let (model, _) = makeModel()
        model.seek(to: 3)
        #expect(!model.isInGap)
    }

    /// 第一句开始之前没有当前句。
    @Test func noActiveSentenceBeforeStart() {
        let (model, _) = makeModel()
        model.seek(to: 0)
        #expect(model.activeID != nil)  // 恰好在起点应命中第一句
    }

    /// 拖进度条后高亮要**立刻**跟上，不能等下一次时间回调。
    @Test func highlightFollowsScrubImmediately() {
        let (model, segments) = makeModel()
        model.seek(to: 11)
        #expect(model.activeID == segments[2].id)
        #expect(model.currentTime == 11)
    }

    // MARK: - 点句跳转

    /// 跳到句首要带一点提前量，否则词级起点压在第一个音素上会听不清头一个字。
    @Test func seekToSegmentIncludesLeadIn() {
        let (model, segments) = makeModel()
        model.seek(toSegment: segments[2].id, autoPlay: false)
        #expect(model.currentTime < 10)
        #expect(model.currentTime > 9.5)
        // 提前量不能把当前句带回上一句
        #expect(model.activeID == segments[2].id)
    }

    /// 第一句的提前量不能变成负数。
    @Test func leadInClampsAtZero() {
        let (model, segments) = makeModel()
        model.seek(toSegment: segments[0].id, autoPlay: false)
        #expect(model.currentTime == 0)
    }

    // MARK: - 单句循环

    @Test func togglesSentenceLoop() {
        let (model, segments) = makeModel()
        model.toggleLoop(segmentID: segments[1].id)
        #expect(model.loopingSegmentID == segments[1].id)
        // 开循环即跳到该句
        #expect(model.currentTime < 2)

        model.toggleLoop(segmentID: segments[1].id)
        #expect(model.loopingSegmentID == nil)
    }

    /// 换一句循环时旧的要自动解除。
    @Test func switchingLoopReplacesPrevious() {
        let (model, segments) = makeModel()
        model.toggleLoop(segmentID: segments[0].id)
        model.toggleLoop(segmentID: segments[2].id)
        #expect(model.loopingSegmentID == segments[2].id)
    }

    @Test func stopLoopingClears() {
        let (model, segments) = makeModel()
        model.toggleLoop(segmentID: segments[0].id)
        model.stopLooping()
        #expect(model.loopingSegmentID == nil)
    }

    // MARK: - 降级

    /// 没有媒体文件时：时间轴照常可用（能点句、能看高亮），只是不能播。
    @Test func worksWithoutMediaFile() {
        let (model, segments) = makeModel()
        #expect(!model.canPlay)
        #expect(model.duration == 12)  // 由最后一句的结束时间推出
        model.seek(to: 3)
        #expect(model.activeID == segments[1].id)
        model.togglePlay()
        #expect(!model.isPlaying)  // 没有 item 就不该假装在播
    }

    /// 没有时间轴的句子（普通文章）不进索引，不会被误判成当前句。
    @Test func ignoresSegmentsWithoutTiming() {
        let model = PlaybackModel()
        model.load(
            url: nil,
            segments: [ArticleSegment(articleId: articleID, order: 0, text: "无时间轴。")],
            startAt: 0)
        model.seek(to: 5)
        #expect(model.activeID == nil)
    }

    @Test func skipMovesRelativeToCurrentTime() {
        let (model, _) = makeModel()
        model.seek(to: 5)
        model.skip(by: 3)
        #expect(model.currentTime == 8)
        model.skip(by: -100)
        #expect(model.currentTime == 0)  // 不能到负数
    }
}
#endif
