import Foundation

/// XHTML 章节 → 带注音的纯文本。
///
/// 用 `XMLParser`（SAX）而不是 `XMLDocument`——后者只有 macOS 有，iOS 上不存在。
/// 野生 EPUB 的 XHTML 经常不是良构 XML（引用无 DTD 的命名实体、标签不闭合），
/// 所以先做容错预处理，仍失败再退到手写扫描器；两条路径产出同样的语义。
public enum XHTMLTextExtractor {
    /// 内容整体丢弃的元素。`svg` 一并跳过：固定版式书把整页塞进 SVG，
    /// 留着会污染"抽取文本近乎为空 ⇒ 图文书"的判定。
    static let skippedElements: Set<String> = ["script", "style", "head", "svg", "template"]

    /// 产生换行的块级元素。必须完整——`SentenceSegmenter` 按 `\n` 切段落，
    /// 漏掉 `p` 之类会让整章挤成一段。
    static let blockElements: Set<String> = [
        "p", "div", "br", "hr", "li", "ul", "ol", "dl", "dd", "dt",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "blockquote", "pre", "section", "article", "aside", "nav", "main",
        "header", "footer", "figure", "figcaption", "table", "tr", "td", "th",
        "body", "center", "address",
    ]

    public static func extract(xhtml: String) -> RubyText {
        let prepared = preprocess(xhtml)
        if let parsed = parseStrictly(prepared) { return parsed }
        return scan(prepared)
    }

    // MARK: - 预处理

    /// 去 DOCTYPE + 把命名实体换成字面量。
    /// XML 预定义的五个实体保留给解析器；表里没有的未知实体转义成 `&amp;name;`
    /// ——既不让解析失败，也不丢字符。
    static func preprocess(_ xhtml: String) -> String {
        var text = xhtml.replacingOccurrences(
            of: "<!DOCTYPE[^>\\[]*(\\[[\\s\\S]*?\\])?[^>]*>",
            with: "", options: [.regularExpression, .caseInsensitive])

        guard text.contains("&") else { return text }

        let pattern = try! NSRegularExpression(pattern: "&([a-zA-Z][a-zA-Z0-9]{1,31});")
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        var result = ""
        var last = text.startIndex

        for match in pattern.matches(in: text, range: full) {
            guard let range = Range(match.range, in: text),
                let nameRange = Range(match.range(at: 1), in: text)
            else { continue }
            let name = String(text[nameRange])
            result += text[last..<range.lowerBound]
            if HTMLEntities.xmlPredefined.contains(name) {
                result += text[range]
            } else if let replacement = HTMLEntities.table[name] {
                result += replacement
            } else {
                result += "&amp;\(name);"
            }
            last = range.upperBound
        }
        result += text[last...]
        text = result
        return text
    }

    // MARK: - SAX 主路径

    private static func parseStrictly(_ xhtml: String) -> RubyText? {
        let parser = XMLParser(data: Data(xhtml.utf8))
        // 关闭命名空间处理：未声明的前缀（野生 EPUB 常见）不会因此直接判为错误，
        // 元素名里的前缀由 delegate 自行剥离。
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        let delegate = SAXDelegate()
        parser.delegate = delegate
        guard parser.parse(), delegate.sawContent else { return nil }
        return delegate.finish()
    }

    private final class SAXDelegate: NSObject, XMLParserDelegate {
        private var builder = RubyTextBuilder()
        private var skipDepth = 0
        private(set) var sawContent = false

        func finish() -> RubyText { builder.build() }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]
        ) {
            let name = localName(elementName)
            sawContent = true
            if skippedElements.contains(name) {
                skipDepth += 1
                return
            }
            guard skipDepth == 0 else { return }
            switch name {
            case "ruby": builder.beginRuby()
            case "rt": builder.beginReading()
            case "rp": builder.beginParenthesis()
            case "rb", "rtc", "rbc": break
            default:
                if blockElements.contains(name) { builder.appendLineBreak() }
            }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            let name = localName(elementName)
            if skippedElements.contains(name) {
                skipDepth = max(0, skipDepth - 1)
                return
            }
            guard skipDepth == 0 else { return }
            switch name {
            case "ruby": builder.endRuby()
            case "rt": builder.endReading()
            case "rp": builder.endParenthesis()
            case "rb", "rtc", "rbc": break
            default:
                if blockElements.contains(name) { builder.appendLineBreak() }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard skipDepth == 0 else { return }
            builder.appendText(string)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard skipDepth == 0 else { return }
            builder.appendText(String(decoding: CDATABlock, as: UTF8.self))
        }

        private func localName(_ raw: String) -> String {
            let stripped = raw.split(separator: ":").last.map(String.init) ?? raw
            return stripped.lowercased()
        }
    }

    // MARK: - 扫描器回退

    /// 手写标签扫描：不要求良构，只认标签边界。
    /// 语义与 SAX 路径一致（ruby / 块级换行 / 跳过元素），两者跑同一套测试。
    static func scan(_ xhtml: String) -> RubyText {
        var builder = RubyTextBuilder()
        let scalars = Array(xhtml.unicodeScalars)
        var index = 0
        var text = String.UnicodeScalarView()

        func flushText() {
            guard !text.isEmpty else { return }
            builder.appendText(HTMLEntities.decode(String(text)))
            text = String.UnicodeScalarView()
        }

        while index < scalars.count {
            guard scalars[index] == "<" else {
                text.append(scalars[index])
                index += 1
                continue
            }

            // 注释里可能含 ">"，必须按 "-->" 找结束。
            if matches(scalars, at: index, "<!--") {
                flushText()
                index = find(scalars, "-->", from: index + 4).map { $0 + 3 } ?? scalars.count
                continue
            }

            guard let close = firstIndex(of: ">", in: scalars, from: index + 1) else {
                text.append(scalars[index])
                index += 1
                continue
            }
            let raw = String(String.UnicodeScalarView(scalars[(index + 1)..<close]))
            index = close + 1

            guard let first = raw.unicodeScalars.first else { continue }
            if first == "!" || first == "?" { continue }  // DOCTYPE / 处理指令

            let isEnd = first == "/"
            let body = isEnd ? String(raw.dropFirst()) : raw
            let name = body
                .prefix { !$0.isWhitespace && $0 != "/" }
                .split(separator: ":").last.map { $0.lowercased() } ?? ""
            guard !name.isEmpty else { continue }
            let isSelfClosing = body.hasSuffix("/")

            flushText()

            // script/style 的内容是**原始文本**，里面的 "<" 不是标签
            // （`var a = 1 < 2;` 会被当成标签开头，把后面整篇正文吃掉）。
            // 直接跳到配对的结束标签，不解析其中任何内容。
            if skippedElements.contains(name), !isEnd, !isSelfClosing {
                if let end = find(scalars, "</\(name)", from: index, caseInsensitive: true),
                    let close = firstIndex(of: ">", in: scalars, from: end)
                {
                    index = close + 1
                } else {
                    index = scalars.count
                }
                continue
            }
            if skippedElements.contains(name) { continue }

            switch name {
            case "ruby":
                if isEnd { builder.endRuby() } else if !isSelfClosing { builder.beginRuby() }
            case "rt":
                if isEnd { builder.endReading() } else if !isSelfClosing { builder.beginReading() }
            case "rp":
                if isEnd {
                    builder.endParenthesis()
                } else if !isSelfClosing {
                    builder.beginParenthesis()
                }
            default:
                if blockElements.contains(name) { builder.appendLineBreak() }
            }
        }
        flushText()
        return builder.build()
    }

    // MARK: - 扫描辅助

    private static func firstIndex(
        of scalar: Unicode.Scalar, in scalars: [Unicode.Scalar], from start: Int
    ) -> Int? {
        var index = start
        while index < scalars.count {
            if scalars[index] == scalar { return index }
            index += 1
        }
        return nil
    }

    private static func matches(
        _ scalars: [Unicode.Scalar], at index: Int, _ needle: String,
        caseInsensitive: Bool = false
    ) -> Bool {
        let target = Array(needle.unicodeScalars)
        guard index + target.count <= scalars.count else { return false }
        for offset in 0..<target.count {
            let lhs = scalars[index + offset]
            let rhs = target[offset]
            if lhs == rhs { continue }
            guard caseInsensitive,
                String(lhs).lowercased() == String(rhs).lowercased()
            else { return false }
        }
        return true
    }

    private static func find(
        _ scalars: [Unicode.Scalar], _ needle: String, from start: Int,
        caseInsensitive: Bool = false
    ) -> Int? {
        var index = start
        while index < scalars.count {
            if matches(scalars, at: index, needle, caseInsensitive: caseInsensitive) {
                return index
            }
            index += 1
        }
        return nil
    }
}

/// HTML 命名实体表。收常见排版符号即可——EPUB 正文用到的实体集中且有限，
/// 表外实体会被转义成字面量而非丢弃。
enum HTMLEntities {
    static let xmlPredefined: Set<String> = ["amp", "lt", "gt", "quot", "apos"]

    static let table: [String: String] = [
        "nbsp": "\u{00A0}", "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}",
        "zwj": "\u{200D}", "zwnj": "\u{200C}", "shy": "\u{00AD}",
        "ndash": "–", "mdash": "—", "horbar": "―", "hellip": "…",
        "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„",
        "laquo": "«", "raquo": "»", "lsaquo": "‹", "rsaquo": "›",
        "dagger": "†", "Dagger": "‡", "bull": "•", "middot": "·", "sect": "§", "para": "¶",
        "copy": "©", "reg": "®", "trade": "™", "deg": "°", "permil": "‰", "prime": "′",
        "Prime": "″", "oline": "‾", "frasl": "⁄",
        "times": "×", "divide": "÷", "minus": "−", "plusmn": "±", "ne": "≠", "le": "≤",
        "ge": "≥", "asymp": "≈", "infin": "∞", "radic": "√", "sum": "∑", "prod": "∏",
        "int": "∫", "part": "∂", "nabla": "∇", "isin": "∈", "notin": "∉", "cap": "∩",
        "cup": "∪", "sub": "⊂", "sup": "⊃", "and": "∧", "or": "∨", "not": "¬",
        "larr": "←", "uarr": "↑", "rarr": "→", "darr": "↓", "harr": "↔", "crarr": "↵",
        "lArr": "⇐", "uArr": "⇑", "rArr": "⇒", "dArr": "⇓", "hArr": "⇔",
        "frac12": "½", "frac14": "¼", "frac34": "¾", "sup1": "¹", "sup2": "²", "sup3": "³",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "curren": "¤",
        "iexcl": "¡", "iquest": "¿", "brvbar": "¦", "uml": "¨", "macr": "¯", "acute": "´",
        "cedil": "¸", "ordf": "ª", "ordm": "º", "micro": "µ",
        "agrave": "à", "aacute": "á", "acirc": "â", "atilde": "ã", "auml": "ä", "aring": "å",
        "aelig": "æ", "ccedil": "ç", "egrave": "è", "eacute": "é", "ecirc": "ê", "euml": "ë",
        "igrave": "ì", "iacute": "í", "icirc": "î", "iuml": "ï", "ntilde": "ñ",
        "ograve": "ò", "oacute": "ó", "ocirc": "ô", "otilde": "õ", "ouml": "ö", "oslash": "ø",
        "ugrave": "ù", "uacute": "ú", "ucirc": "û", "uuml": "ü", "yacute": "ý", "yuml": "ÿ",
        "szlig": "ß", "thorn": "þ", "eth": "ð",
        "Agrave": "À", "Aacute": "Á", "Acirc": "Â", "Atilde": "Ã", "Auml": "Ä", "Aring": "Å",
        "AElig": "Æ", "Ccedil": "Ç", "Egrave": "È", "Eacute": "É", "Ecirc": "Ê", "Euml": "Ë",
        "Igrave": "Ì", "Iacute": "Í", "Icirc": "Î", "Iuml": "Ï", "Ntilde": "Ñ",
        "Ograve": "Ò", "Oacute": "Ó", "Ocirc": "Ô", "Otilde": "Õ", "Ouml": "Ö", "Oslash": "Ø",
        "Ugrave": "Ù", "Uacute": "Ú", "Ucirc": "Û", "Uuml": "Ü", "Yacute": "Ý",
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "theta": "θ",
        "lambda": "λ", "mu": "μ", "pi": "π", "sigma": "σ", "tau": "τ", "phi": "φ",
        "omega": "ω", "Alpha": "Α", "Beta": "Β", "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ",
        "Lambda": "Λ", "Pi": "Π", "Sigma": "Σ", "Phi": "Φ", "Omega": "Ω",
    ]

    /// 扫描器路径用：命名实体 + 数字实体一并解码。
    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let pattern = try! NSRegularExpression(pattern: "&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]{1,31});")
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        var result = ""
        var last = text.startIndex

        for match in pattern.matches(in: text, range: full) {
            guard let range = Range(match.range, in: text),
                let nameRange = Range(match.range(at: 1), in: text)
            else { continue }
            let name = String(text[nameRange])
            result += text[last..<range.lowerBound]
            result += resolve(name) ?? String(text[range])
            last = range.upperBound
        }
        result += text[last...]
        return result
    }

    private static func resolve(_ name: String) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits)
            }
            return value.flatMap(Unicode.Scalar.init).map(String.init)
        }
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        default: return table[name]
        }
    }
}
