import Foundation

/// 播放位置 → 当前句。纯值类型，可单测，不碰 AVFoundation。
///
/// 查找规则是「**最后一个 start ≤ t 的句子**」，而不是「t 落在 [start, end) 里的句子」。
/// 这一条定义顺手解决了桌面端的字幕闪烁：ASR 词级切分天然留静音间隙，
/// 用半开区间判定时 t 落在间隙里就查无结果、字幕卡直接闪成占位（`VideoSubtitlePlayer.tsx:461`）。
/// 按「最后一个已开始的句子」判定，间隙里的答案天然还是上一句，
/// **不需要任何容忍常数，这个 bug 构造不出来**。
public struct TimelineIndex: Sendable, Equatable {
    public struct Active: Sendable, Equatable {
        public let index: Int
        public let id: UUID
        /// 播放位置已越过本句结束超过 `gapTolerance`——UI 可以把高亮调暗，
        /// 但**不换句、不清空**。
        public let isInGap: Bool
    }

    /// 越过句尾多久才算进入间隙（只影响样式，不影响选中）。
    public static let gapTolerance: Double = 0.3

    private let starts: [Double]
    private let ends: [Double]
    private let ids: [UUID]

    public init(entries: [(id: UUID, start: Double, end: Double)]) {
        let sorted = entries.sorted { $0.start < $1.start }
        starts = sorted.map(\.start)
        ends = sorted.map(\.end)
        ids = sorted.map(\.id)
    }

    public var isEmpty: Bool { starts.isEmpty }
    public var count: Int { starts.count }

    /// 二分。600 句的线性扫描每秒跑 10 次也不至于卡，但真正的代价是
    /// 调用方每次都拿到"新"结果导致 SwiftUI 重新 diff 整个列表——
    /// 所以调用方要在 active 没变时**不写 `@Observable` 属性**。
    public func resolve(at time: Double) -> Active? {
        guard let first = starts.first, time >= first else { return nil }
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= time { low = mid + 1 } else { high = mid }
        }
        let index = low - 1
        return Active(
            index: index, id: ids[index], isInGap: time > ends[index] + Self.gapTolerance)
    }

    public func start(at index: Int) -> Double? {
        starts.indices.contains(index) ? starts[index] : nil
    }

    public func end(at index: Int) -> Double? {
        ends.indices.contains(index) ? ends[index] : nil
    }
}
