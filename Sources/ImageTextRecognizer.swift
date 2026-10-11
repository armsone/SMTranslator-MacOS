import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Vision

// Vision 온디바이스 OCR. 이미지 픽셀은 바꾸지 않고, 인식 영역(정규화 좌표)과 텍스트만 돌려준다.

struct OCRRegion: Identifiable {
    let id: String
    let text: String
    /// 정규화 좌표, 원점은 왼쪽 위
    let box: CGRect
    /// 이 영역의 원본 배경/대비 글자색을 원본 비트맵에서 추출한 값(제자리 번역 오버레이용, "#RRGGBB")
    let backgroundHex: String
    let foregroundHex: String
    /// 공백이 아닌 글자 하나당 잉크 영역 근사치(box와 같은 정규화 좌표, 원점은 왼쪽 위).
    /// SDK에서 범위를 못 가져온 글자는 빠져 있을 수 있으며, 그 글자의 원본 픽셀은 마스킹하지 않는다.
    /// 최대 maxGlyphsPerItem개로 제한된다.
    let glyphBoxes: [CGRect]
    /// glyphBoxes와 같은 순서·개수의 인식 글자(글꼴 견본 대조용). 비어 있을 수 있다.
    let glyphTexts: [String]
    /// 원본 글자 모양으로 추정한 글꼴 갈래("gothic"/"myeongjo"/"gungseo"/"hand"). 표본이 부족하거나
    /// 애매하면 nil(미판별 -> 호출자가 고딕으로 대체). 정확한 글꼴 식별이 아니라 거친 추정일 뿐이다.
    let fontStyle: String?
    /// 원본 글자 픽셀 분석 결과(굵기·글자색·배경 복원 조각). 분석하지 않았으면 nil.
    let typography: GlyphTypography?
    /// 번역문에는 넣지 않지만 원문을 지울 때 함께 가려야 하는 글자 상자(본문에서 뺀 후리가나, 글자 상자 상한을 넘은
    /// 합친 칸의 글자). box와 같은 정규화 좌표(원점 왼쪽 위).
    let annotationBoxes: [CGRect]

    init(id: String, text: String, box: CGRect, backgroundHex: String, foregroundHex: String, glyphBoxes: [CGRect] = [],
         glyphTexts: [String] = [], fontStyle: String? = nil, typography: GlyphTypography? = nil,
         annotationBoxes: [CGRect] = []) {
        self.id = id
        self.text = text
        self.box = box
        self.backgroundHex = backgroundHex
        self.foregroundHex = foregroundHex
        self.glyphBoxes = ImageTextRecognizer.resolvedWordBoxes(glyphBoxes, texts: glyphTexts)
        self.glyphTexts = glyphTexts.count == glyphBoxes.count ? glyphTexts : []
        self.fontStyle = fontStyle
        self.typography = typography
        self.annotationBoxes = annotationBoxes
    }

    /// 숫자·코드만 있는 등 번역해도 의미가 없는 조각은 오버레이/목록에서 뺀다.
    /// 한자 한두 글자짜리 말풍선(세로 일본어 만화에 흔함)은 의미가 있을 수 있어 길이만으로 버리지 않고,
    /// 한글/영문 등 비CJK 짧은 조각만 기존처럼 노이즈로 걸러낸다.
    var hasMeaningfulLetters: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("{"), !trimmed.hasPrefix("[") else { return false }
        if trimmed.hasPrefix("\""), trimmed.contains("\":") { return false }
        guard trimmed.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return false }
        if trimmed.unicodeScalars.contains(where: ImageTextRecognizer.isCJK) { return true }
        return trimmed.count > 2
    }
}

enum ImageTextRecognizer {
    static let maxRegions = 150
    /// 항목(문단/줄)마다 추출하는 글자별 잉크 상자 개수 상한. 과도한 메타데이터 전송과 처리 시간을 막는다.
    static let maxGlyphsPerItem = 128

    /// 유한하고 양수 크기이며 0...1 이미지 범위 안으로 자른 상자만 돌려준다. 그 밖(비정상 범위·0 크기)은 nil로
    /// 걸러 호출자가 잘못된 값을 글자 마스킹에 쓰지 않게 한다.
    static func clampedUnitBox(_ box: CGRect) -> CGRect? {
        guard box.minX.isFinite, box.minY.isFinite, box.width.isFinite, box.height.isFinite,
              box.width > 0, box.height > 0 else { return nil }
        let clamped = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard clamped.width > 0, clamped.height > 0 else { return nil }
        return clamped
    }

    /// 큰 가로 제목만 같은 페이지의 실제 제목과 대조한다. 외부 사전이나 추측으로 문장을 만들지 않는다.
    /// 가나 3자 이상, 34% 이내 편집 거리, 유일한 최선 후보가 모두 충족될 때만 OCR 탈락·탁점 오류를 보완한다.
    static func correctingTitles(_ regions: [OCRRegion], pageTitle: String, image: CGImage) -> [OCRRegion] {
        titleCorrections(regions, pageTitle: pageTitle, image: image).regions
    }

    private static func titleCorrections(_ regions: [OCRRegion], pageTitle: String, image: CGImage, maximumDistance: Double = 0.34)
        -> (regions: [OCRRegion], matched: Set<String>) {
        func kana(_ c: Character) -> Bool {
            c.unicodeScalars.allSatisfy { (0x30A1...0x30FA).contains($0.value) || $0.value == 0x30FC }
        }
        func japanese(_ c: Character) -> Bool {
            c.unicodeScalars.allSatisfy { (0x3041...0x30FA).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) || $0.value == 0x30FC }
        }
        func normalized(_ text: String) -> [Character] {
            let scalars = text.decomposedStringWithCanonicalMapping.unicodeScalars.filter {
                $0.value != 0x3099 && $0.value != 0x309A && !CharacterSet.whitespacesAndNewlines.contains($0)
            }
            var converted: [Unicode.Scalar] = []
            for scalar in scalars {
                // 장식 글씨의 가나를 히라가나로 읽은 경우를 제목 대조에서만 정규화한다. 한자 골격은 그대로 보존한다.
                if (0x3041...0x3096).contains(scalar.value) {
                    converted.append(Unicode.Scalar(scalar.value + 0x60)!)
                } else { converted.append(scalar) }
            }
            return Array(String(String.UnicodeScalarView(converted)))
        }
        func distance(_ a: [Character], _ b: [Character]) -> Int {
            var row = Array(0...b.count)
            for (i, x) in a.enumerated() {
                var next = [i + 1]
                for (j, y) in b.enumerated() { next.append(min(row[j + 1] + 1, next[j] + 1, row[j] + (x == y ? 0 : 1))) }
                row = next
            }
            return row[b.count]
        }
        // 가나 단어와 한자·히라가나 구절의 경계를 유지해 단어 중간을 잘라 제목 후보로 삼지 않는다.
        var runs: [String] = [], part = "", previous: Bool?
        for c in pageTitle.prefix(300) {
            guard japanese(c) else {
                if !part.isEmpty { runs.append(part); part = "" }; previous = nil; continue
            }
            let kind = kana(c)
            if let previous, previous != kind, !part.isEmpty { runs.append(part); part = "" }
            part.append(c); previous = kind
        }
        if !part.isEmpty { runs.append(part) }
        var references = Set<String>()
        for i in runs.indices {
            var phrase = ""
            for j in i..<min(runs.count, i + 4) {
                phrase += runs[j]
                if (3...32).contains(phrase.count), pageTitle.contains(phrase) { references.insert(phrase) }
            }
        }
        guard !references.isEmpty else { return (regions, []) }
        var matched = Set<String>()
        let corrected = regions.map { region in
            guard region.box.width * CGFloat(image.width) > region.box.height * CGFloat(image.height) * 1.4,
                  (region.glyphBoxes.map({ $0.height * CGFloat(image.height) }).max() ?? 0) >= 60 else { return region }
            let source = String(region.text.filter(japanese))
            guard (3...28).contains(source.count), source.filter(kana).count >= 3 else { return region }
            let needle = normalized(source)
            let scored = references.compactMap { phrase -> (String, Double)? in
                guard abs(phrase.count - source.count) <= 3 else { return nil }
                let other = normalized(phrase)
                let fixed = String(needle.filter { !kana($0) })
                guard String(other.filter { !kana($0) }) == fixed else { return nil }
                if fixed.isEmpty, needle.first != other.first || needle.last != other.last { return nil }
                let score = Double(distance(needle, other)) / Double(max(needle.count, other.count))
                return score <= maximumDistance ? (phrase, score) : nil
            }.sorted { $0.1 < $1.1 }
            guard let best = scored.first,
                  scored.count == 1 || scored[1].1 - best.1 >= 0.05 else { return region }
            matched.insert(region.id)
            return OCRRegion(id: region.id, text: best.0, box: region.box, backgroundHex: region.backgroundHex,
                             foregroundHex: region.foregroundHex, glyphBoxes: region.glyphBoxes, glyphTexts: region.glyphTexts,
                             fontStyle: region.fontStyle, typography: region.typography, annotationBoxes: region.annotationBoxes)
        }
        return (corrected, matched)
    }

    /// 긴 가로 부제는 실제 페이지 제목과 거의 같은 문장인 경우에만 보완한다.
    /// 한자·첫끝 글자가 같고 최대 두 글자 오류인 유일 후보만 허용한다.
    private static func correctingTitleSentences(_ regions: [OCRRegion], pageTitle: String, image: CGImage) -> [OCRRegion] {
        func japanese(_ c: Character) -> Bool {
            c.unicodeScalars.allSatisfy { (0x3041...0x30FA).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) || $0.value == 0x30FC }
        }
        func kanji(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) } }
        let title = String(pageTitle.prefix(300))
        let positions = title.indices.filter { japanese(title[$0]) }
        let letters = positions.map { title[$0] }
        return regions.map { region in
            let source = Array(region.text.filter(japanese))
            guard (12...60).contains(source.count), letters.count >= source.count - 2,
                  region.box.width * CGFloat(image.width) > region.box.height * CGFloat(image.height) * 2 else { return region }
            let skeleton = source.filter(kanji)
            guard skeleton.count >= 4 else { return region }
            var matches: [String: Int] = [:]
            for start in letters.indices where letters[start] == source.first {
                for count in (source.count - 2)...(source.count + 2) where start + count <= letters.count {
                    let candidate = Array(letters[start..<start + count])
                    guard candidate.last == source.last, candidate.filter(kanji) == skeleton else { continue }
                    var row = Array(0...candidate.count)
                    for (i, x) in source.enumerated() {
                        var next = [i + 1]
                        for (j, y) in candidate.enumerated() {
                            next.append(min(row[j + 1] + 1, next[j] + 1, row[j] + (x == y ? 0 : 1)))
                        }
                        row = next
                    }
                    let edits = row[candidate.count]
                    if edits == 0 { return region } // 정확한 원문을 비슷한 다른 제목으로 바꾸지 않는다.
                    guard edits <= 2, Double(edits) / Double(max(source.count, candidate.count)) <= 0.12 else { continue }
                    let end = title.index(after: positions[start + count - 1])
                    let phrase = String(title[positions[start]..<end])
                    matches[phrase] = min(matches[phrase] ?? edits, edits)
                }
            }
            let ranked = matches.sorted { $0.value < $1.value }
            guard let best = ranked.first, ranked.count == 1 || ranked[1].value > best.value else { return region }
            let leading = region.text.prefix { !japanese($0) }
            let trailing = String(region.text.reversed().prefix { !japanese($0) }.reversed())
            return OCRRegion(id: region.id, text: String(leading) + best.key + trailing, box: region.box,
                             backgroundHex: region.backgroundHex, foregroundHex: region.foregroundHex,
                             glyphBoxes: region.glyphBoxes, glyphTexts: region.glyphTexts, fontStyle: region.fontStyle,
                             typography: region.typography, annotationBoxes: region.annotationBoxes)
        }
    }

    /// 작은 제작자 표기는 국소 OCR과 같은 페이지의 반복 이름이 동의할 때만 보완한다.
    /// 한자는 반복 표기, 가나는 기존 표기와 모두 일치해야 하므로 새 이름을 추측하지 않는다.
    private static func recoveringRepeatedCreditNames(_ regions: [OCRRegion], image: CGImage) async throws -> [OCRRegion] {
        let pattern = "[\\p{Han}]{1,6}[ぁ-ゖァ-ヺー]{2,16}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return regions }
        func names(_ text: String) -> [String] {
            regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range, in: text).map {
                    var name = String(text[$0])
                    // 역할 표기와 이름이 붙어 있어도 이름만 비교한다.
                    for label in ["原作", "漫画", "作画"] where name.hasPrefix(label) { name.removeFirst(label.count) }
                    return name
                }
            }
        }
        func han(_ text: String) -> String { String(text.prefix { $0.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) } }) }
        func kana(_ text: String) -> String { String(text.dropFirst(han(text).count)) }
        func unvoiced(_ text: String) -> String {
            String(String.UnicodeScalarView(text.decomposedStringWithCanonicalMapping.unicodeScalars.filter {
                $0.value != 0x3099 && $0.value != 0x309A
            }))
        }
        var replacements: [String: String] = [:]
        var verifiedCreditGroups: [Set<String>] = []
        for credit in regions.filter({ credit in
            credit.box.minY > 0.65 && credit.box.width * CGFloat(image.width) > credit.box.height * CGFloat(image.height) * 4 &&
            ["原作", "漫画", "作画"].contains { label in credit.text.drop(while: { !$0.isLetter }).hasPrefix(label) }
        }).prefix(2) {
            let originalNames = names(credit.text)
            guard !originalNames.isEmpty else { continue }
            var contextNames = originalNames
            let originalRect = CGRect(x: credit.box.minX * CGFloat(image.width), y: credit.box.minY * CGFloat(image.height),
                                      width: credit.box.width * CGFloat(image.width), height: credit.box.height * CGFloat(image.height))
            // 제작자 줄의 끝을 함께 읽으면 잘린 한자 획의 문맥이 살아난다.
            // 보완 결과는 아래의 별도 영역 이름 대조를 통과한 경우에만 채택한다.
            var creditLine = originalRect
            // 문서 OCR이 같은 제작자 줄의 뒤쪽 이름을 별도 문단으로 나누기도 한다.
            // 같은 높이에서 가까이 이어지는 이름만 읽기 문맥에 포함하고 출력 상자는 유지한다.
            for other in regions where other.id != credit.id && !names(other.text).isEmpty {
                let neighbor = CGRect(x: other.box.minX * CGFloat(image.width), y: other.box.minY * CGFloat(image.height),
                                      width: other.box.width * CGFloat(image.width), height: other.box.height * CGFloat(image.height))
                guard neighbor.width > neighbor.height * 2,
                      neighbor.height >= originalRect.height * 0.5,
                      neighbor.height <= originalRect.height * 1.6,
                      abs(neighbor.midY - originalRect.midY) <= originalRect.height * 0.5,
                      neighbor.minX >= originalRect.maxX - originalRect.height,
                      neighbor.minX <= originalRect.maxX + originalRect.height * 3,
                      originalRect.union(neighbor).width <= CGFloat(image.width) * 0.5 else { continue }
                creditLine = creditLine.union(neighbor)
                contextNames.append(contentsOf: names(other.text))
            }
            var contextRect = creditLine.insetBy(dx: -32, dy: -32)
            contextRect.size.width += min(128, creditLine.width * 0.12)
            let rect = contextRect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let crop = image.cropping(to: rect) else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ja-JP", "en-US"]
            request.usesLanguageCorrection = true
            let local: [String]
            do {
                local = try await withTaskCancellationHandler {
                    try await Task.detached(priority: .userInitiated) {
                        try VNImageRequestHandler(cgImage: crop).perform([request])
                        return (request.results ?? []).compactMap { $0.topCandidates(1).first }
                            .filter { $0.confidence >= 0.3 }.map(\.string)
                    }.value
                } onCancel: { request.cancel() }
            } catch {
                try Task.checkCancellation()
                continue
            }
            try Task.checkCancellation()
            for original in originalNames {
                let candidates = Set(local.flatMap(names).filter { candidate in
                    guard candidate.count == original.count, kana(candidate) == kana(original),
                          zip(candidate, original).filter({ $0 != $1 }).count <= 2 else { return false }
                    return regions.contains { other in
                        other.id != credit.id && names(other.text).contains { repeated in
                            han(repeated) == han(candidate) && unvoiced(kana(repeated)).hasPrefix(unvoiced(kana(candidate))) &&
                            (kana(repeated).count == kana(candidate).count || kana(repeated) == kana(candidate) + "の")
                        }
                    }
                })
                guard candidates.count == 1, let canonical = candidates.first else { continue }
                replacements[original] = canonical
            }
            if originalNames.contains(where: { replacements[$0] != nil }) {
                verifiedCreditGroups.append(Set(contextNames.map { replacements[$0] ?? $0 }))
            }
        }
        let verifiedNames = Set(replacements.values)
        return regions.map { region in
            var text = region.text
            for name in names(region.text) { if let canonical = replacements[name] { text = text.replacingOccurrences(of: name, with: canonical) } }
            let regionNames = Set(names(text))
            // 같은 제작자 조합의 다른 두 이름까지 일치할 때만 반복 표기의 탁점 차이를 보완한다.
            // 같은 철자의 별개 이름을 페이지 전체에서 일괄 치환하지 않는다.
            for group in verifiedCreditGroups where group.intersection(regionNames).count >= 2 {
                for name in regionNames where !group.contains(name) {
                    let matches = group.filter {
                        verifiedNames.contains($0) && $0.count == name.count && han($0) == han(name) &&
                        unvoiced(kana($0)) == unvoiced(kana(name))
                    }
                    if matches.count == 1, let canonical = matches.first {
                        text = text.replacingOccurrences(of: name, with: canonical)
                    }
                }
            }
            guard text != region.text else { return region }
            return OCRRegion(id: region.id, text: text, box: region.box, backgroundHex: region.backgroundHex,
                foregroundHex: region.foregroundHex, glyphBoxes: region.glyphBoxes, glyphTexts: region.glyphTexts,
                fontStyle: region.fontStyle, typography: region.typography, annotationBoxes: region.annotationBoxes)
        }
    }

    /// 일본어 문장의 O/0 혼동은 주변 글자가 같은 국소 재인식 결과로만 보완한다.
    /// 문단·글자 위치와 후리가나는 그대로 두며, 다른 문자열을 추정하여 넣지 않는다.
    private static func recoveringAmbiguousZeros(_ regions: [OCRRegion], image: CGImage) async throws -> [OCRRegion] {
        guard #available(macOS 26.0, *) else { return regions }
        var result = regions
        var attempts = 0
        func compact(_ text: String) -> [Character] { Array(text.filter { $0.isLetter || $0.isNumber }) }
        let ambiguous: Set<Character> = ["O", "Ｏ", "Ο", "О"]
        for index in regions.indices {
            let original = regions[index]
            let letters = compact(original.text)
            let targets = letters.indices.filter { i in
                ambiguous.contains(letters[i]) && i >= 3 && i + 3 < letters.count &&
                letters[(i - 3)..<i].allSatisfy { $0.unicodeScalars.contains(where: isCJK) }
            }
            guard !targets.isEmpty, attempts < 2 else { continue }
            let originalRect = CGRect(x: original.box.minX * CGFloat(image.width), y: original.box.minY * CGFloat(image.height),
                                      width: original.box.width * CGFloat(image.width), height: original.box.height * CGFloat(image.height))
            attempts += 1
            var local: [String] = []
            var replacements = Set<Int>()
            var conflicts = Set<Int>()
            var interruptionMarks: [Character] = []
            let terminalContext = String(letters.suffix(6))
            let mayBeInterrupted = original.text.last?.unicodeScalars.contains { (0x3041...0x3096).contains($0.value) } == true && letters.count >= 10
            // 여백에 따라 작은 숫자를 점으로 읽으면 더 좁은 문맥으로 한 번만 재확인한다.
            // 기존 문맥에서 문자 O가 확인되면 추가 재인식으로 뒤집지 않는다.
            for margin in [CGFloat(32), 16] {
                let rect = originalRect.insetBy(dx: -margin, dy: -margin).integral
                    .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
                guard rect.width * rect.height <= 300_000, let crop = image.cropping(to: rect) else { continue }
                try Task.checkCancellation()
                let paragraphs: [DocumentTextParagraph]
                do { paragraphs = try await DocumentTextRecognizer.recognizeParagraphs(in: crop) }
                catch is CancellationError { throw CancellationError() }
                catch { continue }
                // 서로 다른 두 여백에서 같은 문장 끝과 대시를 읽은 경우에만 누락된 중단 부호를 보완한다.
                if mayBeInterrupted {
                    let marks = Set(paragraphs.compactMap { paragraph -> Character? in
                        let text = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let mark = text.last, [Character("ー"), "—", "―", "−", "-"].contains(mark),
                              String(compact(String(text.dropLast()))).hasSuffix(terminalContext) else { return nil }
                        return mark
                    })
                    if marks.count == 1, let mark = marks.first { interruptionMarks.append(mark) }
                }
                local.append(contentsOf: paragraphs.map { String(compact($0.text)) })
                for i in targets {
                    let after = String(letters[(i + 1)...(i + 3)])
                    func matchesContext(_ chars: [Character], at position: Int) -> Bool {
                        guard position >= 3, position + 3 < chars.count,
                              String(chars[(position + 1)...(position + 3)]) == after,
                              chars[position - 1] == letters[i - 1] else { return false }
                        // 국소 OCR에서도 한자 한 획이 달라질 수 있다. 앞 3글자 중 최소 2글자는 같아야 한다.
                        return zip(chars[(position - 3)..<position], letters[(i - 3)..<i]).filter { $0 != $1 }.count <= 1
                    }
                    let confirmed = local.contains { text in
                        let chars = Array(text)
                        return chars.indices.contains { position in
                            [Character("0"), "０", "〇"].contains(chars[position]) && matchesContext(chars, at: position)
                        }
                    }
                    let conflicting = local.contains { text in
                        let chars = Array(text)
                        return chars.indices.contains { position in ambiguous.contains(chars[position]) && matchesContext(chars, at: position) }
                    }
                    if conflicting { conflicts.insert(i) }
                    if confirmed && !conflicting { replacements.insert(i) }
                }
                if !replacements.isEmpty || !conflicts.isEmpty { break }
            }
            guard !replacements.isEmpty else { continue }
            var offset = 0
            let text = String(original.text.map { character -> Character in
                guard character.isLetter || character.isNumber else { return character }
                defer { offset += 1 }
                return replacements.contains(offset) ? "0" : character
            }) + (interruptionMarks.count == 2 && interruptionMarks[0] == interruptionMarks[1] ? String(interruptionMarks[0]) : "")
            result[index] = OCRRegion(id: original.id, text: text, box: original.box, backgroundHex: original.backgroundHex,
                foregroundHex: original.foregroundHex, glyphBoxes: original.glyphBoxes, glyphTexts: original.glyphTexts,
                fontStyle: original.fontStyle, typography: original.typography, annotationBoxes: original.annotationBoxes)
        }
        return result
    }

    /// 장식 제목은 전체 화면 OCR에서 획이 탈락할 수 있다. 제목이 확정되지 않은 큰 가로 영역 두 곳만
    /// 다시 읽고, 실제 페이지 제목과 엄격한 대조를 통과한 후보가 하나일 때만 적용한다.
    static func recoveringTitles(_ regions: [OCRRegion], pageTitle: String, image: CGImage) async throws -> [OCRRegion] {
        let zeros = try await recoveringAmbiguousZeros(regions, image: image)
        let credits = try await recoveringRepeatedCreditNames(zeros, image: image)
        let recovered = try await recoveringLatinHeadings(credits, image: image)
        var result = correctingTitleSentences(correctingTitles(recovered, pageTitle: pageTitle, image: image), pageTitle: pageTitle, image: image)
        guard !pageTitle.isEmpty else { return result }
        var attempts = 0
        for index in regions.indices {
            let region = regions[index]
            guard result[index].text == region.text,
                  region.box.width * CGFloat(image.width) > region.box.height * CGFloat(image.height) * 1.4,
                  (region.glyphBoxes.map { $0.height * CGFloat(image.height) }.max() ?? 0) >= 60,
                  region.text.unicodeScalars.filter({ (0x30A1...0x30FA).contains($0.value) || $0.value == 0x30FC }).count >= 3,
                  attempts < 2 else { continue }
            try Task.checkCancellation()
            let rect = CGRect(x: region.box.minX * CGFloat(image.width), y: region.box.minY * CGFloat(image.height),
                              width: region.box.width * CGFloat(image.width), height: region.box.height * CGFloat(image.height))
                .insetBy(dx: -8, dy: -8).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let crop = image.cropping(to: rect) else { continue }
            attempts += 1
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ja-JP", "en-US"]
            request.usesLanguageCorrection = true
            let candidates: [String]
            do {
                candidates = try await withTaskCancellationHandler {
                    try await Task.detached(priority: .userInitiated) {
                        try VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
                        return (request.results ?? []).filter { $0.boundingBox.height * CGFloat(crop.height) >= 60 }
                            .flatMap { $0.topCandidates(3).filter { $0.confidence >= 0.3 }.map(\.string) }
                    }.value
                } onCancel: { request.cancel() }
            } catch {
                try Task.checkCancellation()
                continue // 재인식 실패는 정상 OCR 결과를 유지한다.
            }
            try Task.checkCancellation()
            var recovered: [String: OCRRegion] = [:]
            for text in candidates {
                let alternate = OCRRegion(id: region.id, text: text, box: region.box,
                    backgroundHex: region.backgroundHex, foregroundHex: region.foregroundHex,
                    glyphBoxes: region.glyphBoxes, glyphTexts: region.glyphTexts, fontStyle: region.fontStyle,
                    typography: region.typography, annotationBoxes: region.annotationBoxes)
                let checked = titleCorrections([alternate], pageTitle: pageTitle, image: image)
                if checked.matched.contains(region.id), let fixed = checked.regions.first {
                    recovered[fixed.text] = fixed
                }
            }
            // 장식 제목은 두 글자 이상을 놓치기도 한다. 부분 재인식의 순수 가나 후보가 둘 이상
            // 같은 실제 제목에 동의할 때만 50%까지 허용한다. 첫/끝 글자·길이·유일 후보 조건은 유지한다.
            if recovered.isEmpty {
                var votes: [String: (count: Int, region: OCRRegion)] = [:]
                let phonetic = Array(Set(candidates.filter { text in
                    (3...28).contains(text.count) && text.unicodeScalars.allSatisfy {
                        (0x30A1...0x30FA).contains($0.value) || $0.value == 0x30FC || (0x3041...0x3096).contains($0.value)
                    }
                }))
                for text in phonetic {
                    let alternate = OCRRegion(id: region.id, text: text, box: region.box,
                        backgroundHex: region.backgroundHex, foregroundHex: region.foregroundHex,
                        glyphBoxes: region.glyphBoxes, glyphTexts: region.glyphTexts, fontStyle: region.fontStyle,
                        typography: region.typography, annotationBoxes: region.annotationBoxes)
                    let checked = titleCorrections([alternate], pageTitle: pageTitle, image: image, maximumDistance: 0.5)
                    if checked.matched.contains(region.id), let fixed = checked.regions.first {
                        votes[fixed.text] = ((votes[fixed.text]?.count ?? 0) + 1, fixed)
                    }
                }
                if votes.count == 1, let vote = votes.values.first, vote.count >= 2,
                   vote.count * 3 >= phonetic.count * 2 { recovered[vote.region.text] = vote.region }
            }
            if recovered.count == 1, let fixed = recovered.values.first { result[index] = fixed }
        }
        return result
    }

    /// 장식 획에 닿은 영문 제목의 첫·끝 글자가 빠질 때, 여백을 포함해 다시 읽는다.
    /// 기존 글자 순서를 전부 보존하고 두 글자 이상 복원한 단일 후보만 받는다.
    private static func recoveringLatinHeadings(_ regions: [OCRRegion], image: CGImage) async throws -> [OCRRegion] {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        var result = regions
        var attempts = 0
        func letters(_ s: String) -> String { String(s.filter { $0.isLetter }) }
        for i in regions.indices {
            let region = regions[i], old = letters(regions[i].text)
            guard attempts < 2, (5...24).contains(old.count),
                  region.text.unicodeScalars.allSatisfy({ (65...90).contains($0.value) || CharacterSet.whitespacesAndNewlines.contains($0) }) else { continue }
            let box = CGRect(x: region.box.minX * w, y: region.box.minY * h, width: region.box.width * w, height: region.box.height * h)
            guard box.height >= 16, box.width >= box.height * 3 else { continue }
            let rect = box.insetBy(dx: -box.height, dy: -box.height * 0.2).integral.intersection(bounds)
            guard rect.width * rect.height <= 300_000, let crop = image.cropping(to: rect) else { continue }
            attempts += 1
            let lines: [LegacyLine]
            do { lines = try await legacyLines(crop) }
            catch { try Task.checkCancellation(); continue }
            let candidates = lines.filter { line in
                let text = letters(line.0)
                guard text.count >= old.count + 1, text.count <= old.count + 4,
                      line.0.unicodeScalars.allSatisfy({ (65...90).contains($0.value) || CharacterSet.whitespacesAndNewlines.contains($0) }) else { return false }
                var remaining = text[...]
                for c in old {
                    guard let found = remaining.firstIndex(of: c) else { return false }
                    remaining = remaining[remaining.index(after: found)...]
                }
                return true
            }
            guard candidates.count == 1, let candidate = candidates.first else { continue }
            func mapped(_ b: CGRect) -> CGRect {
                CGRect(x: (rect.minX + b.minX * rect.width) / w, y: (rect.minY + b.minY * rect.height) / h,
                       width: b.width * rect.width / w, height: b.height * rect.height / h)
            }
            let b = mapped(candidate.1)
            let overlap = b.intersection(region.box)
            guard !overlap.isNull, overlap.width * overlap.height >= region.box.width * region.box.height * 0.8,
                  !regions.enumerated().contains(where: { other in
                      guard other.offset != i else { return false }
                      let shared = b.intersection(other.element.box)
                      return !shared.isNull && shared.width * shared.height > other.element.box.width * other.element.box.height * 0.5
                  }) else { continue }
            result[i] = OCRRegion(id: region.id, text: candidate.0, box: b, backgroundHex: region.backgroundHex,
                                  foregroundHex: region.foregroundHex, glyphBoxes: candidate.2.map { mapped($0.1) },
                                  glyphTexts: candidate.2.map { $0.0 }, fontStyle: region.fontStyle,
                                  annotationBoxes: [region.box] + region.annotationBoxes)
        }
        return result
    }

    /// - Parameter typography: true면(브라우저 이미지 번역) 인식 뒤 원본 글자 픽셀을 분석해 잉크 상자·글꼴 갈래·
    ///   굵기·글자색과 배경 복원 조각을 더한다. 인식 결과(텍스트·문단 상자) 자체는 바꾸지 않는다.
    static func recognize(_ image: CGImage, assetID: String, typography: Bool = false) async throws -> [OCRRegion] {
        let regions = try await recognizeText(image, assetID: assetID, classifyFonts: !typography)
        try Task.checkCancellation()
        return typography ? analyzed(regions, image: image, restoration: true) : regions
    }

    /// 글자 인식과 문단 정리(본문 속 후리가나 분리, 같은 말풍선 세로 칸 합치기)만 한다. 원본 글자 픽셀 분석은
    /// analyzed(_:image:restoration:)가 따로 맡아, 호출자가 번역과 분석을 겹쳐 돌릴 수 있게 한다.
    /// - Parameter classifyFonts: false면 획 통계 글꼴 추정(classifyFontStyle)을 건너뛴다(뒤에서 글자 대조로 다시 고를 때).
    static func recognizeText(_ image: CGImage, assetID: String, classifyFonts: Bool = true) async throws -> [OCRRegion] {
        guard image.width >= 24, image.height >= 24,
              Double(image.width) * Double(image.height) <= 120_000_000 else { return [] }
        try Task.checkCancellation()

        // mac26+에서는 문서 구조(문단) 단위 인식을 먼저 시도해 세로쓰기 줄 순서를 보존한다.
        // 취소는 그대로 전파하고, 그 외 실패(비어있는 결과 포함)는 기존 Vision 경로로 폴백한다.
        if #available(macOS 26.0, *) {
            // 문서 인식과 레거시 줄 검출을 동시에 시작한다(준비 후 반복 호출에서 순차보다 짧게 잰 값 기준이며,
            // 첫 실행 모델 적재 시간은 줄인다고 확인되지 않았다). 결과는 문서 인식이 성공하면 보충용으로만 쓰고
            // 그때의 레거시 실패는 보충 없이 넘긴다. 문서 인식이 실패·빈 결과로 폴백할 때는 레거시 오류를 그대로 던진다.
            async let linesTask: Result<[LegacyLine], Error> = {
                do { return .success(try await legacyLines(image)) } catch { return .failure(error) }
            }()
            do {
                let paragraphs = try await DocumentTextRecognizer.recognizeParagraphs(in: image)
                if !paragraphs.isEmpty {
                    let regions = documentRegions(paragraphs, image: image, assetID: assetID, classifyFonts: classifyFonts)
                    try Task.checkCancellation()
                    // 문서 인식은 그림 위 큰 장식 제목(로고)을 통째로 빼거나 첫 글자·외곽 글자를 놓치곤 한다.
                    // 같은 이미지의 줄 단위 검출로 문서 결과가 덮지 못한 글자만 보충한다(실패하면 문서 결과만 쓴다).
                    let lines = (try? await linesTask.get()) ?? []
                    try Task.checkCancellation()
                    let supplemented = supplementing(regions, with: lines, image: image, assetID: assetID, classifyFonts: classifyFonts)
                    return try await recoveringVerticalParagraphs(coherentParagraphs(supplemented, image: image), image: image)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 문서 인식 실패(미지원 콘텐츠 등) -> 아래 레거시 경로로 폴백
            }
            let legacy = await linesTask
            try Task.checkCancellation()
            let lines = try legacy.get()
            let regions = group(lines, image: image, assetID: assetID, classifyFonts: classifyFonts)
            return coherentParagraphs(regions, image: image)
        }

        let regions = try await recognizeLegacy(image, assetID: assetID, classifyFonts: classifyFonts)
        try Task.checkCancellation()
        return coherentParagraphs(regions, image: image)
    }

    /// 문서 인식 결과를 영역으로 변환한다. 문단 안 줄 순서는 문서 인식 결과를 따르고, 문단 사이 정리는
    /// coherentParagraphs가 맡는다(레거시 가로 그룹 로직은 다시 적용하지 않는다).
    @available(macOS 26.0, *)
    private static func documentRegions(_ paragraphs: [DocumentTextParagraph], image: CGImage, assetID: String,
                                        classifyFonts: Bool) -> [OCRRegion] {
        paragraphs.prefix(maxRegions).enumerated().map { index, paragraph in
            let b = paragraph.box
            let box = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
            let glyphBoxes = paragraph.glyphBoxes.map { g in
                CGRect(x: g.minX, y: 1 - g.maxY, width: g.width, height: g.height)
            }
            let (bg, fg) = sampleColors(of: image, in: box)
            let fontStyle = classifyFonts ? classifyFontStyle(of: image, glyphBoxes: glyphBoxes) : nil
            return OCRRegion(id: "\(assetID)#\(index)", text: paragraph.text, box: box, backgroundHex: bg, foregroundHex: fg,
                              glyphBoxes: glyphBoxes, glyphTexts: paragraph.glyphTexts, fontStyle: fontStyle)
        }
    }

    // MARK: 문단 정리(번역 단위)

    /// 전체 그림에서 여러 세로 칸을 하나로 읽으며 중간 칸을 놓친 경우, 해당 문단만 다시 읽는다.
    /// 두 문단까지만 시도하고 기존 한자 대부분을 보존하며 의미 글자가 늘어날 때만 교체한다.
    @available(macOS 26.0, *)
    private static func recoveringVerticalParagraphs(_ regions: [OCRRegion], image: CGImage) async throws -> [OCRRegion] {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        var result = regions
        var attempts = 0
        var consumed = Set<Int>()
        func meaningful(_ text: String) -> Int { text.filter { $0.isLetter || $0.isNumber }.count }
        func kanji(_ text: String) -> [Character] {
            text.filter { $0.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) } }.map { $0 }
        }
        func orderedMatches(_ a: [Character], _ b: [Character]) -> Int {
            var row = Array(repeating: 0, count: b.count + 1)
            for value in a {
                let previous = row
                for j in b.indices {
                    row[j + 1] = value == b[j] ? previous[j] + 1 : max(previous[j + 1], row[j])
                }
            }
            return row[b.count]
        }
        for i in regions.indices {
            guard !consumed.contains(i) else { continue }
            let original = regions[i]
            let direction = flow(original, w: w, h: h)
            let box = CGRect(x: original.box.minX * w, y: original.box.minY * h,
                             width: original.box.width * w, height: original.box.height * h)
            guard attempts < 2, meaningful(original.text) >= 18, direction.vertical == true,
                  direction.size >= 12, box.width > direction.size * 2.2, box.height > box.width * 1.4 else { continue }
            let rect = box.insetBy(dx: -direction.size * 0.8, dy: -direction.size * 0.8).integral.intersection(bounds)
            guard rect.width * rect.height <= 600_000, let crop = image.cropping(to: rect) else { continue }
            attempts += 1
            try Task.checkCancellation()
            let paragraphs: [DocumentTextParagraph]
            do { paragraphs = try await DocumentTextRecognizer.recognizeParagraphs(in: crop) }
            catch is CancellationError { throw CancellationError() }
            catch { continue }
            func mapped(_ b: CGRect) -> CGRect {
                CGRect(x: (rect.minX + b.minX * rect.width) / w, y: (rect.minY + b.minY * rect.height) / h,
                       width: b.width * rect.width / w, height: b.height * rect.height / h)
            }
            let local = coherentParagraphs(documentRegions(paragraphs, image: crop, assetID: original.id, classifyFonts: false), image: crop)
            let candidates = local.compactMap { r -> OCRRegion? in
                let b = mapped(r.box)
                guard b.intersection(original.box).width * b.intersection(original.box).height >= b.width * b.height * 0.6 else { return nil }
                return OCRRegion(id: original.id, text: r.text, box: b, backgroundHex: original.backgroundHex,
                                 foregroundHex: original.foregroundHex, glyphBoxes: r.glyphBoxes.map(mapped), glyphTexts: r.glyphTexts,
                                 fontStyle: original.fontStyle, annotationBoxes: r.annotationBoxes.map(mapped))
            }.sorted { $0.box.midX > $1.box.midX }
            guard !candidates.isEmpty else { continue }
            // 여백에서 다시 읽힌 인접 세로 칸은 같은 문단일 때만 함께 소비한다.
            // 가로 제목·크기가 다른 독립 문단은 여전히 합치지 않는다.
            var owners = [i]
            var conflict = false
            for other in regions.indices where other != i && !consumed.contains(other) {
                let r = regions[other]
                guard meaningful(r.text) >= 3 else { continue }
                let covered = candidates.contains { candidate in
                    let overlap = candidate.box.intersection(r.box)
                    return !overlap.isNull && overlap.width * overlap.height >= r.box.width * r.box.height * 0.8
                }
                let intersects = candidates.contains { candidate in
                    let overlap = candidate.box.intersection(r.box)
                    return !overlap.isNull && overlap.width * overlap.height >= candidate.box.width * candidate.box.height * 0.5
                }
                guard covered || intersects else { continue }
                let otherFlow = flow(r, w: w, h: h)
                let verticalOverlap = min(original.box.maxY, r.box.maxY) - max(original.box.minY, r.box.minY)
                if covered, otherFlow.vertical == true, otherFlow.size >= direction.size * 0.5,
                   otherFlow.size <= direction.size * 1.6,
                   verticalOverlap >= min(original.box.height, r.box.height) * 0.7 {
                    owners.append(other)
                } else { conflict = true; break }
            }
            guard !conflict else { continue }
            let text = candidates.map(\.text).joined(separator: " ")
            let originals = owners.sorted { regions[$0].box.midX > regions[$1].box.midX }
                .map { regions[$0] }
            let oldText = originals.map(\.text).joined(separator: " ")
            let oldKanji = kanji(oldText), newKanji = kanji(text)
            let start = Array(oldText.filter { $0.isLetter || $0.isNumber }.prefix(3))
            guard Array(text.filter { $0.isLetter || $0.isNumber }.prefix(3)) == start,
                  meaningful(text) >= meaningful(oldText) + 2,
                  orderedMatches(Array(oldText.filter { $0.isLetter || $0.isNumber }),
                                 Array(text.filter { $0.isLetter || $0.isNumber })) * 5 >= meaningful(oldText) * 4,
                  oldKanji.isEmpty || orderedMatches(oldKanji, newKanji) >= max(0, oldKanji.count - 1) else { continue }
            // 짧은 인접 칸도 그 내용이 실제 재인식 결과에 살아 있을 때만 삭제한다.
            let newMeaning = Array(text.filter { $0.isLetter || $0.isNumber })
            guard owners.filter({ $0 != i }).allSatisfy({ owner in
                let oldMeaning = Array(regions[owner].text.filter { $0.isLetter || $0.isNumber })
                return orderedMatches(oldMeaning, newMeaning) * 5 >= oldMeaning.count * 4
            }) else { continue }
            consumed.formUnion(owners.filter { $0 != i })
            let glyphs = candidates.flatMap(\.glyphBoxes), glyphTexts = candidates.flatMap(\.glyphTexts)
            let recoveredBox = candidates.dropFirst().reduce(candidates[0].box) { $0.union($1.box) }
            result[i] = OCRRegion(id: original.id, text: text, box: recoveredBox, backgroundHex: original.backgroundHex,
                                  foregroundHex: original.foregroundHex, glyphBoxes: Array(glyphs.prefix(maxGlyphsPerItem)),
                                  glyphTexts: Array(glyphTexts.prefix(maxGlyphsPerItem)), fontStyle: original.fontStyle,
                                  annotationBoxes: originals.flatMap { [$0.box] + $0.annotationBoxes } + candidates.flatMap(\.annotationBoxes) + glyphs.dropFirst(maxGlyphsPerItem))
        }
        return result.enumerated().compactMap { consumed.contains($0.offset) ? nil : $0.element }
    }

    /// 인식한 문단을 번역 단위로 정리한다. 애매하면 바꾸지 않는다.
    /// 1. 본문 줄과 함께 읽힌 후리가나(본문 한자 옆/위에 붙은 작은 가나)를 번역문에서 빼고, 지울 상자(annotationBoxes)로만 남긴다.
    /// 2. 같은 말풍선의 세로쓰기 칸(글자 크기가 비슷하고 서로 붙어 있으며 세로로 많이 겹치는 칸)을 오른쪽 칸부터 이어
    ///    한 문단으로 합친다. 칸마다 따로 번역하면 문장이 끊기고 번역 글자가 칸 너비에 갇혀 읽을 수 없을 만큼 작아진다.
    static func coherentParagraphs(_ regions: [OCRRegion], image: CGImage) -> [OCRRegion] {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard w > 0, h > 0, !regions.isEmpty else { return regions }
        let separated = regions.flatMap { splitMixedSizeTitle($0, w: w, h: h) }
        return mergedVerticalColumns(separated.map { strippingInlineRuby($0, w: w, h: h) }, w: w, h: h)
    }

    /// OCR이 크기가 다른 가로 제목과 부제를 한 줄로 읽으면 번역도 두 제목 사이에 놓인다.
    /// 글자 대응이 정확하고 연속한 글자 높이가 크게 달라지는 경우에만 각각의 실제 글자 영역으로 나눈다.
    private static func splitMixedSizeTitle(_ region: OCRRegion, w: CGFloat, h: CGFloat) -> [OCRRegion] {
        let texts = region.glyphTexts, boxes = region.glyphBoxes
        let characters = Array(region.text)
        let positions = characters.indices.filter { !characters[$0].isWhitespace }
        guard texts.count == boxes.count, texts.count >= 4, positions.count == texts.count,
              zip(positions, texts).allSatisfy({ String(characters[$0.0]) == $0.1 }),
              flow(region, w: w, h: h).vertical == false else { return [region] }
        var starts = [0]
        for i in 1..<boxes.count {
            let a = boxes[i - 1].height * h, b = boxes[i].height * h
            if min(a, b) >= 12, max(a, b) >= min(a, b) * 1.65 { starts.append(i) }
        }
        starts.append(boxes.count)
        guard starts.count > 2,
              zip(starts, starts.dropFirst()).allSatisfy({ $0.1 - $0.0 >= 2 }) else { return [region] }
        return zip(starts, starts.dropFirst()).enumerated().map { part, bounds in
            let indices = bounds.0..<bounds.1
            let glyphs = Array(boxes[indices])
            let box = glyphs.dropFirst().reduce(glyphs[0]) { $0.union($1) }
            let first = bounds.0 == 0 ? 0 : positions[bounds.0]
            let last = bounds.1 == boxes.count ? characters.count : positions[bounds.1]
            return OCRRegion(id: "\(region.id):\(part)",
                             text: String(characters[first..<last]).trimmingCharacters(in: .whitespacesAndNewlines),
                             box: box, backgroundHex: region.backgroundHex, foregroundHex: region.foregroundHex,
                             glyphBoxes: glyphs, glyphTexts: Array(texts[indices]), fontStyle: region.fontStyle,
                             annotationBoxes: region.annotationBoxes.filter { $0.intersects(box) })
        }
    }

    private static func isKana(_ u: Unicode.Scalar) -> Bool {
        (0x3041...0x3096).contains(u.value) || (0x30A1...0x30FA).contains(u.value) || u.value == 0x30FC
    }

    private static func isLetterGlyph(_ text: String) -> Bool { text.contains { $0.isLetter || $0.isNumber } }

    /// 글자 진행 방향(true: 세로, false: 가로, nil: 판단 불가)과 본문 글자 크기(px). 본문 크기는 상위 사분위 근처
    /// 글자로만 재 작은 가나·구두점·후리가나가 끌어내리지 않게 한다.
    private static func flow(_ region: OCRRegion, w: CGFloat, h: CGFloat) -> (vertical: Bool?, size: CGFloat) {
        let boxes = zip(region.glyphBoxes, region.glyphTexts.count == region.glyphBoxes.count ? region.glyphTexts
                        : Array(repeating: "", count: region.glyphBoxes.count))
            .filter { $0.1.isEmpty || isLetterGlyph($0.1) }
            .map { CGRect(x: $0.0.minX * w, y: $0.0.minY * h, width: $0.0.width * w, height: $0.0.height * h) }
        let pixelBox = CGRect(x: region.box.minX * w, y: region.box.minY * h, width: region.box.width * w, height: region.box.height * h)
        guard !boxes.isEmpty else {
            return (pixelBox.height > pixelBox.width * 1.6 ? true : nil, min(pixelBox.width, pixelBox.height))
        }
        let sizes = boxes.map { max($0.width, $0.height) }.sorted()
        let reference = sizes[Int(Double(sizes.count - 1) * 0.75)]
        let body = boxes.filter { max($0.width, $0.height) >= reference * 0.6 }
        let size = body.map { max($0.width, $0.height) }.sorted()[body.count / 2]
        guard body.count >= 2 else {
            return (pixelBox.height > pixelBox.width * 1.6 ? true : (pixelBox.width > pixelBox.height * 1.6 ? false : nil), size)
        }
        var dx: [CGFloat] = [], dy: [CGFloat] = []
        for (a, b) in zip(body, body.dropFirst()) {
            dx.append(abs(b.midX - a.midX)); dy.append(abs(b.midY - a.midY))
        }
        let mx = dx.sorted()[dx.count / 2], my = dy.sorted()[dy.count / 2]
        return (my == mx ? nil : my > mx, size)
    }

    /// 본문 글자 바로 오른쪽(세로쓰기)·바로 위(가로쓰기)에 붙은 작은 가나를 후리가나로 보고 번역문에서 뺀다.
    /// 인식 글자와 상자가 정확히 한 글자씩 대응할 때만 하며, 같은 칸 위아래에 본문 글자가 이어지는 작은 가나(ッ·ィ 등
    /// 본문 글자)는 건드리지 않는다.
    private static func strippingInlineRuby(_ region: OCRRegion, w: CGFloat, h: CGFloat) -> OCRRegion {
        let texts = region.glyphTexts, boxes = region.glyphBoxes
        guard texts.count == boxes.count, texts.count >= 3 else { return region }
        let letters = region.text.filter { !$0.isWhitespace }
        guard letters.count == texts.count, zip(letters, texts).allSatisfy({ String($0) == $1 }) else { return region }
        let px = boxes.map { CGRect(x: $0.minX * w, y: $0.minY * h, width: $0.width * w, height: $0.height * h) }
        let sizes = texts.indices.filter { isLetterGlyph(texts[$0]) }.map { max(px[$0].width, px[$0].height) }.sorted()
        guard sizes.count >= 3 else { return region }
        let body = sizes[Int(Double(sizes.count - 1) * 0.75)]
        guard body > 0 else { return region }
        let bodyIndices = texts.indices.filter { isLetterGlyph(texts[$0]) && max(px[$0].width, px[$0].height) >= body * 0.75 }
        guard bodyIndices.count >= 2, let vertical = flow(region, w: w, h: h).vertical else { return region }
        var ruby = Set<Int>()
        for i in texts.indices where !bodyIndices.contains(i) {
            let g = px[i]
            guard texts[i].unicodeScalars.allSatisfy(isKana), max(g.width, g.height) <= body * 0.62 else { continue }
            // 같은 칸(줄)에 위아래(좌우)로 본문 글자가 이어지면 본문 속 작은 가나다.
            let inLine = bodyIndices.contains { j in
                let r = px[j]
                return vertical ? abs(r.midX - g.midX) < body * 0.4 && abs(r.midY - g.midY) < body * 1.6
                                : abs(r.midY - g.midY) < body * 0.4 && abs(r.midX - g.midX) < body * 1.6
            }
            guard !inLine else { continue }
            // 바로 왼쪽(세로)·아래(가로)의 본문 글자에 붙어 있어야 한다.
            let attached = bodyIndices.contains { j in
                let r = px[j]
                let offset = vertical ? g.midX - r.midX : r.midY - g.midY
                let along = vertical ? abs(g.midY - r.midY) : abs(g.midX - r.midX)
                return offset >= body * 0.45 && offset <= body * 1.0 && along <= body * 1.2
            }
            if attached { ruby.insert(i) }
        }
        guard !ruby.isEmpty, texts.count - ruby.count >= 2 else { return region }
        var text = ""
        var glyph = 0
        for character in region.text {
            if character.isWhitespace { text.append(character); continue }
            if !ruby.contains(glyph) { text.append(character) }
            glyph += 1
        }
        let keep = texts.indices.filter { !ruby.contains($0) }
        return OCRRegion(id: region.id, text: text, box: region.box, backgroundHex: region.backgroundHex,
                         foregroundHex: region.foregroundHex, glyphBoxes: keep.map { boxes[$0] }, glyphTexts: keep.map { texts[$0] },
                         fontStyle: region.fontStyle, typography: region.typography,
                         annotationBoxes: region.annotationBoxes + ruby.sorted().map { boxes[$0] })
    }

    /// 같은 말풍선의 세로쓰기 칸들을 오른쪽 칸부터 읽는 순서로 한 문단으로 합친다. 두 칸 모두 세로쓰기이고
    /// 본문 글자 크기가 1.35배 안, 세로 범위가 짧은 칸의 40% 이상 겹치며, 칸 사이 가로 간격이 글자 하나 남짓 이하일 때만.
    private static func mergedVerticalColumns(_ regions: [OCRRegion], w: CGFloat, h: CGFloat) -> [OCRRegion] {
        let flows = regions.map { flow($0, w: w, h: h) }
        let boxes = regions.map { CGRect(x: $0.box.minX * w, y: $0.box.minY * h, width: $0.box.width * w, height: $0.box.height * h) }
        var parent = Array(regions.indices)
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { i = parent[i] }; return i }
        for i in regions.indices where flows[i].vertical == true && regions[i].text.unicodeScalars.contains(where: isCJK) {
            for j in regions.indices where j > i && flows[j].vertical == true && regions[j].text.unicodeScalars.contains(where: isCJK) {
                let a = boxes[i], b = boxes[j], sa = flows[i].size, sb = flows[j].size
                guard sa > 0, sb > 0, max(sa, sb) <= min(sa, sb) * 1.35 else { continue }
                let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                guard overlap >= min(a.height, b.height) * 0.4 else { continue }
                let gap = max(a.minX, b.minX) - min(a.maxX, b.maxX)
                guard gap <= max(sa, sb) * 1.1, gap >= -min(sa, sb) * 0.5 else { continue }
                let (ri, rj) = (find(i), find(j))
                if ri != rj { parent[rj] = ri }
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in regions.indices { groups[find(i), default: []].append(i) }
        var emitted = Set<Int>()
        var result: [OCRRegion] = []
        for i in regions.indices {
            let root = find(i)
            guard !emitted.contains(root), let members = groups[root] else { continue }
            emitted.insert(root)
            guard members.count > 1 else { result.append(regions[i]); continue }
            // 오른쪽 칸부터(세로쓰기 읽는 순서), 같은 자리면 위쪽부터.
            let ordered = members.sorted { boxes[$0].maxX != boxes[$1].maxX ? boxes[$0].maxX > boxes[$1].maxX : boxes[$0].minY < boxes[$1].minY }
            var text = ""
            var glyphBoxes: [CGRect] = [], glyphTexts: [String] = [], annotations: [CGRect] = []
            var textsAligned = true
            var box = regions[ordered[0]].box
            for k in ordered {
                let part = regions[k]
                if !text.isEmpty, !needsNoSpace(text.unicodeScalars.last, part.text.unicodeScalars.first) { text += " " }
                text += part.text
                box = box.union(part.box)
                annotations += part.annotationBoxes
                if part.glyphTexts.count != part.glyphBoxes.count { textsAligned = false }
                for (index, glyph) in part.glyphBoxes.enumerated() {
                    // 상한을 넘는 글자 상자는 크기 산정에는 쓰지 않고 지울 상자로만 남긴다(원문이 남지 않게).
                    guard glyphBoxes.count < maxGlyphsPerItem else { annotations.append(glyph); continue }
                    glyphBoxes.append(glyph)
                    glyphTexts.append(index < part.glyphTexts.count ? part.glyphTexts[index] : "")
                }
            }
            let largest = ordered.max { regions[$0].box.width * regions[$0].box.height < regions[$1].box.width * regions[$1].box.height }!
            let styles = ordered.compactMap { regions[$0].fontStyle }
            let style = Dictionary(grouping: styles, by: { $0 }).max { $0.value.count < $1.value.count }?.key
            result.append(OCRRegion(id: regions[ordered[0]].id, text: text, box: box, backgroundHex: regions[largest].backgroundHex,
                                    foregroundHex: regions[largest].foregroundHex, glyphBoxes: glyphBoxes,
                                    glyphTexts: textsAligned ? glyphTexts : [], fontStyle: style, annotationBoxes: annotations))
        }
        return result
    }

    /// 레거시 줄 검출 한 줄: 인식 글자, 줄 상자, 글자별 상자(정규화 좌표, 원점 왼쪽 위).
    typealias LegacyLine = (String, CGRect, [(String, CGRect)])

    /// 문서 인식 영역에 레거시 줄 검출을 겹쳐 본다. 번역문이 두 번 나오지 않게 판단은 면적으로만 한다.
    /// - 문서 영역과 거의 겹치지 않는 줄(겹친 면적 20% 미만): 문서 인식이 놓친 글자(그림 위 로고 등)로 보고
    ///   기존 줄 묶기(group)로 새 항목을 만든다. 실제 글자 상자가 있으므로 글자 모양대로 지울 수 있다.
    /// - 문서 영역과 겹치는 줄: 이미 번역되는 원문이므로 새 항목을 만들지 않고, 문서 글자 상자가 덮지 못한
    ///   레거시 글자 상자(잘린 첫 글자·외곽 글자)만 가장 많이 겹친 문서 항목의 지울 상자(annotationBoxes)로 더한다.
    /// 문단 구조와 번역 단위는 문서 결과를 그대로 따른다.
    private static func supplementing(_ regions: [OCRRegion], with lines: [LegacyLine], image: CGImage, assetID: String,
                                      classifyFonts: Bool) -> [OCRRegion] {
        guard !lines.isEmpty else { return regions }
        func area(_ r: CGRect) -> CGFloat { r.isNull || r.isEmpty ? 0 : r.width * r.height }
        func covered(_ box: CGRect, by others: [CGRect]) -> CGFloat {
            let a = area(box)
            guard a > 0 else { return 1 }
            return min(1, others.reduce(0) { $0 + area($1.intersection(box)) } / a)
        }
        let regionBoxes = regions.map(\.box)
        let regionGlyphs = regions.map { $0.glyphBoxes + $0.annotationBoxes }
        var extra = [[CGRect]](repeating: [], count: regions.count)
        var missed: [LegacyLine] = []
        for line in lines {
            guard covered(line.1, by: regionBoxes) >= 0.2 else { missed.append(line); continue }
            guard let owner = regions.indices.max(by: { area(regionBoxes[$0].intersection(line.1)) < area(regionBoxes[$1].intersection(line.1)) })
            else { continue }
            let known = regionGlyphs.flatMap { $0 } + extra.flatMap { $0 }
            let letters = line.2.filter { isLetterGlyph($0.0) }
            let missingLetters = letters.filter { covered($0.1, by: known) < 0.3 }
            let compact = String(line.0.filter { $0.isLetter || $0.isNumber })
            let neighbors = regions.filter { area($0.box.intersection(line.1)) > 0 }
            let alreadyRead = !compact.isEmpty && neighbors.contains {
                String($0.text.filter { $0.isLetter || $0.isNumber }).contains(compact)
            }
            let ownerLetters = regions[owner].text.filter { $0.isLetter || $0.isNumber }.count
            let ownerGlyphs = zip(regions[owner].glyphTexts, regions[owner].glyphBoxes).filter { isLetterGlyph($0.0) }.count
            let reliableOwner = ownerLetters > 0 && ownerGlyphs * 5 >= ownerLetters * 4
            // 문단 상자 안에 있어도 글자 대부분을 놓친 독립 줄은 번역 대상으로 보충한다.
            // 지울 상자로만 추가하던 경로는 인식한 작은 본문까지 번역 없이 지웠다.
            if reliableOwner, letters.count >= 2, missingLetters.count * 5 >= letters.count * 4, !alreadyRead {
                missed.append(line)
                continue
            }
            for (text, glyph) in line.2 where isLetterGlyph(text) && covered(glyph, by: known) < 0.3 {
                extra[owner].append(glyph)
            }
        }
        var result = regions.indices.map { i -> OCRRegion in
            let region = regions[i]
            guard !extra[i].isEmpty else { return region }
            return OCRRegion(id: region.id, text: region.text, box: region.box, backgroundHex: region.backgroundHex,
                             foregroundHex: region.foregroundHex, glyphBoxes: region.glyphBoxes, glyphTexts: region.glyphTexts,
                             fontStyle: region.fontStyle, typography: region.typography,
                             annotationBoxes: region.annotationBoxes + extra[i])
        }
        let room = maxRegions - result.count
        if room > 0, !missed.isEmpty {
            result += group(missed, image: image, assetID: assetID, classifyFonts: classifyFonts, idOffset: regions.count).prefix(room)
        }
        return result
    }

    private static func recognizeLegacy(_ image: CGImage, assetID: String, classifyFonts: Bool) async throws -> [OCRRegion] {
        let lines = try await legacyLines(image)
        return group(lines, image: image, assetID: assetID, classifyFonts: classifyFonts)
    }

    private static func legacyLines(_ image: CGImage) async throws -> [LegacyLine] {
        try Task.checkCancellation()

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let lines: [(String, CGRect, [(String, CGRect)])] = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                try handler.perform([request])
                let observations = request.results ?? []
                return observations.compactMap { obs -> (String, CGRect, [(String, CGRect)])? in
                    guard let candidate = obs.topCandidates(1).first, candidate.confidence >= 0.3 else { return nil }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    let b = obs.boundingBox
                    let box = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
                    return (text, box, glyphs(of: candidate))
                }
            }.value
        } onCancel: {
            request.cancel()
        }
        try Task.checkCancellation()
        return lines
    }

    /// 세로로 가깝고 왼쪽 정렬이 비슷한 줄을 하나의 문단으로 묶어 번역 품질을 높인다.
    /// 글자 상자는 묶이는 줄 순서대로 그대로 이어붙일 뿐 다시 의미 단위로 재구성하지 않는다.
    /// - Parameter idOffset: 다른 영역 뒤에 덧붙일 때 항목 id가 겹치지 않게 번호를 이만큼 밀어 시작한다.
    private static func group(_ lines: [LegacyLine], image: CGImage, assetID: String,
                              classifyFonts: Bool, idOffset: Int = 0) -> [OCRRegion] {
        let sorted = lines.sorted { a, b in
            abs(a.1.minY - b.1.minY) < min(a.1.height, b.1.height) * 0.5 ? a.1.minX < b.1.minX : a.1.minY < b.1.minY
        }
        // extra: 글자 상자 상한(maxGlyphsPerItem)을 넘은 글자. 크기 산정에는 쓰지 않고 원문을 지울 상자로만 남긴다.
        var groups: [(text: String, box: CGRect, lastBox: CGRect, glyphs: [(String, CGRect)], extra: [CGRect])] = []
        for (text, box, glyphs) in sorted {
            if let last = groups.last {
                let gap = box.minY - last.lastBox.maxY
                let heightRatio = box.height / max(last.lastBox.height, 0.0001)
                let alignedLeft = abs(box.minX - last.lastBox.minX) < 0.06
                let overlaps = box.minX < last.box.maxX && box.maxX > last.box.minX
                if gap >= -last.lastBox.height * 0.3, gap < last.lastBox.height * 0.9,
                   heightRatio > 0.65, heightRatio < 1.5, alignedLeft || overlaps {
                    let joiner = needsNoSpace(last.text.unicodeScalars.last, text.unicodeScalars.first) ? "" : " "
                    let remaining = max(0, maxGlyphsPerItem - last.glyphs.count)
                    let mergedGlyphs = last.glyphs + glyphs.prefix(remaining)
                    let extra = last.extra + glyphs.dropFirst(remaining).map(\.1)
                    groups[groups.count - 1] = (last.text + joiner + text, last.box.union(box), box, mergedGlyphs, extra)
                    continue
                }
            }
            groups.append((text, box, box, Array(glyphs.prefix(maxGlyphsPerItem)), glyphs.dropFirst(maxGlyphsPerItem).map(\.1)))
        }
        return groups.prefix(maxRegions).enumerated().map { index, g in
            let (bg, fg) = sampleColors(of: image, in: g.box)
            let glyphBoxes = g.glyphs.map(\.1)
            let fontStyle = classifyFonts ? classifyFontStyle(of: image, glyphBoxes: glyphBoxes) : nil
            return OCRRegion(id: "\(assetID)#\(idOffset + index)", text: g.text, box: g.box, backgroundHex: bg, foregroundHex: fg,
                              glyphBoxes: glyphBoxes, glyphTexts: g.glyphs.map(\.0), fontStyle: fontStyle, annotationBoxes: g.extra)
        }
    }

    /// candidate의 string에서 공백이 아닌 글자마다 boundingBox(for:)로 잉크 상자를 구한다. 범위를 못 구한
    /// 글자는 건너뛸 뿐(문단 전체를 지우는 폴백은 쓰지 않음) 결과 개수는 최대 maxGlyphsPerItem개로 제한한다.
    static func glyphBoxes(of candidate: VNRecognizedText) -> [CGRect] {
        glyphs(of: candidate).map(\.1)
    }

    /// Vision이 글자별 범위에 같은 단어 상자를 반환할 때, 그 단어를 한 글자 크기로 재지 않는다.
    /// 라틴 글자뿐 아니라 장식 제목의 가나·한자(예: 큰 제목 한 줄)도 글자마다 같은 단어 상자가 올 수 있어, 그대로 두면
    /// 글자 크기를 단어 길이로 재고(긴 변 기준) 가림도 단어 상자 전체가 된다. 같은 상자가 이어진 구간만 읽는 방향(긴 변)으로
    /// 고르게 나누며 다른 글자·공백 영역은 유지한다.
    static func resolvedWordBoxes(_ boxes: [CGRect], texts: [String]) -> [CGRect] {
        guard boxes.count == texts.count else { return boxes }
        func latin(_ text: String) -> Bool {
            text.unicodeScalars.count == 1 && text.unicodeScalars.allSatisfy {
                (65...90).contains(Int($0.value)) || (97...122).contains(Int($0.value))
            }
        }
        func cjk(_ text: String) -> Bool {
            text.unicodeScalars.count == 1 && text.unicodeScalars.allSatisfy {
                (0x3041...0x30FF).contains(Int($0.value)) || (0x3400...0x9FFF).contains(Int($0.value))
                    || (0xFF66...0xFF9F).contains(Int($0.value))
            }
        }
        var result = boxes
        var start = 0
        while start < boxes.count {
            let isLatin = latin(texts[start]), isCJK = !isLatin && cjk(texts[start])
            let box = boxes[start]
            // 라틴은 기존대로 가로 단어만, 가나·한자는 가로·세로 어느 쪽이든 긴 변 방향으로 나눈다.
            let vertical = isCJK && box.height > box.width * 1.5
            guard isLatin || isCJK, box.width > box.height * 1.5 || vertical else { start += 1; continue }
            let first = boxes[start]
            var end = start + 1
            var word = first
            while end < boxes.count, isLatin ? latin(texts[end]) : cjk(texts[end]) {
                let other = boxes[end]
                let overlap = first.intersection(other)
                let smaller = min(first.width * first.height, other.width * other.height)
                guard smaller > 0, !overlap.isNull, overlap.width * overlap.height / smaller > 0.85 else { break }
                word = word.union(other)
                end += 1
            }
            if end - start >= 2 {
                let count = CGFloat(end - start)
                for index in start..<end {
                    let step = CGFloat(index - start)
                    result[index] = vertical
                        ? CGRect(x: word.minX, y: word.minY + step * word.height / count, width: word.width, height: word.height / count)
                        : CGRect(x: word.minX + step * word.width / count, y: word.minY, width: word.width / count, height: word.height)
                }
            }
            start = end
        }
        return result
    }

    /// glyphBoxes(of:)와 같되 각 상자의 인식 글자를 함께 돌려준다(원본 글자 모양 대조용).
    static func glyphs(of candidate: VNRecognizedText) -> [(String, CGRect)] {
        let transcript = candidate.string
        var boxes: [(String, CGRect)] = []
        var index = transcript.startIndex
        while index < transcript.endIndex, boxes.count < maxGlyphsPerItem {
            let next = transcript.index(after: index)
            if !transcript[index].isWhitespace, let rect = try? candidate.boundingBox(for: index..<next) {
                let b = rect.boundingBox
                let box = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
                if let clamped = clampedUnitBox(box) { boxes.append((String(transcript[index]), clamped)) }
            }
            index = next
        }
        return boxes
    }

    /// 글자 bbox와 그 주변 여백을 함께 작은 그리드로 샘플링해, 글자(잉크)나 말풍선 테두리 같은
    /// 이상치에 휘둘리지 않는 지배적 배경색을 고른다. bbox 바깥의 여백 샘플에 더 큰 가중치를 줘
    /// "흰 말풍선 전체가 회색으로 뭉개지는" 문제를 막는다. 투명 픽셀은 배경 후보에서 제외하고,
    /// 샘플이 전혀 없거나 컨텍스트 생성이 실패하면 기존처럼 흰/검정으로 되돌아간다.
    /// 원본 파일은 건드리지 않으며 이 샘플은 화면 표시용 오버레이 색상에만 쓰인다.
    private static func sampleColors(of image: CGImage, in box: CGRect) -> (background: String, foreground: String) {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let imageBounds = CGRect(x: 0, y: 0, width: w, height: h)
        let boxRect = CGRect(x: box.minX * w, y: box.minY * h, width: max(box.width * w, 1), height: max(box.height * h, 1))
            .intersection(imageBounds).integral
        guard boxRect.width >= 1, boxRect.height >= 1 else { return ("#FFFFFF", "#000000") }

        let pad = min(max(min(boxRect.width, boxRect.height) * 0.25, 2), 12)
        let paddedRect = boxRect.insetBy(dx: -pad, dy: -pad).intersection(imageBounds).integral
        guard paddedRect.width >= 1, paddedRect.height >= 1, let cropped = image.cropping(to: paddedRect) else {
            return ("#FFFFFF", "#000000")
        }

        let gridSize = 10
        var pixels = [UInt8](repeating: 0, count: gridSize * gridSize * 4)
        guard let ctx = CGContext(data: &pixels, width: gridSize, height: gridSize, bitsPerComponent: 8, bytesPerRow: gridSize * 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return ("#FFFFFF", "#000000")
        }
        ctx.interpolationQuality = .none
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: gridSize, height: gridSize))

        // 패딩 영역 기준 상대 좌표로 원래 bbox 경계를 표현해, 그리드의 각 샘플이
        // "글자 내부(bbox 안)"인지 "주변 여백(bbox 밖)"인지 구분한다.
        let localMinX = (boxRect.minX - paddedRect.minX) / paddedRect.width
        let localMaxX = (boxRect.maxX - paddedRect.minX) / paddedRect.width
        let localMinY = (boxRect.minY - paddedRect.minY) / paddedRect.height
        let localMaxY = (boxRect.maxY - paddedRect.minY) / paddedRect.height

        struct Bucket { var key = 0; var weight = 0.0; var rSum = 0.0; var gSum = 0.0; var bSum = 0.0 }
        var buckets: [Int: Bucket] = [:]

        for gy in 0..<gridSize {
            for gx in 0..<gridSize {
                let idx = (gy * gridSize + gx) * 4
                let a = pixels[idx + 3]
                guard a > 10 else { continue } // 투명/거의 투명한 픽셀은 배경 후보로 쓰지 않는다.
                let alpha = Double(a) / 255
                let r = min(Double(pixels[idx]) / 255 / alpha, 1)
                let g = min(Double(pixels[idx + 1]) / 255 / alpha, 1)
                let b = min(Double(pixels[idx + 2]) / 255 / alpha, 1)

                let fx = (Double(gx) + 0.5) / Double(gridSize)
                let fy = (Double(gy) + 0.5) / Double(gridSize)
                let isInterior = fx > localMinX && fx < localMaxX && fy > localMinY && fy < localMaxY
                let weight = isInterior ? 1.0 : 3.0 // 여백 샘플이 더 깨끗한 배경이므로 더 신뢰한다.

                let key = (Int(r * 7) << 6) | (Int(g * 7) << 3) | Int(b * 7)
                var bucket = buckets[key] ?? Bucket(key: key)
                bucket.weight += weight
                bucket.rSum += r * weight
                bucket.gSum += g * weight
                bucket.bSum += b * weight
                buckets[key] = bucket
            }
        }

        guard let best = buckets.values.max(by: { $0.weight < $1.weight || ($0.weight == $1.weight && $0.key < $1.key) }), best.weight > 0 else {
            return ("#FFFFFF", "#000000")
        }
        let r = best.rSum / best.weight, g = best.gSum / best.weight, b = best.bSum / best.weight
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        let bg = String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        let fg = luminance > 0.55 ? "#000000" : "#FFFFFF"
        return (bg, fg)
    }

    // MARK: 글꼴 갈래 추정(고딕/명조/손글씨)

    /// 실제 원본 글자 획의 두께 대비·가장자리 규칙성을 가볍게 재어 고딕/명조/손글씨 중 하나로 거칠게 가른다.
    /// 언어나 세로쓰기 여부만으로 정하지 않으며(실제 자모 모양을 본다), 정밀한 글꼴 식별을 목표로 하지 않는다.
    /// OCR 결과 하나당 한 번만 계산하고(글자당 상한 10개) 캐시하지 않으며, 움직임·스크롤마다 다시 재지 않는다.
    static func classifyFontStyle(of image: CGImage, glyphBoxes: [CGRect]) -> String? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard w > 0, h > 0, !glyphBoxes.isEmpty else { return nil }
        let imageBounds = CGRect(x: 0, y: 0, width: w, height: h)
        let widths = glyphBoxes.map { $0.width * w }.sorted()
        let medianWidth = widths[widths.count / 2]
        guard medianWidth > 0 else { return nil }

        var widthCVs: [Double] = []
        var irregularities: [Double] = []
        for box in glyphBoxes {
            guard widthCVs.count < 10 else { break } // 글자당 비용 상한
            let bw = box.width * w, bh = box.height * h
            // 중앙값과 너무 다른 상자(구두점·후리가나, 또는 여러 글자가 뭉친 상자)는 전형적이지 않으므로 뺀다.
            guard bw >= medianWidth * 0.6, bw <= medianWidth * 1.8, bh > 0 else { continue }
            let rect = CGRect(x: box.minX * w, y: box.minY * h, width: bw, height: bh).intersection(imageBounds).integral
            guard rect.width >= 6, rect.height >= 6, let cropped = image.cropping(to: rect),
                  let stats = strokeStats(of: cropped) else { continue }
            widthCVs.append(stats.widthCV)
            irregularities.append(stats.edgeIrregularity)
        }
        guard widthCVs.count >= 2 else { return nil } // 표본이 너무 적으면 미판별로 둔다

        // 한 글자의 특이한 모양이 문단 전체를 결정하지 않도록, 유효 표본의 60% 이상이 같은
        // 특징을 보일 때만 명조/손글씨로 분류한다. 임계값은 경험적 휴리스틱이며 정확한 식별은 아니다.
        let requiredVotes = max(2, Int(ceil(Double(widthCVs.count) * 0.6)))
        let handVotes = zip(widthCVs, irregularities).filter { $0.0 > 0.22 && $0.1 > 0.4 }.count
        if handVotes >= requiredVotes { return "hand" }
        let serifVotes = zip(widthCVs, irregularities).filter { $0.0 > 0.4 && $0.1 <= 0.4 }.count
        if serifVotes >= requiredVotes { return "myeongjo" }
        return "gothic"
    }

    /// 각 픽셀을 지나는 가로·세로 run 중 짧은 쪽으로 획 두께를 근사한다. 가로 run만 쓰면
    /// 긴 가로획 자체가 "두꺼운 획"으로 계산되는 문제가 있다. 윤곽의 꺾임은 글자 전체 크기가
    /// 아닌 대표 획 두께로 나누므로 얇은 손글씨의 작은 흔들림도 유효한 척도로 측정된다.
    private static func strokeStats(of image: CGImage) -> (widthCV: Double, edgeIrregularity: Double)? {
        let grid = 32
        var pixels = [UInt8](repeating: 0, count: grid * grid * 4)
        guard let ctx = CGContext(data: &pixels, width: grid, height: grid, bitsPerComponent: 8, bytesPerRow: grid * 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: grid, height: grid))

        func luminance(_ x: Int, _ y: Int) -> Double {
            let idx = (y * grid + x) * 4
            let a = Double(pixels[idx + 3]) / 255
            guard a > 0.05 else { return 1 }
            let r = min(Double(pixels[idx]) / 255 / a, 1), g = min(Double(pixels[idx + 1]) / 255 / a, 1),
                b = min(Double(pixels[idx + 2]) / 255 / a, 1)
            return 0.299 * r + 0.587 * g + 0.114 * b
        }
        let levels = (0..<(grid * grid)).map { luminance($0 % grid, $0 / grid) }
        let ordered = levels.sorted()
        // 얇은 글씨는 잉크가 상자의 10%보다 적을 수 있다. 10~90%만 보면 양끝이
        // 모두 배경색이 되어 정상 글자를 빈 상자로 버리므로, 양끝 2%만 제외한다.
        let low = ordered[ordered.count / 50], high = ordered[ordered.count * 49 / 50]
        guard high - low >= 0.15 else { return nil } // 저대비·빈 상자는 분류하지 않는다
        let threshold = (low + high) / 2
        let border = (0..<grid).flatMap { i in [luminance(i, 0), luminance(i, grid - 1),
                                                 luminance(0, i), luminance(grid - 1, i)] }.sorted()
        let darkInk = border[border.count / 2] >= threshold
        let ink = levels.map { darkInk ? $0 < threshold : $0 > threshold }
        let inkCount = ink.filter { $0 }.count
        guard inkCount >= 12, inkCount < grid * grid * 3 / 4 else { return nil }

        var horizontal = [Int](repeating: 0, count: grid * grid)
        var vertical = horizontal
        var edges: [[Int?]] = []
        for alongRows in [true, false] {
            var first = [Int?](repeating: nil, count: grid)
            var last = first
            for line in 0..<grid {
                var position = 0
                while position < grid {
                    let index = alongRows ? line * grid + position : position * grid + line
                    guard ink[index] else { position += 1; continue }
                    let start = position
                    while position < grid && ink[alongRows ? line * grid + position : position * grid + line] {
                        position += 1
                    }
                    if first[line] == nil { first[line] = start }
                    last[line] = position - 1
                    for offset in start..<position {
                        let pixel = alongRows ? line * grid + offset : offset * grid + line
                        if alongRows { horizontal[pixel] = position - start }
                        else { vertical[pixel] = position - start }
                    }
                }
            }
            edges.append(first)
            edges.append(last)
        }
        let widths = ink.indices.compactMap { index -> Double? in
            guard ink[index] else { return nil }
            let width = min(horizontal[index], vertical[index])
            // 큰 교차점·뭉친 상자는 획 두께 표본에서 제외한다.
            return width > 0 && width <= grid / 3 ? Double(width) : nil
        }.sorted()
        guard widths.count >= 12 else { return nil }
        let typicalWidth = widths[widths.count / 2]
        let mean = widths.reduce(0, +) / Double(widths.count)
        let variance = widths.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(widths.count)
        var bends: [Double] = []
        for edge in edges {
            for i in 1..<(grid - 1) {
                guard let a = edge[i - 1], let b = edge[i], let c = edge[i + 1],
                      abs(b - a) <= grid / 4, abs(c - b) <= grid / 4 else { continue }
                // 일정한 기울기 자체는 불규칙성이 아니다. 떨어진 부품 사이의 큰 점프도 제외한다.
                bends.append(Double(abs(c - 2 * b + a)))
            }
        }
        guard bends.count >= 8 else { return nil }
        let irregularity = bends.reduce(0, +) / Double(bends.count) / max(typicalWidth, 1)
        return (variance.squareRoot() / mean, irregularity)
    }

    /// 원본 글자 픽셀 분석(GlyphAnalyzer)을 적용한 영역. 실제 잉크로 좁힌 글자 상자, 글자 대조로 고른 글꼴 갈래,
    /// 굵기·글자색, (요청 시) 배경 복원 조각을 담는다. 분석이 실패한 값은 기존 값을 그대로 둔다.
    /// - Parameter restoreIDs: 주어지면 이 항목들만 배경 복원 조각을 만든다(번역해 그리지 않을 항목의 조각은 버려지므로).
    static func analyzed(_ regions: [OCRRegion], image: CGImage, restoration: Bool, restoreIDs: Set<String>? = nil) -> [OCRRegion] {
        guard !regions.isEmpty, let canvas = GlyphAnalyzer.Canvas(image) else { return regions }
        var occupied = [Bool](repeating: false, count: canvas.width * canvas.height)
        for region in regions {
            for box in region.glyphBoxes + region.annotationBoxes {
                guard let r = canvas.pixelRect(box) else { continue }
                for y in r.y0..<r.y1 { for x in r.x0..<r.x1 { occupied[y * canvas.width + x] = true } }
            }
        }
        // 항목마다 독립적인 분석(픽셀 버퍼·occupied는 읽기만 함)이므로 여러 코어에서 함께 잰다.
        let measures = GlyphAnalyzer.concurrentMap(regions.count) {
            GlyphAnalyzer.measure(regions[$0], canvas: canvas, occupied: occupied)
        }
        // 본문 한자에 붙은 후리가나 항목은 따로 번역하지 않는다. 그 원문은 본문 배경 복원에만 함께 지우고,
        // 본문 글자 상자(글자 크기 산정)에는 섞지 않는다. 분석은 다시 하지 않고 첫 분석 결과를 그대로 쓴다.
        let furigana = furiganaAttachments(regions, inkBoxes: measures.map(\.inkBoxes), canvas: canvas)
        let attached = Set(furigana.values.joined())
        let kept = regions.indices.filter { !attached.contains($0) }
        let patches: [GlyphAnalyzer.Restoration?] = restoration ? GlyphAnalyzer.concurrentMap(kept.count) { k in
            let index = kept[k]
            if let restoreIDs, !restoreIDs.contains(regions[index].id) { return nil }
            let annotations = (furigana[index] ?? []).flatMap { measures[$0].targets }
            return GlyphAnalyzer.restoration(measures[index].targets + annotations, canvas: canvas, occupied: occupied)
        } : Array(repeating: nil, count: kept.count)
        return kept.enumerated().map { k, index in
            let region = regions[index]
            let measure = measures[index]
            let patch = patches[k]
            // 화면 표시 쪽이 복원 조각을 못 쓸 때(응답 크기 상한 등) 대신 가릴 상자: 본문 글자 상자(g) 밖의 지울 대상.
            let cover = measure.extraCoverBoxes + (furigana[index] ?? []).flatMap { measures[$0].coverBoxes }
            let typography = GlyphTypography(inkBoxes: measure.inkBoxes, maskedGlyphs: measure.maskedGlyphs,
                                             fontStyle: measure.fontStyle, bold: measure.bold,
                                             foregroundHex: measure.foregroundHex, outlineHex: measure.outlineHex,
                                             restorationBox: patch?.box, restorationPNG: patch?.png,
                                             coverBoxes: cover, uncoveredGlyphs: measure.uncoveredGlyphs)
            // 픽셀 대조가 불확실하면 기본 인쇄체로 표시한다. 복원 잡음의 불규칙성을
            // 손글씨로 해석하는 획 통계를 다시 적용하면 대조에서 거른 오판을 되살린다.
            let style = measure.fontStyle ?? region.fontStyle
            return OCRRegion(id: region.id, text: region.text, box: region.box, backgroundHex: measure.backgroundHex ?? region.backgroundHex,
                             foregroundHex: region.foregroundHex, glyphBoxes: measure.inkBoxes, glyphTexts: region.glyphTexts,
                             fontStyle: style, typography: typography, annotationBoxes: region.annotationBoxes)
        }
    }

    /// 큰 한자 본문에 붙은 작은 가나 읽기(후리가나)로 보이는 항목을 본문 번호 -> 후리가나 항목 번호로 돌려준다.
    /// 실제 잉크 상자로 잰 크기와 위치만 근거로 하며, 다음을 모두 만족할 때만 묶는다(애매하면 독립 항목으로 남긴다).
    /// - 후리가나 항목: 공백 외 1~8자가 모두 가나, 글자 크기(잉크 긴 변 중앙값)가 본문 글자 크기의 60% 이하,
    ///   줄 두께(세로쓰기 너비/가로쓰기 높이)가 본문 글자 크기의 75% 이하
    /// - 본문: 글자 2자 이상, 글자 진행 방향(세로/가로)이 과반으로 정해지고 한자를 포함
    /// - 위치: 세로쓰기면 한자 바로 오른쪽, 가로쓰기면 한자 바로 위(간격 -25%~50% 본문 글자 크기)이며,
    ///   후리가나 길이의 60% 이상이 그 한자들의 범위와 겹친다
    private static func furiganaAttachments(_ regions: [OCRRegion], inkBoxes: [[CGRect]], canvas: GlyphAnalyzer.Canvas) -> [Int: [Int]] {
        let cw = CGFloat(canvas.width), ch = CGFloat(canvas.height)
        func pixel(_ b: CGRect) -> CGRect { CGRect(x: b.minX * cw, y: b.minY * ch, width: b.width * cw, height: b.height * ch) }
        func median(_ values: [CGFloat]) -> CGFloat { values.sorted()[values.count / 2] }
        func isKana(_ u: Unicode.Scalar) -> Bool {
            (0x3041...0x3096).contains(u.value) || (0x30A1...0x30FA).contains(u.value) || u.value == 0x30FC
        }
        func isKanji(_ text: String) -> Bool {
            text.unicodeScalars.contains { u in
                (0x4E00...0x9FFF).contains(u.value) || (0x3400...0x4DBF).contains(u.value)
                    || (0xF900...0xFAFF).contains(u.value) || u.value == 0x3005
            }
        }
        // 본문 후보: 글자 상자 크기·진행 방향·한자 상자(픽셀)
        struct Body { let size: CGFloat; let vertical: Bool; let kanji: [CGRect] }
        let bodies = regions.indices.map { index -> Body? in
            let region = regions[index]
            guard region.glyphTexts.count == inkBoxes[index].count else { return nil }
            let letters = zip(region.glyphTexts, inkBoxes[index].map(pixel)).filter { $0.0.contains { $0.isLetter || $0.isNumber } }
            guard letters.count >= 2 else { return nil }
            var down = 0, across = 0
            for (a, b) in zip(letters, letters.dropFirst()) {
                if abs(b.1.midY - a.1.midY) > abs(b.1.midX - a.1.midX) { down += 1 } else { across += 1 }
            }
            let kanji = letters.filter { isKanji($0.0) }.map(\.1)
            guard down != across, !kanji.isEmpty else { return nil }
            return Body(size: median(letters.map { max($0.1.width, $0.1.height) }), vertical: down > across, kanji: kanji)
        }
        var result: [Int: [Int]] = [:]
        for (index, region) in regions.enumerated() {
            let scalars = region.text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            guard (1...8).contains(scalars.count), scalars.allSatisfy(isKana), !inkBoxes[index].isEmpty else { continue }
            let boxes = inkBoxes[index].map(pixel)
            let span = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
            let size = median(boxes.map { max($0.width, $0.height) })
            var best: (body: Int, gap: CGFloat)?
            for (bodyIndex, body) in bodies.enumerated() {
                guard bodyIndex != index, let body, size <= body.size * 0.6,
                      (body.vertical ? span.width : span.height) <= body.size * 0.75 else { continue }
                var covered: CGFloat = 0
                var nearest: CGFloat?
                for k in body.kanji {
                    // 세로쓰기는 한자 오른쪽, 가로쓰기는 한자 위
                    let gap = body.vertical ? span.minX - k.maxX : k.minY - span.maxY
                    guard gap >= -body.size * 0.25, gap <= body.size * 0.5 else { continue }
                    let overlap = body.vertical ? min(span.maxY, k.maxY) - max(span.minY, k.minY)
                                                : min(span.maxX, k.maxX) - max(span.minX, k.minX)
                    guard overlap > 0 else { continue }
                    covered += overlap
                    nearest = min(nearest ?? gap, gap)
                }
                guard let nearest, covered >= (body.vertical ? span.height : span.width) * 0.6 else { continue }
                if best == nil || abs(nearest) < abs(best!.gap) { best = (bodyIndex, nearest) }
            }
            if let best { result[best.body, default: []].append(index) }
        }
        return result
    }

    private static func needsNoSpace(_ a: Unicode.Scalar?, _ b: Unicode.Scalar?) -> Bool {
        guard let a, let b else { return false }
        return isCJK(a) && isCJK(b)
    }

    fileprivate static func isCJK(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF: return true
        default: return false
        }
    }
}

// MARK: - 원본 글자 픽셀 분석(브라우저 이미지 번역 전용)

/// OCR 항목 하나의 원본 글자 픽셀 분석 결과. 모든 값은 원본 비트맵 픽셀에서 잰 것이며 실패한 값은 nil/false다.
/// 이미지 바이트는 메모리에서만 쓰고, 복원 조각은 화면 표시용 오버레이에만 쓰인다(원본 파일을 바꾸지 않음).
struct GlyphTypography {
    /// 입력 glyphBoxes와 같은 순서·개수. 실제 잉크로 좁힌 상자(좁히지 못한 글자는 원래 상자)
    let inkBoxes: [CGRect]
    /// 잉크 마스크를 실제로 구한 글자 수(배경 복원 대상)
    let maskedGlyphs: Int
    /// 인식 글자를 일본어 견본 글꼴로 그려 원본 모양과 대조해 고른 갈래. 표본이 부족하면 nil.
    let fontStyle: String?
    /// 대조에서 이긴 견본이 굵은 굵기였던 글자가 과반이면 true
    let bold: Bool
    /// 잉크 안쪽(테두리 제외) 실제 글자색 "#RRGGBB"
    let foregroundHex: String?
    /// 글자 바깥 테두리(외곽선) 색. 테두리가 뚜렷할 때만.
    let outlineHex: String?
    /// 원본 글자를 지운 픽셀만 불투명한 PNG 조각과 그 위치(정규화 좌표, 원점 왼쪽 위). 나머지 픽셀은 투명이다.
    let restorationBox: CGRect?
    let restorationPNG: Data?
    /// inkBoxes 밖에서 함께 지운 상자(후리가나·상한을 넘은 글자·위치를 못 잡은 글자의 문단 영역). 화면 표시 쪽이
    /// 복원 조각을 쓸 수 없을 때 inkBoxes와 함께 가리는 데 쓴다.
    var coverBoxes: [CGRect] = []
    /// 위치를 못 잡아 가리지 못한 글자 수(진단용). 0이 아니면 그 글자의 원문이 남을 수 있다.
    var uncoveredGlyphs: Int = 0
}

enum GlyphAnalyzer {
    /// 배경 복원 조각 하나의 최대 픽셀 수. 넘으면 덮는 범위를 줄이는 배율만큼 미리 넓힌 뒤 줄인다(응답 1MB 상한 안에
    /// 한 화면의 조각이 모두 들어가게). 이전에는 넓히지 않고 줄여 큰 제목 조각이 모자이크처럼 보이고 가장자리가 비쳤다.
    static let maxPatchPixels = 90_000
    /// 글자 하나당 글꼴 견본 대조 표본 상한(항목 하나당)
    static let maxStyleSamples = 8
    /// 주변 배경 색 군집과 이 거리(RGB 0~255 유클리드)보다 먼 픽셀을 글자 잉크로 본다.
    static let inkDistance: Float = 60

    struct PixelRect {
        var x0: Int, y0: Int, x1: Int, y1: Int
        var width: Int { x1 - x0 }
        var height: Int { y1 - y0 }
        func padded(_ p: Int, in canvas: Canvas) -> PixelRect {
            PixelRect(x0: max(0, x0 - p), y0: max(0, y0 - p), x1: min(canvas.width, x1 + p), y1: min(canvas.height, y1 + p))
        }
        func contains(_ x: Int, _ y: Int) -> Bool { x >= x0 && x < x1 && y >= y0 && y < y1 }
    }

    /// 원본 이미지를 sRGB RGBA8로 한 번만 그린 픽셀 버퍼
    final class Canvas {
        let width: Int, height: Int
        private(set) var rgba: [UInt8]

        init?(_ image: CGImage) {
            let w = image.width, h = image.height
            guard w > 0, h > 0, w * h <= 40_000_000, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            var buffer = [UInt8](repeating: 0, count: w * h * 4)
            let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard drawn else { return nil }
            width = w; height = h; rgba = buffer
        }

        func pixelRect(_ box: CGRect) -> PixelRect? {
            guard box.minX.isFinite, box.minY.isFinite, box.width > 0, box.height > 0 else { return nil }
            let r = PixelRect(x0: max(0, Int((box.minX * CGFloat(width)).rounded(.down))),
                              y0: max(0, Int((box.minY * CGFloat(height)).rounded(.down))),
                              x1: min(width, Int((box.maxX * CGFloat(width)).rounded(.up))),
                              y1: min(height, Int((box.maxY * CGFloat(height)).rounded(.up))))
            return r.width >= 2 && r.height >= 2 ? r : nil
        }

        func unitBox(_ r: PixelRect) -> CGRect {
            CGRect(x: CGFloat(r.x0) / CGFloat(width), y: CGFloat(r.y0) / CGFloat(height),
                   width: CGFloat(r.width) / CGFloat(width), height: CGFloat(r.height) / CGFloat(height))
        }

        /// 불투명에 가까운 픽셀만 색으로 돌려준다(투명 픽셀은 nil).
        @inline(__always) func color(_ x: Int, _ y: Int) -> SIMD3<Float>? {
            let i = (y * width + x) * 4
            let a = rgba[i + 3]
            guard a > 200 else { return nil }
            return SIMD3(Float(rgba[i]), Float(rgba[i + 1]), Float(rgba[i + 2]))
        }
    }

    /// 글자 하나의 잉크 마스크(window 범위, 행 우선). inkBox는 원래 글자 상자 안 잉크만으로 좁힌 상자다.
    fileprivate struct GlyphInk {
        let window: PixelRect
        let mask: [Bool]
        /// 번짐을 더하기 전 확실한 잉크만(글꼴 대조용, 획 두께가 부풀지 않게)
        let core: [Bool]
        let inkBox: PixelRect
        let text: String
        /// 이 글자 주변 고리의 가장 큰 색 군집(바탕색)
        let background: SIMD3<Float>
        let uniformBackground: Bool
    }

    /// 글자 상자 하나의 분석 창과 바로 바깥 고리의 배경 색 군집
    fileprivate struct GlyphWindow {
        let index: Int
        let rect: PixelRect
        let window: PixelRect
        let centers: [SIMD3<Float>]
        let background: SIMD3<Float>
        let uniformBackground: Bool
        /// 고리 표본 중 가장 큰 색 군집의 비율(바탕이 얼마나 한 색인지)
        let dominantShare: Double
    }

    /// 지울 대상 하나: 원본 글자(또는 후리가나·문단 영역) 픽셀 상자, 그 바로 바깥 배경 색 군집, 확실한 잉크 마스크.
    fileprivate struct CoverTarget {
        let rect: PixelRect
        let window: GlyphWindow?
        let ink: GlyphInk?
        /// 글자 하나가 아닌 줄·문단 크기 상자(문서 인식이 글자 범위 대신 준 상자, 위치를 못 잡은 글자의 문단 영역).
        /// 단색 바탕일 때만 지운다(그림 위에서 통째로 덮으면 그림을 크게 망가뜨린다).
        var wide = false
        /// 잉크를 못 가른 글자의 모양 마스크(rect 기준, 행 우선). 그림 위에서는 크기와 관계없이 이 모양 안만 지워
        /// 상자에 걸친 인물·소품·바탕 그림을 남긴다.
        var shape: [Bool]? = nil
    }

    /// 항목 하나의 원본 글자 분석(배경 복원 전 단계). 복원은 후리가나를 붙인 뒤 restoration(_:canvas:occupied:)이 만든다.
    struct Measurement {
        let inkBoxes: [CGRect]
        let maskedGlyphs: Int
        let fontStyle: String?
        let bold: Bool
        let foregroundHex: String?
        let outlineHex: String?
        /// 이 항목의 원문으로 보고 지울 대상(본문 글자·annotationBoxes·위치를 못 잡은 글자의 문단 영역)
        fileprivate let targets: [CoverTarget]
        /// inkBoxes 밖의 지울 상자(정규화 좌표). 화면 표시 쪽의 대체 가림용.
        let extraCoverBoxes: [CGRect]
        /// 이 항목 전체의 지울 상자(다른 본문에 붙을 때 그 본문의 대체 가림용)
        let coverBoxes: [CGRect]
        let uncoveredGlyphs: Int

        /// 축소 견본의 글자색이 섞이지 않도록 원본 해상도의 글자 둘레에서 고른 바탕색을 쓴다.
        var backgroundHex: String? {
            let samples = targets.compactMap { target -> SIMD3<Float>? in
                guard let window = target.window, window.dominantShare >= 0.55 else { return nil }
                return window.background
            }
            guard !samples.isEmpty else { return nil }
            let groups = Dictionary(grouping: samples) { color in
                (Int(color.x) / 32) * 64 + (Int(color.y) / 32) * 8 + Int(color.z) / 32
            }
            guard let best = groups.values.max(by: { $0.count < $1.count }) else { return nil }
            func channel(_ values: [Float]) -> Int { Int(min(255, max(0, values.sorted()[values.count / 2])).rounded()) }
            return String(format: "#%02X%02X%02X", channel(best.map(\.x)), channel(best.map(\.y)), channel(best.map(\.z)))
        }
    }

    struct Restoration {
        let box: CGRect
        let png: Data
    }

    /// 0..<count를 여러 코어에서 함께 계산한다(결과 순서 유지). body는 서로 독립적이어야 한다.
    static func concurrentMap<T>(_ count: Int, _ body: (Int) -> T) -> [T] {
        guard count > 1 else { return (0..<count).map(body) }
        var results = [T?](repeating: nil, count: count)
        results.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: count) { base[$0] = body($0) }
        }
        return results.map { $0! }
    }

    static func measure(_ region: OCRRegion, canvas: Canvas, occupied: [Bool]) -> Measurement {
        let rects = region.glyphBoxes.map { canvas.pixelRect($0) }
        // 문단 전체 같은 넓은 상자(문서 API가 글자 범위 대신 줄·문단 영역을 준 경우)나 같은 상자의 반복은
        // 글자 하나가 아니므로 마스킹·대조에 쓰지 않는다(지울 대상으로는 남긴다).
        let areas = rects.compactMap { $0.map { Double($0.width * $0.height) } }.sorted()
        let medianArea = areas.isEmpty ? 0 : areas[areas.count / 2]
        var windows: [GlyphWindow] = []
        var seen: [PixelRect] = []
        var targetRects: [(Int?, PixelRect)] = []
        // 복원 여부를 가르는 기준 글자 수. 잉크가 적어 검증이 어려운 구두점·괄호는 세지 않는다.
        var letters = Set<Int>()
        for (index, rect) in rects.enumerated() {
            guard let rect else { continue }
            if seen.contains(where: { overlapRatio($0, rect) > 0.85 }) { continue }
            seen.append(rect)
            // 면적만 크면 줄·문단 상자로 보지 않는다. 크기가 섞인 장식 제목의 큰 글자는 정사각에 가깝고 다른 글자를 품지 않는다.
            let others = rects.indices.filter { $0 != index }.compactMap { rects[$0] }
            if rects.count >= 3 && Double(rect.width * rect.height) > medianArea * 4
                && others.contains(where: { rect.contains(($0.x0 + $0.x1) / 2, ($0.y0 + $0.y1) / 2) }) {
                targetRects.append((nil, rect))
                continue
            }
            targetRects.append((index, rect))
            let text = index < region.glyphTexts.count ? region.glyphTexts[index] : ""
            if text.isEmpty || text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }) {
                letters.insert(index)
            }
            if let window = glyphWindow(index: index, rect: rect, canvas: canvas, occupied: occupied) { windows.append(window) }
        }
        var inks = [GlyphInk?](repeating: nil, count: rects.count)
        for ink in inkMasks(windows, region: region, canvas: canvas) { inks[ink.0] = ink.1 }
        let inkBoxes = region.glyphBoxes.enumerated().map { index, box in inks[index].map { canvas.unitBox($0.inkBox) } ?? box }
        let valid = inks.compactMap { $0 }
        // 글꼴 대조는 배경 복원보다 덜 엄격해도 되므로, 주변색으로 잉크를 못 가른 글자(그림 위 제목 등)는 상자 안
        // 두 색 무리로 잰 모양을 대신 쓴다.
        var shapes: [ShapeSample] = []
        let comparable = letters.sorted().filter { $0 < region.glyphTexts.count && isComparable(region.glyphTexts[$0]) }
        let interval = max(1, (comparable.count + maxStyleSamples - 1) / maxStyleSamples)
        for (position, index) in comparable.enumerated() where position % interval == 0 {
            guard shapes.count < maxStyleSamples, let rect = rects[index] else { continue }
            let text = index < region.glyphTexts.count ? region.glyphTexts[index] : ""
            guard isComparable(text) else { continue }
            // 무늬 배경에서 연결 성분이 끊기면 복원용 마스크에는 작은 잡음만 남을 수 있다.
            // 글꼴 대조에는 충분한 획이 남은 마스크만 쓰고, 부족하면 글자 칸의 두 색 모양을 쓴다.
            if let ink = inks[index], ink.core.filter({ $0 }).count * 20 >= ink.core.count {
                let w = ink.window.width
                shapes.append(ShapeSample(text: text, box: ink.inkBox) { ink.core[($1 - ink.window.y0) * w + ($0 - ink.window.x0)] })
            } else if let shape = shapeMask(rect, canvas: canvas) {
                shapes.append(ShapeSample(text: text, box: shape.box) { shape.mask[($1 - rect.y0) * rect.width + ($0 - rect.x0)] })
            }
        }
        let (style, bold) = matchStyle(shapes)
        let (fg, outline) = inkColors(valid, canvas: canvas)

        // 지울 대상: 본문 글자 상자 전부(잉크를 못 가른 글자 포함), 함께 지울 상자(본문에서 뺀 후리가나 등).
        let windowByIndex = Dictionary(windows.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
        var targets = targetRects.map { index, rect in
            let target = CoverTarget(rect: rect, window: index.map { windowByIndex[$0] }
                                         ?? glyphWindow(index: -1, rect: rect, canvas: canvas, occupied: occupied),
                                     ink: index.flatMap { inks[$0] }, wide: index == nil)
            return target
        }
        var extraCover: [CGRect] = []
        for box in region.annotationBoxes {
            guard let rect = canvas.pixelRect(box) else { continue }
            // 후리가나·보충 줄 검출 글자도 그림 위에서는 글자 모양만 지운다(모양을 못 재면 상자 전체, 마지막 수단).
            targets.append(CoverTarget(rect: rect, window: glyphWindow(index: -1, rect: rect, canvas: canvas, occupied: occupied), ink: nil,
                                       shape: shapeMask(rect, canvas: canvas, core: true, occupied: occupied)?.mask))
            extraCover.append(box)
        }
        // 인식 글자보다 위치를 잡은 상자가 적으면(범위를 못 구한 글자) 그 글자 자리를 알 수 없다. 문단 영역의 바탕이
        // 거의 한 색이면 문단 영역에서 바탕과 다른 픽셀을 지울 대상으로 더하고, 그림 위라 통째로 덮어야 하면 더하지 않고 센다.
        let located = region.glyphBoxes.count + region.annotationBoxes.count
        let expected = region.text.filter { !$0.isWhitespace }.count
        var uncovered = 0
        if !(expected > 0 && targetRects.count >= expected && targetRects.allSatisfy { $0.0 != nil }),
           let rect = canvas.pixelRect(region.box) {
            let window = glyphWindow(index: -1, rect: rect, canvas: canvas, occupied: occupied)
            targets.append(CoverTarget(rect: rect, window: window, ink: nil, wide: true))
            extraCover.append(region.box)
            uncovered = max(0, expected - located)
        }
        // 단색 말풍선 안에서 인식되지 않은 원문 조각(후리가나·긴 대시·획 끝)도 지운다.
        for stray in strayInk(region, glyphRects: targets.map(\.rect), canvas: canvas, occupied: occupied) {
            targets.append(stray)
            extraCover.append(canvas.unitBox(stray.rect))
        }
        let validLetters = inks.indices.filter { letters.contains($0) && inks[$0] != nil }.count
        return Measurement(inkBoxes: inkBoxes, maskedGlyphs: validLetters, fontStyle: style, bold: bold, foregroundHex: fg,
                           outlineHex: outline, targets: targets, extraCoverBoxes: extraCover,
                           coverBoxes: inkBoxes + extraCover, uncoveredGlyphs: uncovered)
    }

    /// 문단 영역(글자 크기의 35%만큼 넓힘)에서 글자 상자 밖의 바탕이 거의 한 색(85% 이상)일 때, 그 바탕색과 뚜렷이 다른
    /// 잉크 덩어리 중 영역 경계에 닿지 않는 것(말풍선 테두리·그림으로 이어지지 않는 것)을 지울 대상으로 돌려준다.
    /// 문자 인식이 놓친 후리가나·대시·말줄임표와 글자 상자 밖으로 나온 획 끝이 남지 않게 한다. 다른 항목의 글자 상자는 건드리지 않는다.
    private static func strayInk(_ region: OCRRegion, glyphRects: [PixelRect], canvas: Canvas, occupied: [Bool]) -> [CoverTarget] {
        guard let base = canvas.pixelRect(region.box) else { return [] }
        let sizes = glyphRects.map { max($0.width, $0.height) }.sorted()
        let size = sizes.isEmpty ? min(base.width, base.height) : sizes[sizes.count / 2]
        let r = base.padded(max(2, Int(Double(size) * 0.35)), in: canvas)
        let w = r.width, h = r.height
        guard w >= 4, h >= 4, w * h <= 4_000_000 else { return [] }
        var buckets: [Int: (count: Int, sum: SIMD3<Float>)] = [:]
        var samples = 0
        let step = max(1, Int((Double(w * h) / 6000).squareRoot()))
        for y in Swift.stride(from: r.y0, to: r.y1, by: step) {
            for x in Swift.stride(from: r.x0, to: r.x1, by: step) where !occupied[y * canvas.width + x] {
                guard let c = canvas.color(x, y) else { continue }
                let key = (Int(c.x) >> 4) << 8 | (Int(c.y) >> 4) << 4 | Int(c.z) >> 4
                let old = buckets[key] ?? (0, .zero)
                buckets[key] = (old.count + 1, old.sum + c)
                samples += 1
            }
        }
        guard samples >= 24, let top = buckets.values.max(by: { $0.count < $1.count }),
              Double(top.count) >= Double(samples) * 0.85 else { return [] }
        let bg = top.sum / Float(top.count)
        var ink = [Bool](repeating: false, count: w * h)
        for y in r.y0..<r.y1 {
            for x in r.x0..<r.x1 where !occupied[y * canvas.width + x] {
                guard let c = canvas.color(x, y) else { continue }
                let d = c - bg
                if (d * d).sum() > 40 * 40 { ink[(y - r.y0) * w + (x - r.x0)] = true }
            }
        }
        let window = { (rect: PixelRect) in
            GlyphWindow(index: -1, rect: rect, window: rect, centers: [bg], background: bg, uniformBackground: true,
                        dominantShare: Double(top.count) / Double(samples))
        }
        var visited = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        var result: [CoverTarget] = []
        for start in 0..<(w * h) where ink[start] && !visited[start] {
            visited[start] = true
            stack.append(start)
            var count = 0, touches = false
            var b = PixelRect(x0: w, y0: h, x1: 0, y1: 0)
            while let i = stack.popLast() {
                count += 1
                let x = i % w, y = i / w
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { touches = true }
                b.x0 = min(b.x0, x); b.y0 = min(b.y0, y); b.x1 = max(b.x1, x + 1); b.y1 = max(b.y1, y + 1)
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, yy >= 0, xx < w, yy < h else { continue }
                    let j = yy * w + xx
                    if ink[j] && !visited[j] { visited[j] = true; stack.append(j) }
                } }
            }
            guard !touches, count >= 3, result.count < 64 else { continue }
            let rect = PixelRect(x0: r.x0 + b.x0, y0: r.y0 + b.y0, x1: r.x0 + b.x1, y1: r.y0 + b.y1).padded(1, in: canvas)
            result.append(CoverTarget(rect: rect, window: window(rect), ink: nil))
        }
        return result
    }

    private static func overlapRatio(_ a: PixelRect, _ b: PixelRect) -> Double {
        let w = min(a.x1, b.x1) - max(a.x0, b.x0), h = min(a.y1, b.y1) - max(a.y0, b.y0)
        guard w > 0, h > 0 else { return 0 }
        return Double(w * h) / Double(min(a.width * a.height, b.width * b.height))
    }

    // MARK: 잉크 마스크

    /// 글자 상자 바로 바깥 고리(다른 글자 상자 제외)의 색 군집을 그 글자의 배경으로 잰다. 고리가 그림·복잡한
    /// 무늬라 몇 개 군집으로 설명되지 않으면 주변색으로 글자를 가를 수 없으므로 nil(마스킹하지 않음).
    private static func glyphWindow(index: Int, rect: PixelRect, canvas: Canvas, occupied: [Bool]) -> GlyphWindow? {
        let size = min(rect.width, rect.height)
        guard size >= 6 else { return nil }
        let window = rect.padded(max(1, size / 8) + 3, in: canvas)
        // 고리는 글자 바로 옆만 본다(좁은 말풍선에서 말풍선 밖 그림까지 배경 표본에 섞이지 않게).
        let ring = window.padded(max(3, size / 6), in: canvas)
        let stride = max(1, Int((Double(ring.width * ring.height) / 900).squareRoot()))
        // 4비트(채널당 16단계) 양자화 히스토그램으로 고리 색 군집을 만든다.
        var buckets: [Int: (count: Int, sum: SIMD3<Float>)] = [:]
        var samples = 0
        for y in Swift.stride(from: ring.y0, to: ring.y1, by: stride) {
            for x in Swift.stride(from: ring.x0, to: ring.x1, by: stride) {
                guard !window.contains(x, y), !occupied[y * canvas.width + x], let c = canvas.color(x, y) else { continue }
                let key = (Int(c.x) >> 4) << 8 | (Int(c.y) >> 4) << 4 | Int(c.z) >> 4
                let old = buckets[key] ?? (0, .zero)
                buckets[key] = (old.count + 1, old.sum + c)
                samples += 1
            }
        }
        guard samples >= 12 else { return nil }
        // 고리를 스치는 말풍선 테두리·작은 무늬 같은 소수 색은 배경 군집에서 뺀다.
        let major = buckets.values.filter { Double($0.count) >= Double(samples) * 0.06 }.sorted { $0.count > $1.count }
        guard let largest = major.first, Double(major.reduce(0) { $0 + $1.count }) >= Double(samples) * 0.6 else { return nil }
        return GlyphWindow(index: index, rect: rect, window: window, centers: major.map { $0.sum / Float($0.count) },
                           background: largest.sum / Float(largest.count),
                           uniformBackground: Double(largest.count) >= Double(samples) * 0.94,
                           dominantShare: Double(largest.count) / Double(samples))
    }

    /// 문단의 글자 창들을 합친 영역에서 잉크를 가른다. 각 픽셀은 자기를 덮는 모든 글자 창의 배경 군집과 멀어야 잉크다.
    /// 확실한 잉크를 8연결 덩어리로 묶어, 창들의 바깥 경계에 닿는 덩어리(글자 밖으로 이어지는 그림·말풍선 테두리)는
    /// 뺀다. 같은 문단의 이웃 글자 창으로 넘어가는 획은 경계가 아니므로 유지된다.
    private static func inkMasks(_ windows: [GlyphWindow], region: OCRRegion, canvas: Canvas) -> [(Int, GlyphInk)] {
        guard var area = windows.first?.window else { return [] }
        for g in windows {
            area.x0 = min(area.x0, g.window.x0); area.y0 = min(area.y0, g.window.y0)
            area.x1 = max(area.x1, g.window.x1); area.y1 = max(area.y1, g.window.y1)
        }
        let w = area.width, h = area.height
        guard w * h <= 8_000_000 else { return [] }
        // -1: 어느 글자 창에도 속하지 않음
        var distance = [Float](repeating: -1, count: w * h)
        for g in windows {
            for y in g.window.y0..<g.window.y1 {
                for x in g.window.x0..<g.window.x1 {
                    let i = (y - area.y0) * w + (x - area.x0)
                    guard let c = canvas.color(x, y) else { distance[i] = 0; continue }
                    var nearest = Float.greatestFiniteMagnitude
                    for center in g.centers {
                        let d = c - center
                        nearest = min(nearest, (d * d).sum())
                    }
                    let value = nearest.squareRoot()
                    distance[i] = distance[i] < 0 ? value : min(distance[i], value)
                }
            }
        }
        var mask = [Bool](repeating: false, count: w * h)
        var visited = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        var component: [Int] = []
        for start in 0..<(w * h) where !visited[start] && distance[start] > inkDistance {
            visited[start] = true
            stack.append(start)
            component.removeAll(keepingCapacity: true)
            var touchesBorder = false
            while let i = stack.popLast() {
                component.append(i)
                let x = i % w, y = i / w
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, yy >= 0, xx < w, yy < h, distance[yy * w + xx] >= 0 else { touchesBorder = true; continue }
                    let j = yy * w + xx
                    if !visited[j] && distance[j] > inkDistance { visited[j] = true; stack.append(j) }
                } }
            }
            if !touchesBorder { for i in component { mask[i] = true } }
        }
        let core = mask
        // 안티앨리어싱 번짐: 확실한 잉크 바로 옆(2px)의 덜 다른 픽셀까지만 잉크로 더한다.
        for _ in 0..<2 {
            let source = mask
            for i in 0..<(w * h) where !source[i] && distance[i] > inkDistance * 0.35 {
                let x = i % w, y = i / w
                if (x > 0 && source[i - 1]) || (x < w - 1 && source[i + 1]) || (y > 0 && source[i - w]) || (y < h - 1 && source[i + w]) {
                    mask[i] = true
                }
            }
        }
        return windows.compactMap { g -> (Int, GlyphInk)? in
            let ww = g.window.width
            var local = [Bool](repeating: false, count: ww * g.window.height)
            var localCore = local
            var count = 0
            var box = PixelRect(x0: g.rect.x1, y0: g.rect.y1, x1: g.rect.x0, y1: g.rect.y0)
            // 안티앨리어싱 번짐(inkMasks에서 최대 2px 확장)이 원래 글자 상자 밖으로 살짝 넘어가도 inkBox가
            // 놓치지 않도록, 상자 테두리에 같은 여유(2px)를 둔다. 창 전체로 열어두면 이웃 글자까지 섞이므로
            // 소량의 여유만 둔다(원본 가장자리가 남는 사고를 막되 상자가 커지지 않게).
            let guardRect = PixelRect(x0: max(g.window.x0, g.rect.x0 - 2), y0: max(g.window.y0, g.rect.y0 - 2),
                                      x1: min(g.window.x1, g.rect.x1 + 2), y1: min(g.window.y1, g.rect.y1 + 2))
            for y in g.window.y0..<g.window.y1 {
                for x in g.window.x0..<g.window.x1 {
                    let i = (y - area.y0) * w + (x - area.x0)
                    // 단색 말풍선에서는 창 경계에 닿는 획도 글자다. 경계 접촉만으로 버리면 원문 가장자리가
                    // 남는다. 그림이 있는 배경에는 기존 연결 성분 판정을 유지한다.
                    let c = canvas.color(x, y)
                    let delta = c.map { $0 - g.background }
                    let flatInk = g.uniformBackground && delta.map { ($0 * $0).sum() > 24 * 24 } == true
                    guard mask[i] || flatInk else { continue }
                    local[(y - g.window.y0) * ww + (x - g.window.x0)] = true
                    localCore[(y - g.window.y0) * ww + (x - g.window.x0)] = core[i] ||
                        (g.uniformBackground && delta.map { ($0 * $0).sum() > inkDistance * inkDistance } == true)
                    count += 1
                    // 잉크 상자는 원래 글자 상자(+2px 여유) 안 잉크만으로 좁힌다(이웃 글자 창과 겹친 여백 제외).
                    guard guardRect.contains(x, y) else { continue }
                    box.x0 = min(box.x0, x); box.y0 = min(box.y0, y); box.x1 = max(box.x1, x + 1); box.y1 = max(box.y1, y + 1)
                }
            }
            // 잉크가 거의 없거나(배경과 구분 안 됨) 창을 대부분 덮으면(그림 자체가 다름) 믿지 않는다.
            let fraction = Double(count) / Double(local.count)
            guard count >= 8, fraction >= 0.02, fraction <= 0.6, box.width >= 2, box.height >= 2 else { return nil }
            let text = g.index < region.glyphTexts.count ? region.glyphTexts[g.index] : ""
            return (g.index, GlyphInk(window: g.window, mask: local, core: localCore, inkBox: box, text: text,
                                     background: g.background, uniformBackground: g.uniformBackground))
        }
    }

    // MARK: 글꼴 갈래(견본 글꼴 대조)

    private struct Exemplar {
        let style: String
        let bold: Bool
        let font: CTFont
    }

    /// macOS 기본 일본어 글꼴을 갈래별 견본으로 쓴다(새 의존성 없음). 설치되지 않은 견본은 건너뛴다.
    private static let exemplars: [Exemplar] = {
        let table: [(String, String, Bool)] = [
            ("gothic", "HiraginoSans-W3", false), ("gothic", "HiraginoSans-W6", true), ("gothic", "HiraginoSans-W8", true),
            ("myeongjo", "HiraMinProN-W3", false), ("myeongjo", "HiraMinProN-W6", true), ("myeongjo", "YuMin-Extrabold", true),
            ("gothic", "Helvetica", false), ("gothic", "Helvetica-Bold", true),
            ("myeongjo", "TimesNewRomanPSMT", false), ("myeongjo", "TimesNewRomanPS-BoldMT", true),
            ("gungseo", "YuKyo-Medium", false), ("gungseo", "YuKyo-Bold", true), ("gungseo", "STKaiti", false),
            ("hand", "Klee-Medium", false), ("hand", "Klee-Demibold", true)
        ]
        return table.compactMap { style, name, bold in
            let font = CTFontCreateWithName(name as CFString, 64, nil)
            guard CTFontCopyPostScriptName(font) as String == name else { return nil }
            return Exemplar(style: style, bold: bold, font: font)
        }
    }()

    static let grid = 32

    /// 잉크 마스크를 잉크 상자 기준으로 비율을 지켜 grid×grid에 넣고(면적 평균) 살짝 흐린다.
    private static func normalized(_ value: (Int, Int) -> Float, box: PixelRect) -> [Float] {
        var out = [Float](repeating: 0, count: grid * grid)
        let scale = Float(grid - 2) / Float(max(box.width, box.height))
        let offX = (Float(grid) - Float(box.width) * scale) / 2, offY = (Float(grid) - Float(box.height) * scale) / 2
        var weight = [Float](repeating: 0, count: grid * grid)
        for y in box.y0..<box.y1 {
            for x in box.x0..<box.x1 {
                let gx = min(grid - 1, max(0, Int(offX + (Float(x - box.x0) + 0.5) * scale)))
                let gy = min(grid - 1, max(0, Int(offY + (Float(y - box.y0) + 0.5) * scale)))
                out[gy * grid + gx] += value(x, y)
                weight[gy * grid + gx] += 1
            }
        }
        for i in out.indices where weight[i] > 0 { out[i] /= weight[i] }
        var blurred = out
        for y in 0..<grid {
            for x in 0..<grid {
                var sum: Float = 0, n: Float = 0
                for dy in -1...1 { for dx in -1...1 {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, yy >= 0, xx < grid, yy < grid else { continue }
                    sum += out[yy * grid + xx]; n += 1
                } }
                blurred[y * grid + x] = sum / n
            }
        }
        return blurred
    }

    private static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let n = Float(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var num: Float = 0, da: Float = 0, db: Float = 0
        for i in a.indices {
            let x = a[i] - ma, y = b[i] - mb
            num += x * y; da += x * x; db += y * y
        }
        guard da > 0, db > 0 else { return 0 }
        return num / (da * db).squareRoot()
    }

    /// 견본 글자 격자 캐시(견본 글꼴 이름|글자 → 정규화 격자, 글리프 없음은 빈 배열). 같은 글자는 페이지·항목마다
    /// 반복되므로 견본(최대 11개 글꼴)을 매번 다시 그리지 않는다. 글자 모양만 담고 원문 문장은 담지 않는다.
    private final class ExemplarCache: @unchecked Sendable {
        private let lock = NSLock()
        private var grids: [String: [Float]] = [:]
        static let shared = ExemplarCache()
        static let limit = 4000

        func grid(_ text: String, font: CTFont) -> [Float]? {
            let key = "\(CTFontCopyPostScriptName(font) as String)|\(text)"
            lock.lock()
            if let cached = grids[key] { lock.unlock(); return cached.isEmpty ? nil : cached }
            lock.unlock()
            let computed = GlyphAnalyzer.renderExemplarGrid(text, font: font)
            lock.lock()
            if grids.count >= Self.limit { grids.removeAll(keepingCapacity: true) }
            grids[key] = computed ?? []
            lock.unlock()
            return computed
        }
    }

    private static func exemplarGrid(_ text: String, font: CTFont) -> [Float]? {
        ExemplarCache.shared.grid(text, font: font)
    }

    /// 견본 글꼴로 글자 하나를 그려 같은 방식으로 정규화한다. 그 글꼴에 글리프가 없으면 nil.
    fileprivate static func renderExemplarGrid(_ text: String, font: CTFont) -> [Float]? {
        let utf16 = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        guard !utf16.isEmpty, CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count), glyphs.allSatisfy({ $0 != 0 }) else { return nil }
        let side = 96
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            var position = CGPoint(x: 16, y: 24)
            CTFontDrawGlyphs(font, glyphs, &position, 1, ctx)
            return true
        }
        guard drawn else { return nil }
        var box = PixelRect(x0: side, y0: side, x1: 0, y1: 0)
        for y in 0..<side { for x in 0..<side where pixels[y * side + x] >= 128 {
            box.x0 = min(box.x0, x); box.y0 = min(box.y0, y); box.x1 = max(box.x1, x + 1); box.y1 = max(box.y1, y + 1)
        } }
        guard box.width >= 2, box.height >= 2 else { return nil }
        return normalized({ Float(pixels[$1 * side + $0]) / 255 }, box: box)
    }

    /// 대조에 쓸 만한 글자: 영문·가나·한자(획 하나뿐인 글자와 구두점 제외).
    private static func isComparable(_ text: String) -> Bool {
        guard text.unicodeScalars.count == 1, let u = text.unicodeScalars.first else { return false }
        if u.value == 0x30FC || u.value == 0x4E00 || u.value == 0x30FB { return false }
        switch u.value {
        case 0x41...0x5A, 0x61...0x7A, 0x3041...0x3096, 0x30A1...0x30FA, 0x4E00...0x9FFF: return true
        default: return false
        }
    }

    /// 실제 원본 글자 모양과 견본 글꼴로 그린 같은 글자의 상관계수를 갈래별로 평균내 가장 닮은 갈래를 고른다.
    /// 애매하면(1등과 고딕 차이가 작으면) 고딕으로 둔다. 표본이 2개 미만이면 nil.
    /// 글꼴 대조용 원본 글자 모양 하나(잉크 상자와 그 안 픽셀의 잉크 여부)
    private struct ShapeSample {
        let text: String
        let box: PixelRect
        let isInk: (Int, Int) -> Bool
    }

    /// shapeMask가 한 번에 재는 최대 칸 수(이보다 큰 상자는 표본 격자로 잰다)
    private static let shapeAnalysisPixels = 400_000

    /// 주변색으로 잉크를 가를 수 없는 글자의 모양만 재는 느슨한 마스크(상자 기준, 행 우선). occupied가 주어지면 글자 무리를
    /// inkClusters로 고르고, 없거나 고르지 못하면 상자 안 색을 두 무리로 나눠 상자 가장자리에 덜 나타나는 무리를 글자로 본다.
    /// 글꼴 대조와 그림 위 글자의 지울 범위에 쓴다.
    /// 큰 상자(장식 제목 글자)는 고른 간격의 표본 격자(최대 shapeAnalysisPixels칸)에서 재고 원래 해상도로 되돌린다.
    /// 되돌릴 때 모양 칸은 통째로, 모양 칸에 붙은 경계 칸은 픽셀마다 글자 무리 색인지 다시 가려 가는 획·외곽 픽셀을 놓치지 않는다.
    /// - Parameter core: true면 글자 무리 중 가장 큰 8연결 덩어리(와 그 5% 이상인 덩어리)만 남긴다. 장식 제목 글자는
    ///   외곽선 안에서 한 덩어리로 이어지고, 같은 색 무리에 든 그림 조각은 외곽선에 끊겨 따로 떨어지므로 배경 복원에서 덜 지운다.
    /// - Parameters:
    ///   - texts: 이 상자의 인식 글자와 같은 줄 앞뒤 글자(견본 대조로 글자 무리를 고를 때)
    ///   - occupied: 주어지면 상자 바깥 고리(다른 글자 상자 제외)와 비교해 글자 무리를 고른다(inkClusters). 고르지 못하면 두 무리 판정.
    private static func shapeMask(_ rect: PixelRect, canvas: Canvas, core: Bool = false, texts: [String] = [],
                                  occupied: [Bool]? = nil) -> (mask: [Bool], box: PixelRect)? {
        let fw = rect.width, fh = rect.height
        // 복원 조각 영역 상한(8M)과 같은 범위까지만 원래 해상도 마스크를 만든다.
        guard min(fw, fh) >= 8, fw * fh <= 8_000_000 else { return nil }
        let s = fw * fh <= shapeAnalysisPixels ? 1 : Int((Double(fw * fh) / Double(shapeAnalysisPixels)).squareRoot().rounded(.up))
        let w = (fw + s - 1) / s, h = (fh + s - 1) / s
        guard min(w, h) >= 8 else { return nil }
        var colors = [SIMD3<Float>](repeating: .zero, count: w * h)
        for y in 0..<h { for x in 0..<w {
            colors[y * w + x] = canvas.color(rect.x0 + min(fw - 1, x * s + s / 2), rect.y0 + min(fh - 1, y * s + s / 2)) ?? .zero
        } }
        func luma(_ c: SIMD3<Float>) -> Float { 0.299 * c.x + 0.587 * c.y + 0.114 * c.z }
        var a = colors.min { luma($0) < luma($1) }!, b = colors.max { luma($0) < luma($1) }!
        var assign = [Bool](repeating: false, count: w * h)
        for _ in 0..<6 {
            var sa = SIMD3<Float>.zero, sb = SIMD3<Float>.zero, na: Float = 0, nb: Float = 0
            for (i, c) in colors.enumerated() {
                let da = c - a, db = c - b
                assign[i] = (db * db).sum() < (da * da).sum()
                if assign[i] { sb += c; nb += 1 } else { sa += c; na += 1 }
            }
            if na > 0 { a = sa / na }
            if nb > 0 { b = sb / nb }
        }
        guard ((a - b) * (a - b)).sum().squareRoot() > inkDistance else { return nil }
        var borderB = 0, border = 0
        for y in 0..<h { for x in 0..<w where x == 0 || y == 0 || x == w - 1 || y == h - 1 {
            border += 1
            if assign[y * w + x] { borderB += 1 }
        } }
        let inkIsB = borderB * 2 < border
        var isInk = assign.map { $0 == inkIsB }
        var inkColor: (SIMD3<Float>) -> Bool = { c in
            let da = c - a, db = c - b
            return ((db * db).sum() < (da * da).sum()) == inkIsB
        }
        if let occupied, let chosen = inkClusters(colors, cells: (w, h), rect: rect, canvas: canvas, texts: texts, occupied: occupied) {
            isInk = chosen.isInkCell
            inkColor = chosen.isInkColor
        }
        var mask = [Bool](repeating: false, count: w * h)
        var count = 0
        var cells = PixelRect(x0: w, y0: h, x1: 0, y1: 0)
        var keep: [Bool]? = nil
        if core {
            var label = [Int32](repeating: -1, count: w * h)
            var sizes: [Int] = []
            var stack: [Int] = []
            for start in 0..<(w * h) where isInk[start] && label[start] < 0 {
                let id = Int32(sizes.count)
                label[start] = id
                stack.append(start)
                var n = 0
                while let i = stack.popLast() {
                    n += 1
                    let x = i % w, y = i / w
                    for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                        let xx = x + dx, yy = y + dy
                        guard xx >= 0, yy >= 0, xx < w, yy < h else { continue }
                        let j = yy * w + xx
                        if isInk[j] && label[j] < 0 { label[j] = id; stack.append(j) }
                    } }
                }
                sizes.append(n)
            }
            let largest = sizes.max() ?? 0
            keep = label.map { $0 >= 0 && Double(sizes[Int($0)]) >= Double(largest) * 0.05 }
        }
        for i in 0..<(w * h) where isInk[i] && keep?[i] != false {
            mask[i] = true
            count += 1
            let x = i % w, y = i / w
            cells.x0 = min(cells.x0, x); cells.y0 = min(cells.y0, y); cells.x1 = max(cells.x1, x + 1); cells.y1 = max(cells.y1, y + 1)
        }
        let fraction = Double(count) / Double(w * h)
        guard fraction >= 0.05, fraction <= 0.6, cells.width * s >= 4, cells.height * s >= 4 else { return nil }
        if core {
            // 지울 모양으로 쓸 때는 글자 획에 완전히 둘러싸인 안쪽(외곽선 글자의 속 색·획 사이 틈)도 함께 지운다.
            // 테두리 무리만 글자로 잡혀도 속 색이 원문 모양으로 남지 않게 한다. 상자 가장자리와 이어진 바깥은 그대로 둔다.
            var outside = [Bool](repeating: false, count: w * h)
            var stack: [Int] = []
            for y in 0..<h { for x in 0..<w where (x == 0 || y == 0 || x == w - 1 || y == h - 1) && !mask[y * w + x] {
                let i = y * w + x
                if !outside[i] { outside[i] = true; stack.append(i) }
            } }
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                for (xx, yy) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where xx >= 0 && yy >= 0 && xx < w && yy < h {
                    let j = yy * w + xx
                    if !mask[j] && !outside[j] { outside[j] = true; stack.append(j) }
                }
            }
            for i in 0..<(w * h) where !mask[i] && !outside[i] { mask[i] = true }
        }
        guard s > 1 else {
            return (mask, PixelRect(x0: rect.x0 + cells.x0, y0: rect.y0 + cells.y0, x1: rect.x0 + cells.x1, y1: rect.y0 + cells.y1))
        }
        // 표본 격자 → 원래 해상도. 모양 칸 바로 옆 칸은 글자 무리 색에 더 가까운 픽셀만 더한다(한 칸 폭까지만).
        var full = [Bool](repeating: false, count: fw * fh)
        var box = PixelRect(x0: rect.x1, y0: rect.y1, x1: rect.x0, y1: rect.y0)
        for cy in 0..<h {
            for cx in 0..<w {
                let inside = mask[cy * w + cx]
                var edge = false
                if !inside {
                    for dy in -1...1 { for dx in -1...1 where !edge {
                        let xx = cx + dx, yy = cy + dy
                        if xx >= 0, yy >= 0, xx < w, yy < h, mask[yy * w + xx] { edge = true }
                    } }
                    if !edge { continue }
                }
                for y in (cy * s)..<min(fh, cy * s + s) {
                    for x in (cx * s)..<min(fw, cx * s + s) {
                        if !inside {
                            guard let c = canvas.color(rect.x0 + x, rect.y0 + y), inkColor(c) else { continue }
                        }
                        full[y * fw + x] = true
                        box.x0 = min(box.x0, rect.x0 + x); box.y0 = min(box.y0, rect.y0 + y)
                        box.x1 = max(box.x1, rect.x0 + x + 1); box.y1 = max(box.y1, rect.y0 + y + 1)
                    }
                }
            }
        }
        return (full, box)
    }

    /// 그림 위 글자 상자의 색을 최대 네 무리로 나눠 글자 무리(속 색·외곽선처럼 여럿일 수 있음)를 고른다. 두 무리 판정은
    /// 인식 상자가 글자에 꼭 맞아 획이 상자 가장자리에 닿으면 거꾸로 골랐고(흰 제목에서 둘레 그림 전체를 글자로), 글자색과
    /// 그림색이 섞인 세 색 이상의 상자에서는 글자와 그림을 한 무리로 묶어 상자 크기 판으로 지웠다.
    /// 대비: 상자 바로 바깥 고리(다른 글자 상자 제외)보다 상자 안에 훨씬 많은 무리를 대비가 큰 것부터 상자의 60%를 넘지
    /// 않을 때까지 더한 조합. 견본: 인식 글자를 견본 글꼴(고딕·명조)로 그린 모양과 가장 닮은 무리 조합. 장식 제목에서는
    /// 인식 글자 상자가 실제 글자와 한 글자씩 어긋나기도 해서(page5 실측), 견본 근거는 뚜렷할 때만 대비보다 앞세운다.
    /// 대비는 상자 안 일부 바탕색이 고리에 없을 때(고리가 다른 색 패널에 걸침) 바탕을 고르기도 한다.
    /// 1. 이 상자 글자 견본 상관 0.5 이상(상자가 글자에 맞음) 2. 강한 대비(고리 비율이 상자 안의 25% 이하)
    /// 3. 이 상자 글자 견본 상관 0.3 이상 4. 같은 줄 앞뒤 글자 견본 상관 0.45 이상 5. 약한 대비(50% 이하). 그림 위에서는 둘레 그림에 글자색이 흔해 약한 대비만으로는 글자 대신 그림을 고르기 쉽다.
    /// 고른 조합은 상자의 5~60%여야 하고, 바깥 고리에서도 상자 안만큼 흔하면(그림 바탕) 고르지 않는다. 못 고르면 nil.
    private static func inkClusters(_ colors: [SIMD3<Float>], cells: (w: Int, h: Int), rect: PixelRect, canvas: Canvas, texts: [String],
                                    occupied: [Bool]) -> (isInkCell: [Bool], isInkColor: (SIMD3<Float>) -> Bool)? {
        let n = colors.count
        guard n >= 16 else { return nil }
        func luma(_ c: SIMD3<Float>) -> Float { 0.299 * c.x + 0.587 * c.y + 0.114 * c.z }
        // 무리 중심은 표본(최대 약 8천 칸)으로 정하고, 가장 어두운 색에서 시작해 기존 중심과 가장 먼 색을 차례로 더한다.
        let sample = Swift.stride(from: 0, to: n, by: max(1, n / 8000)).map { colors[$0] }
        var centers = [sample.min { luma($0) < luma($1) }!]
        while centers.count < 4 {
            var farthest = sample[0], distance: Float = -1
            for c in sample {
                let d = centers.reduce(Float.greatestFiniteMagnitude) { min($0, ((c - $1) * (c - $1)).sum()) }
                if d > distance { distance = d; farthest = c }
            }
            guard distance > 24 * 24 else { break }
            centers.append(farthest)
        }
        guard centers.count >= 2 else { return nil }
        func nearest(_ c: SIMD3<Float>) -> Int {
            var best = 0, bestD = Float.greatestFiniteMagnitude
            for (j, center) in centers.enumerated() {
                let d = ((c - center) * (c - center)).sum()
                if d < bestD { bestD = d; best = j }
            }
            return best
        }
        for _ in 0..<6 {
            var sums = [SIMD3<Float>](repeating: .zero, count: centers.count), counts = [Float](repeating: 0, count: centers.count)
            for c in sample { let j = nearest(c); sums[j] += c; counts[j] += 1 }
            for j in centers.indices where counts[j] > 0 { centers[j] = sums[j] / counts[j] }
        }
        let m = centers.count
        let labels = colors.map { nearest($0) }
        var inside = [Double](repeating: 0, count: m)
        for l in labels { inside[l] += 1 / Double(n) }
        var ring = [Double](repeating: 0, count: m)
        var ringCount = 0
        let outer = rect.padded(max(3, min(rect.width, rect.height) / 6), in: canvas)
        let step = max(1, Int((Double(outer.width * outer.height - rect.width * rect.height) / 3000).squareRoot()))
        for y in Swift.stride(from: outer.y0, to: outer.y1, by: step) {
            for x in Swift.stride(from: outer.x0, to: outer.x1, by: step) {
                guard !rect.contains(x, y), !occupied[y * canvas.width + x], let c = canvas.color(x, y) else { continue }
                ring[nearest(c)] += 1
                ringCount += 1
            }
        }
        let hasRing = ringCount >= 24
        if hasRing { ring = ring.map { $0 / Double(ringCount) } }
        func share(_ subset: Int, _ values: [Double]) -> Double {
            (0..<m).reduce(0) { subset & (1 << $1) != 0 ? $0 + values[$1] : $0 }
        }
        func acceptable(_ subset: Int) -> Bool {
            let s = share(subset, inside)
            return s >= 0.05 && s <= 0.6 && (!hasRing || share(subset, ring) <= s * 0.8)
        }
        func contrasted(_ limit: Double) -> Int? {
            guard hasRing else { return nil }
            var subset = 0
            for j in (0..<m).filter({ inside[$0] >= 0.02 && ring[$0] <= inside[$0] * limit }).sorted(by: { ring[$0] / inside[$0] < ring[$1] / inside[$1] })
                where share(subset | (1 << j), inside) <= 0.6 { subset |= 1 << j }
            return subset != 0 && acceptable(subset) ? subset : nil
        }
        var grids: [[Float]] = []
        func exemplarMatch(_ texts: ArraySlice<String>, threshold: Float) -> (subset: Int, score: Float)? {
            let references = texts.flatMap { exemplarGrids($0) }
            guard !references.isEmpty else { return nil }
            if grids.isEmpty {
                let box = PixelRect(x0: 0, y0: 0, x1: cells.w, y1: cells.h)
                grids = (0..<m).map { j in normalized({ labels[$1 * cells.w + $0] == j ? 1 : 0 }, box: box) }
            }
            var best = threshold, chosen: Int? = nil
            for subset in 1..<((1 << m) - 1) where acceptable(subset) {
                var combined = [Float](repeating: 0, count: grid * grid)
                for j in 0..<m where subset & (1 << j) != 0 { for i in combined.indices { combined[i] += grids[j][i] } }
                for reference in references {
                    let c = correlation(combined, reference)
                    if c > best { best = c; chosen = subset }
                }
            }
            return chosen.map { ($0, best) }
        }
        let own = exemplarMatch(texts.prefix(1), threshold: 0.3)
        let chosen = own.flatMap { $0.score >= 0.5 ? $0.subset : nil } ?? contrasted(0.25) ?? own?.subset
            ?? exemplarMatch(texts.dropFirst(), threshold: 0.45)?.subset ?? contrasted(0.5)
        guard let chosen else { return nil }
        let ink = (0..<m).map { chosen & (1 << $0) != 0 }
        return (labels.map { ink[$0] }, { ink[nearest($0)] })
    }

    /// 인식 글자 하나를 고딕·명조 견본으로 그린 정규화 격자들(가나·한자만). 세로쓰기에서 돌아가는 장음 부호는 90° 돌린 격자도 넣는다.
    private static func exemplarGrids(_ text: String) -> [[Float]] {
        guard text.unicodeScalars.count == 1, let u = text.unicodeScalars.first else { return [] }
        switch u.value {
        case 0x3041...0x3096, 0x30A1...0x30FC, 0x4E00...0x9FFF: break
        default: return []
        }
        var grids: [[Float]] = []
        for exemplar in exemplars where exemplar.style == "gothic" || exemplar.style == "myeongjo" {
            guard let g = exemplarGrid(text, font: exemplar.font) else { continue }
            grids.append(g)
            if u.value == 0x30FC { grids.append((0..<(grid * grid)).map { g[($0 % grid) * grid + $0 / grid] }) }
        }
        return grids
    }

    private static func matchStyle(_ shapes: [ShapeSample]) -> (String?, Bool) {
        let exemplars = Self.exemplars
        guard !exemplars.isEmpty else { return (nil, false) }
        var totals: [String: Float] = [:], counts: [String: Int] = [:]
        var boldVotes = 0, samples = 0
        var wins: [String: Int] = [:]
        for shape in shapes where min(shape.box.width, shape.box.height) >= 8 {
            // 복원용 상자는 번짐 여백을 포함한다. 견본과 같은 실제 획 범위로 맞춰 비교한다.
            var inkBox = PixelRect(x0: shape.box.x1, y0: shape.box.y1, x1: shape.box.x0, y1: shape.box.y0)
            var inkCount = 0
            for y in shape.box.y0..<shape.box.y1 {
                for x in shape.box.x0..<shape.box.x1 where shape.isInk(x, y) {
                    inkCount += 1
                    inkBox.x0 = min(inkBox.x0, x); inkBox.y0 = min(inkBox.y0, y)
                    inkBox.x1 = max(inkBox.x1, x + 1); inkBox.y1 = max(inkBox.y1, y + 1)
                }
            }
            guard min(inkBox.width, inkBox.height) >= 8,
                  inkCount * 20 >= shape.box.width * shape.box.height else { continue }
            let original = normalized({ shape.isInk($0, $1) ? 1 : 0 }, box: inkBox)
            var best: [String: (Float, Bool)] = [:]
            for exemplar in exemplars {
                guard let grid = exemplarGrid(shape.text, font: exemplar.font) else { continue }
                let score = correlation(original, grid)
                if score > (best[exemplar.style]?.0 ?? -2) { best[exemplar.style] = (score, exemplar.bold) }
            }
            guard best["gothic"] != nil else { continue }
            samples += 1
            for (style, value) in best {
                totals[style, default: 0] += value.0
                counts[style, default: 0] += 1
            }
            if let top = best.max(by: { $0.value.0 < $1.value.0 }) {
                wins[top.key, default: 0] += 1
                if top.value.1 { boldVotes += 1 }
            }
        }
        guard samples >= 2 else { return (nil, false) }
        // 견본 글리프가 없어 표본 일부에서만 점수를 받은 갈래는 공정하지 않으므로 표본 절반 이상에서 잰 갈래만 비교한다.
        let means = totals.compactMap { style, total -> (String, Float)? in
            let n = counts[style] ?? 0
            return n * 2 >= samples ? (style, total / Float(n)) : nil
        }
        func mean(_ style: String) -> Float { means.first { $0.0 == style }?.1 ?? -1 }
        guard let top = means.max(by: { $0.1 < $1.1 }) else { return (nil, false) }
        // 약한 대조에서 인쇄체가 일관되게 이겼다면 장식체로 재분류하지 않는다.
        // 잡음의 불규칙성을 손글씨로 오해하던 획 통계 대신 읽기 쉬운 기본 인쇄체를 쓴다.
        if top.1 < 0.4 {
            return top.0 == "gothic" && top.1 >= 0.2 && top.1 - mean("myeongjo") >= 0.01
                && (wins["gothic"] ?? 0) * 3 >= samples * 2
                ? ("gothic", false) : (nil, false)
        }
        // 기본은 고딕. 다른 갈래는 평균 점수 차이와 글자별 1등 과반을 함께 만족할 때만 고른다. 궁서(붓글씨)·손글씨
        // 견본은 인쇄체 사이 모양이라 애매한 글자에서 이기기 쉬우므로 고딕·명조 둘 다를 더 큰 차이로 넘어야 한다.
        let majority = { (style: String) in (wins[style] ?? 0) * 2 > samples }
        var style = "gothic"
        if ["gungseo", "hand"].contains(top.0), top.1 - max(mean("gothic"), mean("myeongjo")) >= 0.04, majority(top.0) {
            style = top.0
        } else if mean("myeongjo") - mean("gothic") >= 0.02, majority("myeongjo") {
            style = "myeongjo"
        }
        return (style, boldVotes * 2 > samples)
    }

    // MARK: 글자색·테두리색

    /// 잉크 픽셀을 밝기로 두 무리로 나눠, 한 무리가 잉크 가장자리에 몰려 있고 글자색과 바탕색 사이의 번짐(섞인 색)이
    /// 아니면 그것을 테두리색으로 본다. 테두리가 없으면 바탕색과 더 먼 무리를 글자색으로 쓴다.
    private static func inkColors(_ inks: [GlyphInk], canvas: Canvas) -> (String?, String?) {
        var colors: [SIMD3<Float>] = []
        var edges: [Bool] = []
        for ink in inks {
            let w = ink.window.width, h = ink.window.height
            let step = max(1, Int((Double(w * h) / 2500).squareRoot()))
            for ly in Swift.stride(from: 0, to: h, by: step) {
                for lx in Swift.stride(from: 0, to: w, by: step) where ink.mask[ly * w + lx] {
                    guard let c = canvas.color(ink.window.x0 + lx, ink.window.y0 + ly) else { continue }
                    let edge = [(lx - 1, ly), (lx + 1, ly), (lx, ly - 1), (lx, ly + 1)].contains { x, y in
                        x < 0 || y < 0 || x >= w || y >= h || !ink.mask[y * w + x]
                    }
                    colors.append(c)
                    edges.append(edge)
                }
            }
            if colors.count > 20_000 { break }
        }
        guard colors.count >= 12 else { return (nil, nil) }
        let background = inks.reduce(SIMD3<Float>.zero) { $0 + $1.background } / Float(inks.count)
        func luma(_ c: SIMD3<Float>) -> Float { 0.299 * c.x + 0.587 * c.y + 0.114 * c.z }
        var a = colors.min { luma($0) < luma($1) }!, b = colors.max { luma($0) < luma($1) }!
        var assign = [Bool](repeating: false, count: colors.count)
        for _ in 0..<6 {
            var sa = SIMD3<Float>.zero, sb = SIMD3<Float>.zero, na: Float = 0, nb: Float = 0
            for (i, c) in colors.enumerated() {
                let da = c - a, db = c - b
                assign[i] = (db * db).sum() < (da * da).sum()
                if assign[i] { sb += c; nb += 1 } else { sa += c; na += 1 }
            }
            if na > 0 { a = sa / na }
            if nb > 0 { b = sb / nb }
        }
        let nb = assign.filter { $0 }.count, na = colors.count - nb
        let edgeB = Float(zip(assign, edges).filter { $0.0 && $0.1 }.count) / Float(max(nb, 1))
        let edgeA = Float(zip(assign, edges).filter { !$0.0 && $0.1 }.count) / Float(max(na, 1))
        let separation = ((a - b) * (a - b)).sum().squareRoot()
        func hex(_ c: SIMD3<Float>) -> String {
            String(format: "#%02X%02X%02X", Int(min(max(c.x, 0), 255).rounded()), Int(min(max(c.y, 0), 255).rounded()),
                   Int(min(max(c.z, 0), 255).rounded()))
        }
        /// 테두리 후보가 글자색→바탕색 선분 위(섞인 번짐 색)에서 inkDistance 넘게 벗어나야 진짜 테두리다.
        func isOutline(_ outline: SIMD3<Float>, fill: SIMD3<Float>) -> Bool {
            let axis = background - fill
            let length = (axis * axis).sum()
            guard length > 0 else { return true }
            let t = min(max(((outline - fill) * axis).sum() / length, 0), 1)
            let offset = outline - (fill + axis * t)
            return (offset * offset).sum().squareRoot() > inkDistance
        }
        let minShare = Float(colors.count) * 0.15
        if separation > 110, Float(na) >= minShare, Float(nb) >= minShare {
            if edgeB > edgeA * 1.6, isOutline(b, fill: a) { return (hex(a), hex(b)) }
            if edgeA > edgeB * 1.6, isOutline(a, fill: b) { return (hex(b), hex(a)) }
        }
        let da = a - background, db = b - background
        return (hex((da * da).sum() >= (db * db).sum() ? a : b), nil)
    }

    // MARK: 배경 복원 조각

    /// 지울 대상(원본 글자·후리가나·대체 문단 영역)의 원문을 덮는 불투명 PNG 조각을 만든다. 덮은 픽셀만 불투명하고
    /// 나머지는 투명이라 원본 그림이 그대로 보인다. 원본 그림을 정확히 되살리는 것이 아니라, 주변의 깨끗한 배경으로
    /// 자연스럽게 메우려는 최선의 근사다.
    /// - 지울 픽셀: 거의 한 색인 바탕(고리 표본의 55% 이상이 한 색이고 상자 안도 고른 종이, plainInterior)에서는 그 바탕색과
    ///   다른 픽셀만(글자 사이 바탕·말풍선 테두리는 원본 유지). 둘레만 한 색이고 상자 안이 그림이면 잰 잉크·글자 모양만. 그림·무늬 위처럼 바탕을 믿을 수 없으면 잰 글자 모양(못 재면 둘레와 다른 픽셀, 마지막으로 상자 전체).
    ///   모두 번짐·압축 잡음까지 넓힌다.
    /// - 메우기(덮은 덩어리마다): 주변의 깨끗한 픽셀(지울 픽셀·다른 글자 상자 제외)만 표본으로 쓰고 글자 잉크·테두리 같은
    ///   이상치는 뺀다. 고르면 평면/완만한 기울기 면으로, 무늬가 있으면 가장 비슷한 주변 영역을 밝기만 맞춰 옮겨 오고,
    ///   맞는 영역이 없으면 사방의 가장 가까운 깨끗한 픽셀로 보간한다. 이웃 원문 잉크를 평균에 섞지 않는다.
    fileprivate static func restoration(_ targets: [CoverTarget], canvas: Canvas, occupied: [Bool]) -> Restoration? {
        guard !targets.isEmpty else { return nil }
        // 문단 폭을 글자 크기로 삼으면 긴 제목·부제의 주변까지 크게 지워진다.
        // 실제 글자 표본을 먼저 쓰고, 표본이 없으면 문단의 짧은 변을 기준으로 한다.
        let glyphSizes = targets.filter { !$0.wide }.map { max($0.rect.width, $0.rect.height) }
        let sizes = (glyphSizes.isEmpty ? targets.map { min($0.rect.width, $0.rect.height) } : glyphSizes).sorted()
        let size = sizes[sizes.count / 2]
        let pad = max(1, min(3, Int((Double(size) * 0.02).rounded())))
        let radius = max(1, min(3, Int((Double(size) * 0.015).rounded()))) + 1
        var area = targets[0].rect
        for t in targets {
            var r = t.rect
            if let ink = t.ink { r = PixelRect(x0: min(r.x0, ink.window.x0), y0: min(r.y0, ink.window.y0),
                                              x1: max(r.x1, ink.window.x1), y1: max(r.y1, ink.window.y1)) }
            area.x0 = min(area.x0, r.x0); area.y0 = min(area.y0, r.y0)
            area.x1 = max(area.x1, r.x1); area.y1 = max(area.y1, r.y1)
        }
        let samplePad = max(pad, Int((Double(size) * 0.12).rounded())) + max(radius, Int((Double(size) * 0.1).rounded())) + 1
        area = area.padded(max(samplePad, pad + 2 + radius), in: canvas)
        let w = area.width, h = area.height
        guard w >= 2, h >= 2, w * h <= 8_000_000 else { return nil }
        var mask = [Bool](repeating: false, count: w * h)
        var own = [Bool](repeating: false, count: w * h)
        // 글자·후리가나와 복합 단어 상자까지 모두 불투명하게 복원한다. 복합 상자는 모양만
        // 지우면 일부 일본어 획이 남으므로, 인식된 범위 안에서는 원문 제거를 우선한다.
        var hintOf = [Int32](repeating: -1, count: w * h)
        var hints: [SIMD3<Float>] = []
        for t in targets {
            // 인식된 원문 범위는 모두 지우고 주변 압축·번짐용 여백만 줄인다.
            let edgePad = t.wide ? 2 : 0
            let r = t.rect.padded(pad + edgePad, in: canvas)
            let hintIndex = Int32(hints.count)
            hints.append(t.window?.background ?? SIMD3<Float>(255, 255, 255))
            for y in r.y0..<r.y1 { for x in r.x0..<r.x1 {
                let i = (y - area.y0) * w + (x - area.x0)
                own[i] = true
                mask[i] = true
                if t.window?.uniformBackground == true { hintOf[i] = hintIndex }
            } }
        }
        // OCR 상자 밖으로 잘린 획도 포함한다. 글자 사이 공간은 문단 상자 대신 실제 글자 상자로 남긴다.
        do {
            for t in targets {
                guard let ink = t.ink else { continue }
                for y in ink.window.y0..<ink.window.y1 { for x in ink.window.x0..<ink.window.x1 {
                    guard ink.mask[(y - ink.window.y0) * ink.window.width + x - ink.window.x0] else { continue }
                    let i = (y - area.y0) * w + x - area.x0
                    own[i] = true; mask[i] = true
                } }
            }
        }
        do {
            for t in targets {
                guard !t.wide, let window = t.window else { continue }
                let darkBackground = max(window.background.x, window.background.y, window.background.z) <= 64 && window.dominantShare >= 0.25
                guard darkBackground || (window.dominantShare >= 0.55 && min(window.background.x, window.background.y, window.background.z) >= 220) else { continue }
                // 어두운 망점 배경의 흰 외곽선도 포함하되, 탐색 경계에 닿는 말풍선 테두리는 보존한다.
                func foreground(_ c: SIMD3<Float>) -> Bool {
                    darkBackground
                        ? min(c.x, c.y, c.z) > max(112, max(window.background.x, window.background.y, window.background.z) + 80)
                        : max(c.x, c.y, c.z) < 48
                }
                let edge = t.rect.padded(darkBackground ? min(24, max(6, min(t.rect.width, t.rect.height) / 4)) : min(14, max(6, min(t.rect.width, t.rect.height) / 5)), in: canvas)
                var seen = [Bool](repeating: false, count: edge.width * edge.height)
                for sy in edge.y0..<edge.y1 { for sx in edge.x0..<edge.x1 {
                    let start=(sy-edge.y0)*edge.width+sx-edge.x0
                    guard !seen[start] else { continue }
                    seen[start]=true
                    guard !occupied[sy*canvas.width+sx] || t.rect.contains(sx,sy), let c=canvas.color(sx,sy), foreground(c) else { continue }
                    var queue=[(sx,sy)], cursor=0, boundary=false, touchesGlyph=false
                    var x0=sx, x1=sx, y0=sy, y1=sy
                    while cursor<queue.count {
                        let (x,y)=queue[cursor]; cursor+=1
                        boundary = boundary || x==edge.x0 || x==edge.x1-1 || y==edge.y0 || y==edge.y1-1
                        touchesGlyph = touchesGlyph || t.rect.contains(x,y)
                        x0=min(x0,x); x1=max(x1,x); y0=min(y0,y); y1=max(y1,y)
                        for dy in -1...1 { for dx in -1...1 {
                            let nx=x+dx, ny=y+dy
                            guard edge.contains(nx,ny) else { continue }
                            let i=(ny-edge.y0)*edge.width+nx-edge.x0
                            guard !seen[i] else { continue }; seen[i]=true
                            guard !occupied[ny*canvas.width+nx] || t.rect.contains(nx,ny),
                                  let c=canvas.color(nx,ny), foreground(c) else { continue }
                            queue.append((nx,ny))
                        } }
                    }
                    let alignedX = max(0,min(x1+1,t.rect.x1)-max(x0,t.rect.x0))*2 >= x1-x0+1
                    let alignedY = max(0,min(y1+1,t.rect.y1)-max(y0,t.rect.y0))*2 >= y1-y0+1
                    guard (!darkBackground || !boundary), touchesGlyph || (!boundary && (alignedX || alignedY)) else { continue }
                    for (x,y) in queue where area.contains(x,y) && !t.rect.contains(x,y) && !occupied[y*canvas.width+x] {
                        let i=(y-area.y0)*w+x-area.x0
                        own[i]=true; mask[i]=true
                    }
                } }
            }
        }
        dilate(&mask, w: w, h: h, radius: radius)

        let cw = canvas.width, ch = canvas.height
        // 메우기 표본으로 쓸 수 있는 원본 픽셀(지울 픽셀·다른 항목의 글자 상자·투명 픽셀 제외)
        func clean(_ x: Int, _ y: Int) -> SIMD3<Float>? {
            guard x >= 0, y >= 0, x < cw, y < ch else { return nil }
            if area.contains(x, y) {
                let i = (y - area.y0) * w + (x - area.x0)
                if mask[i] || (occupied[y * cw + x] && !own[i]) { return nil }
            } else if occupied[y * cw + x] {
                return nil
            }
            return canvas.color(x, y)
        }

        var color = [SIMD3<Float>](repeating: .zero, count: w * h)
        var label = [Int32](repeating: -1, count: w * h)
        var stack: [Int] = []
        var crop = PixelRect(x0: w, y0: h, x1: 0, y1: 0)
        var componentCount: Int32 = 0
        for start in 0..<(w * h) where mask[start] && label[start] < 0 {
            // 8연결 덩어리 하나
            var pixels: [Int] = []
            label[start] = componentCount
            stack.append(start)
            var b = PixelRect(x0: w, y0: h, x1: 0, y1: 0)
            while let i = stack.popLast() {
                pixels.append(i)
                let x = i % w, y = i / w
                b.x0 = min(b.x0, x); b.y0 = min(b.y0, y); b.x1 = max(b.x1, x + 1); b.y1 = max(b.y1, y + 1)
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, yy >= 0, xx < w, yy < h else { continue }
                    let j = yy * w + xx
                    if mask[j] && label[j] < 0 { label[j] = componentCount; stack.append(j) }
                } }
            }
            componentCount += 1
            crop.x0 = min(crop.x0, b.x0); crop.y0 = min(crop.y0, b.y0); crop.x1 = max(crop.x1, b.x1); crop.y1 = max(crop.y1, b.y1)
            let hint = pixels.lazy.map { hintOf[$0] }.first { $0 >= 0 }.map { hints[Int($0)] }
            fill(pixels, bounds: b, origin: (area.x0, area.y0), w: w, hint: hint, clean: clean, into: &color)
        }
        guard crop.width > 0, crop.height > 0 else { return nil }

        // 너무 큰 조각은 줄여 보낸다. 줄였다 키우면 가장자리가 반투명해지므로 그 배율만큼 덮는 범위를 먼저 넓힌다
        // (넓힌 픽셀은 원본 색 그대로라 보이는 모양은 같다).
        var scale = 1.0
        if crop.width * crop.height > maxPatchPixels {
            scale = (Double(maxPatchPixels) / Double(crop.width * crop.height)).squareRoot()
            let extra = Int((1 / scale).rounded(.up)) + 1
            let before = mask
            dilate(&mask, w: w, h: h, radius: extra)
            for i in 0..<(w * h) where mask[i] && !before[i] {
                color[i] = canvas.color(area.x0 + i % w, area.y0 + i / w) ?? color[i]
            }
            crop = PixelRect(x0: max(0, crop.x0 - extra), y0: max(0, crop.y0 - extra), x1: min(w, crop.x1 + extra), y1: min(h, crop.y1 + extra))
        }
        let pw = crop.width, ph = crop.height
        var bytes = [UInt8](repeating: 0, count: pw * ph * 4)
        for y in 0..<ph {
            for x in 0..<pw {
                let i = (y + crop.y0) * w + (x + crop.x0)
                guard mask[i] else { continue }
                let c = color[i], o = (y * pw + x) * 4
                bytes[o] = UInt8(min(max(c.x, 0), 255).rounded()); bytes[o + 1] = UInt8(min(max(c.y, 0), 255).rounded())
                bytes[o + 2] = UInt8(min(max(c.z, 0), 255).rounded()); bytes[o + 3] = 255
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              var image = CGImage(width: pw, height: ph, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pw * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        if scale < 1 {
            let sw = max(1, Int(Double(pw) * scale)), sh = max(1, Int(Double(ph) * scale))
            guard let ctx = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: sw, height: sh))
            guard let scaled = ctx.makeImage() else { return nil }
            image = scaled
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let placed = PixelRect(x0: area.x0 + crop.x0, y0: area.y0 + crop.y0, x1: area.x0 + crop.x1, y1: area.y0 + crop.y1)
        return Restoration(box: canvas.unitBox(placed), png: data as Data)
    }

    /// 글자 상자(rect) 안에서 지울 픽셀(marks, area 기준)에 둘러싸인 안쪽도 지울 픽셀로 더한다. 외곽선 글자의 속 색이
    /// 둘레 무늬와 같은 색이면(마름모 무늬 위 흰 글자 등) 외곽선만 잡혀 속 글자 모양이 그대로 남았다(page5 실측).
    /// 외곽선의 작은 틈(압축 번짐·가는 획)은 글자 크기의 4%만큼 닫고 본다. 상자 가장자리와 이어진 바깥은 그대로 두고,
    /// 더한 뒤 상자의 75%를 넘으면(둘레 그림까지 막힌 경우) 더하지 않는다.
    private static func fillEnclosed(_ marks: inout [Bool], in rect: PixelRect, area: PixelRect, close: Int? = nil) {
        let x0 = max(rect.x0, area.x0), y0 = max(rect.y0, area.y0), x1 = min(rect.x1, area.x1), y1 = min(rect.y1, area.y1)
        let lw = x1 - x0, lh = y1 - y0
        guard lw >= 4, lh >= 4 else { return }
        let aw = area.width
        let radius = close ?? max(1, Int(Double(min(lw, lh)) * 0.04))
        var ink = [Bool](repeating: false, count: lw * lh)
        var count = 0
        for y in 0..<lh { for x in 0..<lw where marks[(y + y0 - area.y0) * aw + (x + x0 - area.x0)] { ink[y * lw + x] = true; count += 1 } }
        guard count > 0 else { return }
        var barrier = ink
        dilate(&barrier, w: lw, h: lh, radius: radius)
        var outside = [Bool](repeating: false, count: lw * lh)
        var stack: [Int] = []
        for y in 0..<lh { for x in 0..<lw where (x == 0 || y == 0 || x == lw - 1 || y == lh - 1) && !barrier[y * lw + x] {
            outside[y * lw + x] = true; stack.append(y * lw + x)
        } }
        while let i = stack.popLast() {
            let x = i % lw, y = i / lw
            for (xx, yy) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where xx >= 0 && yy >= 0 && xx < lw && yy < lh {
                let j = yy * lw + xx
                if !barrier[j] && !outside[j] { outside[j] = true; stack.append(j) }
            }
        }
        // 닫느라 넓힌 만큼 바깥을 되돌려, 획 바깥 가장자리가 부풀지 않게 한다.
        dilate(&outside, w: lw, h: lh, radius: radius)
        var added: [Int] = []
        for i in 0..<(lw * lh) where !ink[i] && !outside[i] { added.append(i) }
        guard !added.isEmpty, Double(count + added.count) <= Double(lw * lh) * 0.75 else { return }
        for i in added { marks[(i / lw + y0 - area.y0) * aw + (i % lw + x0 - area.x0)] = true }
    }

    /// 상자 안이 둘레 바탕색(bg) 그대로인 고른 바탕인지: 바탕색과 다른 픽셀(글자 획·번짐)이 상자의 일부이고 상자 테두리는
    /// 거의 바탕색이어야 한다. 그림·기울기 면이 상자에 걸치면 다른 픽셀이 늘고 테두리까지 이어진다. 큰 상자도 표본 격자
    /// (최대 약 4만 칸)로 잰다. 줄·문단 상자는 그 안 글자 상자가 따로 지워지므로 더 엄격하게 본다.
    private static func plainInterior(_ r: PixelRect, background bg: SIMD3<Float>, uniform: Bool, wide: Bool, canvas: Canvas) -> Bool {
        guard r.width > 0, r.height > 0 else { return false }
        let step = max(1, Int((Double(r.width * r.height) / 40_000).squareRoot()))
        func differs(_ x: Int, _ y: Int) -> Bool? {
            guard let c = canvas.color(x, y) else { return nil }
            let d = c - bg
            return (d * d).sum() > 14 * 14
        }
        var inside = 0, differ = 0, edge = 0, edgeDiffer = 0
        for y in Swift.stride(from: r.y0, to: r.y1, by: step) {
            for x in Swift.stride(from: r.x0, to: r.x1, by: step) {
                guard let far = differs(x, y) else { continue }
                inside += 1
                if far { differ += 1 }
            }
        }
        let rim = Swift.stride(from: r.x0, to: r.x1, by: step).flatMap { [($0, r.y0), ($0, r.y1 - 1)] }
            + Swift.stride(from: r.y0, to: r.y1, by: step).flatMap { [(r.x0, $0), (r.x1 - 1, $0)] }
        for (x, y) in rim {
            guard let far = differs(x, y) else { continue }
            edge += 1
            if far { edgeDiffer += 1 }
        }
        guard inside > 0, edge > 0 else { return false }
        let interiorLimit = wide ? 0.45 : (uniform ? 0.6 : 0.5)
        let rimLimit = wide ? 0.15 : 0.35
        return Double(differ) <= Double(inside) * interiorLimit && Double(edgeDiffer) <= Double(edge) * rimLimit
    }

    /// 정사각형 팽창(가로 → 세로 분리). 줄마다 앞뒤로 한 번씩 훑어 가장 가까운 참 칸까지 거리를 재므로 반경과 관계없이
    /// 면적에 비례한다(이전에는 칸마다 반경만큼 훑어 큰 제목에서 느렸다). 결과는 같다.
    private static func dilate(_ mask: inout [Bool], w: Int, h: Int, radius: Int) {
        guard radius > 0, w > 0, h > 0 else { return }
        for horizontal in [true, false] {
            let source = mask
            let lines = horizontal ? h : w, length = horizontal ? w : h
            for line in 0..<lines {
                func index(_ p: Int) -> Int { horizontal ? line * w + p : p * w + line }
                var last = Int.min / 2
                for p in 0..<length {
                    if source[index(p)] { last = p } else if p - last <= radius { mask[index(p)] = true }
                }
                last = Int.max / 2
                for p in Swift.stride(from: length - 1, through: 0, by: -1) {
                    if source[index(p)] { last = p } else if last - p <= radius { mask[index(p)] = true }
                }
            }
        }
    }

    /// 덮은 덩어리 하나(pixels, 국소 좌표 bounds)를 주변의 깨끗한 픽셀로 메운다. 바탕 표본은 덩어리 둘레(글자 크기의
    /// 1/3, 3~24px)에서만 모으고 중앙값에서 먼 표본(글자 잉크·테두리·다른 무늬)은 뺀다.
    /// hint: 이 덩어리 글자의 바탕색(둘레 가장 큰 색 군집). 둘레에 테두리·바깥 그림이 섞여 중앙값이 흔들릴 때 기준 색으로 쓴다.
    private static func fill(_ pixels: [Int], bounds b: PixelRect, origin: (Int, Int), w: Int, hint: SIMD3<Float>?,
                             clean: (Int, Int) -> SIMD3<Float>?, into color: inout [SIMD3<Float>]) {
        let ring = min(24, max(3, min(b.width, b.height) / 3))
        let gx0 = origin.0 + b.x0 - ring, gy0 = origin.1 + b.y0 - ring
        let gx1 = origin.0 + b.x1 + ring, gy1 = origin.1 + b.y1 + ring
        let step = max(1, Int((Double((gx1 - gx0) * (gy1 - gy0)) / 4000).squareRoot()))
        let cx = Float(origin.0 + (b.x0 + b.x1) / 2), cy = Float(origin.1 + (b.y0 + b.y1) / 2)
        let norm = 1 / Float(max(b.width, b.height, 1))
        var samples: [(x: Float, y: Float, c: SIMD3<Float>)] = []
        for y in Swift.stride(from: gy0, to: gy1, by: step) {
            for x in Swift.stride(from: gx0, to: gx1, by: step) {
                if let c = clean(x, y) { samples.append(((Float(x) - cx) * norm, (Float(y) - cy) * norm, c)) }
            }
        }
        func median(_ values: [Float]) -> Float { values.sorted()[values.count / 2] }
        // 고른 바탕(단색 말풍선·완만한 기울기·잔 무늬): 평면 식으로 채우고, 둘레 표본의 실제 잔차(종이 결·망점·압축 잡음)를
        // 다시 뿌려 지운 자리만 매끈하게 튀지 않게 한다. 표본 범위 밖 색은 만들지 않는다.
        var smooth: (plane: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>), residuals: [SIMD3<Float>], low: SIMD3<Float>, high: SIMD3<Float>, error: Float)?
        if samples.count >= 8 {
            let med = SIMD3(median(samples.map(\.c.x)), median(samples.map(\.c.y)), median(samples.map(\.c.z)))
            func near(_ center: SIMD3<Float>) -> [(x: Float, y: Float, c: SIMD3<Float>)] {
                samples.filter { let d = $0.c - center; return (d * d).sum() < 40 * 40 }
            }
            var inliers = near(med)
            var required = 0.6
            if let hint {
                // 글자 바탕색 근처 표본이 더 많으면 그것을 쓴다(덩어리 둘레에 바탕이 고루 있어야 하므로 40% 이상).
                let hinted = near(hint)
                if hinted.count > inliers.count { inliers = hinted; required = 0.4 }
            }
            if Double(inliers.count) >= Double(samples.count) * required, let fit = fitPlane(inliers) {
                var low = inliers[0].c, high = inliers[0].c
                for s in inliers { low = pointwiseMin(low, s.c); high = pointwiseMax(high, s.c) }
                let residuals = inliers.map { $0.c - (fit.plane.0 + fit.plane.1 * $0.x + fit.plane.2 * $0.y) }
                smooth = (fit.plane, residuals, low, high, fit.error)
            }
        }
        // 이웃 픽셀 사이 변화(가로·세로). 잔차에 비해 크면 망점·거친 결 같은 잔 무늬, 작으면 옅은 선·기울기 같은 큰 구조다.
        var gx: Float = 1, gy: Float = 1, adjacent: Float = 0, pairs: Float = 0
        for sample in samples {
            let x = Int(sample.x / norm + cx), y = Int(sample.y / norm + cy)
            if let r = clean(x + 1, y) { let d = r - sample.c; let v = abs(d.x) + abs(d.y) + abs(d.z); gx += v; adjacent += v; pairs += 1 }
            if let u = clean(x, y + 1) { let d = u - sample.c; let v = abs(d.x) + abs(d.y) + abs(d.z); gy += v; adjacent += v; pairs += 1 }
        }
        let grain = pairs > 0 ? adjacent / pairs / 3 : 0
        func fillSmooth(_ model: (plane: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>), residuals: [SIMD3<Float>],
                                  low: SIMD3<Float>, high: SIMD3<Float>, error: Float)) {
            var seed: UInt32 = 0x9E37_79B9 &+ UInt32(truncatingIfNeeded: pixels.count)
            for i in pixels {
                let x = (Float(origin.0 + i % w) - cx) * norm, y = (Float(origin.1 + i / w) - cy) * norm
                seed = seed &* 1_664_525 &+ 1_013_904_223
                // 매끈한 바탕·옅은 선 같은 큰 구조에 잔차를 뿌리면 글자 모양 얼룩으로 보이므로 매끈하게 채우고, 망점·거친 결
                // (이웃 픽셀 변화가 잔차만큼 큰) 바탕에만 결이 보일 만큼(0.7배, 1배면 조각 PNG가 커져 응답 상한에 걸림) 뿌린다.
                let noise = model.error > 8 && grain >= model.error * 0.5
                    ? model.residuals[Int(seed >> 8) % model.residuals.count] * 0.7 : .zero
                let value = model.plane.0 + model.plane.1 * x + model.plane.2 * y + noise
                color[i] = pointwiseMin(pointwiseMax(value, model.low - 4), model.high + 4)
            }
        }
        if let smooth, smooth.error <= 8 { fillSmooth(smooth); return }
        // 다른 위치의 그림·글자를 복제하면 얼굴과 원문이 되살아날 수 있어 주변색 보간만 쓴다.
        // 큰 제목에서 맞는 무늬가 없으면 먼 그림 픽셀을 길게 늘이지 않는다(줄무늬 번짐). 이전에는 둘레 대표색의 평면
        // 한 장으로 칠해, 그림 위 제목 전체가 한 덩어리가 되면 거대한 단색 판이 남았다. 둘레의 깨끗한 픽셀을 거친
        // 해상도부터 안쪽으로 고르게 번지게 해 자리마다 가까운 주변 색(바탕 쪽은 바탕, 그림 쪽은 그림 색)을 따른다.
        // 가려진 그림의 구조(선·무늬)는 되살리지 못하고 흐린 면이 된다.
        if max(b.width, b.height) >= 96, min(b.width, b.height) >= 24, samples.count >= 8,
           pushPull(pixels, bounds: b, origin: origin, w: w, ring: ring, clean: clean, into: &color) {
            return
        }
        // 한 방향으로 길게 이어지는 무늬(속도선·집중선)는 그 방향으로 이어 메우는 편이 자연스럽다. 그 밖의 잔 무늬 바탕만
        // 평면(+잔차)으로 채운다.
        let directional = max(gx, gy) >= min(gx, gy) * 2
        if !directional, let smooth, smooth.error <= 30 { fillSmooth(smooth); return }
        // 맞는 무늬를 못 찾으면 사방(상하좌우)의 가장 가까운 깨끗한 픽셀을 거리 제곱 역수로 섞는다. 가장 가까운 픽셀은
        // 둘레를 포함한 범위에서 행·열을 한 번씩 훑어 찾는다(픽셀마다 따로 찾으면 큰 제목에서 수 초가 걸렸다).
        let fallback = samples.isEmpty ? SIMD3<Float>(255, 255, 255)
            : samples.reduce(SIMD3<Float>.zero) { $0 + $1.c } / Float(samples.count)
        let ew = gx1 - gx0, eh = gy1 - gy0
        var known = [Bool](repeating: false, count: ew * eh)
        var source = [SIMD3<Float>](repeating: .zero, count: ew * eh)
        for y in 0..<eh {
            for x in 0..<ew {
                if let c = clean(gx0 + x, gy0 + y) { known[y * ew + x] = true; source[y * ew + x] = c }
            }
        }
        var sum = [SIMD3<Float>](repeating: .zero, count: ew * eh)
        var weight = [Float](repeating: 0, count: ew * eh)
        func sweep(lines: Int, length: Int, scale: Float, index: (Int, Int) -> Int) {
            for line in 0..<lines {
                for forward in [true, false] {
                    var last = -1
                    for step in 0..<length {
                        let position = forward ? step : length - 1 - step
                        let i = index(line, position)
                        if known[i] { last = position; continue }
                        guard last >= 0 else { continue }
                        let distance = Float(abs(position - last))
                        let k = scale / (distance * distance)
                        sum[i] += source[index(line, last)] * k
                        weight[i] += k
                    }
                }
            }
        }
        // 무늬가 이어지는 방향(속도선 등)을 따라 메우도록, 둘레의 가로·세로 밝기 변화가 작은 쪽 방향에 더 큰 가중을 준다.
        var acrossX: Float = 1, acrossY: Float = 1
        for y in 0..<eh {
            for x in 0..<ew where known[y * ew + x] {
                if x + 1 < ew, known[y * ew + x + 1] { let d = source[y * ew + x + 1] - source[y * ew + x]; acrossX += abs(d.x) + abs(d.y) + abs(d.z) }
                if y + 1 < eh, known[(y + 1) * ew + x] { let d = source[(y + 1) * ew + x] - source[y * ew + x]; acrossY += abs(d.x) + abs(d.y) + abs(d.z) }
            }
        }
        // 가로 방향 변화가 작으면(가로 줄무늬) 가로로 훑은 값을, 세로 변화가 작으면 세로로 훑은 값을 더 믿는다.
        let rowWeight = acrossY / (acrossX + acrossY), columnWeight = acrossX / (acrossX + acrossY)
        sweep(lines: eh, length: ew, scale: rowWeight) { $0 * ew + $1 }
        sweep(lines: ew, length: eh, scale: columnWeight) { $1 * ew + $0 }
        var inside = [Bool](repeating: false, count: ew * eh)
        func local(_ i: Int) -> Int { (origin.1 + i / w - gy0) * ew + (origin.0 + i % w - gx0) }
        for i in pixels {
            let j = local(i)
            inside[j] = true
            color[i] = weight[j] > 0 ? sum[j] / weight[j] : fallback
        }
        // 사방 보간의 십자 무늬를 덩어리 안에서만 몇 번 고르게 편다.
        for _ in 0..<3 {
            let previous = color
            for i in pixels {
                let j = local(i)
                var total = previous[i], n: Float = 1
                if j % ew > 0, inside[j - 1] { total += previous[i - 1]; n += 1 }
                if j % ew < ew - 1, inside[j + 1] { total += previous[i + 1]; n += 1 }
                if j >= ew, inside[j - ew] { total += previous[i - w]; n += 1 }
                if j + ew < ew * eh, inside[j + ew] { total += previous[i + w]; n += 1 }
                color[i] = total / n
            }
        }
    }

    /// 덮은 덩어리 하나를 둘레(ring)를 포함한 범위의 깨끗한 픽셀로 피라미드 밀고 당기기 보간한다. 2배씩 줄이며 깨끗한
    /// 픽셀의 가중 평균을 모으고(밀기), 거친 단계 값을 겹선형으로 키워 빈 자리만 채운다(당기기). 빈 자리는 가까운 깨끗한
    /// 픽셀의 색을 따르고 멀수록 넓은 주변 평균에 가까워진다. 깨끗한 픽셀이 너무 적으면 false.
    private static func pushPull(_ pixels: [Int], bounds b: PixelRect, origin: (Int, Int), w: Int, ring: Int,
                                 clean: (Int, Int) -> SIMD3<Float>?, into color: inout [SIMD3<Float>]) -> Bool {
        let gx0 = origin.0 + b.x0 - ring, gy0 = origin.1 + b.y0 - ring
        let ew = b.width + 2 * ring, eh = b.height + 2 * ring
        var base = [SIMD3<Float>](repeating: .zero, count: ew * eh)
        var weight = [Float](repeating: 0, count: ew * eh)
        var known = 0
        for y in 0..<eh {
            for x in 0..<ew {
                guard let c = clean(gx0 + x, gy0 + y) else { continue }
                base[y * ew + x] = c; weight[y * ew + x] = 1; known += 1
            }
        }
        guard known >= 8 else { return false }
        var levels: [(w: Int, h: Int, c: [SIMD3<Float>], k: [Float])] = [(ew, eh, base, weight)]
        while levels[levels.count - 1].w > 1 || levels[levels.count - 1].h > 1 {
            let p = levels[levels.count - 1]
            let nw = (p.w + 1) / 2, nh = (p.h + 1) / 2
            var c = [SIMD3<Float>](repeating: .zero, count: nw * nh)
            var k = [Float](repeating: 0, count: nw * nh)
            for y in 0..<p.h {
                for x in 0..<p.w where p.k[y * p.w + x] > 0 {
                    let i = y * p.w + x, j = (y / 2) * nw + x / 2
                    c[j] += p.c[i] * p.k[i]; k[j] += p.k[i]
                }
            }
            for j in 0..<(nw * nh) where k[j] > 0 { c[j] /= k[j]; k[j] = min(1, k[j]) }
            levels.append((nw, nh, c, k))
        }
        for l in Swift.stride(from: levels.count - 2, through: 0, by: -1) {
            let coarse = levels[l + 1]
            var fine = levels[l]
            for y in 0..<fine.h {
                let fy = min(Float(coarse.h - 1), max(0, (Float(y) + 0.5) / 2 - 0.5))
                let y0 = Int(fy), y1 = min(coarse.h - 1, y0 + 1), ty = fy - Float(y0)
                for x in 0..<fine.w {
                    let i = y * fine.w + x
                    guard fine.k[i] < 1 else { continue }
                    let fx = min(Float(coarse.w - 1), max(0, (Float(x) + 0.5) / 2 - 0.5))
                    let x0 = Int(fx), x1 = min(coarse.w - 1, x0 + 1), tx = fx - Float(x0)
                    let top = coarse.c[y0 * coarse.w + x0] * (1 - tx) + coarse.c[y0 * coarse.w + x1] * tx
                    let bottom = coarse.c[y1 * coarse.w + x0] * (1 - tx) + coarse.c[y1 * coarse.w + x1] * tx
                    fine.c[i] = fine.c[i] * fine.k[i] + (top * (1 - ty) + bottom * ty) * (1 - fine.k[i])
                    fine.k[i] = 1
                }
            }
            levels[l] = fine
        }
        let filled = levels[0].c
        for i in pixels {
            color[i] = filled[(origin.1 + i / w - gy0) * ew + (origin.0 + i % w - gx0)]
        }
        return true
    }

    /// 표본에 c = a + b·x + c·y 평면을 최소제곱으로 맞추고 잔차의 RMS(채널 평균)를 함께 돌려준다.
    private static func fitPlane(_ samples: [(x: Float, y: Float, c: SIMD3<Float>)])
        -> (plane: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>), error: Float)? {
        var sxx: Float = 0, sxy: Float = 0, syy: Float = 0, sx: Float = 0, sy: Float = 0
        var sc = SIMD3<Float>.zero, sxc = SIMD3<Float>.zero, syc = SIMD3<Float>.zero
        let n = Float(samples.count)
        for s in samples {
            sx += s.x; sy += s.y; sxx += s.x * s.x; sxy += s.x * s.y; syy += s.y * s.y
            sc += s.c; sxc += s.c * s.x; syc += s.c * s.y
        }
        let mean = sc / n
        var a = mean, bx = SIMD3<Float>.zero, by = SIMD3<Float>.zero
        // 중심화한 2×2 정규방정식. 표본이 한 줄로만 놓여 기울기를 정할 수 없으면 평균(평면 없음)으로 둔다.
        let mx = sx / n, my = sy / n
        let cxx = sxx / n - mx * mx, cxy = sxy / n - mx * my, cyy = syy / n - my * my
        let det = cxx * cyy - cxy * cxy
        if det > 1e-6 {
            let vx = sxc / n - mean * mx, vy = syc / n - mean * my
            bx = (vx * cyy - vy * cxy) / det
            by = (vy * cxx - vx * cxy) / det
            a = mean - bx * mx - by * my
        }
        var error: Float = 0
        for s in samples {
            let d = s.c - (a + bx * s.x + by * s.y)
            error += (d * d).sum()
        }
        return ((a, bx, by), (error / n / 3).squareRoot())
    }

    /// 무늬가 있는 바탕: 덩어리와 같은 모양의 주변 영역 중 덩어리 둘레(3px 띠)가 가장 비슷한 곳을 골라 옮겨 온다.
    /// 옮긴 영역이 모두 깨끗해야 하며(지울 픽셀·글자 상자 제외), 밝기 차이는 띠 평균 차로 맞춘다. 비슷한 곳이 없으면 false.
    private static func copyTexture(_ pixels: [Int], bounds b: PixelRect, origin: (Int, Int), w: Int,
                                    clean: (Int, Int) -> SIMD3<Float>?, into color: inout [SIMD3<Float>]) -> Bool {
        var band: [(x: Int, y: Int, c: SIMD3<Float>)] = []
        let bx0 = origin.0 + b.x0 - 3, by0 = origin.1 + b.y0 - 3, bx1 = origin.0 + b.x1 + 3, by1 = origin.1 + b.y1 + 3
        let bandStep = max(1, Int((Double((bx1 - bx0) * (by1 - by0)) / 6000).squareRoot()))
        for y in Swift.stride(from: by0, to: by1, by: bandStep) {
            for x in Swift.stride(from: bx0, to: bx1, by: bandStep) {
                if let c = clean(x, y) { band.append((x, y, c)) }
            }
        }
        guard band.count >= 12 else { return false }
        let targetMean = band.reduce(SIMD3<Float>.zero) { $0 + $1.c } / Float(band.count)
        // 둘레 자체의 무늬 변동폭(평균에서 벗어난 정도)과 밝기 범위. 옮겨 올 영역은 이 범위 안의 무늬여야 한다
        // (주변 둘레만 비슷하고 안에 테두리 선·다른 그림이 든 곳을 옮겨 오지 않게).
        func luma(_ c: SIMD3<Float>) -> Float { 0.299 * c.x + 0.587 * c.y + 0.114 * c.z }
        let spread = band.reduce(Float(0)) { let d = $1.c - targetMean; return $0 + abs(d.x) + abs(d.y) + abs(d.z) } / Float(band.count) / 3
        let lumas = band.map { luma($0.c) }.sorted()
        let lowLuma = lumas[lumas.count * 3 / 100] - 24, highLuma = lumas[lumas.count * 97 / 100] + 24
        // 둘레 밝기 분포(8칸). 옮겨 올 영역의 분포가 크게 다르면(인물·물체 같은 다른 그림) 옮기지 않는다.
        var bandHistogram = [Float](repeating: 0, count: 8)
        for l in lumas { bandHistogram[min(7, max(0, Int(l / 32)))] += 1 / Float(lumas.count) }
        let checkStep = max(1, pixels.count / 4000)
        let stepX = max(3, b.width / 2 + 2), stepY = max(3, b.height / 2 + 2)
        var offsets: [(Int, Int)] = []
        for ry in -3...3 { for rx in -3...3 where rx != 0 || ry != 0 { offsets.append((rx * stepX, ry * stepY)) } }
        offsets.sort { $0.0 * $0.0 + $0.1 * $0.1 < $1.0 * $1.0 + $1.1 * $1.1 }
        var best: (score: Float, dx: Int, dy: Int, shift: SIMD3<Float>)?
        for (dx, dy) in offsets {
            var valid = true, outside = 0, checked = 0
            var histogram = [Float](repeating: 0, count: 8)
            for k in Swift.stride(from: 0, to: pixels.count, by: checkStep) {
                let i = pixels[k]
                guard let c = clean(origin.0 + i % w + dx, origin.1 + i / w + dy) else { valid = false; break }
                checked += 1
                let l = luma(c)
                if l < lowLuma || l > highLuma { outside += 1 }
                histogram[min(7, max(0, Int(l / 32)))] += 1
            }
            guard valid, checked > 0, Double(outside) <= Double(checked) * 0.04 else { continue }
            let difference = zip(histogram, bandHistogram).reduce(Float(0)) { $0 + abs($1.0 / Float(checked) - $1.1) }
            guard difference <= 0.6 else { continue }
            var pairs: [(SIMD3<Float>, SIMD3<Float>)] = []
            pairs.reserveCapacity(band.count)
            for s in band { if let c = clean(s.x + dx, s.y + dy) { pairs.append((s.c, c)) } }
            guard Double(pairs.count) >= Double(band.count) * 0.6 else { continue }
            let sourceMean = pairs.reduce(SIMD3<Float>.zero) { $0 + $1.1 } / Float(pairs.count)
            let shift = targetMean - sourceMean
            var total: Float = 0
            for (t, c) in pairs {
                let d = t - (c + shift)
                total += abs(d.x) + abs(d.y) + abs(d.z)
            }
            // 평균 색이 크게 다른 곳(다른 색 물체)은 밝기만 맞춰 옮기면 엉뚱한 그림이 된다.
            guard (shift * shift).sum().squareRoot() <= 30 else { continue }
            let score = total / Float(pairs.count) / 3 + (shift * shift).sum().squareRoot() * 0.25
            if best == nil || score < best!.score { best = (score, dx, dy, shift) }
        }
        guard let best, best.score <= max(26, spread * 1.1) else { return false }
        for i in pixels {
            let x = origin.0 + i % w + best.dx, y = origin.1 + i / w + best.dy
            // 표본 확인에서 건너뛴 픽셀이 깨끗하지 않으면 원래 자리 근처 표본 평균으로 대신한다.
            color[i] = clean(x, y).map { $0 + best.shift } ?? targetMean
        }
        return true
    }
}
