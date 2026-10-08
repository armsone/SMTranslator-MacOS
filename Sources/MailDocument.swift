import AppKit
import ImageIO
import UniformTypeIdentifiers

// 파싱된 MIME 트리를 화면/번역용 문서 모델로 변환한다.

struct ImageAsset: Identifiable {
    let id: String
    let name: String?
    let image: NSImage
    let cgImage: CGImage
    let pixelSize: CGSize

    static let maxBytes = 40 * 1024 * 1024

    init?(id: String, data: Data, name: String?) {
        guard data.count <= Self.maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        self.id = id
        self.name = name
        self.cgImage = cg
        self.pixelSize = CGSize(width: cg.width, height: cg.height)
        self.image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

struct ContentBlock: Identifiable {
    enum Kind {
        case text(TextBlockStyle, String)
        case image(assetID: String)
        case remoteImage(url: URL?, alt: String?)
        case missingImage(alt: String?)
        case sectionTitle(String)
        case divider
    }

    let id: String
    let kind: Kind
}

struct AttachmentInfo: Identifiable {
    let id: String
    let name: String
    let mimeType: String
    let size: Int
}

struct MailDocument: Identifiable {
    enum Origin {
        case mail(selectionCount: Int)
        case emlFile
        case imageFile

        var isMail: Bool {
            if case .mail = self { return true }
            return false
        }
    }

    let id = UUID()
    var origin: Origin
    var subject: String?
    var headerLines: [(label: String, value: String)] = []
    var blocks: [ContentBlock] = []
    var assets: [String: ImageAsset] = [:]
    var attachments: [AttachmentInfo] = []
    var notices: [String] = []
    /// 주 HTML 본문(멀티파트 대안 중 선택된 것 하나)을 정제한 원본 서식 보기용 문서. 일반 텍스트/이미지 입력은 nil.
    var formattedHTML: FormattedHTML?

    var remoteImageBlocks: [ContentBlock] {
        blocks.filter { if case .remoteImage = $0.kind { return true } else { return false } }
    }
}

final class MailDocumentBuilder {
    private let parser: MIMEParser
    private var blocks: [ContentBlock] = []
    private var assets: [String: ImageAsset] = [:]
    private var attachments: [AttachmentInfo] = []
    private var notices: [String] = []
    private var cidMap: [String: MIMEPart] = [:]
    private var locationMap: [String: MIMEPart] = [:]
    private var consumed = Set<ObjectIdentifier>()
    private var assetForPart: [ObjectIdentifier: String] = [:]
    private var counter = 0
    private var trackingPixels = 0
    private var undecodableImages = 0
    private var encryptedFound = false
    private var embeddedDepth = 0
    private var formattedHTML: FormattedHTML?
    /// 본문 img src(엔티티 해석·공백 제거) → 해석 결과. 서식 보기의 img가 같은 asset/원격 블록을 쓰도록 한다.
    private var htmlImageSources: [String: HTMLImageSource] = [:]

    init(parser: MIMEParser) {
        self.parser = parser
    }

    static func build(message: ParsedMessage, parser: MIMEParser, origin: MailDocument.Origin) -> MailDocument {
        let builder = MailDocumentBuilder(parser: parser)
        return builder.run(message: message, origin: origin)
    }

    static func build(imageData: Data, fileName: String) -> MailDocument? {
        guard let asset = ImageAsset(id: "img-0", data: imageData, name: fileName) else { return nil }
        var doc = MailDocument(origin: .imageFile)
        doc.subject = nil
        doc.headerLines = [("파일", fileName)]
        doc.assets[asset.id] = asset
        doc.blocks = [ContentBlock(id: "b-0", kind: .image(assetID: asset.id))]
        return doc
    }

    private func nextID(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)-\(counter)"
    }

    private func run(message: ParsedMessage, origin: MailDocument.Origin) -> MailDocument {
        collectReferences(message.root)
        render(message.root)

        // 본문에서 참조되지 않은 이미지 파트는 "첨부 이미지" 섹션에 원본 그대로 표시
        var leftovers: [MIMEPart] = []
        collectUnconsumedImages(message.root, into: &leftovers)
        if !leftovers.isEmpty {
            blocks.append(ContentBlock(id: nextID("s"), kind: .sectionTitle("첨부 이미지")))
            for part in leftovers { appendImage(part) }
        }

        if trackingPixels > 0 {
            notices.append("추적용 픽셀로 보이는 아주 작은 원격 이미지 \(trackingPixels)개는 표시하지 않았습니다.")
        }
        let remoteCount = blocks.filter { if case .remoteImage = $0.kind { return true } else { return false } }.count
        // Mail에서 요청한 메시지는 원격 이미지를 자동으로 불러오므로, 화면에서 진행 상황과 함께 따로 안내한다.
        if remoteCount > 0, !origin.isMail {
            notices.append("개인정보 보호를 위해 원격(인터넷) 이미지 \(remoteCount)개를 불러오지 않았습니다. 해당 위치에는 자리표시만 표시되며, 이미지 속 글자는 번역되지 않습니다.")
        }
        if undecodableImages > 0 {
            notices.append("해석할 수 없는 이미지 \(undecodableImages)개는 첨부 파일 목록에만 표시했습니다.")
        }
        if encryptedFound {
            notices.append("암호화(S/MIME 또는 PGP)된 부분은 해독할 수 없어 번역하지 않았습니다.")
        }

        var doc = MailDocument(origin: origin)
        doc.subject = message.subject
        doc.headerLines = headerLines(of: message)
        doc.blocks = blocks
        doc.assets = assets
        doc.attachments = attachments
        doc.notices = notices
        doc.formattedHTML = formattedHTML
        return doc
    }

    private func headerLines(of message: ParsedMessage) -> [(label: String, value: String)] {
        var lines: [(label: String, value: String)] = []
        if let v = message.from { lines.append(("보낸 사람", v)) }
        if let v = message.to { lines.append(("받는 사람", v)) }
        if let v = message.cc { lines.append(("참조", v)) }
        if let v = message.date { lines.append(("날짜", v)) }
        return lines
    }

    private func collectReferences(_ part: MIMEPart) {
        if let cid = part.contentID { cidMap[cid] = part }
        if let loc = part.contentLocation, !loc.isEmpty { locationMap[loc] = part }
        part.children.forEach(collectReferences)
        if let embedded = part.embedded { collectReferences(embedded.root) }
    }

    private func collectUnconsumedImages(_ part: MIMEPart, into list: inout [MIMEPart]) {
        if part.isMultipart {
            for child in part.children { collectUnconsumedImages(child, into: &list) }
        } else if part.embedded == nil, isImage(part), !consumed.contains(ObjectIdentifier(part)) {
            list.append(part)
        }
    }

    private func isImage(_ part: MIMEPart) -> Bool {
        if part.mimeType.hasPrefix("image/") { return true }
        if let name = part.filename, let ext = name.split(separator: ".").last,
           let type = UTType(filenameExtension: String(ext)), type.conforms(to: .image) {
            return true
        }
        return false
    }

    // MARK: 트리 렌더링

    private func render(_ part: MIMEPart) {
        let type = part.mimeType
        if part.isMultipart {
            switch type {
            case "multipart/alternative":
                guard let chosen = chooseAlternative(part.children) else { return }
                for child in part.children where child !== chosen { markConsumed(child) }
                render(chosen)
            case "multipart/related":
                let startID = part.params["start"].map(MIMEDecoding.normalizeContentID)
                let root = part.children.first { startID != nil && $0.contentID == startID } ?? part.children.first
                if let root { render(root) }
            case "multipart/signed":
                if let first = part.children.first { render(first) }
                part.children.dropFirst().forEach(markConsumed)
            case "multipart/encrypted":
                encryptedFound = true
                part.children.forEach { addAttachment($0) }
            default:
                part.children.forEach(render)
            }
            return
        }

        consumed.insert(ObjectIdentifier(part))

        if let embedded = part.embedded {
            renderEmbedded(embedded)
            return
        }
        if type == "application/pkcs7-mime" || type == "application/x-pkcs7-mime" || type == "application/pgp-encrypted" {
            encryptedFound = true
            addAttachment(part)
            return
        }
        if type == "application/pkcs7-signature" || type == "application/x-pkcs7-signature"
            || type == "application/pgp-signature" {
            return
        }
        let isAttachment = part.isAttachmentDisposition || (part.filename != nil && !type.hasPrefix("image/") && part.disposition != "inline")
        if type == "text/html" && !isAttachment {
            let html = parser.decodeText(of: part)
            let start = blocks.count
            appendNodes(HTMLBlockExtractor.extract(html))
            // 첨부된 메일이 아닌 첫 HTML 본문만 원본 서식으로 보여 준다(나머지는 기존 읽기용 블록).
            if formattedHTML == nil, embeddedDepth == 0 {
                var formatted = HTMLSanitizer.sanitize(html) { [unowned self] src, width, height in
                    self.resolveHTMLImage(src, width: width, height: height)
                }
                formatted.blockRange = start..<blocks.count
                formattedHTML = formatted
            }
            return
        }
        if (type == "text/plain" || type == "text/enriched") && !isAttachment {
            let flowed = part.params["format"]?.lowercased() == "flowed"
            let delsp = part.params["delsp"]?.lowercased() == "yes"
            appendNodes(PlainTextConverter.nodes(from: parser.decodeText(of: part), flowed: flowed, delsp: delsp))
            return
        }
        if isImage(part) {
            // multipart/mixed 안의 이미지 첨부는 Apple Mail처럼 해당 위치에 표시
            appendImage(part)
            return
        }
        addAttachment(part)
    }

    private func renderEmbedded(_ message: ParsedMessage) {
        blocks.append(ContentBlock(id: nextID("d"), kind: .divider))
        blocks.append(ContentBlock(id: nextID("s"), kind: .sectionTitle("첨부된 메일")))
        if let subject = message.subject {
            blocks.append(ContentBlock(id: nextID("t"), kind: .text(.heading(3), subject)))
        }
        for line in headerLines(of: message) {
            blocks.append(ContentBlock(id: nextID("h"), kind: .text(.caption, "\(line.label): \(line.value)")))
        }
        collectReferences(message.root)
        embeddedDepth += 1
        render(message.root)
        embeddedDepth -= 1
        blocks.append(ContentBlock(id: nextID("d"), kind: .divider))
    }

    private func chooseAlternative(_ children: [MIMEPart]) -> MIMEPart? {
        func containsHTML(_ p: MIMEPart) -> Bool {
            p.mimeType == "text/html" || p.children.contains(where: containsHTML)
        }
        if let html = children.last(where: containsHTML) { return html }
        if let plain = children.last(where: { $0.mimeType == "text/plain" }) { return plain }
        return children.last
    }

    private func markConsumed(_ part: MIMEPart) {
        consumed.insert(ObjectIdentifier(part))
        part.children.forEach(markConsumed)
    }

    private func appendNodes(_ nodes: [ContentNode]) {
        for node in nodes {
            switch node {
            case .text(let style, let text):
                blocks.append(ContentBlock(id: nextID("t"), kind: .text(style, text)))
            case .rule:
                blocks.append(ContentBlock(id: nextID("d"), kind: .divider))
            case .image(let ref):
                appendImageReference(ref)
            }
        }
    }

    private func appendImageReference(_ ref: HTMLImageRef) {
        let src = ref.src.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = appendImageBlock(for: ref, src: src)
        if htmlImageSources[src] == nil { htmlImageSources[src] = source }
    }

    /// 기존 읽기용 블록을 만들고, 같은 결과를 서식 보기의 img 매핑에도 쓰도록 돌려준다.
    private func appendImageBlock(for ref: HTMLImageRef, src: String) -> HTMLImageSource {
        let lower = src.lowercased()
        if lower.hasPrefix("cid:") {
            if let part = cidMap[contentID(fromCIDURL: src)] {
                if let assetID = appendImage(part, alt: ref.alt) { return .asset(assetID) }
                return .missing
            }
            blocks.append(ContentBlock(id: nextID("m"), kind: .missingImage(alt: ref.alt)))
            return .missing
        }
        if lower.hasPrefix("data:") {
            if let assetID = decodeDataImage(src) {
                blocks.append(ContentBlock(id: nextID("i"), kind: .image(assetID: assetID)))
                return .asset(assetID)
            }
            blocks.append(ContentBlock(id: nextID("m"), kind: .missingImage(alt: ref.alt)))
            return .missing
        }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("//") {
            if let w = ref.width, let h = ref.height, w <= 3, h <= 3 {
                trackingPixels += 1
                return .tracking
            }
            let normalized = lower.hasPrefix("//") ? "https:" + src : src
            let blockID = nextID("r")
            blocks.append(ContentBlock(id: blockID, kind: .remoteImage(url: URL(string: normalized), alt: ref.alt)))
            return .remote(blockID: blockID)
        }
        if let part = locationMap[src] {
            if let assetID = appendImage(part, alt: ref.alt) { return .asset(assetID) }
            return .missing
        }
        blocks.append(ContentBlock(id: nextID("m"), kind: .missingImage(alt: ref.alt)))
        return .missing
    }

    private func contentID(fromCIDURL src: String) -> String {
        let raw = String(src.dropFirst(4))
        return MIMEDecoding.normalizeContentID(raw.removingPercentEncoding ?? raw)
    }

    private func decodeDataImage(_ src: String) -> String? {
        guard let comma = src.firstIndex(of: ","), src[..<comma].lowercased().contains(";base64") else { return nil }
        let data = MIMEDecoding.decodeBase64(Array(src[src.index(after: comma)...].utf8))
        guard let asset = ImageAsset(id: nextID("img"), data: data, name: nil) else { return nil }
        assets[asset.id] = asset
        return asset.id
    }

    /// 서식 보기 정제기가 img/CSS 배경 주소를 해석할 때 쓴다. 읽기용 블록 추출에서 이미 본 주소는 같은 결과를,
    /// 처음 보는 주소(숨겨진 요소의 이미지, CSS 배경)는 블록을 만들지 않고 메일 안 이미지만 asset으로 해석한다.
    /// 원격 주소는 여기서 새로 내려받지 않는다(기존 원격 이미지 블록만 Mail 요청 시 내려받음).
    private func resolveHTMLImage(_ rawSrc: String, width: Int?, height: Int?) -> HTMLImageSource {
        let src = rawSrc.trimmingCharacters(in: .whitespacesAndNewlines)
        if let known = htmlImageSources[src] { return known }
        let lower = src.lowercased()
        var result: HTMLImageSource = .missing
        if lower.hasPrefix("cid:") {
            if let part = cidMap[contentID(fromCIDURL: src)], let assetID = assetID(forReferencedPart: part) {
                result = .asset(assetID)
            }
        } else if lower.hasPrefix("data:") {
            if let assetID = decodeDataImage(src) { result = .asset(assetID) }
        } else if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("//") {
            if let width, let height, width <= 3, height <= 3 {
                result = .tracking
            } else {
                result = .unfetchedRemote
            }
        } else if let part = locationMap[src], let assetID = assetID(forReferencedPart: part) {
            result = .asset(assetID)
        }
        htmlImageSources[src] = result
        return result
    }

    /// 블록 없이 이미지 파트를 asset으로만 만든다. 해석에 실패하면 소비 처리하지 않아 첨부 목록에 남게 한다.
    private func assetID(forReferencedPart part: MIMEPart) -> String? {
        let key = ObjectIdentifier(part)
        if let existing = assetForPart[key] { return existing }
        guard let asset = ImageAsset(id: nextID("img"), data: part.body, name: part.filename) else { return nil }
        consumed.insert(key)
        assets[asset.id] = asset
        assetForPart[key] = asset.id
        return asset.id
    }

    @discardableResult
    private func appendImage(_ part: MIMEPart, alt: String? = nil) -> String? {
        let key = ObjectIdentifier(part)
        consumed.insert(key)
        if let existing = assetForPart[key] {
            blocks.append(ContentBlock(id: nextID("i"), kind: .image(assetID: existing)))
            return existing
        }
        guard let asset = ImageAsset(id: nextID("img"), data: part.body, name: part.filename) else {
            undecodableImages += 1
            addAttachment(part)
            return nil
        }
        assets[asset.id] = asset
        assetForPart[key] = asset.id
        blocks.append(ContentBlock(id: nextID("i"), kind: .image(assetID: asset.id)))
        return asset.id
    }

    private func addAttachment(_ part: MIMEPart) {
        consumed.insert(ObjectIdentifier(part))
        attachments.append(AttachmentInfo(id: nextID("a"), name: part.filename ?? "(이름 없음)",
                                          mimeType: part.mimeType, size: part.body.count))
    }
}
