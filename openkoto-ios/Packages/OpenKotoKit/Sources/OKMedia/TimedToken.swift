import Foundation

/// 带时间的文本片段——**所有字幕来源的统一中间表示**。
///
/// 词级来源（iOS 26 端上转写）是 1 词 = 1 token；
/// cue 级来源（用户导入的 SRT/VTT）是 1 条字幕 = 1 token。
///
/// 两者唯一的差别是「句边界落在 token 内部时要不要按字符比例插值」——
/// 而在一个 0.3 秒的词内部插值，误差是亚 100 毫秒的噪声，无害。
/// **所以永远插值，不分支**，下游只有一条代码路径。
public struct TimedToken: Sendable, Equatable, Hashable, Codable {
    public var text: String
    /// 秒。
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }

    public var duration: Double { max(0, end - start) }
}

extension Array where Element == TimedToken {
    /// 排序、丢空、修 `end < start`、修单调性。
    ///
    /// 单调性修复是桌面端「时间戳漂移」那一类问题的正解：与其在下游到处判重叠，
    /// 不如在入口就保证 `start[i] >= end[i-1]`，让后面所有代码可以假定时间轴是有序的。
    func normalized(minDuration: Double = 0.08) -> [TimedToken] {
        var result: [TimedToken] = []
        result.reserveCapacity(count)
        for token in self.filter({ !$0.text.isEmpty && $0.start.isFinite && $0.end.isFinite })
            .sorted(by: { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start })
        {
            var fixed = token
            if let previous = result.last {
                fixed.start = Swift.max(fixed.start, previous.end)
            }
            if fixed.end < fixed.start + minDuration {
                fixed.end = fixed.start + minDuration
            }
            result.append(fixed)
        }
        return result
    }
}
