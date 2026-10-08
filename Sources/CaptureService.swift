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

    /// Vision을 이용해 지정 언어로 텍스트 인식. 각 줄의 텍스트와 캡처 영역 내부 기준
    /// 정규화 바운딩 박스(원점 좌하단, 0...1)를 위→아래 순서로 정렬해 반환한다.
    static func recognizeText(in image: CGImage, language: AppLanguage) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = [language.visionRecognitionCode]

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        guard let observations = request.results else { return [] }
        let sorted = observations.sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }
        return sorted.enumerated().compactMap { index, observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return OCRLine(id: index, text: text, boundingBox: observation.boundingBox)
        }
    }
}
