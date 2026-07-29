import Foundation
import Testing

@testable import OKFeatures

/// 统计页分类 X 轴的标签抽稀。
///
/// 守的是一个三平台同时坏了很久的回归：`.automatic(desiredCount:)` 对分类轴
/// （X 值是 String）无效，30 天日期序列会渲染 30 个标签，全部被压成「…」。
/// 这里断言的核心不变量是**结果数量不超过 target** —— 一旦超了就又开始截断，
/// 而截断了等于一个标签都没有。
@Suite struct ChartAxisTests {
    /// 复习活跃度 / 阅读时长：30 天。
    @Test func thirtyDaysCollapseToAtMostFiveLabels() {
        let labels = (1...30).map { String(format: "07-%02d", $0) }
        let result = ChartAxis.stridedLabels(labels)
        #expect(result.count == 5)
        #expect(result.first == "07-01")
        // 等距，不是取前 5 个
        #expect(result == ["07-01", "07-07", "07-13", "07-19", "07-25"])
    }

    /// 复习预测：实测约 13 天，同样不能超。
    @Test func forecastRangeStaysWithinTarget() {
        let labels = (1...13).map { String(format: "08-%02d", $0) }
        #expect(ChartAxis.stridedLabels(labels).count <= 5)
    }

    /// 少于目标数时原样返回——没有截断风险就不该丢信息。
    @Test func shortSeriesKeepsEveryLabel() {
        let labels = ["07-01", "07-02", "07-03"]
        #expect(ChartAxis.stridedLabels(labels) == labels)
        #expect(ChartAxis.stridedLabels([]) == [])
    }

    /// 任意长度都不得超过 target。这条比具体取值更重要：
    /// 超了就是回到「一排省略号」的坏状态。
    @Test(arguments: [1, 2, 5, 6, 7, 9, 10, 13, 30, 31, 90, 365])
    func neverExceedsTarget(count: Int) {
        let labels = (0..<count).map { "d\($0)" }
        let result = ChartAxis.stridedLabels(labels)
        #expect(result.count <= 5)
        #expect(result.count >= 1)
        #expect(result.first == labels.first)
        // 抽出来的必须是原序列里的值，且保持原顺序
        #expect(result.allSatisfy(labels.contains))
    }

    /// target 是可调的，别把 5 焊死在实现里。
    @Test func honoursAnExplicitTarget() {
        let labels = (0..<100).map { "d\($0)" }
        #expect(ChartAxis.stridedLabels(labels, target: 3).count <= 3)
        #expect(ChartAxis.stridedLabels(labels, target: 10).count <= 10)
        #expect(ChartAxis.stridedLabels(labels, target: 0).isEmpty)
    }
}
