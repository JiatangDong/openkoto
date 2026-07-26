import Foundation
import Testing

@testable import OKMedia

/// 播放位置 → 当前句。
///
/// 桌面端用半开区间 `[start, end)` 判定，ASR 词级切分天然留静音间隙，
/// 播到间隙就查无结果、字幕卡闪成占位——用户感知是「字幕一闪一闪对不上」。
/// 这里改成「最后一个已开始的句子」，那个 bug 构造不出来。
@Suite struct TimelineIndexTests {
    private let ids = (0..<4).map { _ in UUID() }

    private func makeIndex() -> TimelineIndex {
        TimelineIndex(entries: [
            (ids[0], 0, 2),
            (ids[1], 2, 4),
            (ids[2], 10, 12),  // 与上一句之间有 6 秒静音
            (ids[3], 12, 14),
        ])
    }

    @Test func resolvesInsideSentence() {
        let index = makeIndex()
        #expect(index.resolve(at: 1)?.id == ids[0])
        #expect(index.resolve(at: 3)?.id == ids[1])
        #expect(index.resolve(at: 13)?.id == ids[3])
    }

    /// 静音间隙里**保留上一句**，不清空、不闪烁。
    @Test func staysOnPreviousSentenceDuringSilence() {
        let index = makeIndex()
        let active = try! #require(index.resolve(at: 7))
        #expect(active.id == ids[1])
        #expect(active.isInGap)  // 只影响样式变暗
    }

    /// 句内不算间隙。
    @Test func notInGapWhileSpeaking() {
        #expect(makeIndex().resolve(at: 3)?.isInGap == false)
    }

    /// 第一句开始之前没有当前句。
    @Test func returnsNilBeforeFirstSentence() {
        #expect(makeIndex().resolve(at: -1) == nil)
        // 边界：恰好等于第一句起点时应命中
        #expect(makeIndex().resolve(at: 0)?.id == ids[0])
    }

    /// 播完之后停在最后一句。
    @Test func clampsToLastSentenceAfterEnd() {
        let active = try! #require(makeIndex().resolve(at: 999))
        #expect(active.id == ids[3])
        #expect(active.isInGap)
    }

    @Test func handlesEmptyTimeline() {
        #expect(TimelineIndex(entries: []).resolve(at: 5) == nil)
        #expect(TimelineIndex(entries: []).isEmpty)
    }

    /// 乱序输入要自己排好，不能依赖调用方。
    @Test func sortsUnorderedEntries() {
        let index = TimelineIndex(entries: [
            (ids[1], 5, 7),
            (ids[0], 0, 2),
        ])
        #expect(index.resolve(at: 1)?.id == ids[0])
        #expect(index.resolve(at: 6)?.id == ids[1])
    }

    /// 二分在大规模下也要给出正确答案（600 句是一小时视频的量级）。
    @Test func binarySearchIsCorrectAtScale() {
        let entries = (0..<600).map { index in
            (UUID(), Double(index) * 5, Double(index) * 5 + 4)
        }
        let index = TimelineIndex(entries: entries)
        for probe in stride(from: 0, to: 3000, by: 37) {
            let active = try! #require(index.resolve(at: Double(probe)))
            #expect(active.index == probe / 5)
        }
    }
}
