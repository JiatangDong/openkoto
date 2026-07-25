#if os(iOS)
import Foundation
import Testing
import UIKit

@testable import OKDesignSystem

/// 把振假名渲染成 PNG 落到临时目录，供人眼确认排版（注音位置、折行、宽注音撑宽）。
/// 不做像素断言——字体渲染跨系统版本会变，断言像素只会变成噪声。
@Suite struct RubySnapshotTests {
    @MainActor
    private func snapshot(_ runs: [RubyRun], maxWidth: CGFloat, name: String) throws {
        let view = RubyUIView()
        view.apply(runs: runs, fontSize: 22, color: .black, rubyColor: .darkGray)
        let size = view.layout(maxWidth: maxWidth).size
        view.frame = CGRect(origin: .zero, size: size)

        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            view.layer.render(in: context.cgContext)
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ruby-\(name).png")
        try #require(image.pngData()).write(to: url)
        print("SNAPSHOT \(name): \(url.path)")
    }

    @MainActor
    @Test func rendersJapaneseFurigana() throws {
        try snapshot(
            [
                ReadingRunFixture.run("夜", "よる"), ReadingRunFixture.run("に"),
                ReadingRunFixture.run("駆", "か"), ReadingRunFixture.run("ける"),
                ReadingRunFixture.run("君", "きみ"), ReadingRunFixture.run("の"),
                ReadingRunFixture.run("声", "こえ"), ReadingRunFixture.run("が"),
                ReadingRunFixture.run("聞", "き"), ReadingRunFixture.run("こえる"),
            ], maxWidth: 320, name: "japanese")
    }

    /// 注音比基文宽（私/わたくし）时 CoreText 会撑宽基文，注音不该压到邻字上。
    @MainActor
    @Test func rendersWideReadingAndWrapping() throws {
        let runs = (0..<6).flatMap { _ in
            [ReadingRunFixture.run("私", "わたくし"), ReadingRunFixture.run("は")]
        }
        try snapshot(runs, maxWidth: 240, name: "wide-wrapped")
    }

    @MainActor
    @Test func rendersChinesePinyin() throws {
        try snapshot(
            [
                ReadingRunFixture.run("银行", "yínháng"),
                ReadingRunFixture.run("行长", "hángzhǎng"),
                ReadingRunFixture.run("说这首歌的"),
                ReadingRunFixture.run("长度", "chángdù"),
            ], maxWidth: 320, name: "chinese")
    }
}

private enum ReadingRunFixture {
    static func run(_ text: String, _ reading: String? = nil) -> RubyRun {
        RubyRun(text: text, reading: reading)
    }
}
#endif
