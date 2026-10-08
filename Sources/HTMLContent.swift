import Foundation

// 신뢰할 수 없는 HTML을 렌더링하지 않고 "읽기용 블록"으로만 변환한다.
// WebKit/NSAttributedString(html:)을 쓰지 않으므로 스크립트 실행, 원격 리소스 로드,
// 내비게이션이 구조적으로 일어나지 않는다.

enum TextBlockStyle: Equatable {
    case paragraph
    case heading(Int)
    case listItem(depth: Int, marker: String)
    case quote(depth: Int)
    case preformatted
    case tableRow
    case caption
}

struct HTMLImageRef {
    var src: String
    var alt: String?
    var width: Int?
    var height: Int?
}

enum ContentNode {
    case text(TextBlockStyle, String)
    case image(HTMLImageRef)
    case rule
}

enum TextCleanup {
    private static let invisible: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{FEFF}", "\u{034F}", "\u{00AD}", "\u{2060}"]

    static func removeInvisible(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in s.unicodeScalars where !invisible.contains(u) { scalars.append(u) }
        return String(scalars)
    }

    static func isBlank(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { invisible.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}

struct HTMLBlockExtractor {
    private static let skipElements: Set<String> = [
        "script", "style", "head", "title", "noscript", "template", "svg", "math",
        "iframe", "object", "embed", "applet", "xml", "select", "button", "textarea", "canvas", "video", "audio",
    ]
    private static let blockElements: Set<String> = [
        "address", "article", "aside", "blockquote", "center", "dd", "div", "dl", "dt", "fieldset",
        "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr",
        "li", "main", "nav", "ol", "p", "pre", "section", "table", "tbody", "thead", "tfoot", "tr",
        "ul", "caption", "details", "summary", "body", "html",
    ]
    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param",
        "source", "track", "wbr",
    ]

    private let s: [Unicode.Scalar]
    private var i = 0
    private var nodes: [ContentNode] = []
    private var current = ""
    private var pendingSpace = false
    private var preDepth = 0
    private var quoteDepth = 0
    private var headingLevel: Int?
    private var listStack: [(ordered: Bool, counter: Int)] = []
    private var liMarker: String?
    private var liDepth = 0
    private var inLi = false
    private var tableRowDepth = 0
    private var cellCount = 0

    static func extract(_ html: String) -> [ContentNode] {
        var e = HTMLBlockExtractor(scalars: Array(html.unicodeScalars))
        e.run()
        return e.nodes
    }

    private init(scalars: [Unicode.Scalar]) {
        s = scalars
    }

    // MARK: 메인 루프

    private mutating func run() {
        var textStart = 0
        while i < s.count {
            if s[i] == "<" {
                if textStart < i { appendText(String(String.UnicodeScalarView(s[textStart..<i]))) }
                handleTag()
                textStart = i
            } else {
                i += 1
            }
        }
        if textStart < s.count { appendText(String(String.UnicodeScalarView(s[textStart..<s.count]))) }
        flush()
    }

    private mutating func handleTag() {
        guard i + 1 < s.count else { i += 1; return }
        let next = s[i + 1]
        if next == "!" {
            if matches("<!--", at: i) {
                i = indexAfter("-->", from: i + 4) ?? s.count
            } else {
                i = indexAfter(">", from: i + 2) ?? s.count
            }
            return
        }
        if next == "?" {
            i = indexAfter(">", from: i + 2) ?? s.count
            return
        }
        let isEnd = next == "/"
        let nameStart = isEnd ? i + 2 : i + 1
        guard nameStart < s.count, isNameStart(s[nameStart]) else {
            // 태그가 아닌 '<' 문자
            appendText("<")
            i += 1
            return
        }
        var j = nameStart
        while j < s.count, isNameChar(s[j]) { j += 1 }
        let name = String(String.UnicodeScalarView(s[nameStart..<j])).lowercased()
        let (attrs, end, selfClosing) = parseAttributes(from: j)
        i = end

        if isEnd {
            endTag(name)
        } else {
            startTag(name, attrs: attrs, selfClosing: selfClosing)
        }
    }

    private mutating func startTag(_ name: String, attrs: [String: String], selfClosing: Bool) {
        if Self.skipElements.contains(name) {
            if !selfClosing && !Self.voidElements.contains(name) { skipElement(name) }
            return
        }
        if isHidden(attrs) {
            if !selfClosing && !Self.voidElements.contains(name) { skipElement(name) }
            return
        }
        switch name {
        case "br":
            if current.hasSuffix("\n") && preDepth == 0 {
                flush() // <br><br> 는 문단 구분으로 본다
            } else {
                current += "\n"
                pendingSpace = false
            }
        case "img":
            flush()
            if let src = attrs["src"], !src.isEmpty {
                nodes.append(.image(HTMLImageRef(src: decodeEntities(src), alt: attrs["alt"].map(decodeEntities),
                                                 width: intAttr(attrs["width"]), height: intAttr(attrs["height"]))))
            }
        case "hr":
            flush()
            nodes.append(.rule)
        case "h1", "h2", "h3", "h4", "h5", "h6":
            flush()
            headingLevel = Int(String(name.dropFirst())) ?? 2
        case "pre":
            flush()
            preDepth += 1
        case "blockquote":
            flush()
            quoteDepth += 1
        case "ul", "ol":
            flush()
            var start = 1
            if name == "ol", let v = intAttr(attrs["start"]) { start = v }
            listStack.append((name == "ol", start - 1))
        case "li":
            flush()
            if listStack.isEmpty { listStack.append((false, 0)) }
            listStack[listStack.count - 1].counter += 1
            let top = listStack[listStack.count - 1]
            liMarker = top.ordered ? "\(top.counter)." : "•"
            liDepth = listStack.count
            inLi = true
        case "tr":
            flush()
            tableRowDepth += 1
            cellCount = 0
        case "td", "th":
            if cellCount > 0 && !TextCleanup.isBlank(current) {
                current += " │ "
                pendingSpace = false
            } else if !current.isEmpty {
                pendingSpace = true
            }
            cellCount += 1
        default:
            if Self.blockElements.contains(name) { flush() }
        }
    }

    private mutating func endTag(_ name: String) {
        switch name {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            flush()
            headingLevel = nil
        case "pre":
            flush()
            preDepth = max(0, preDepth - 1)
        case "blockquote":
            flush()
            quoteDepth = max(0, quoteDepth - 1)
        case "ul", "ol":
            flush()
            if !listStack.isEmpty { listStack.removeLast() }
            inLi = false
        case "li":
            flush()
            inLi = false
        case "tr":
            flush()
            tableRowDepth = max(0, tableRowDepth - 1)
        case "td", "th":
            pendingSpace = !current.isEmpty
        default:
            if Self.blockElements.contains(name) { flush() }
        }
    }

    // MARK: 텍스트 누적

    private mutating func appendText(_ raw: String) {
        let text = decodeEntities(raw)
        if preDepth > 0 {
            current += text.replacingOccurrences(of: "\r\n", with: "\n")
            return
        }
        for ch in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(ch) && ch != "\u{00A0}" {
                if !current.isEmpty && !current.hasSuffix("\n") { pendingSpace = true }
            } else {
                if pendingSpace { current += " " }
                pendingSpace = false
                current.unicodeScalars.append(ch == "\u{00A0}" ? " " : ch)
            }
        }
    }

    private mutating func flush() {
        defer {
            current = ""
            pendingSpace = false
        }
        var text = TextCleanup.removeInvisible(current)
        if preDepth == 0 {
            text = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
            while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("│") || text.hasSuffix("│") {
                text = text.trimmingCharacters(in: CharacterSet(charactersIn: "│ "))
            }
        } else {
            text = text.trimmingCharacters(in: .newlines)
        }
        guard !TextCleanup.isBlank(text) else { return }

        let style: TextBlockStyle
        if preDepth > 0 {
            style = .preformatted
        } else if let level = headingLevel {
            style = .heading(level)
        } else if inLi {
            style = .listItem(depth: liDepth, marker: liMarker ?? "")
            liMarker = "" // 같은 항목 안의 후속 블록은 표식 없이 들여쓰기만
        } else if quoteDepth > 0 {
            style = .quote(depth: quoteDepth)
        } else if tableRowDepth > 0 && text.contains("│") {
            style = .tableRow
        } else {
            style = .paragraph
        }
        nodes.append(.text(style, text))
    }

    // MARK: 스캐닝 도우미

    private func isNameStart(_ c: Unicode.Scalar) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
    }

    private func isNameChar(_ c: Unicode.Scalar) -> Bool {
        isNameStart(c) || (c >= "0" && c <= "9") || c == "-" || c == ":" || c == "_"
    }

    private func matches(_ pattern: String, at index: Int) -> Bool {
        var k = index
        for p in pattern.unicodeScalars {
            guard k < s.count, Self.lower(s[k]) == p else { return false }
            k += 1
        }
        return true
    }

    private static func lower(_ c: Unicode.Scalar) -> Unicode.Scalar {
        if c >= "A" && c <= "Z", let l = Unicode.Scalar(c.value + 32) { return l }
        return c
    }

    private func indexAfter(_ pattern: String, from start: Int) -> Int? {
        let p = Array(pattern.unicodeScalars)
        var k = start
        while k + p.count <= s.count {
            if s[k] == p[0] && matches(pattern, at: k) { return k + p.count }
            k += 1
        }
        return nil
    }

    /// 태그 이름 이후부터 '>'까지 속성을 읽는다. (속성, 다음 위치, self-closing 여부)
    private func parseAttributes(from start: Int) -> ([String: String], Int, Bool) {
        var attrs: [String: String] = [:]
        var k = start
        var selfClosing = false
        while k < s.count {
            let c = s[k]
            if c == ">" { return (attrs, k + 1, selfClosing) }
            if c == "/" { selfClosing = true; k += 1; continue }
            if CharacterSet.whitespacesAndNewlines.contains(c) { k += 1; continue }
            selfClosing = false
            var nameEnd = k
            while nameEnd < s.count, !CharacterSet.whitespacesAndNewlines.contains(s[nameEnd]),
                  s[nameEnd] != "=", s[nameEnd] != ">", s[nameEnd] != "/" { nameEnd += 1 }
            if nameEnd == k { k += 1; continue }
            let name = String(String.UnicodeScalarView(s[k..<nameEnd])).lowercased()
            k = nameEnd
            while k < s.count, CharacterSet.whitespacesAndNewlines.contains(s[k]) { k += 1 }
            var value = ""
            if k < s.count, s[k] == "=" {
                k += 1
                while k < s.count, CharacterSet.whitespacesAndNewlines.contains(s[k]) { k += 1 }
                if k < s.count, s[k] == "\"" || s[k] == "'" {
                    let quote = s[k]
                    let vs = k + 1
                    var ve = vs
                    while ve < s.count, s[ve] != quote { ve += 1 }
                    value = String(String.UnicodeScalarView(s[vs..<min(ve, s.count)]))
                    k = min(ve + 1, s.count)
                } else {
                    let vs = k
                    while k < s.count, !CharacterSet.whitespacesAndNewlines.contains(s[k]), s[k] != ">" { k += 1 }
                    value = String(String.UnicodeScalarView(s[vs..<k]))
                }
            }
            if attrs[name] == nil { attrs[name] = value }
        }
        return (attrs, s.count, selfClosing)
    }

    /// 같은 이름의 중첩을 고려해 대응하는 닫는 태그 뒤로 이동한다. 없으면 여는 태그만 무시한다.
    private mutating func skipElement(_ name: String) {
        var depth = 1
        var k = i
        let open = "<" + name
        let close = "</" + name
        while k < s.count {
            if s[k] == "<" {
                if matches("<!--", at: k) {
                    k = indexAfter("-->", from: k + 4) ?? s.count
                    continue
                }
                if matches(close, at: k), k + close.unicodeScalars.count < s.count,
                   !isNameChar(s[k + close.unicodeScalars.count]) {
                    depth -= 1
                    if depth == 0 {
                        i = indexAfter(">", from: k) ?? s.count
                        return
                    }
                } else if matches(open, at: k), k + open.unicodeScalars.count < s.count,
                          !isNameChar(s[k + open.unicodeScalars.count]) {
                    depth += 1
                }
            }
            k += 1
        }
        // 닫는 태그가 없는 깨진 HTML: head 등은 그냥 계속 읽는다
    }

    private func isHidden(_ attrs: [String: String]) -> Bool {
        if attrs["hidden"] != nil { return true }
        guard let style = attrs["style"]?.lowercased().replacingOccurrences(of: " ", with: "") else { return false }
        return style.contains("display:none") || style.contains("mso-hide:all")
            || style.contains("visibility:hidden") || style.contains("max-height:0;overflow:hidden")
    }

    private func intAttr(_ v: String?) -> Int? {
        guard let v else { return nil }
        let digits = v.prefix { $0.isNumber }
        return Int(digits)
    }

    // MARK: 엔티티

    private static let entities: [String: String] = [
        "nbsp": "\u{00A0}", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–",
        "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„",
        "bull": "•", "middot": "·", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢",
        "laquo": "«", "raquo": "»", "lsaquo": "‹", "rsaquo": "›", "times": "×", "divide": "÷",
        "deg": "°", "plusmn": "±", "para": "¶", "sect": "§", "zwnj": "\u{200C}", "zwj": "\u{200D}",
        "shy": "\u{00AD}", "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}",
        "iexcl": "¡", "iquest": "¿", "dagger": "†", "Dagger": "‡", "permil": "‰", "prime": "′",
        "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔", "check": "✓",
        "frac12": "½", "frac14": "¼", "frac34": "¾", "sup1": "¹", "sup2": "²", "sup3": "³",
        "micro": "µ", "ordf": "ª", "ordm": "º", "not": "¬", "macr": "¯", "acute": "´", "uml": "¨",
        "agrave": "à", "aacute": "á", "acirc": "â", "atilde": "ã", "auml": "ä", "aring": "å", "aelig": "æ",
        "ccedil": "ç", "egrave": "è", "eacute": "é", "ecirc": "ê", "euml": "ë", "igrave": "ì",
        "iacute": "í", "icirc": "î", "iuml": "ï", "ntilde": "ñ", "ograve": "ò", "oacute": "ó",
        "ocirc": "ô", "otilde": "õ", "ouml": "ö", "oslash": "ø", "ugrave": "ù", "uacute": "ú",
        "ucirc": "û", "uuml": "ü", "yacute": "ý", "yuml": "ÿ", "szlig": "ß",
        "Agrave": "À", "Aacute": "Á", "Acirc": "Â", "Atilde": "Ã", "Auml": "Ä", "Aring": "Å", "AElig": "Æ",
        "Ccedil": "Ç", "Egrave": "È", "Eacute": "É", "Ecirc": "Ê", "Euml": "Ë", "Igrave": "Ì",
        "Iacute": "Í", "Icirc": "Î", "Iuml": "Ï", "Ntilde": "Ñ", "Ograve": "Ò", "Oacute": "Ó",
        "Ocirc": "Ô", "Otilde": "Õ", "Ouml": "Ö", "Oslash": "Ø", "Ugrave": "Ù", "Uacute": "Ú",
        "Ucirc": "Û", "Uuml": "Ü", "Yacute": "Ý",
    ]

    private func decodeEntities(_ text: String) -> String {
        Self.decodeEntities(text)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var idx = text.startIndex
        while idx < text.endIndex {
            let ch = text[idx]
            guard ch == "&", let semi = text[idx...].prefix(12).firstIndex(of: ";") else {
                out.append(ch)
                idx = text.index(after: idx)
                continue
            }
            let name = String(text[text.index(after: idx)..<semi])
            var replacement: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                if let v = UInt32(name.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { replacement = String(u) }
            } else if name.hasPrefix("#") {
                if let v = UInt32(name.dropFirst()), let u = Unicode.Scalar(v) { replacement = String(u) }
            } else {
                replacement = entities[name] ?? entities[name.lowercased()]
            }
            if let r = replacement {
                out += r
                idx = text.index(after: semi)
            } else {
                out.append(ch)
                idx = text.index(after: idx)
            }
        }
        return out
    }
}

// MARK: - 일반 텍스트 본문

enum PlainTextConverter {
    static func nodes(from text: String, flowed: Bool, delsp: Bool) -> [ContentNode] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        if flowed {
            var joined: [String] = []
            var buffer: String?
            for var line in lines {
                if line.hasPrefix(" ") { line.removeFirst() } // space-stuffing 제거
                let isSoft = line.hasSuffix(" ") && line != "-- "
                var piece = line
                if isSoft && delsp { piece.removeLast() }
                buffer = (buffer ?? "") + piece
                if !isSoft {
                    joined.append(buffer ?? "")
                    buffer = nil
                }
            }
            if let b = buffer { joined.append(b) }
            lines = joined
        }

        var nodes: [ContentNode] = []
        var paragraph: [String] = []
        var paragraphQuote = 0

        func flushParagraph() {
            defer { paragraph = [] }
            guard !paragraph.isEmpty else { return }
            let text = unwrapIfHardWrapped(paragraph)
            guard !TextCleanup.isBlank(text) else { return }
            nodes.append(.text(paragraphQuote > 0 ? .quote(depth: paragraphQuote) : .paragraph,
                               TextCleanup.removeInvisible(text)))
        }

        for line in lines {
            var depth = 0
            var rest = Substring(line)
            while let first = rest.first, first == ">" {
                depth += 1
                rest = rest.dropFirst()
                if rest.first == " " { rest = rest.dropFirst() }
            }
            let content = String(rest).trimmingCharacters(in: .whitespaces)
            if content.isEmpty {
                flushParagraph()
                continue
            }
            if depth != paragraphQuote { flushParagraph() }
            paragraphQuote = depth
            paragraph.append(String(rest).replacingOccurrences(of: "\t", with: "    "))
        }
        flushParagraph()
        return nodes
    }

    /// 72열 등으로 강제 줄바꿈된 문단은 번역 품질을 위해 공백으로 이어 붙인다.
    private static func unwrapIfHardWrapped(_ lines: [String]) -> String {
        guard lines.count > 1 else { return lines.first ?? "" }
        let body = lines.dropLast()
        let hardWrapped = body.allSatisfy { line in
            let n = line.count
            let t = line.trimmingCharacters(in: .whitespaces)
            let listLike = t.hasPrefix("-") || t.hasPrefix("*") || t.hasPrefix("•")
                || (t.first?.isNumber ?? false && t.dropFirst().prefix(2).contains("."))
            return n >= 55 && n <= 100 && !listLike
        }
        if hardWrapped {
            return lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        }
        return lines.joined(separator: "\n")
    }
}
