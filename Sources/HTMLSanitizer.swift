import Foundation

// 원본 HTML 메일을 '원본 서식 보기'용으로 다시 직렬화한다. 이것은 여러 방어선 중 첫 번째일 뿐이다.
// - 위험 요소(script/iframe/object/embed/base/meta/link/form 등)는 버리고, 허용 목록에 있는 속성만
//   항목마다 다시 따옴표로 감싸 출력한다(이벤트 처리기·srcset·target·ping 등은 출력되지 않는다).
// - 원본 텍스트는 '<'가 없는 구간만 그대로 옮기므로 출력은 항상 이 직렬화기가 만든 태그 구조를 따른다.
// - CSS의 url()은 메일 안 이미지(cid·data·Content-Location)만 앱 전용 스킴으로 바꾸고 나머지는 none으로 바꾼다.
//   @import, image-set(), expression() 등도 무력화한다.
// 이후 방어선: 문서 응답 헤더와 <head> 첫머리의 CSP, http/https/file 요청을 막는 WKContentRuleList,
// 모든 외부 내비게이션을 취소하는 내비게이션 대리자, 페이지 스크립트 비활성화, 비영구 데이터 저장소.

enum HTMLImageSource {
    /// 메일 안에 들어 있는(또는 이미 해석된) 이미지
    case asset(String)
    /// 기존 원격 이미지 블록. 실제 이미지는 AppModel.remoteStates[blockID]가 .loaded일 때만 있다.
    case remote(blockID: String)
    /// 화면 밖 등에 있어 다운로드 대상이 아니었던 원격 이미지(불러오지 않음)
    case unfetchedRemote
    case missing
    /// 추적용 픽셀로 보이는 아주 작은 원격 이미지(출력하지 않음)
    case tracking
}

struct HTMLImageSlot {
    let key: String
    let source: HTMLImageSource
    let alt: String?
}

struct FormattedHTML {
    static let scheme = "mailtranslator-asset"
    static let host = "local"

    static let contentSecurityPolicy = [
        "default-src 'none'",
        "style-src 'unsafe-inline'",
        "img-src \(scheme): data:",
        "font-src data:",
        "script-src 'none'",
        "connect-src 'none'",
        "object-src 'none'",
        "frame-src 'none'",
        "child-src 'none'",
        "worker-src 'none'",
        "media-src 'none'",
        "manifest-src 'none'",
        "form-action 'none'",
        "base-uri 'none'",
    ].joined(separator: "; ")

    /// 앱이 끼워 넣는 요소(mt-*)에만 적용되는 스타일. 원본 메일의 CSS는 덮어쓰지 않는다.
    static let appCSS = """
    mt-tr{all:initial!important;display:block!important;margin:3px 0 5px!important;padding:2px 6px 2px 8px!important;\
    border-left:3px solid #3b82f6!important;border-radius:3px!important;background:rgba(239,246,255,.92)!important;\
    color:#1e3a8a!important;font:inherit!important;font-size:.92em!important;line-height:1.45!important;\
    text-align:start!important;white-space:normal!important}
    mt-warn{all:initial!important;display:inline!important;color:#d97706!important;font:600 12px -apple-system,sans-serif!important;\
    margin-left:3px!important;cursor:help!important}
    mt-note{all:initial!important;display:block!important;margin:4px 0!important;padding:4px 7px!important;\
    border:1px dashed #9ca3af!important;border-radius:4px!important;background:#f9fafb!important;color:#4b5563!important;\
    font:11px/1.4 -apple-system,sans-serif!important;text-align:left!important;white-space:normal!important}
    mt-cap{all:initial!important;display:block!important;box-sizing:border-box!important;margin:6px 0 10px!important;\
    padding:8px 10px!important;border-radius:6px!important;background:#f3f4f6!important;color:#111827!important;\
    font:12px/1.45 -apple-system,sans-serif!important;text-align:left!important;white-space:normal!important}
    mt-caph{all:initial!important;display:flex!important;align-items:center!important;gap:4px!important;\
    margin-bottom:4px!important;color:#4b5563!important;font:600 11px/1.4 -apple-system,sans-serif!important}
    mt-toggle{cursor:pointer!important}
    mt-arrow{all:initial!important;display:inline-block!important;width:9px!important;color:#6b7280!important;\
    font:600 10px/1 -apple-system,sans-serif!important}
    mt-title{all:initial!important;display:inline!important;font:inherit!important;color:inherit!important}
    mt-rows{all:initial!important;display:block!important}
    mt-row{all:initial!important;display:flex!important;gap:6px!important;align-items:baseline!important;margin:3px 0!important}
    mt-num{all:initial!important;flex:none!important;display:inline-block!important;min-width:16px!important;padding:0 4px!important;\
    border-radius:3px!important;background:#2563eb!important;color:#fff!important;text-align:center!important;\
    font:700 10px/16px -apple-system,sans-serif!important}
    mt-txt{all:initial!important;display:block!important;color:#111827!important;font:12px/1.45 -apple-system,sans-serif!important}
    mt-main{all:initial!important;display:block!important;color:#111827!important;font:inherit!important}
    mt-sub{all:initial!important;display:block!important;color:#6b7280!important;font:11px/1.4 -apple-system,sans-serif!important}
    mt-layer{all:initial!important;position:absolute!important;left:0!important;top:0!important;width:0!important;height:0!important;\
    overflow:visible!important;pointer-events:none!important;z-index:2147483647!important}
    mt-box{position:absolute;box-sizing:border-box;border:1.5px solid rgba(37,99,235,.85);pointer-events:none}
    mt-lbl{position:absolute;padding:0 3px;border-radius:3px;background:#2563eb;color:#fff;pointer-events:none;\
    font:700 10px/14px -apple-system,sans-serif}
    mt-ov{position:absolute;box-sizing:border-box;display:flex;align-items:center;justify-content:center;\
    overflow:hidden;border-radius:2px;padding:1px 3px;text-align:center;line-height:1.1;white-space:normal;\
    word-break:break-word;pointer-events:none;font:600 12px -apple-system,sans-serif}
    mt-end{all:initial!important;display:block!important;clear:both!important;height:0!important}
    """

    let html: String
    let slots: [HTMLImageSlot]
    /// 정제 과정에서 표시하지 않은 외부 리소스(CSS 배경 이미지·글꼴 등) 수
    let blockedResources: Int
    /// MailDocument.blocks 중 이 HTML 파트에서 만들어진 블록 범위(서식 보기에서는 대신 웹 보기로 표시)
    var blockRange: Range<Int> = 0..<0

    private static let idCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    static func assetURL(_ assetID: String) -> String {
        "\(scheme)://\(host)/a/\(assetID.addingPercentEncoding(withAllowedCharacters: idCharacters) ?? "")"
    }
}

struct HTMLSanitizer {
    typealias Resolver = (_ src: String, _ width: Int?, _ height: Int?) -> HTMLImageSource

    static func sanitize(_ html: String, resolve: @escaping Resolver) -> FormattedHTML {
        var sanitizer = HTMLSanitizer(scalars: Array(html.unicodeScalars), resolve: resolve)
        sanitizer.run()
        return sanitizer.makeDocument()
    }

    /// 닫는 태그까지 내용을 원문 텍스트로 취급하는 요소 → 내용째 버린다.
    private static let dropRawText: Set<String> = ["script", "title", "textarea", "xmp", "iframe", "noembed", "noframes"]
    /// 중첩을 고려해 내용째 버리는 요소
    private static let dropNested: Set<String> = [
        "noscript", "template", "svg", "math", "object", "applet", "video", "audio", "select", "canvas",
        "frameset", "datalist", "fencedframe",
    ]
    /// 태그만 버리고 내용은 남기는 요소(빈 요소 포함)
    private static let dropTag: Set<String> = [
        "html", "head", "body", "meta", "link", "base", "basefont", "embed", "frame", "param", "source", "track",
        "input", "keygen", "isindex", "bgsound", "form", "portal", "plaintext", "area",
    ]
    private static let allowedAttributes: Set<String> = [
        "align", "valign", "bgcolor", "width", "height", "border", "cellpadding", "cellspacing", "style", "class", "id",
        "dir", "lang", "xml:lang", "colspan", "rowspan", "color", "face", "size", "alt", "title", "nowrap", "type",
        "start", "span", "summary", "frame", "rules", "hspace", "vspace", "headers", "scope", "abbr", "clear", "role",
        "reversed", "value", "bordercolor", "text", "link", "vlink", "alink", "leftmargin", "topmargin", "marginwidth",
        "marginheight", "aria-label", "aria-hidden", "hidden", "char", "charoff", "axis", "compact", "noshade", "label",
        "open", "datetime", "translate",
    ]
    private static let blockedCSSFunctions: Set<String> = ["image-set", "expression", "src", "image", "element", "paint"]

    private let s: [Unicode.Scalar]
    private let resolve: Resolver
    private var i = 0
    private var out = ""
    private var doctype: String?
    private var sawContent = false
    private var htmlAttrs: String?
    private var bodyAttrs: String?
    private var slots: [HTMLImageSlot] = []
    private var blocked = 0

    private init(scalars: [Unicode.Scalar], resolve: @escaping Resolver) {
        s = scalars
        self.resolve = resolve
    }

    private func makeDocument() -> FormattedHTML {
        var html = ""
        if let doctype { html += doctype + "\n" }
        // CSP는 원본의 어떤 요소보다 먼저 온다(원본 meta는 모두 제거됨). 문서 응답 헤더에도 같은 CSP를 둔다.
        html += "<html\(htmlAttrs ?? "")><head><meta charset=\"utf-8\">"
        html += "<meta http-equiv=\"Content-Security-Policy\" content=\"\(Self.escape(FormattedHTML.contentSecurityPolicy))\">"
        html += "<meta name=\"referrer\" content=\"no-referrer\"><meta name=\"color-scheme\" content=\"light only\">"
        html += "<style>\(FormattedHTML.appCSS)</style></head><body\(bodyAttrs ?? "")>"
        html += out
        html += "</body></html>"
        return FormattedHTML(html: html, slots: slots, blockedResources: blocked)
    }

    // MARK: 토큰 처리

    private mutating func run() {
        var textStart = 0
        while i < s.count {
            if s[i] == "<" {
                appendText(textStart, i)
                handleMarkup()
                textStart = i
            } else {
                i += 1
            }
        }
        appendText(textStart, s.count)
    }

    private mutating func appendText(_ start: Int, _ end: Int) {
        guard start < end else { return }
        let slice = s[start..<end]
        out.unicodeScalars.append(contentsOf: slice)
        if !sawContent, slice.contains(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }) { sawContent = true }
    }

    private mutating func handleMarkup() {
        guard i + 1 < s.count else {
            out += "&lt;"
            i += 1
            return
        }
        let next = s[i + 1]
        if next == "!" {
            if matches("<!--", at: i) {
                i = indexAfter("-->", from: i + 4) ?? s.count
                return
            }
            let end = indexAfter(">", from: i + 2) ?? s.count
            if matches("<!doctype", at: i), doctype == nil, !sawContent {
                let innerEnd = max(i + 9, min(end - 1, s.count))
                doctype = Self.cleanDoctype(String(String.UnicodeScalarView(s[min(i + 9, innerEnd)..<innerEnd])))
            }
            i = end
            return
        }
        if next == "?" {
            i = indexAfter(">", from: i + 2) ?? s.count
            return
        }
        let isEnd = next == "/"
        let nameStart = isEnd ? i + 2 : i + 1
        guard nameStart < s.count, isNameStart(s[nameStart]) else {
            if isEnd {
                // "</" 뒤가 태그 이름이 아니면 HTML 파서도 '>'까지를 버린다.
                i = indexAfter(">", from: i + 2) ?? s.count
            } else {
                out += "&lt;"
                i += 1
            }
            return
        }
        var j = nameStart
        while j < s.count, isNameChar(s[j]) { j += 1 }
        let name = String(String.UnicodeScalarView(s[nameStart..<j])).lowercased()
        let (attrs, end) = parseAttributes(from: j)
        i = end
        if isEnd {
            endTag(name)
        } else {
            sawContent = true
            startTag(name, attrs)
        }
    }

    private mutating func startTag(_ rawName: String, _ attrs: [(String, String)]) {
        let name = rawName == "image" ? "img" : rawName // HTML 파서는 <image>를 <img>로 바꾼다
        if name == "style" {
            handleStyleElement()
            return
        }
        if Self.dropRawText.contains(name) {
            skipRawText(name)
            return
        }
        if Self.dropNested.contains(name) {
            skipNested(name)
            return
        }
        if name == "html" {
            if htmlAttrs == nil { htmlAttrs = sanitizedAttributes(name, attrs.filter { ["lang", "dir", "style", "class"].contains($0.0) }) }
            return
        }
        if name == "body" {
            if bodyAttrs == nil { bodyAttrs = sanitizedAttributes(name, attrs) }
            return
        }
        if Self.dropTag.contains(name) { return }
        if name == "img" {
            emitImage(attrs)
            return
        }
        out += "<" + name + sanitizedAttributes(name, attrs) + ">"
    }

    private mutating func endTag(_ name: String) {
        if name == "style" || name == "image" || Self.dropRawText.contains(name) || Self.dropNested.contains(name)
            || Self.dropTag.contains(name) {
            return
        }
        out += "</" + name + ">"
    }

    private mutating func emitImage(_ attrs: [(String, String)]) {
        var lookup: [String: String] = [:]
        for (name, value) in attrs where lookup[name] == nil { lookup[name] = value }
        let src = HTMLBlockExtractor.decodeEntities(lookup["src"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let source: HTMLImageSource = src.isEmpty
            ? .missing
            : resolve(src, Self.intValue(lookup["width"]), Self.intValue(lookup["height"]))
        if case .tracking = source { return }
        let key = "i\(slots.count + 1)"
        slots.append(HTMLImageSlot(key: key, source: source, alt: lookup["alt"].map(HTMLBlockExtractor.decodeEntities)))
        var tag = "<img" + sanitizedAttributes("img", attrs.filter { $0.0 != "src" })
        if case .asset(let assetID) = source {
            tag += " src=\"\(Self.escape(FormattedHTML.assetURL(assetID)))\""
        }
        tag += " data-mt-img=\"\(key)\">"
        out += tag
    }

    private mutating func sanitizedAttributes(_ element: String, _ attrs: [(String, String)]) -> String {
        var result = ""
        var seen = Set<String>()
        for (name, rawValue) in attrs {
            guard seen.insert(name).inserted else { continue }
            let value = HTMLBlockExtractor.decodeEntities(rawValue)
            switch name {
            case "style":
                let css = sanitizeCSS(value, inStyleElement: false)
                if !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result += " style=\"\(Self.escape(css))\"" }
            case "href":
                // 링크 모양(:link 스타일)만 유지하고 실제 주소는 남기지 않는다. 클릭은 내비게이션 대리자가 취소한다.
                if element == "a" { result += " href=\"#\"" }
            case "background":
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = resolveCSSURL(trimmed) {
                    result += " background=\"\(Self.escape(url))\""
                } else if !trimmed.isEmpty {
                    blocked += 1
                }
            default:
                if Self.allowedAttributes.contains(name) { result += " \(name)=\"\(Self.escape(value))\"" }
            }
        }
        return result
    }

    // MARK: 요소 건너뛰기

    private mutating func handleStyleElement() {
        let close = indexOfCloseTag("style", from: i)
        let content = String(String.UnicodeScalarView(s[i..<(close ?? s.count)]))
        i = close.flatMap { indexAfter(">", from: $0) } ?? s.count
        out += "<style>" + sanitizeCSS(content, inStyleElement: true) + "</style>"
    }

    private mutating func skipRawText(_ name: String) {
        if let close = indexOfCloseTag(name, from: i) {
            i = indexAfter(">", from: close) ?? s.count
        } else {
            i = s.count
        }
    }

    /// 같은 이름의 중첩을 고려해 대응하는 닫는 태그 뒤로 이동한다. 닫는 태그가 없으면 여는 태그만 버린다.
    private mutating func skipNested(_ name: String) {
        var depth = 1
        var k = i
        let open = "<" + name
        let close = "</" + name
        let openCount = open.unicodeScalars.count
        let closeCount = close.unicodeScalars.count
        while k < s.count {
            if s[k] == "<" {
                if matches("<!--", at: k) {
                    k = indexAfter("-->", from: k + 4) ?? s.count
                    continue
                }
                if matches(close, at: k), k + closeCount >= s.count || !isNameChar(s[k + closeCount]) {
                    depth -= 1
                    if depth == 0 {
                        i = indexAfter(">", from: k) ?? s.count
                        return
                    }
                } else if matches(open, at: k), k + openCount < s.count, !isNameChar(s[k + openCount]) {
                    depth += 1
                }
            }
            k += 1
        }
    }

    private func indexOfCloseTag(_ name: String, from start: Int) -> Int? {
        let close = "</" + name
        let count = close.unicodeScalars.count
        var k = start
        while k < s.count {
            if s[k] == "<", matches(close, at: k), k + count >= s.count || !isNameChar(s[k + count]) { return k }
            k += 1
        }
        return nil
    }

    // MARK: CSS

    private mutating func sanitizeCSS(_ css: String, inStyleElement: Bool) -> String {
        let c = Self.decodeSimpleEscapes(Self.stripComments(Array(css.unicodeScalars)))
        var result = String.UnicodeScalarView()
        var k = 0
        while k < c.count {
            let ch = c[k]
            if ch == "@", k + 1 < c.count, Self.isIdentStart(c[k + 1]) {
                let (ident, after) = Self.readIdent(c, from: k + 1)
                if ident.lowercased() == "import" {
                    result.append(contentsOf: "@x-blocked-import".unicodeScalars)
                    blocked += 1
                } else {
                    result.append("@")
                    result.append(contentsOf: ident.unicodeScalars)
                }
                k = after
                continue
            }
            if Self.isIdentStart(ch), k == 0 || !Self.isIdentChar(c[k - 1]) {
                let (ident, after) = Self.readIdent(c, from: k)
                if after < c.count, c[after] == "(" {
                    let lower = ident.lowercased()
                    let bare = lower.hasPrefix("-webkit-") ? String(lower.dropFirst(8)) : lower
                    if lower == "url" {
                        let (value, next) = Self.readURLArgument(c, from: after + 1)
                        if let mapped = resolveCSSURL(value) {
                            result.append(contentsOf: "url(\"\(mapped)\")".unicodeScalars)
                        } else {
                            if !value.isEmpty { blocked += 1 }
                            result.append(contentsOf: "none".unicodeScalars)
                        }
                        k = next
                        continue
                    }
                    if Self.blockedCSSFunctions.contains(bare) {
                        result.append(contentsOf: "x-blocked(".unicodeScalars)
                        blocked += 1
                        k = after + 1
                        continue
                    }
                }
                result.append(contentsOf: ident.unicodeScalars)
                k = after
                continue
            }
            if inStyleElement && ch == "<" {
                result.append(contentsOf: "\\3c ".unicodeScalars) // </style> 탈출 방지
            } else {
                result.append(ch)
            }
            k += 1
        }
        return String(result)
    }

    /// 메일 안 이미지(cid·data·Content-Location)만 앱 전용 주소로 바꾼다. 외부 주소는 nil(표시 안 함).
    private func resolveCSSURL(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.unicodeScalars.contains(where: { "\"'\\<>()\n\r\t".unicodeScalars.contains($0) }) else {
            return nil
        }
        let lower = value.lowercased()
        if lower.hasPrefix("data:") {
            let allowed = ["data:image/", "data:font/", "data:application/font", "data:application/x-font",
                           "data:application/vnd.ms-fontobject"]
            return allowed.contains(where: lower.hasPrefix) ? value : nil
        }
        if lower.hasPrefix("#") { return value } // 문서 안 조각 참조(SVG 필터 등), 요청 없음
        if case .asset(let assetID) = resolve(value, nil, nil) { return FormattedHTML.assetURL(assetID) }
        return nil
    }

    private static func stripComments(_ c: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var result: [Unicode.Scalar] = []
        result.reserveCapacity(c.count)
        var k = 0
        while k < c.count {
            if c[k] == "/", k + 1 < c.count, c[k + 1] == "*" {
                var j = k + 2
                while j + 1 < c.count, !(c[j] == "*" && c[j + 1] == "/") { j += 1 }
                k = min(j + 2, c.count)
                result.append(" ") // 주석 제거로 토큰이 이어 붙지 않게 공백으로 바꾼다
                continue
            }
            result.append(c[k])
            k += 1
        }
        return result
    }

    /// 탐지를 우회하는 CSS 이스케이프(예: \75 rl( → url()를 글자/괄호/하이픈/@에 한해 풀어 둔다.
    private static func decodeSimpleEscapes(_ c: [Unicode.Scalar]) -> [Unicode.Scalar] {
        func safe(_ u: Unicode.Scalar) -> Bool {
            (u >= "a" && u <= "z") || (u >= "A" && u <= "Z") || u == "(" || u == "-" || u == "@" || u == "_"
        }
        var result: [Unicode.Scalar] = []
        result.reserveCapacity(c.count)
        var k = 0
        while k < c.count {
            guard c[k] == "\\", k + 1 < c.count else {
                result.append(c[k])
                k += 1
                continue
            }
            var j = k + 1
            var hex = ""
            while j < c.count, hex.unicodeScalars.count < 6, c[j].properties.isASCIIHexDigit {
                hex.unicodeScalars.append(c[j])
                j += 1
            }
            if !hex.isEmpty {
                if j < c.count, c[j] == " " || c[j] == "\t" || c[j] == "\n" { j += 1 }
                if let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v), safe(u) {
                    result.append(u)
                } else {
                    result.append(contentsOf: c[k..<j])
                }
                k = j
                continue
            }
            if safe(c[k + 1]) {
                result.append(c[k + 1])
            } else {
                result.append(c[k])
                result.append(c[k + 1])
            }
            k += 2
        }
        return result
    }

    private static func isIdentStart(_ u: Unicode.Scalar) -> Bool {
        (u >= "a" && u <= "z") || (u >= "A" && u <= "Z") || u == "_" || u == "-" || u.value > 0x7F
    }

    private static func isIdentChar(_ u: Unicode.Scalar) -> Bool {
        isIdentStart(u) || (u >= "0" && u <= "9") || u == "\\"
    }

    private static func readIdent(_ c: [Unicode.Scalar], from start: Int) -> (String, Int) {
        var k = start
        while k < c.count, isIdentChar(c[k]) { k += 1 }
        return (String(String.UnicodeScalarView(c[start..<k])), k)
    }

    /// url( 다음부터 인자를 읽는다. (값, ')' 다음 위치)
    private static func readURLArgument(_ c: [Unicode.Scalar], from start: Int) -> (String, Int) {
        var k = start
        while k < c.count, CharacterSet.whitespacesAndNewlines.contains(c[k]) { k += 1 }
        var value = ""
        if k < c.count, c[k] == "\"" || c[k] == "'" {
            let quote = c[k]
            k += 1
            let valueStart = k
            while k < c.count, c[k] != quote {
                if c[k] == "\\" { k += 1 }
                k += 1
            }
            value = String(String.UnicodeScalarView(c[valueStart..<min(k, c.count)]))
            k = min(k + 1, c.count)
            while k < c.count, c[k] != ")" { k += 1 }
        } else {
            let valueStart = k
            while k < c.count, c[k] != ")" { k += 1 }
            value = String(String.UnicodeScalarView(c[valueStart..<k]))
        }
        return (value.trimmingCharacters(in: .whitespacesAndNewlines), min(k + 1, c.count))
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
            guard k < s.count else { return false }
            let c = s[k]
            let lower = (c >= "A" && c <= "Z") ? Unicode.Scalar(c.value + 32)! : c
            guard lower == p else { return false }
            k += 1
        }
        return true
    }

    private func indexAfter(_ pattern: String, from start: Int) -> Int? {
        let count = pattern.unicodeScalars.count
        var k = start
        while k + count <= s.count {
            if matches(pattern, at: k) { return k + count }
            k += 1
        }
        return nil
    }

    /// 태그 이름 이후부터 '>'까지 속성을 읽는다. 이름은 소문자, 값은 원문(엔티티 미해석).
    private func parseAttributes(from start: Int) -> ([(String, String)], Int) {
        var attrs: [(String, String)] = []
        var k = start
        while k < s.count {
            let c = s[k]
            if c == ">" { return (attrs, k + 1) }
            if c == "/" || CharacterSet.whitespacesAndNewlines.contains(c) {
                k += 1
                continue
            }
            var nameEnd = k
            while nameEnd < s.count, !CharacterSet.whitespacesAndNewlines.contains(s[nameEnd]),
                  s[nameEnd] != "=", s[nameEnd] != ">", s[nameEnd] != "/" { nameEnd += 1 }
            if nameEnd == k {
                k += 1
                continue
            }
            let name = String(String.UnicodeScalarView(s[k..<nameEnd])).lowercased()
            k = nameEnd
            while k < s.count, CharacterSet.whitespacesAndNewlines.contains(s[k]) { k += 1 }
            var value = ""
            if k < s.count, s[k] == "=" {
                k += 1
                while k < s.count, CharacterSet.whitespacesAndNewlines.contains(s[k]) { k += 1 }
                if k < s.count, s[k] == "\"" || s[k] == "'" {
                    let quote = s[k]
                    let valueStart = k + 1
                    var valueEnd = valueStart
                    while valueEnd < s.count, s[valueEnd] != quote { valueEnd += 1 }
                    value = String(String.UnicodeScalarView(s[valueStart..<min(valueEnd, s.count)]))
                    k = min(valueEnd + 1, s.count)
                } else {
                    let valueStart = k
                    while k < s.count, !CharacterSet.whitespacesAndNewlines.contains(s[k]), s[k] != ">" { k += 1 }
                    value = String(String.UnicodeScalarView(s[valueStart..<k]))
                }
            }
            attrs.append((name, value))
        }
        return (attrs, s.count)
    }

    private static func intValue(_ v: String?) -> Int? {
        guard let v else { return nil }
        return Int(v.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber })
    }

    /// 문서 모드(표준/쿼크)를 유지하기 위해 DOCTYPE은 남기되 안전한 글자만 둔다. (DOCTYPE의 URL은 요청되지 않는다)
    private static func cleanDoctype(_ inner: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -/.:\"'_"))
        var cleaned = String.UnicodeScalarView()
        for u in inner.unicodeScalars where u.isASCII && allowed.contains(u) { cleaned.append(u) }
        return "<!DOCTYPE \(String(cleaned).trimmingCharacters(in: .whitespaces))>"
    }

    static func escape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for u in value.unicodeScalars {
            switch u {
            case "&": result += "&amp;"
            case "\"": result += "&quot;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\u{0}": continue
            default: result.unicodeScalars.append(u)
            }
        }
        return result
    }
}
