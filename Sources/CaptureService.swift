import AppKit
import ScreenCaptureKit
import Vision

enum CaptureError: LocalizedError {
    case noMatchingDisplay
    case spansMultipleDisplays
    case regionTooSmall
    case permissionDenied
    case screenshotFailed(String)
    case shareableContentFailed(domain: String, code: Int, description: String)

    var errorDescription: String? {
        switch self {
        case .noMatchingDisplay:
            return "영역이 위치한 화면을 찾을 수 없습니다."
        case .spansMultipleDisplays:
            return "영역이 여러 디스플레이에 걸쳐 있습니다. 하나의 화면 안으로 영역을 이동해주세요."
        case .regionTooSmall:
            return "선택한 영역이 너무 작습니다."
        case .permissionDenied:
            return "화면 기록 권한이 필요합니다. 시스템 설정 > 개인정보 보호 및 보안 > 화면 기록에서 이 앱을 허용한 뒤 다시 시도해주세요."
        case .screenshotFailed(let reason):
            return "화면 캡처에 실패했습니다: \(reason)"
        case .shareableContentFailed(let domain, let code, let description):
            return "화면 콘텐츠 조회에 실패했습니다 (\(domain) \(code)): \(description)"
        }
    }
}

/// 상태 없는 캡처+OCR 헬퍼. SCScreenshotManager로 지정 영역만 캡처하고
/// Vision으로 텍스트를 인식한다. 캡처한 이미지/텍스트는 저장하거나
/// 외부로 전송하지 않고 메모리에서만 즉시 사용 후 버려진다.
enum CaptureService {

    /// 시스템 프롬프트 없이 현재 화면 기록 권한 상태만 확인한다.
    static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 아직 결정되지 않은 경우에만 시스템 권한 다이얼로그를 띄운다. 이미 허용/거부된
    /// 상태라면 다이얼로그 없이 현재 상태를 즉시 반환한다. 호출자가 명시적 사용자
    /// 동작(시작 버튼 등) 시점에만 호출해 반복 프롬프트를 피해야 한다.
    static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// AppKit 전역 좌표(원점 좌하단) 사각형을 캡처해 CGImage로 반환
    static func captureRegion(globalFrame: NSRect, excludingWindowNumbers: [Int]) async throws -> CGImage {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(globalFrame) }) else {
            throw CaptureError.noMatchingDisplay
        }

        // 영역이 선택된 화면 안에 완전히 들어가는지 확인 (다중 디스플레이 걸침 방지)
        guard screen.frame.contains(globalFrame) else {
            throw CaptureError.spansMultipleDisplays
        }

        guard globalFrame.width >= 10, globalFrame.height >= 10 else {
            throw CaptureError.regionTooSmall
        }

        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw CaptureError.noMatchingDisplay
        }
        let displayID = CGDirectDisplayID(screenNumber.uint32Value)

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch let error as SCStreamError where error.code == .userDeclined {
            throw CaptureError.permissionDenied
        } catch {
            let nsError = error as NSError
            throw CaptureError.shareableContentFailed(
                domain: nsError.domain,
                code: nsError.code,
                description: nsError.localizedDescription
            )
        }

        guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.noMatchingDisplay
        }

        let excludedWindows = content.windows.filter { excludingWindowNumbers.contains(Int($0.windowID)) }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: excludedWindows)

        // AppKit(좌하단 원점) -> 디스플레이 로컬 top-left 원점 좌표 변환 (points 단위)
        let localX = globalFrame.minX - screen.frame.minX
        let localYTopLeft = screen.frame.maxY - globalFrame.maxY
        let sourceRect = CGRect(x: localX, y: localYTopLeft, width: globalFrame.width, height: globalFrame.height)

        let scale = screen.backingScaleFactor
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = max(1, Int(sourceRect.width * scale))
        configuration.height = max(1, Int(sourceRect.height * scale))
        configuration.showsCursor = false
        configuration.scalesToFit = false
        if #available(macOS 14.2, *) {
            configuration.captureResolution = .best
        }

        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch let error as SCStreamError where error.code == .userDeclined {
            throw CaptureError.permissionDenied
        } catch {
            throw CaptureError.screenshotFailed(error.localizedDescription)
        }
    }

    /// 텍스트 인식. mac26+에서는 공용 DocumentTextRecognizer로 문서 구조(문단) 단위 인식을
    /// 먼저 시도해 세로쓰기 등 문단 내 줄 순서를 그대로 보존한다(다시 y좌표로 정렬하거나
    /// 재묶지 않음). 취소는 그대로 전파하고, 그 외 실패나 빈 결과는 기존 VNRecognizeTextRequest
    /// 레거시 경로(mac15~25, 또는 문서 인식이 지원하지 않는 콘텐츠)로 폴백한다.
    static func recognizeText(in image: CGImage, source: SourceSelection) async throws -> [OCRLine] {
        if #available(macOS 26.0, *) {
            do {
                let recognitionLanguages = source.language.map { [$0.localeLanguage] }
                let paragraphs = try await DocumentTextRecognizer.recognizeParagraphs(in: image, recognitionLanguages: recognitionLanguages)
                try Task.checkCancellation()
                if !paragraphs.isEmpty {
                    return paragraphs.enumerated().map { index, paragraph in
                        OCRLine(id: index, text: paragraph.text, boundingBox: paragraph.box)
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 문서 인식 실패(미지원 콘텐츠 등) -> 아래 레거시 경로로 폴백
            }
        }
        return try recognizeTextLegacy(in: image, source: source)
    }

    /// Vision을 이용해 텍스트 인식(mac15~25 및 문서 인식 폴백 경로). 각 줄의 텍스트와 캡처 영역
    /// 내부 기준 정규화 바운딩 박스(원점 좌하단, 0...1)를 위→아래 순서로 정렬해 반환한다.
    /// 원문 언어를 직접 골랐으면 그 언어로 고정하고, 자동 인식이면 Vision이 알맞은 인식 모델·언어 보정을
    /// 고르게 하며(automaticallyDetectsLanguage) 우선순위 목록은 이 기기가 지원하는 언어만 넘긴다.
    private static func recognizeTextLegacy(in image: CGImage, source: SourceSelection) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        if let language = source.language {
            request.recognitionLanguages = [language.visionRecognitionCode]
            try handler.perform([request])
        } else {
            request.automaticallyDetectsLanguage = true
            let supported = Set((try? request.supportedRecognitionLanguages()) ?? [])
            let preferred = SourceSelection.automaticRecognitionCodes.filter(supported.contains)
            if !preferred.isEmpty { request.recognitionLanguages = preferred }
            do {
                try handler.perform([request])
            } catch where !preferred.isEmpty {
                // 우선순위 목록 조합을 받아들이지 않으면 목록 없이 자동 인식만으로 한 번 더 시도한다.
                let fallback = VNRecognizeTextRequest()
                fallback.recognitionLevel = .accurate
                fallback.usesLanguageCorrection = true
                fallback.automaticallyDetectsLanguage = true
                try handler.perform([fallback])
                return sortedLines(fallback.results)
            }
        }
        return sortedLines(request.results)
    }

    private static func sortedLines(_ observations: [VNRecognizedTextObservation]?) -> [OCRLine] {
        guard let observations else { return [] }
        let sorted = observations.sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }
        return sorted.enumerated().compactMap { index, observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return OCRLine(id: index, text: text, boundingBox: observation.boundingBox)
        }
    }

    // MARK: - 줄별 배경색 추출(번역 패치 자동 배경색/글자색용)

    private struct RGBABuffer {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let bytesPerPixel: Int
        let data: [UInt8]
    }

    /// 캡처 이미지를 한 번만 디코딩해 RGBA8 픽셀 버퍼로 만든다(캡처당 1회).
    private static func makeRGBABuffer(_ image: CGImage) -> RGBABuffer? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // CGContext로 다시 그려 픽셀 포맷(채널 순서·정렬)을 고정한다. 버퍼의 첫 행이
        // 이미지 맨 위 행과 같아, Vision의 좌하단 원점 bbox를 위→아래로 뒤집어 맞춘다.
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return RGBABuffer(width: width, height: height, bytesPerRow: bytesPerRow, bytesPerPixel: bytesPerPixel, data: data)
    }

    private static func median(_ values: [UInt8]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return CGFloat(sorted[sorted.count / 2]) / 255.0
    }

    /// 한 OCR 줄의 정규화 바운딩 박스(원점 좌하단) 바로 바깥 가장자리 테두리만 샘플해
    /// 배경 대표색을 구한다. 타이트 박스 내부(글자 획일 가능성이 높음)는 제외하고,
    /// 가장자리 픽셀들의 채널별 중앙값을 사용해 이상치(획이 테두리에 닿은 경우)에 강하다.
    private static func sampleBackgroundColor(for normalizedBox: CGRect, in buffer: RGBABuffer) -> RGBColor? {
        let width = buffer.width, height = buffer.height
        let minX = Int((normalizedBox.minX * CGFloat(width)).rounded(.down))
        let maxX = Int((normalizedBox.maxX * CGFloat(width)).rounded(.up))
        // Vision bbox는 좌하단 원점, 버퍼는 이미지 맨 위가 0행이므로 y를 뒤집는다.
        let topY = Int(((1 - normalizedBox.maxY) * CGFloat(height)).rounded(.down))
        let bottomY = Int(((1 - normalizedBox.minY) * CGFloat(height)).rounded(.up))

        let marginX = max(2, (maxX - minX) / 10)
        let marginY = max(2, (bottomY - topY) / 6)
        let outerMinX = max(0, minX - marginX)
        let outerMaxX = min(width - 1, maxX + marginX)
        let outerTopY = max(0, topY - marginY)
        let outerBottomY = min(height - 1, bottomY + marginY)
        guard outerMaxX > outerMinX, outerBottomY > outerTopY else { return nil }

        var reds: [UInt8] = [], greens: [UInt8] = [], blues: [UInt8] = []

        func sample(_ x: Int, _ y: Int) {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            if x > minX, x < maxX, y > topY, y < bottomY { return } // 타이트 박스 내부(글자) 제외
            let offset = y * buffer.bytesPerRow + x * buffer.bytesPerPixel
            guard offset + 2 < buffer.data.count else { return }
            reds.append(buffer.data[offset])
            greens.append(buffer.data[offset + 1])
            blues.append(buffer.data[offset + 2])
        }

        let xStep = max(1, (outerMaxX - outerMinX) / 24)
        var x = outerMinX
        while x <= outerMaxX {
            sample(x, outerTopY)
            sample(x, outerBottomY)
            x += xStep
        }
        let yStep = max(1, (outerBottomY - outerTopY) / 12)
        var y = outerTopY
        while y <= outerBottomY {
            sample(outerMinX, y)
            sample(outerMaxX, y)
            y += yStep
        }

        guard let r = median(reds), let g = median(greens), let b = median(blues) else { return nil }
        return RGBColor(red: r, green: g, blue: b)
    }

    /// 캡처 이미지를 한 번만 픽셀 버퍼로 만들고, OCR 줄마다 한 번씩만 배경색을 샘플한다.
    /// 추출 실패(샘플 없음 등)한 줄은 결과에서 빠지며, 호출 쪽이 중립색으로 대체한다.
    static func sampleBackgroundColors(in image: CGImage, lines: [OCRLine]) -> [Int: RGBColor] {
        guard let buffer = makeRGBABuffer(image) else { return [:] }
        var result: [Int: RGBColor] = [:]
        for line in lines {
            if let color = sampleBackgroundColor(for: line.boundingBox, in: buffer) {
                result[line.id] = color
            }
        }
        return result
    }
}
