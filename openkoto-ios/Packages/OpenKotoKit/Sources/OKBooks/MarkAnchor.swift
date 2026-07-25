import Foundation
import OKModels

/// 书签 / 划线的重锚。
///
/// 锚点会失效：章节重新切分后句序变了，或者用户在原版模式建的标记要拿到原生模式用。
/// 所以每条标记都同时存三样东西——句序、原版定位符、**选中的原文**，
/// 按可靠性从高到低依次尝试，最后退到"大概位置"也绝不丢标记。
public enum MarkAnchor {
    public struct Resolution: Sendable, Equatable {
        /// 定位到的句序；整章都找不到时为 nil。
        public let segmentOrder: Int?
        /// 句内区间（Unicode 标量偏移）。
        public let range: Range<Int>?
        /// 靠比例兜底定位的，位置只是近似——界面上要标出来。
        public let isApproximate: Bool
    }

    /// 原生模式的重锚级联：句序命中 → 扫原文 → 按比例兜底。
    public static func resolve(_ mark: BookMark, in segments: [ArticleSegment]) -> Resolution {
        guard !segments.isEmpty else {
            return Resolution(segmentOrder: nil, range: nil, isApproximate: true)
        }

        // 1. 句序仍然指向同一段文字 → 直接采信。
        if let order = mark.segmentOrder,
            let segment = segments.first(where: { $0.order == order })
        {
            if let text = mark.selectedText, !text.isEmpty {
                if let range = scalarRange(of: text, in: segment.text) {
                    return Resolution(segmentOrder: order, range: range, isApproximate: false)
                }
            } else {
                return Resolution(
                    segmentOrder: order, range: charRange(of: mark), isApproximate: false)
            }
        }

        // 2. 句序漂了（重新切分过）：拿原文全章找。
        if let text = mark.selectedText, !text.isEmpty {
            for segment in segments {
                if let range = scalarRange(of: text, in: segment.text) {
                    return Resolution(
                        segmentOrder: segment.order, range: range, isApproximate: false)
                }
            }
        }

        // 3. 都找不到：按比例落到大概位置，并标记为近似。
        if let fraction = mark.scrollFraction {
            let index = Int((fraction * Double(segments.count)).rounded())
            let clamped = min(max(index, 0), segments.count - 1)
            return Resolution(
                segmentOrder: segments[clamped].order, range: nil, isApproximate: true)
        }
        if let order = mark.segmentOrder {
            let clamped = min(max(order, 0), segments.count - 1)
            return Resolution(
                segmentOrder: segments[clamped].order, range: nil, isApproximate: true)
        }
        return Resolution(segmentOrder: nil, range: nil, isApproximate: true)
    }

    /// 在原版模式建的标记补上原生锚点（反之亦然），让书签面板与两种模式都能用。
    public static func filledCrossModeAnchors(
        _ mark: BookMark, segments: [ArticleSegment], segmentCount: Int
    ) -> BookMark {
        var filled = mark
        let resolution = resolve(mark, in: segments)
        if filled.segmentOrder == nil { filled.segmentOrder = resolution.segmentOrder }
        if filled.charStart == nil, let range = resolution.range {
            filled.charStart = range.lowerBound
            filled.charEnd = range.upperBound
        }
        if filled.scrollFraction == nil, let order = resolution.segmentOrder, segmentCount > 0 {
            filled.scrollFraction = Double(order) / Double(segmentCount)
        }
        return filled
    }

    private static func charRange(of mark: BookMark) -> Range<Int>? {
        guard let start = mark.charStart, let end = mark.charEnd, start < end else { return nil }
        return start..<end
    }

    /// 按 Unicode 标量偏移找子串——与 `ArticleSegment` 里其它偏移语义保持一致。
    static func scalarRange(of needle: String, in haystack: String) -> Range<Int>? {
        let target = Array(needle.unicodeScalars)
        let source = Array(haystack.unicodeScalars)
        guard !target.isEmpty, target.count <= source.count else { return nil }
        let last = source.count - target.count
        var index = 0
        while index <= last {
            var matched = true
            for offset in 0..<target.count where source[index + offset] != target[offset] {
                matched = false
                break
            }
            if matched { return index..<(index + target.count) }
            index += 1
        }
        return nil
    }
}
