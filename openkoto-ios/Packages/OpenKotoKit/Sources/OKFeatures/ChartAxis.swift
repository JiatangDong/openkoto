/// 分类（字符串）X 轴的标签抽稀。
///
/// **不要用 `.automatic(desiredCount:)` 抽稀分类轴** —— 它只对连续轴（Date / 数值）
/// 生效。三个日期图表的 X 值是 `String(dateLocal.suffix(5))`，Swift Charts 按分类轴
/// 处理，每个类目必出一个标签：30 天就是 30 个标签挤在 360–470pt 里，
/// 每个都被压成「…」，整条轴变成一排省略号。必须把要显示的类目值显式交给
/// `AxisMarks(values:)`。
///
/// 与平台无关的纯函数，进 `swift test`（见 `ChartAxisTests`）——
/// 这是唯一能自动守住这个回归的层。
enum ChartAxis {
    /// 从类目序列里等距抽出至多 `target` 个作为轴标签，永远包含第一个。
    ///
    /// 步长向上取整，保证结果**不超过** `target`：宁可标签稀一点，
    /// 也不能多到又开始截断——截断了等于一个都没有。
    static func stridedLabels(_ labels: [String], target: Int = 5) -> [String] {
        guard target > 0 else { return [] }
        guard labels.count > target else { return labels }
        let step = Int((Double(labels.count) / Double(target)).rounded(.up))
        return stride(from: 0, to: labels.count, by: step).map { labels[$0] }
    }
}
