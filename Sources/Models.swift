import Foundation
import Translation

/// 앱이 지원하는 언어 목록 (요구사항 최소 4개: 영어, 일본어, 중국어 간체, 한국어)
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case japanese = "ja"
    case chineseSimplified = "zh-Hans"
    case korean = "ko"

    var id: String { rawValue }

    var displayNameKorean: String {
        switch self {
        case .english: return "영어"
        case .japanese: return "일본어"
        case .chineseSimplified: return "중국어 (간체)"
        case .korean: return "한국어"
        }
    }

    /// Translation.Locale.Language 변환
    var localeLanguage: Locale.Language {
        Locale.Language(identifier: rawValue)
    }

    /// Vision OCR 인식 언어 코드
    var visionRecognitionCode: String {
        switch self {
        case .english: return "en-US"
        case .japanese: return "ja-JP"
        case .chineseSimplified: return "zh-Hans"
        case .korean: return "ko-KR"
        }
    }
}

enum AppStatus: Equatable {
    case idle
    case capturing
    case recognizing
    case translating(done: Int, total: Int)
    case completed
    case showingOriginal
    case info(String)
    case error(String)

    var koreanText: String {
        switch self {
        case .idle: return "캡처·번역을 눌러 시작하세요"
        case .capturing: return "화면 캡처 중"
        case .recognizing: return "텍스트 인식 중"
        case .translating(let done, let total): return "번역 중 (\(done)/\(total)줄)"
        case .completed: return "완료"
        case .showingOriginal: return "원문 표시 중"
        case .info(let message): return message
        case .error(let message): return message
        }
    }

    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

/// 주 버튼(가장 오른쪽)의 현재 동작. 번역이 모두 성공한 결과가 있을 때만
/// '원문보기'가 되고, 원문을 보여준 뒤에는 다시 '캡처·번역'으로 돌아온다.
enum PrimaryAction {
    case captureAndTranslate
    case showOriginal

    var title: String {
        switch self {
        case .captureAndTranslate: return "캡처·번역"
        case .showOriginal: return "원문보기"
        }
    }

    var systemImage: String {
        switch self {
        case .captureAndTranslate: return "camera.viewfinder"
        case .showOriginal: return "photo"
        }
    }
}

/// Vision이 인식한 한 줄의 원문 텍스트와 위치(바운딩 박스).
/// boundingBox는 Vision 정규화 좌표(원점 좌하단, 0...1, 캡처한 영역 내부 기준)이다.
struct OCRLine: Identifiable {
    let id: Int
    let text: String
    let boundingBox: CGRect
}

/// 화면에 그릴 번역 패치: 원문 줄의 위치에 번역문을 겹쳐 그리기 위한 단위.
struct TranslatedPatch: Identifiable {
    let id: Int
    let translatedText: String
    let boundingBox: CGRect
}

/// .translationTask 클로저에 전달되는 한 번의 스트리밍 배치 번역 작업.
/// clientIdentifier는 "세대:줄ID" 형식이라 응답 순서가 달라도 원래 줄(바운딩
/// 박스)에 정확히 대응된다.
struct TranslationJob {
    let generation: Int
    let requests: [TranslationSession.Request]
}
