import Foundation

/// `RubyText` 的增量构造器：XHTML(SAX / 扫描器回退) 与青空文庫解析共用同一套语义。
///
/// 负责三件容易写歪的事：
/// 1. 文本节点里的空白按 HTML 规则折叠成单个空格（否则源码缩进会被当成正文）；
/// 2. 块级元素产生的换行去重——`SentenceSegmenter` 按 `\n` 切段落，多余换行会切出空段；
/// 3. 收尾时删掉夹在中日文之间的空格（源码换行折叠出来的，中文/日文排版里不该出现）。
struct RubyTextBuilder {
    private var runs: [RubyText.Run] = []
    private var plain = String.UnicodeScalarView()
    private var rubyBase = String.UnicodeScalarView()
    private var rubyReading = String.UnicodeScalarView()
    private var rubyDepth = 0
    private var readingDepth = 0
    /// `<rp>` 是给不支持 ruby 的阅读器看的括号，正文与注音都不要。
    private var parenthesisDepth = 0

    // MARK: - 文本

    mutating func appendText(_ text: String) {
        guard !text.isEmpty, parenthesisDepth == 0 else { return }
        var collapsed = Self.collapsingWhitespace(text)
        guard !collapsed.isEmpty else { return }
        // XMLParser 会在实体处把一个文本节点拆成多次回调（"a " / "<" / " b"），
        // 所以空白折叠必须跨调用去重——只看单次输入会把 "a &lt; b" 吃成 "a <b"。
        if collapsed.first == " ", let last = lastScalar, last == " " || last == "\n" {
            collapsed.removeFirst()
            guard !collapsed.isEmpty else { return }
        }
        if readingDepth > 0 {
            rubyReading.append(contentsOf: collapsed)
        } else if rubyDepth > 0 {
            rubyBase.append(contentsOf: collapsed)
        } else {
            plain.append(contentsOf: collapsed)
        }
    }

    /// 当前写入目标的最后一个标量（正文缓冲为空时看上一个 run 的结尾）。
    private var lastScalar: Unicode.Scalar? {
        if readingDepth > 0 { return rubyReading.last }
        if rubyDepth > 0 { return rubyBase.last }
        if let last = plain.last { return last }
        return runs.last?.text.unicodeScalars.last
    }

    /// 块级元素/`<br>` 产生的换行。连续换行折叠，段首换行丢弃。
    mutating func appendLineBreak() {
        guard rubyDepth == 0, parenthesisDepth == 0 else { return }
        // 换行前的悬空空格没有意义。
        while plain.last == " " { plain.removeLast() }
        guard let last = lastScalar else { return }
        if last != "\n" { plain.append("\n") }
    }

    // MARK: - ruby

    mutating func beginRuby() {
        flushPlain()
        rubyDepth += 1
    }

    mutating func endRuby() {
        guard rubyDepth > 0 else { return }
        rubyDepth -= 1
        guard rubyDepth == 0 else { return }
        let base = String(rubyBase)
        let reading = String(rubyReading)
        rubyBase = String.UnicodeScalarView()
        rubyReading = String.UnicodeScalarView()
        guard !base.isEmpty else { return }
        runs.append(RubyText.Run(text: base, reading: reading.isEmpty ? nil : reading))
    }

    mutating func beginReading() { readingDepth += 1 }
    mutating func endReading() { readingDepth = max(0, readingDepth - 1) }
    mutating func beginParenthesis() { parenthesisDepth += 1 }
    mutating func endParenthesis() { parenthesisDepth = max(0, parenthesisDepth - 1) }

    /// 直接写入一个带注音的片段（青空文庫 `｜漢字《かんじ》` 走这条路）。
    mutating func appendAnnotated(base: String, reading: String) {
        guard !base.isEmpty else { return }
        flushPlain()
        runs.append(RubyText.Run(text: base, reading: reading.isEmpty ? nil : reading))
    }

    private mutating func flushPlain() {
        guard !plain.isEmpty else { return }
        runs.append(RubyText.Run(text: String(plain)))
        plain = String.UnicodeScalarView()
    }

    mutating func build() -> RubyText {
        // 未闭合的 ruby（残缺 HTML）不能丢字：基文并入正文。
        if rubyDepth > 0 {
            let base = String(rubyBase)
            rubyBase = String.UnicodeScalarView()
            rubyReading = String.UnicodeScalarView()
            rubyDepth = 0
            readingDepth = 0
            plain.append(contentsOf: base.unicodeScalars)
        }
        flushPlain()
        return RubyText(runs: Self.tidy(runs))
    }

    // MARK: - 归一化

    /// 文本节点内的空白按 HTML 规则折叠：任意空白串 → 单个空格。
    /// 首尾空白照样保留成一个空格，交给 `appendText` 的跨调用去重与 `tidy` 的收尾处理——
    /// 单次调用无法知道自己是不是文本节点的开头。
    private static func collapsingWhitespace(_ text: String) -> String.UnicodeScalarView {
        var output = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
                pendingSpace = true
                continue
            }
            if pendingSpace {
                output.append(" ")
                pendingSpace = false
            }
            output.append(scalar)
        }
        if pendingSpace { output.append(" ") }
        return output
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x3040...0x30FF).contains(value)  // 假名
            || (0x3400...0x4DBF).contains(value) || (0x4E00...0x9FFF).contains(value)  // 汉字
            || (0xF900...0xFAFF).contains(value)  // 兼容汉字
            || (0x3000...0x303F).contains(value)  // CJK 标点
            || (0xFF00...0xFFEF).contains(value)  // 全角
    }

    /// 收尾清理：删除中日文之间的空格、折叠多余空行、去首尾空白。
    /// 在 run 序列上整体做——空格两侧的字符可能分属不同 run。
    private static func tidy(_ runs: [RubyText.Run]) -> [RubyText.Run] {
        var scalars: [Unicode.Scalar] = []
        var owners: [Int] = []
        for (index, run) in runs.enumerated() {
            for scalar in run.text.unicodeScalars {
                scalars.append(scalar)
                owners.append(index)
            }
        }
        guard !scalars.isEmpty else {
            return runs.filter { !$0.text.isEmpty }
        }

        var keep = [Bool](repeating: true, count: scalars.count)

        // 中日文之间由源码换行折叠出来的空格：删掉。
        for index in 1..<max(scalars.count - 1, 1) where scalars[index] == " " {
            if isCJK(scalars[index - 1]) && isCJK(scalars[index + 1]) { keep[index] = false }
        }
        // 换行前的悬空空格（"正文 \n"）同样无意义，先反向清一遍。
        for index in stride(from: scalars.count - 2, through: 0, by: -1)
        where keep[index] && scalars[index] == " " {
            var next = index + 1
            while next < scalars.count, !keep[next] { next += 1 }
            if next < scalars.count, scalars[next] == "\n" { keep[index] = false }
        }
        // 连续空行折叠成一个（段落之间保留单个 \n 即可，切分器按 \n 分段）。
        var previousWasNewline = false
        for index in 0..<scalars.count {
            guard keep[index] else { continue }
            if scalars[index] == "\n" {
                if previousWasNewline { keep[index] = false }
                previousWasNewline = true
            } else if scalars[index] == " " {
                // 换行之后的空格无意义
                if previousWasNewline { keep[index] = false }
            } else {
                previousWasNewline = false
            }
        }
        // 去首尾空白
        var head = 0
        while head < scalars.count,
            !keep[head] || scalars[head] == " " || scalars[head] == "\n"
        {
            keep[head] = false
            head += 1
        }
        var tail = scalars.count - 1
        while tail >= 0, !keep[tail] || scalars[tail] == " " || scalars[tail] == "\n" {
            keep[tail] = false
            tail -= 1
        }

        var rebuilt: [RubyText.Run] = []
        rebuilt.reserveCapacity(runs.count)
        var currentOwner = -1
        var buffer = String.UnicodeScalarView()

        func flush() {
            guard currentOwner >= 0 else { return }
            let text = String(buffer)
            let reading = runs[currentOwner].reading
            if !text.isEmpty { rebuilt.append(RubyText.Run(text: text, reading: reading)) }
            buffer = String.UnicodeScalarView()
        }

        for index in 0..<scalars.count where keep[index] {
            if owners[index] != currentOwner {
                flush()
                currentOwner = owners[index]
            }
            buffer.append(scalars[index])
        }
        flush()
        return rebuilt
    }
}
