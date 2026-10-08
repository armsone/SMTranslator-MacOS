import Foundation

// 외부 의존성 없는 MIME(RFC 5322 / 2045-2047 / 2231) 파서.
// 메일 내용은 메모리에서만 다루며 어디에도 기록하지 않는다.

struct MIMEHeaders {
    private(set) var fields: [(name: String, value: String)] = []

    mutating func append(name: String, value: String) {
        fields.append((name, value))
    }

    func value(_ name: String) -> String? {
        let key = name.lowercased()
        return fields.first { $0.name.lowercased() == key }?.value
    }
}

final class MIMEPart {
    var headers = MIMEHeaders()
    var mimeType = "text/plain"
    var params: [String: String] = [:]
    var disposition: String?
    var filename: String?
    var contentID: String?
    var contentLocation: String?
    var transferEncoding = "7bit"
    var body = Data()
    var children: [MIMEPart] = []
    var embedded: ParsedMessage?

    var charset: String? { params["charset"] }
    var isMultipart: Bool { mimeType.hasPrefix("multipart/") }
    var isAttachmentDisposition: Bool { disposition == "attachment" }
}

struct ParsedMessage {
    let root: MIMEPart

    var headers: MIMEHeaders { root.headers }
    var subject: String? { decodedHeader("Subject") }
    var from: String? { decodedHeader("From") }
    var to: String? { decodedHeader("To") }
    var cc: String? { decodedHeader("Cc") }
    var date: String? { headers.value("Date")?.trimmingCharacters(in: .whitespaces) }

    private func decodedHeader(_ name: String) -> String? {
        guard let raw = headers.value(name) else { return nil }
        let decoded = MIMEDecoding.decodeEncodedWords(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }
}

enum MIMEParseError: LocalizedError {
    case empty
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .empty: return "메일 원본이 비어 있습니다."
        case .tooLarge: return "메일 원본이 너무 큽니다(200MB 초과)."
        }
    }
}

struct MIMEParser {
    static let maxInputSize = 200 * 1024 * 1024
    private let maxDepth = 24
    private let maxParts = 2000
    private var partCount = 0
    /// Mail AppleScript `source`처럼 이미 유니코드 문자열로 받은 원본이면,
    /// 8bit 본문은 선언된 charset보다 UTF-8 해석을 먼저 시도한다.
    private let preferUTF8For8bit: Bool

    init(preferUTF8For8bit: Bool = false) {
        self.preferUTF8For8bit = preferUTF8For8bit
    }

    mutating func parse(_ data: Data) throws -> ParsedMessage {
        guard !data.isEmpty else { throw MIMEParseError.empty }
        guard data.count <= Self.maxInputSize else { throw MIMEParseError.tooLarge }
        var bytes = [UInt8](data)
        // mbox 형식의 "From " 구분 줄 건너뛰기
        if bytes.starts(with: Array("From ".utf8)), let nl = bytes.firstIndex(of: 0x0A) {
            bytes.removeSubrange(0...nl)
        }
        return ParsedMessage(root: parsePart(bytes[...], depth: 0, defaultType: "text/plain"))
    }

    func decodeText(of part: MIMEPart) -> String {
        let eightBit = !["base64", "quoted-printable"].contains(part.transferEncoding)
        return MIMEDecoding.decodeText(part.body, charset: part.charset,
                                       preferUTF8: preferUTF8For8bit && eightBit)
    }

    // MARK: - 파트 분해

    private mutating func parsePart(_ bytes: ArraySlice<UInt8>, depth: Int, defaultType: String) -> MIMEPart {
        partCount += 1
        let part = MIMEPart()
        let (headerBytes, bodyBytes) = Self.splitHeaderBody(bytes)
        part.headers = Self.parseHeaders(headerBytes)

        let (type, params) = MIMEDecoding.parseParameterized(part.headers.value("Content-Type") ?? "")
        part.mimeType = type.isEmpty || !type.contains("/") ? defaultType : type
        part.params = params
        part.transferEncoding = (part.headers.value("Content-Transfer-Encoding") ?? "7bit")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if let dispositionHeader = part.headers.value("Content-Disposition") {
            let (disp, dparams) = MIMEDecoding.parseParameterized(dispositionHeader)
            part.disposition = disp.isEmpty ? nil : disp
            part.filename = dparams["filename"]
        }
        if part.filename == nil { part.filename = params["name"] }
        if let cid = part.headers.value("Content-ID") {
            part.contentID = MIMEDecoding.normalizeContentID(cid)
        }
        part.contentLocation = part.headers.value("Content-Location")?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if part.isMultipart, let boundary = params["boundary"], !boundary.isEmpty,
           depth < maxDepth, partCount < maxParts {
            let childDefault = part.mimeType == "multipart/digest" ? "message/rfc822" : "text/plain"
            for slice in Self.splitMultipart(bodyBytes, boundary: boundary) {
                guard partCount < maxParts else { break }
                part.children.append(parsePart(slice, depth: depth + 1, defaultType: childDefault))
            }
            return part
        }
        if part.isMultipart {
            // boundary가 없거나 깊이 제한 초과: 텍스트로 취급
            part.mimeType = "text/plain"
        }

        part.body = MIMEDecoding.decodeTransfer(bodyBytes, encoding: part.transferEncoding)

        let looksLikeEML = (part.filename?.lowercased().hasSuffix(".eml") ?? false)
            && (part.mimeType == "application/octet-stream" || part.mimeType.hasPrefix("message/"))
        if (part.mimeType == "message/rfc822" || part.mimeType == "message/global" || looksLikeEML),
           depth < maxDepth, !part.body.isEmpty {
            var nested = [UInt8](part.body)[...]
            if nested.starts(with: Array("From ".utf8)), let nl = nested.firstIndex(of: 0x0A) {
                nested = nested[(nl + 1)...]
            }
            part.mimeType = "message/rfc822"
            part.embedded = ParsedMessage(root: parsePart(nested, depth: depth + 1, defaultType: "text/plain"))
        }
        return part
    }

    /// 첫 빈 줄을 기준으로 헤더/본문을 나눈다(CRLF, LF 모두 허용).
    static func splitHeaderBody(_ b: ArraySlice<UInt8>) -> (ArraySlice<UInt8>, ArraySlice<UInt8>) {
        var lineStart = b.startIndex
        var i = b.startIndex
        // 첫 줄이 헤더 형식이 아니면 전체를 본문으로 본다.
        if let firstNL = b.firstIndex(of: 0x0A) {
            let first = b[b.startIndex..<firstNL]
            if !first.isEmpty, !(first.count == 1 && first.first == 0x0D), !first.contains(0x3A) {
                return (b[b.startIndex..<b.startIndex], b)
            }
        }
        while i < b.endIndex {
            if b[i] == 0x0A {
                let len = i - lineStart
                if len == 0 || (len == 1 && b[lineStart] == 0x0D) {
                    return (b[b.startIndex..<lineStart], b[(i + 1)...])
                }
                lineStart = i + 1
            }
            i += 1
        }
        return (b, b[b.endIndex...])
    }

    static func parseHeaders(_ bytes: ArraySlice<UInt8>) -> MIMEHeaders {
        var headers = MIMEHeaders()
        let data = Data(bytes)
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        var currentName: String?
        var currentValue = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = Substring(rawLine)
            if line.hasSuffix("\r") { line = line.dropLast() }
            if line.isEmpty { continue }
            if let first = line.first, first == " " || first == "\t" {
                if currentName != nil { currentValue += line }
                continue
            }
            if let name = currentName { headers.append(name: name, value: currentValue) }
            if let colon = line.firstIndex(of: ":") {
                currentName = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                currentValue = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            } else {
                currentName = nil
                currentValue = ""
            }
        }
        if let name = currentName { headers.append(name: name, value: currentValue) }
        return headers
    }

    static func splitMultipart(_ body: ArraySlice<UInt8>, boundary: String) -> [ArraySlice<UInt8>] {
        let delimiter = Array(("--" + boundary).utf8)
        var parts: [ArraySlice<UInt8>] = []
        var currentStart: Int?
        var lineStart = body.startIndex
        while lineStart < body.endIndex {
            var lineEnd = lineStart
            while lineEnd < body.endIndex && body[lineEnd] != 0x0A { lineEnd += 1 }
            if lineEnd - lineStart >= delimiter.count,
               body[lineStart..<(lineStart + delimiter.count)].elementsEqual(delimiter) {
                var k = lineStart + delimiter.count
                var isClose = false
                if k + 1 < lineEnd, body[k] == 0x2D, body[k + 1] == 0x2D {
                    isClose = true
                    k += 2
                }
                var restIsSpace = true
                while k < lineEnd {
                    if ![0x20, 0x09, 0x0D].contains(body[k]) { restIsSpace = false; break }
                    k += 1
                }
                if restIsSpace {
                    if let s = currentStart {
                        var end = lineStart
                        if end > s, body[end - 1] == 0x0A {
                            end -= 1
                            if end > s, body[end - 1] == 0x0D { end -= 1 }
                        }
                        parts.append(body[s..<max(s, end)])
                    }
                    if isClose { return parts }
                    currentStart = min(lineEnd + 1, body.endIndex)
                }
            }
            lineStart = lineEnd + 1
        }
        if let s = currentStart, s < body.endIndex {
            parts.append(body[s..<body.endIndex]) // 닫는 경계가 없는 경우
        }
        return parts
    }
}

// MARK: - 디코딩 도우미

enum MIMEDecoding {
    static func decodeTransfer(_ bytes: ArraySlice<UInt8>, encoding: String) -> Data {
        switch encoding {
        case "base64": return decodeBase64(bytes)
        case "quoted-printable": return decodeQuotedPrintable(bytes)
        default: return Data(bytes)
        }
    }

    static func decodeBase64<S: Sequence>(_ bytes: S) -> Data where S.Element == UInt8 {
        var clean: [UInt8] = []
        for b in bytes {
            switch b {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2B, 0x2F: clean.append(b)
            case 0x2D: clean.append(0x2B) // base64url 허용
            case 0x5F: clean.append(0x2F)
            default: continue // '=' 포함 나머지는 버리고 아래에서 패딩 재구성
            }
        }
        switch clean.count % 4 {
        case 1: clean.removeLast()
        case 2: clean.append(contentsOf: [0x3D, 0x3D])
        case 3: clean.append(0x3D)
        default: break
        }
        return Data(base64Encoded: Data(clean)) ?? Data()
    }

    static func decodeQuotedPrintable<S: Collection>(_ input: S, underscoreIsSpace: Bool = false) -> Data
    where S.Element == UInt8 {
        let bytes = Array(input)
        var out = Data()
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x3D { // '='
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A { i += 2; continue }
                if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A { i += 3; continue }
                if i + 2 < bytes.count, let h = hexValue(bytes[i + 1]), let l = hexValue(bytes[i + 2]) {
                    out.append(h << 4 | l)
                    i += 3
                    continue
                }
                // 잘못된 줄 끝 공백 뒤 soft break
                var j = i + 1
                while j < bytes.count, bytes[j] == 0x20 || bytes[j] == 0x09 { j += 1 }
                if j < bytes.count, bytes[j] == 0x0A || bytes[j] == 0x0D {
                    i = j + (bytes[j] == 0x0D && j + 1 < bytes.count && bytes[j + 1] == 0x0A ? 2 : 1)
                    continue
                }
                out.append(b)
            } else if underscoreIsSpace && b == 0x5F {
                out.append(0x20)
            } else {
                out.append(b)
            }
            i += 1
        }
        return out
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x41 + 10
        case 0x61...0x66: return c - 0x61 + 10
        default: return nil
        }
    }

    static func stringEncoding(for charset: String?) -> String.Encoding? {
        guard var cs = charset?.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'")).lowercased(),
              !cs.isEmpty else { return nil }
        if let star = cs.firstIndex(of: "*") { cs = String(cs[cs.startIndex..<star]) }
        let cf: CFStringEncoding
        switch cs {
        case "utf-8", "utf8", "unicode-1-1-utf-8":
            return .utf8
        case "us-ascii", "ascii", "iso-8859-1", "latin1", "iso8859-1", "windows-1252", "cp1252":
            return .windowsCP1252
        case "euc-kr", "ks_c_5601-1987", "ks_c_5601", "ksc5601", "ksc_5601", "korean", "cp949",
             "uhc", "windows-949", "x-windows-949", "ms949":
            cf = CFStringEncoding(CFStringEncodings.dosKorean.rawValue)
        case "gb2312", "gbk", "x-gbk", "cp936", "gb18030", "euc-cn":
            cf = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        case "shift_jis", "shift-jis", "sjis", "x-sjis", "windows-31j", "cp932":
            cf = CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)
        case "big5", "x-big5", "cp950":
            cf = CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue)
        default:
            cf = CFStringConvertIANACharSetNameToEncoding(cs as CFString)
            if cf == kCFStringEncodingInvalidId { return nil }
        }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    static func decodeText(_ data: Data, charset: String?, preferUTF8: Bool = false) -> String {
        if preferUTF8, let s = String(data: data, encoding: .utf8) { return s }
        if let enc = stringEncoding(for: charset), let s = String(data: data, encoding: enc) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    private static let encodedWordRegex = try? NSRegularExpression(
        pattern: "=\\?([^?\\s]+)\\?([bBqQ])\\?([^?\\s]*)\\?=")

    /// RFC 2047 encoded-word 디코딩. 같은 charset의 인접 단어는 바이트를 이어 붙여 디코딩한다.
    static func decodeEncodedWords(_ input: String) -> String {
        guard input.contains("=?"), let regex = encodedWordRegex else { return input }
        let ns = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }

        var result = ""
        var pendingBytes = Data()
        var pendingCharset: String?
        var cursor = 0

        func flush() {
            if let cs = pendingCharset {
                result += decodeText(pendingBytes, charset: cs)
            }
            pendingBytes = Data()
            pendingCharset = nil
        }

        for m in matches {
            let gap = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let gapIsSpace = gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !(gapIsSpace && pendingCharset != nil) {
                flush()
                result += gap
            }
            let charset = ns.substring(with: m.range(at: 1)).lowercased()
            let mode = ns.substring(with: m.range(at: 2)).lowercased()
            let text = ns.substring(with: m.range(at: 3))
            let bytes = mode == "b"
                ? decodeBase64(Array(text.utf8))
                : decodeQuotedPrintable(Array(text.utf8), underscoreIsSpace: true)
            if pendingCharset != nil && pendingCharset != charset { flush() }
            pendingCharset = charset
            pendingBytes.append(bytes)
            cursor = m.range.location + m.range.length
        }
        flush()
        if cursor < ns.length { result += ns.substring(from: cursor) }
        return result
    }

    /// "type/subtype; a=b; c*=utf-8''..." 형식을 (소문자 값, 파라미터)로 해석한다(RFC 2231 포함).
    static func parseParameterized(_ header: String) -> (String, [String: String]) {
        var segments: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for ch in header {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" && inQuotes { current.append(ch); escaped = true; continue }
            if ch == "\"" { inQuotes.toggle() }
            if ch == ";" && !inQuotes {
                segments.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        segments.append(current)

        let value = segments.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        var simple: [String: String] = [:]
        var continuations: [String: [(index: Int, value: String, extended: Bool)]] = [:]
        var extendedSingle: [String: String] = [:]

        for seg in segments.dropFirst() {
            guard let eq = seg.firstIndex(of: "=") else { continue }
            let key = seg[seg.startIndex..<eq].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var val = seg[seg.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if val.count >= 2, val.hasPrefix("\""), val.hasSuffix("\"") {
                val = String(val.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            guard !key.isEmpty else { continue }
            let pieces = key.split(separator: "*", omittingEmptySubsequences: false)
            if pieces.count >= 2 {
                let name = String(pieces[0])
                let extended = key.hasSuffix("*")
                if pieces.count == 2 && pieces[1].isEmpty {
                    extendedSingle[name] = val
                } else if let idx = Int(pieces[1]) {
                    continuations[name, default: []].append((idx, val, extended))
                }
            } else {
                simple[key] = decodeEncodedWords(val)
            }
        }
        for (name, val) in extendedSingle {
            simple[name] = decodeRFC2231(val, charset: nil, hasCharsetPrefix: true)
        }
        for (name, list) in continuations {
            let sorted = list.sorted { $0.index < $1.index }
            var charset: String?
            var bytes = Data()
            for (i, item) in sorted.enumerated() {
                var v = item.value
                if item.extended {
                    if i == 0 {
                        let parts = v.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                        if parts.count == 3 {
                            charset = String(parts[0])
                            v = String(parts[2])
                        }
                    }
                    bytes.append(percentDecodeBytes(v))
                } else {
                    bytes.append(contentsOf: Array(v.utf8))
                }
            }
            simple[name] = decodeText(bytes, charset: charset ?? "utf-8")
        }
        return (value, simple)
    }

    private static func decodeRFC2231(_ v: String, charset: String?, hasCharsetPrefix: Bool) -> String {
        var cs = charset
        var text = v
        if hasCharsetPrefix {
            let parts = v.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count == 3 {
                cs = String(parts[0])
                text = String(parts[2])
            }
        }
        return decodeText(percentDecodeBytes(text), charset: cs ?? "utf-8")
    }

    private static func percentDecodeBytes(_ s: String) -> Data {
        let bytes = Array(s.utf8)
        var out = Data()
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x25, i + 2 < bytes.count, let h = hexValue(bytes[i + 1]), let l = hexValue(bytes[i + 2]) {
                out.append(h << 4 | l)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }

    static func normalizeContentID(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("<") { s.removeFirst() }
        if s.hasSuffix(">") { s.removeLast() }
        return s.lowercased()
    }
}
