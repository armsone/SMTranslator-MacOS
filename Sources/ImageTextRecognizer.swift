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

    /// 숫자·코드만 있는 등 번역해도 의미가 없는 조각은 오버레이/목록에서 뺀다.
    var hasMeaningfulLetters: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 2, !trimmed.hasPrefix("{"), !trimmed.hasPrefix("[") else { return false }
        if trimmed.hasPrefix("\""), trimmed.contains("\":") { return false }
        return trimmed.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }
}

enum ImageTextRecognizer {
    static let maxRegions = 150

    static func recognize(_ image: CGImage, assetID: String) async throws -> [OCRRegion] {
        guard image.width >= 24, image.height >= 24,
              Double(image.width) * Double(image.height) <= 120_000_000 else { return [] }
        try Task.checkCancellation()

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let lines: [(String, CGRect)] = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                try handler.perform([request])
                let observations = request.results ?? []
                return observations.compactMap { obs -> (String, CGRect)? in
                    guard let candidate = obs.topCandidates(1).first, candidate.confidence >= 0.3 else { return nil }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    let b = obs.boundingBox
                    return (text, CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
                }
            }.value
        } onCancel: {
            request.cancel()
        }
        try Task.checkCancellation()
        return group(lines, image: image, assetID: assetID)
    }

    /// 세로로 가깝고 왼쪽 정렬이 비슷한 줄을 하나의 문단으로 묶어 번역 품질을 높인다.
    private static func group(_ lines: [(String, CGRect)], image: CGImage, assetID: String) -> [OCRRegion] {
        let sorted = lines.sorted { a, b in
            abs(a.1.minY - b.1.minY) < min(a.1.height, b.1.height) * 0.5 ? a.1.minX < b.1.minX : a.1.minY < b.1.minY
        }
        var groups: [(text: String, box: CGRect, lastBox: CGRect)] = []
        for (text, box) in sorted {
            if let last = groups.last {
                let gap = box.minY - last.lastBox.maxY
                let heightRatio = box.height / max(last.lastBox.height, 0.0001)
                let alignedLeft = abs(box.minX - last.lastBox.minX) < 0.06
                let overlaps = box.minX < last.box.maxX && box.maxX > last.box.minX
                if gap >= -last.lastBox.height * 0.3, gap < last.lastBox.height * 0.9,
                   heightRatio > 0.65, heightRatio < 1.5, alignedLeft || overlaps {
                    let joiner = needsNoSpace(last.text.unicodeScalars.last, text.unicodeScalars.first) ? "" : " "
                    groups[groups.count - 1] = (last.text + joiner + text, last.box.union(box), box)
                    continue
                }
            }
            groups.append((text, box, box))
        }
        return groups.prefix(maxRegions).enumerated().map { index, g in
            let (bg, fg) = sampleColors(of: image, in: g.box)
            return OCRRegion(id: "\(assetID)#\(index)", text: g.text, box: g.box, backgroundHex: bg, foregroundHex: fg)
        }
    }

    /// 영역을 1x1 픽셀로 보간 축소해 평균 배경색을 근사하고, 밝기에 따라 읽기 좋은 글자색(검정/흰색)을 고른다.
    /// 원본 파일은 건드리지 않으며 이 샘플은 화면 표시용 오버레이 색상에만 쓰인다.
    private static func sampleColors(of image: CGImage, in box: CGRect) -> (background: String, foreground: String) {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let rect = CGRect(x: box.minX * w, y: box.minY * h, width: max(box.width * w, 1), height: max(box.height * h, 1))
            .intersection(CGRect(x: 0, y: 0, width: w, height: h)).integral
        guard rect.width >= 1, rect.height >= 1, let cropped = image.cropping(to: rect) else {
            return ("#FFFFFF", "#000000")
        }
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return ("#FFFFFF", "#000000")
        }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let r = Double(pixel[0]) / 255, g = Double(pixel[1]) / 255, b = Double(pixel[2]) / 255
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        let bg = String(format: "#%02X%02X%02X", pixel[0], pixel[1], pixel[2])
        let fg = luminance > 0.55 ? "#000000" : "#FFFFFF"
        return (bg, fg)
    }

    private static func needsNoSpace(_ a: Unicode.Scalar?, _ b: Unicode.Scalar?) -> Bool {
        guard let a, let b else { return false }
        return isCJK(a) && isCJK(b)
    }

    private static func isCJK(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF: return true
        default: return false
        }
    }
}
