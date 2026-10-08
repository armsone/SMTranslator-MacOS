import CoreGraphics
import Foundation
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
    /// 원본 글자 획의 가벼운 통계로 추정한 글꼴 갈래("gothic"/"myeongjo"/"hand"). 표본이 부족하거나
    /// 애매하면 nil(미판별 -> 호출자가 고딕으로 대체). 정확한 글꼴 식별이 아니라 거친 추정일 뿐이다.
    let fontStyle: String?

    init(id: String, text: String, box: CGRect, backgroundHex: String, foregroundHex: String, glyphBoxes: [CGRect] = [],
         fontStyle: String? = nil) {
        self.id = id
        self.text = text
        self.box = box
        self.backgroundHex = backgroundHex
        self.foregroundHex = foregroundHex
        self.glyphBoxes = glyphBoxes
        self.fontStyle = fontStyle
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

    static func recognize(_ image: CGImage, assetID: String) async throws -> [OCRRegion] {
        guard image.width >= 24, image.height >= 24,
              Double(image.width) * Double(image.height) <= 120_000_000 else { return [] }
        try Task.checkCancellation()

        // mac26+에서는 문서 구조(문단) 단위 인식을 먼저 시도해 세로쓰기 줄 순서를 보존한다.
        // 취소는 그대로 전파하고, 그 외 실패(비어있는 결과 포함)는 기존 Vision 경로로 폴백한다.
        if #available(macOS 26.0, *) {
            do {
                let paragraphs = try await DocumentTextRecognizer.recognizeParagraphs(in: image)
                if !paragraphs.isEmpty {
                    return documentRegions(paragraphs, image: image, assetID: assetID)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 문서 인식 실패(미지원 콘텐츠 등) -> 아래 레거시 경로로 폴백
            }
        }

        return try await recognizeLegacy(image, assetID: assetID)
    }

    /// 문서 인식 결과를 그대로 영역으로 변환한다. 이미 올바른 문단 단위(세로쓰기 줄 순서 포함)로
    /// 나뉘어 있으므로 레거시 가로 그룹 로직을 다시 적용하지 않는다.
    @available(macOS 26.0, *)
    private static func documentRegions(_ paragraphs: [DocumentTextParagraph], image: CGImage, assetID: String) -> [OCRRegion] {
        paragraphs.prefix(maxRegions).enumerated().map { index, paragraph in
            let b = paragraph.box
            let box = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
            let glyphBoxes = paragraph.glyphBoxes.map { g in
                CGRect(x: g.minX, y: 1 - g.maxY, width: g.width, height: g.height)
            }
            let (bg, fg) = sampleColors(of: image, in: box)
            let fontStyle = classifyFontStyle(of: image, glyphBoxes: glyphBoxes)
            return OCRRegion(id: "\(assetID)#\(index)", text: paragraph.text, box: box, backgroundHex: bg, foregroundHex: fg,
                              glyphBoxes: glyphBoxes, fontStyle: fontStyle)
        }
    }

    private static func recognizeLegacy(_ image: CGImage, assetID: String) async throws -> [OCRRegion] {
        try Task.checkCancellation()

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let lines: [(String, CGRect, [CGRect])] = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                try handler.perform([request])
                let observations = request.results ?? []
                return observations.compactMap { obs -> (String, CGRect, [CGRect])? in
                    guard let candidate = obs.topCandidates(1).first, candidate.confidence >= 0.3 else { return nil }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    let b = obs.boundingBox
                    let box = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
                    return (text, box, glyphBoxes(of: candidate))
                }
            }.value
        } onCancel: {
            request.cancel()
        }
        try Task.checkCancellation()
        return group(lines, image: image, assetID: assetID)
    }

    /// 세로로 가깝고 왼쪽 정렬이 비슷한 줄을 하나의 문단으로 묶어 번역 품질을 높인다.
    /// 글자 상자는 묶이는 줄 순서대로 그대로 이어붙일 뿐 다시 의미 단위로 재구성하지 않는다.
    private static func group(_ lines: [(String, CGRect, [CGRect])], image: CGImage, assetID: String) -> [OCRRegion] {
        let sorted = lines.sorted { a, b in
            abs(a.1.minY - b.1.minY) < min(a.1.height, b.1.height) * 0.5 ? a.1.minX < b.1.minX : a.1.minY < b.1.minY
        }
        var groups: [(text: String, box: CGRect, lastBox: CGRect, glyphBoxes: [CGRect])] = []
        for (text, box, glyphs) in sorted {
            if let last = groups.last {
                let gap = box.minY - last.lastBox.maxY
                let heightRatio = box.height / max(last.lastBox.height, 0.0001)
                let alignedLeft = abs(box.minX - last.lastBox.minX) < 0.06
                let overlaps = box.minX < last.box.maxX && box.maxX > last.box.minX
                if gap >= -last.lastBox.height * 0.3, gap < last.lastBox.height * 0.9,
                   heightRatio > 0.65, heightRatio < 1.5, alignedLeft || overlaps {
                    let joiner = needsNoSpace(last.text.unicodeScalars.last, text.unicodeScalars.first) ? "" : " "
                    let remaining = maxGlyphsPerItem - last.glyphBoxes.count
                    let mergedGlyphs = remaining > 0 ? last.glyphBoxes + glyphs.prefix(remaining) : last.glyphBoxes
                    groups[groups.count - 1] = (last.text + joiner + text, last.box.union(box), box, mergedGlyphs)
                    continue
                }
            }
            groups.append((text, box, box, Array(glyphs.prefix(maxGlyphsPerItem))))
        }
        return groups.prefix(maxRegions).enumerated().map { index, g in
            let (bg, fg) = sampleColors(of: image, in: g.box)
            let fontStyle = classifyFontStyle(of: image, glyphBoxes: g.glyphBoxes)
            return OCRRegion(id: "\(assetID)#\(index)", text: g.text, box: g.box, backgroundHex: bg, foregroundHex: fg,
                              glyphBoxes: g.glyphBoxes, fontStyle: fontStyle)
        }
    }

    /// candidate의 string에서 공백이 아닌 글자마다 boundingBox(for:)로 잉크 상자를 구한다. 범위를 못 구한
    /// 글자는 건너뛸 뿐(문단 전체를 지우는 폴백은 쓰지 않음) 결과 개수는 최대 maxGlyphsPerItem개로 제한한다.
    static func glyphBoxes(of candidate: VNRecognizedText) -> [CGRect] {
        let transcript = candidate.string
        var boxes: [CGRect] = []
        var index = transcript.startIndex
        while index < transcript.endIndex, boxes.count < maxGlyphsPerItem {
            let next = transcript.index(after: index)
            if !transcript[index].isWhitespace, let rect = try? candidate.boundingBox(for: index..<next) {
                let b = rect.boundingBox
                let box = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
                if let clamped = clampedUnitBox(box) { boxes.append(clamped) }
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

        let avgIrregularity = irregularities.reduce(0, +) / Double(irregularities.count)
        let avgWidthCV = widthCVs.reduce(0, +) / Double(widthCVs.count)
        if avgIrregularity > 0.42 { return "hand" }
        if avgWidthCV > 0.55 { return "myeongjo" }
        return "gothic"
    }

    /// 작은 흑백 그리드로 내려 찍어 획 두께 변동계수(가로 run-length 분산)와 가장자리 불규칙성(연속한
    /// 행에서 획 시작 위치가 얼마나 들쭉날쭉한지)을 잰다. 정밀한 글자 모양 분석이 아니라 대략적 통계이며,
    /// 오탐이 있을 수 있다(수동으로 고를 수 있어야 하는 이유).
    private static func strokeStats(of image: CGImage) -> (widthCV: Double, edgeIrregularity: Double)? {
        let grid = 24
        var pixels = [UInt8](repeating: 0, count: grid * grid * 4)
        guard let ctx = CGContext(data: &pixels, width: grid, height: grid, bitsPerComponent: 8, bytesPerRow: grid * 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: grid, height: grid))

        func luminance(_ x: Int, _ y: Int) -> Double {
            let idx = (y * grid + x) * 4
            let a = Double(pixels[idx + 3]) / 255
            guard a > 0.05 else { return 1 } // 투명은 배경으로 본다
            let r = min(Double(pixels[idx]) / 255 / a, 1), g = min(Double(pixels[idx + 1]) / 255 / a, 1),
                b = min(Double(pixels[idx + 2]) / 255 / a, 1)
            return 0.299 * r + 0.587 * g + 0.114 * b
        }
        var total = 0.0
        for y in 0..<grid { for x in 0..<grid { total += luminance(x, y) } }
        let mean = total / Double(grid * grid)
        func isInk(_ x: Int, _ y: Int) -> Bool { luminance(x, y) < mean - 0.12 }

        var runWidths: [Double] = []
        var previousStart: Int?
        var edgeShifts: [Double] = []
        for y in 0..<grid {
            var x = 0
            var firstStart: Int?
            while x < grid {
                if isInk(x, y) {
                    let start = x
                    if firstStart == nil { firstStart = start }
                    var end = x
                    while end < grid, isInk(end, y) { end += 1 }
                    runWidths.append(Double(end - start))
                    x = end
                } else {
                    x += 1
                }
            }
            if let start = firstStart {
                if let previousStart { edgeShifts.append(Double(abs(start - previousStart))) }
                previousStart = start
            }
        }
        guard runWidths.count >= 3 else { return nil }
        let meanWidth = runWidths.reduce(0, +) / Double(runWidths.count)
        guard meanWidth > 0 else { return nil }
        let variance = runWidths.reduce(0.0) { $0 + ($1 - meanWidth) * ($1 - meanWidth) } / Double(runWidths.count)
        let widthCV = variance.squareRoot() / meanWidth
        let edgeIrregularity = edgeShifts.isEmpty ? 0 : (edgeShifts.reduce(0, +) / Double(edgeShifts.count)) / Double(grid)
        return (widthCV, edgeIrregularity)
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
