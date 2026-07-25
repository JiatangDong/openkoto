import Foundation
import Testing

@testable import OKBooks

/// 编码嗅探测试。
/// 样本一律在测试期用 `String.data(using:)` 现编，git 里不放二进制 fixture。
@Suite struct EncodingDetectorTests {
    static let japanese = "吾輩は猫である。名前はまだ無い。どこで生れたか頓と見当がつかぬ。"
    static let simplifiedChinese = "我是一只猫。还没有名字。不知道在什么地方出生的。"
    static let traditionalChinese = "我是一隻貓。還沒有名字。不知道在什麼地方出生的。"
    static let korean = "나는 고양이다. 이름은 아직 없다. 어디서 태어났는지 도무지 알 수 없다."

    /// 往返：各历史编码编出的字节必须解回原文。
    @Test(arguments: [
        (japanese, String.Encoding.shiftJIS),
        (japanese, .japaneseEUC),
        (japanese, .utf8),
        (simplifiedChinese, EncodingDetector.gb18030),
        (traditionalChinese, EncodingDetector.big5),
        (korean, EncodingDetector.eucKR),
        ("I am a cat. As yet I have no name.", .utf8),
        ("Le café est très chaud, à côté de la fenêtre déjà ouverte.", .isoLatin1),
    ])
    func roundTripsLegacyEncodings(text: String, encoding: String.Encoding) throws {
        let data = try #require(text.data(using: encoding))
        #expect(EncodingDetector.decode(data).text == text)
    }

    /// 回归：旧实现（第一个不返回 nil 的编码）把这两例解成乱码——
    /// Shift_JIS 变「賡鑹苍鑌苅芠苩腂」，GB18030 中文变谚文。
    @Test func recoversTextThatLegacyOrderingCorrupted() throws {
        let sjis = try #require(Self.japanese.data(using: .shiftJIS))
        #expect(EncodingDetector.decode(sjis).text == Self.japanese)
        #expect(EncodingDetector.decode(sjis).encoding == .shiftJIS)

        let gb = try #require(Self.simplifiedChinese.data(using: EncodingDetector.gb18030))
        #expect(EncodingDetector.decode(gb).text == Self.simplifiedChinese)
        #expect(EncodingDetector.decode(gb).encoding == EncodingDetector.gb18030)
    }

    @Test(arguments: [
        (String.Encoding.utf8, Data([0xEF, 0xBB, 0xBF])),
        (.utf16LittleEndian, Data([0xFF, 0xFE])),
        (.utf16BigEndian, Data([0xFE, 0xFF])),
        (.utf32LittleEndian, Data([0xFF, 0xFE, 0x00, 0x00])),
        (.utf32BigEndian, Data([0x00, 0x00, 0xFE, 0xFF])),
    ])
    func stripsBOMAndHonorsIt(encoding: String.Encoding, bom: Data) throws {
        let body = try #require(Self.japanese.data(using: encoding))
        let result = EncodingDetector.decode(bom + body)
        #expect(result.text == Self.japanese)
        #expect(result.encoding == encoding)
    }

    /// 无 BOM 的 UTF-16 靠 NUL 密度 + 奇偶位置判定字节序。
    @Test(arguments: [String.Encoding.utf16LittleEndian, .utf16BigEndian])
    func detectsUTF16WithoutBOM(encoding: String.Encoding) throws {
        let text = "吾輩は猫である。Name is not yet decided."
        let data = try #require(text.data(using: encoding))
        let result = EncodingDetector.decode(data)
        #expect(result.text == text)
        #expect(result.encoding == encoding)
    }

    /// 短样本（几个字）也要判对——分章标题就是这个长度。
    @Test func handlesVeryShortSamples() throws {
        for (text, encoding) in [
            ("第一章", String.Encoding.shiftJIS),
            ("第一章", EncodingDetector.gb18030),
            ("こんにちは", .shiftJIS),
            ("猫", .shiftJIS),
        ] {
            let data = try #require(text.data(using: encoding))
            #expect(EncodingDetector.decode(data).text == text)
        }
    }

    /// 青空文庫的底本说明块（半角数字 + 全角标点混排）。
    @Test func handlesAozoraColophonInShiftJIS() throws {
        let text = "底本：「吾輩は猫である」岩波文庫、岩波書店\n1990（平成2）年1月16日第1刷発行"
        let data = try #require(text.data(using: .shiftJIS))
        #expect(EncodingDetector.decode(data).text == text)
    }

    /// 以 ASCII 为主、只夹杂个别重音字母的西欧文本不能被误判成中文——
    /// 打分里"夹在 ASCII 字母之间的孤立汉字"惩罚就是为这个场景。
    @Test func doesNotMistakeLatinTextForChinese() throws {
        let text = "naive resume with cafeé inside a long english sentence here"
        let data = try #require(text.data(using: .isoLatin1))
        #expect(EncodingDetector.decode(data).text == text)
    }

    @Test func decodesEmptyDataAsEmptyString() {
        let result = EncodingDetector.decode(Data())
        #expect(result.text.isEmpty)
        #expect(result.encoding == .utf8)
    }

    /// 打分是相对比较：正确解码必须高于同一份字节的错误解码。
    /// 对照组用 Latin-1——单字节编码 256 个码位全有定义，任何字节序列都解得出，
    /// 而多字节编码（如 EUC-KR）遇到非法序列会直接返回 nil，构不成对照。
    @Test func scoresCorrectDecodingHigherThanMojibake() throws {
        let data = try #require(Self.japanese.data(using: .shiftJIS))
        let correct = try #require(String(data: data, encoding: .shiftJIS))
        let mojibake = try #require(String(data: data, encoding: .isoLatin1))
        #expect(EncodingDetector.score(correct) > EncodingDetector.score(mojibake))
    }

    /// 超过采样上限的大文件：打分只看前 64KB，但返回的必须是全量文本。
    @Test func decodesFullTextBeyondSampleWindow() throws {
        let text = String(repeating: "そのころ私は毎日のように海へ出かけていた。", count: 8_000)
        let data = try #require(text.data(using: .shiftJIS))
        #expect(data.count > EncodingDetector.sampleByteCount)
        let result = EncodingDetector.decode(data)
        #expect(result.encoding == .shiftJIS)
        #expect(result.text == text)
    }
}
