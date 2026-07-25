import CoreFoundation
import Foundation

/// 文本编码嗅探（小说导入的第一道关口）。
///
/// 取代"按顺序取第一个解码不返回 nil 的编码"这种写法——那条路径对**所有**非 UTF-8
/// 文本都会失败，因为 `.utf16` 接受任意偶数长度字节序列：Shift_JIS 的
/// 「吾輩は猫である。」会被解成「賡鑹苍鑌苅芠苩腂」，GB18030 中文同样变成谚文乱码。
///
/// 判定顺序：
/// 1. BOM（UTF-8 / UTF-16 / UTF-32）——最可靠，直接采信；
/// 2. 无 BOM 的 UTF-16——按 NUL 字节密度判定，再按 NUL 落在奇位还是偶位区分 LE/BE；
/// 3. 严格 UTF-8 校验；
/// 4. 候选编码逐个解码 + 打分取最高（见 `score(_:)`）。
///
/// 打分只在前 64KB 上做，选出编码后再全量解码——避免对一本 50 万字小说做 7 次全量解码。
public enum EncodingDetector {
    public struct Result: Sendable, Equatable {
        public let text: String
        public let encoding: String.Encoding

        public init(text: String, encoding: String.Encoding) {
            self.text = text
            self.encoding = encoding
        }
    }

    /// Foundation 未直接暴露的编码经 CoreFoundation 取值。
    private static func cf(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(encoding.rawValue)))
    }

    public static let gb18030 = cf(.GB_18030_2000)
    public static let big5 = cf(.big5)
    public static let eucKR = cf(.EUC_KR)

    /// 候选集：中日韩三语常见的历史编码 + 西欧兜底。
    /// 顺序只影响同分时的取舍，实际由 `score` 决定。
    static let candidates: [String.Encoding] = [
        .shiftJIS, .japaneseEUC, gb18030, big5, eucKR, .windowsCP1252, .isoLatin1,
    ]

    /// 打分采样上限：足够判断语种，又不至于让大文件解码 7 遍。
    static let sampleByteCount = 64 * 1024

    public static func decode(_ data: Data) -> Result {
        guard !data.isEmpty else { return Result(text: "", encoding: .utf8) }
        if let bom = decodeWithBOM(data) { return bom }
        if let wide = decodeUTF16WithoutBOM(data) { return wide }
        if let text = String(data: data, encoding: .utf8) {
            return Result(text: text, encoding: .utf8)
        }

        let sample = data.prefix(sampleByteCount)
        var ranked: [(encoding: String.Encoding, score: Int)] = []
        for encoding in candidates {
            guard let text = decodeTolerantly(sample, encoding) else { continue }
            ranked.append((encoding, score(text)))
        }
        ranked.sort { $0.score > $1.score }
        // 采样能解不代表全量能解（尾部可能截断在多字节序列中间），按分数依次退让。
        for candidate in ranked {
            if let text = String(data: data, encoding: candidate.encoding) {
                return Result(text: text, encoding: candidate.encoding)
            }
        }
        return Result(text: String(decoding: data, as: UTF8.self), encoding: .utf8)
    }

    // MARK: - 前置判定

    static func decodeWithBOM(_ data: Data) -> Result? {
        let head = [UInt8](data.prefix(4))
        func stripping(_ count: Int, _ encoding: String.Encoding) -> Result? {
            guard let text = String(data: data.dropFirst(count), encoding: encoding)
            else { return nil }
            return Result(text: text, encoding: encoding)
        }
        if head.count >= 3, head[0] == 0xEF, head[1] == 0xBB, head[2] == 0xBF {
            return stripping(3, .utf8)
        }
        // UTF-32 的 BOM 前两字节与 UTF-16 相同，必须先判。
        if head.count >= 4, head[0] == 0xFF, head[1] == 0xFE, head[2] == 0x00, head[3] == 0x00 {
            return stripping(4, .utf32LittleEndian)
        }
        if head.count >= 4, head[0] == 0x00, head[1] == 0x00, head[2] == 0xFE, head[3] == 0xFF {
            return stripping(4, .utf32BigEndian)
        }
        if head.count >= 2, head[0] == 0xFF, head[1] == 0xFE {
            return stripping(2, .utf16LittleEndian)
        }
        if head.count >= 2, head[0] == 0xFE, head[1] == 0xFF {
            return stripping(2, .utf16BigEndian)
        }
        return nil
    }

    /// 无 BOM 的 UTF-16：拉丁/CJK 文本在 UTF-16 下有大量 NUL 高位字节。
    /// 用密度判定，再用 NUL 的奇偶位置定字节序（LE 下 NUL 落在奇位）。
    /// 这条规则让 `.utf16` 不必进入打分候选集——它对任意偶数长度输入都返回非 nil，
    /// 一旦参与打分就会污染结果。
    static func decodeUTF16WithoutBOM(_ data: Data) -> Result? {
        let probe = [UInt8](data.prefix(4096))
        guard probe.count >= 16 else { return nil }
        var evenZeros = 0
        var oddZeros = 0
        for (index, byte) in probe.enumerated() where byte == 0 {
            if index.isMultiple(of: 2) { evenZeros += 1 } else { oddZeros += 1 }
        }
        guard (evenZeros + oddZeros) * 4 > probe.count else { return nil }
        let encoding: String.Encoding = evenZeros > oddZeros ? .utf16BigEndian : .utf16LittleEndian
        guard let text = String(data: data, encoding: encoding) else { return nil }
        return Result(text: text, encoding: encoding)
    }

    /// 采样切片可能截断在多字节序列中间，去掉尾部至多 4 字节再试。
    static func decodeTolerantly(_ data: Data, _ encoding: String.Encoding) -> String? {
        for trimmed in 0...4 {
            let slice = data.dropLast(trimmed)
            if slice.isEmpty { return nil }
            if let text = String(data: slice, encoding: encoding) { return text }
        }
        return nil
    }

    // MARK: - 打分

    /// 正常文本可能出现的 Unicode 区段白名单。落在名单外一律重罚——
    /// 乱码的典型特征就是散落到彝文、傈僳文这类几乎不会出现在小说里的区段。
    static let textRanges: [ClosedRange<UInt32>] = [
        0x0009...0x000A, 0x000D...0x000D, 0x0020...0x007E,  // ASCII
        0x00A0...0x024F,  // 拉丁-1 补充 + 拉丁扩展 A/B
        0x0370...0x03FF, 0x0400...0x04FF,  // 希腊、西里尔
        0x1100...0x11FF,  // 谚文字母
        0x2000...0x206F, 0x20A0...0x20BF, 0x2190...0x21FF,  // 标点、货币、箭头
        0x2500...0x257F, 0x25A0...0x25FF, 0x2600...0x26FF,  // 制表符（青空文庫分隔线）、几何图形
        0x3000...0x303F, 0x3040...0x309F, 0x30A0...0x30FF,  // CJK 标点、平假名、片假名
        0x3130...0x318F, 0x31F0...0x31FF,
        0x3400...0x4DBF, 0x4E00...0x9FFF,  // 汉字扩展 A、基本区
        0xAC00...0xD7A3, 0xF900...0xFAFF,  // 谚文音节、兼容汉字
        0xFF01...0xFF60, 0xFF61...0xFF9F,  // 全角、半角片假名
        0x1F300...0x1FAFF, 0x20000...0x2A6DF,  // emoji、汉字扩展 B
    ]

    /// 高频字加分：区分"解出了汉字"和"解对了语言"。
    static let commonCJK: Set<Unicode.Scalar> = [
        "的", "一", "是", "了", "不", "在", "人", "有", "我", "他", "这", "中", "大", "来", "上",
        "の", "は", "に", "を", "た", "し", "て", "い", "る", "と", "が", "で", "な", "だ", "ま",
        "이", "다", "는", "을", "에", "하", "고", "지", "서", "의",
    ]

    static func isTextScalar(_ value: UInt32) -> Bool {
        textRanges.contains { $0.contains(value) }
    }

    static func isCJKScalar(_ value: UInt32) -> Bool {
        (0x3040...0x30FF).contains(value) || (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value) || (0xAC00...0xD7A3).contains(value)
            || (0xF900...0xFAFF).contains(value)
    }

    static func isASCIILetter(_ value: UInt32) -> Bool {
        (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
    }

    /// 每千字符得分（可比较，不做绝对阈值判断）。
    static func score(_ text: String) -> Int {
        let scalars = Array(text.unicodeScalars.prefix(20_000))
        guard !scalars.isEmpty else { return 0 }
        var points = 0
        var kana = 0
        var hangul = 0

        for (index, scalar) in scalars.enumerated() {
            let value = scalar.value
            if value == 0xFFFD {
                points -= 30
                continue
            }
            // 私用区：解码器塞不下时的产物，正常文本几乎不会用。
            if (0xE000...0xF8FF).contains(value) || (0xF0000...0x10FFFD).contains(value) {
                points -= 30
                continue
            }
            if !isTextScalar(value) {
                points -= 12
                continue
            }
            points += 2
            if commonCJK.contains(scalar) { points += 3 }
            if (0x3040...0x30FF).contains(value) { kana += 1 }
            if (0xAC00...0xD7A3).contains(value) { hangul += 1 }
            // 夹在两个 ASCII 字母中间的孤立汉字/假名是典型乱码特征
            // （如 "Café" 的 0xE9 被 GB18030 当成汉字前导字节）。
            if isCJKScalar(value), index > 0, index + 1 < scalars.count,
                isASCIILetter(scalars[index - 1].value), isASCIILetter(scalars[index + 1].value)
            {
                points -= 12
            }
        }

        // 假名与谚文大量共存基本只出现在乱码里（如 Shift_JIS 被当成 UTF-16）。
        points -= min(kana, hangul) * 8
        return points * 1000 / scalars.count
    }
}
