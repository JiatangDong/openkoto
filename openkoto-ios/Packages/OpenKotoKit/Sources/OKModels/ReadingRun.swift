import Foundation

/// 带读音的文本片段：`reading` 非空表示这一段需要注音（日语振假名 / 中文拼音 / 罗马字转写）。
///
/// 一句话被切成若干 run，顺序拼接即原文——用 run 序列而不是"偏移 + 注音表"，
/// 是为了绕开 `String.Index` 换算和切分后重定位的坑（理由同 `RubyText`）。
///
/// 三个来源共用这一个结构：原书 `<ruby>` / 青空 `《》` 解析、离线注音器、AI 精讲。
public struct ReadingRun: Sendable, Equatable, Hashable, Codable {
    public var text: String
    public var reading: String?

    public init(text: String, reading: String? = nil) {
        self.text = text
        self.reading = reading
    }
}

extension Array where Element == ReadingRun {
    /// 顺序拼接即原文。
    public var plainText: String { map(\.text).joined() }

    public var hasReadings: Bool { contains { $0.reading?.isEmpty == false } }

    /// 合并相邻的无注音片段，减少 run 数量（CoreText 的 attribute run 越少越好）。
    public func mergingUnannotated() -> [ReadingRun] {
        reduce(into: [ReadingRun]()) { result, run in
            if run.reading == nil, let last = result.last, last.reading == nil {
                result[result.count - 1].text += run.text
            } else {
                result.append(run)
            }
        }
    }
}
