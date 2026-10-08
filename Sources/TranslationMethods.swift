import Foundation
import Observation
import Translation

// 메일 번역과 화면 번역이 함께 쓰는 번역 방식 선택과 Apple 번역 구성.
// 선택값(방식 이름)만 UserDefaults에 저장하며, 고르는 것만으로는 아무 내용도 보내지 않는다.

extension TranslationBackend {
    /// 화면 번역 툴바처럼 좁은 곳에 쓰는 짧은 이름
    var shortTitle: String {
        switch self {
        case .system: return "Mac 기본"
        case .intelligence: return "Apple AI 우선"
        case .chatgpt, .claude, .gemini: return title
        case .deepl, .google, .papago: return webTranslator == .google ? "Google" : title
        }
    }

    /// macOS 26.4 이상에서는 방식별 전략(Mac 기본 = lowLatency, Apple Intelligence 우선 = highFidelity)을 지정하고,
    /// 그보다 낮은 macOS에서는 기존 기본 구성을 쓴다.
    func makeConfiguration(source: Locale.Language?, target: Locale.Language) -> TranslationSession.Configuration {
        if #available(macOS 26.4, *) {
            return TranslationSession.Configuration(source: source, target: target, preferredStrategy: strategy)
        }
        return TranslationSession.Configuration(source: source, target: target)
    }

    func makeLanguageAvailability() -> LanguageAvailability {
        if !isExternal, #available(macOS 26.4, *) {
            return LanguageAvailability(preferredStrategy: strategy)
        }
        return LanguageAvailability()
    }

    @available(macOS 26.4, *)
    var strategy: TranslationSession.Strategy {
        switch self {
        case .intelligence: return .highFidelity
        case .system, .chatgpt, .claude, .gemini, .deepl, .google, .papago: return .lowLatency
        }
    }
}

/// 외부 AI 전송 동의 문구. 제공사마다 한 번 묻고, 메일 번역과 화면 번역 모두에 적용된다.
enum ExternalConsent {
    static func message(for provider: AIProvider) -> String {
        "번역을 실행할 때만 아래 텍스트가 사용자가 로그인한 \(provider.title) 웹 계정의 대화로 전송됩니다.\n"
        + "• 메일 번역: 메일의 제목, 본문 텍스트, 이미지에서 인식한(OCR) 텍스트. 원본 HTML, 이미지 파일, 보낸 사람·받는 사람 주소는 보내지 않습니다.\n"
        + "• 화면 번역: 선택한 화면 영역에서 인식한(OCR) 글자. 스크린샷 이미지와 위치 정보는 보내지 않습니다.\n"
        + "보낸 내용은 \(provider.title) 대화 기록에 남을 수 있으며 해당 서비스의 정책이 적용됩니다. 방식이나 언어를 고르는 것만으로는 보내지 않습니다.\n\n"
        + "동의는 \(provider.title)에 대해 기억되어 다음 번역부터 다시 묻지 않습니다. 설정 › 외부 AI에서 언제든 철회할 수 있습니다."
    }
}

/// 앱 전체에서 하나뿐인 번역 방식 선택. 기본값은 Mac 기본 번역이다.
@MainActor
@Observable
final class TranslationBackendStore {
    static let shared = TranslationBackendStore()

    var backend: TranslationBackend {
        didSet {
            guard oldValue != backend else { return }
            UserDefaults.standard.set(backend.rawValue, forKey: TranslationBackend.defaultsKey)
            for observer in observers { observer(oldValue, backend) }
        }
    }

    @ObservationIgnored private var observers: [(TranslationBackend, TranslationBackend) -> Void] = []

    private init() {
        let stored = UserDefaults.standard.string(forKey: TranslationBackend.defaultsKey)
            .flatMap(TranslationBackend.init(rawValue:)) ?? .system
        backend = stored == .intelligence && !TranslationBackend.intelligenceSupported ? .system : stored
    }

    /// 방식이 바뀔 때(이전 값, 새 값) 호출된다. 메일 모델과 화면 모델이 각자 진행 중 작업을 정리한다.
    func observe(_ observer: @escaping (TranslationBackend, TranslationBackend) -> Void) {
        observers.append(observer)
    }
}
