import Foundation
import Translation
import AppKit
import NaturalLanguage

/// 앱이 지원하는 언어 목록 (요구사항 최소 4개: 영어, 일본어, 중국어 간체, 한국어)
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case japanese = "ja"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"
    case korean = "ko"

    var id: String { rawValue }

    var displayNameKorean: String {
        switch self {
        case .english: return "영어"
        case .japanese: return "일본어"
        case .chineseSimplified: return "중국어 (간체)"
        case .chineseTraditional: return "중국어 (번체)"
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
        case .chineseTraditional: return "zh-Hant"
        case .korean: return "ko-KR"
        }
    }
}

/// 화면 번역 원문 언어 선택. 기본값은 자동 인식이며, 언어를 직접 고르면 지금처럼 그 언어로 고정한다.
/// 번역 언어(대상)는 자동 인식 없이 AppLanguage로만 고른다.
enum SourceSelection: Hashable, Identifiable {
    case automatic
    case language(AppLanguage)

    static let allCases: [SourceSelection] = [.automatic] + AppLanguage.allCases.map { .language($0) }

    /// 자동 인식 때 Vision OCR에 넘기는 우선순위 목록(기기가 지원하는 것만 걸러서 쓴다).
    static let automaticRecognitionCodes = ["ja-JP", "en-US", "zh-Hans", "zh-Hant", "ko-KR"]

    var id: String { languageID }

    /// 직접 고른 언어. 자동 인식이면 nil.
    var language: AppLanguage? {
        if case .language(let language) = self { return language }
        return nil
    }

    /// 외부 AI 요청문에 넘기는 원문 언어 ID. 자동 인식은 "auto"(항목마다 언어를 판별하라고 지시).
    var languageID: String { language?.rawValue ?? "auto" }

    var displayNameKorean: String { language?.displayNameKorean ?? "자동 인식" }
}

enum AppStatus: Equatable {
    case idle
    case capturing
    case recognizing
    /// skipped: 언어를 판별하지 못했거나 지원되지 않아 원문 그대로 둔(번역 요청을 보내지 않은) 줄 수.
    case translating(done: Int, total: Int, skipped: Int = 0)
    /// 외부 AI(웹 로그인) 번역 진행: 단계, 답변 대기 남은 시간(생성 확인 뒤에만), 완료 줄 수
    case externalTranslating(provider: String, stage: String, remaining: TimeInterval?, done: Int, total: Int)
    case completed(skipped: Int = 0)
    case showingOriginal
    case info(String)
    case error(String)

    var koreanText: String {
        switch self {
        case .idle: return "번역을 눌러 시작하세요"
        case .capturing: return "화면 캡처 중"
        case .recognizing: return "텍스트 인식 중"
        case .translating(let done, let total, let skipped):
            let suffix = skipped > 0 ? " (언어 미판별 \(skipped)줄 원문 유지)" : ""
            return "번역 중 (\(done)/\(total)줄)" + suffix
        case .externalTranslating(let provider, let stage, let remaining, let done, let total):
            var text = "\(provider) · \(stage)"
            if let remaining {
                let seconds = Int(max(0, remaining).rounded(.down))
                text += " · 남은 시간 \(seconds / 60):\(String(format: "%02d", seconds % 60))"
            }
            return text + " (\(done)/\(total)줄)"
        case .completed(let skipped):
            return skipped > 0 ? "완료(언어 미판별 \(skipped)줄 원문 유지) · Space/Enter: 원문보기" : "완료 · Space/Enter: 원문보기"
        case .showingOriginal: return "원문 표시 중 · Space: 저장된 번역 · Enter: 새로 번역"
        case .info(let message): return message
        case .error(let message): return message
        }
    }

    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

/// 주 버튼(제목 스트립 오른쪽)·Enter·메뉴의 현재 동작. 번역이 모두 성공한 결과가 보일 때만
/// '원문보기'가 되고, 원문을 보여준 뒤에는 다시 '번역'(새 캡처·번역)으로 돌아온다.
/// Space의 저장된 번역↔원본 전환은 이 값과 별도로 AppViewModel.performCachedToggle이 처리한다.
enum PrimaryAction {
    case captureAndTranslate
    case showOriginal

    var title: String {
        switch self {
        case .captureAndTranslate: return "번역"
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
    /// 원본 글자 획 통계로 추정한 글꼴 갈래("gothic"/"myeongjo"/"hand"). 표본 부족·애매함이면 nil(미판별).
    var fontStyleHint: String? = nil
}

/// 0...1 범위 RGB. 캡처 이미지에서 추출한 배경색을 가볍게 들고 다니기 위한 값 타입.
struct RGBColor: Equatable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat

    /// ITU-R BT.601 명도 근사값(0...1). 배경 밝기에 따라 검정/흰색 글자를 고르는 데 쓴다.
    var luminance: CGFloat { 0.299 * red + 0.587 * green + 0.114 * blue }

    var nsColor: NSColor { NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1) }

    /// 실제 픽셀 추출이 불가능할 때 쓰는 중립 배경색 대체값(라이트/다크 모드별).
    static func neutralFallback(isDark: Bool) -> RGBColor {
        isDark ? RGBColor(red: 0.12, green: 0.12, blue: 0.12) : RGBColor(red: 0.96, green: 0.96, blue: 0.96)
    }
}

/// 화면에 그릴 번역 패치: 원문 줄의 위치에 번역문을 겹쳐 그리기 위한 단위.
struct TranslatedPatch: Identifiable {
    let id: Int
    let translatedText: String
    let boundingBox: CGRect
    /// 캡처 이미지에서 추출한 원문 줄 배경색. 추출 실패 시 nil(뷰가 중립색으로 대체).
    var autoBackgroundColor: RGBColor?
    /// 원본 글자 획 통계로 추정한 글꼴 갈래("gothic"/"myeongjo"/"hand"). 표본 부족·애매함이면 nil(미판별 -> 고딕).
    var fontStyleHint: String? = nil
}

/// 번역 패치의 글자색/배경색/진하기 사용자 설정. UserDefaults에 비민감 값만 저장한다.
struct PatchColorSettings: Equatable {
    static let defaultOpacity: Double = 0.95

    /// true면 캡처 이미지에서 추출한 배경색 + 명도 대비 자동 글자색을 쓴다.
    var useAutoColors: Bool = true
    var manualBackgroundColor: RGBColor = RGBColor(red: 0.96, green: 0.96, blue: 0.96)
    var manualTextColor: RGBColor = RGBColor(red: 0, green: 0, blue: 0)
    /// 패치 배경 불투명도 0...1 (기본 95%). 자동/수동 모드 모두에 적용된다.
    var backgroundOpacity: Double = defaultOpacity
    /// 번역문 글꼴(고딕/명조/손글씨). 자동은 원본 글자 획 특징으로 고른다.
    var fontStyle: FontStyle = .auto

    private enum Keys {
        static let useAuto = "PatchColor.useAutoColors"
        static let bgR = "PatchColor.manualBackgroundRed"
        static let bgG = "PatchColor.manualBackgroundGreen"
        static let bgB = "PatchColor.manualBackgroundBlue"
        static let textR = "PatchColor.manualTextRed"
        static let textG = "PatchColor.manualTextGreen"
        static let textB = "PatchColor.manualTextBlue"
        static let opacity = "PatchColor.backgroundOpacity"
        static let fontStyle = "PatchColor.fontStyle"
    }

    static func loadFromDefaults() -> PatchColorSettings {
        let d = UserDefaults.standard
        var settings = PatchColorSettings()
        if d.object(forKey: Keys.useAuto) != nil { settings.useAutoColors = d.bool(forKey: Keys.useAuto) }
        if d.object(forKey: Keys.opacity) != nil { settings.backgroundOpacity = d.double(forKey: Keys.opacity) }
        if d.object(forKey: Keys.bgR) != nil {
            settings.manualBackgroundColor = RGBColor(
                red: d.double(forKey: Keys.bgR), green: d.double(forKey: Keys.bgG), blue: d.double(forKey: Keys.bgB))
        }
        if d.object(forKey: Keys.textR) != nil {
            settings.manualTextColor = RGBColor(
                red: d.double(forKey: Keys.textR), green: d.double(forKey: Keys.textG), blue: d.double(forKey: Keys.textB))
        }
        settings.fontStyle = FontStyle.validated(d.string(forKey: Keys.fontStyle))
        return settings
    }

    func saveToDefaults() {
        let d = UserDefaults.standard
        d.set(useAutoColors, forKey: Keys.useAuto)
        d.set(backgroundOpacity, forKey: Keys.opacity)
        d.set(manualBackgroundColor.red, forKey: Keys.bgR)
        d.set(manualBackgroundColor.green, forKey: Keys.bgG)
        d.set(manualBackgroundColor.blue, forKey: Keys.bgB)
        d.set(manualTextColor.red, forKey: Keys.textR)
        d.set(manualTextColor.green, forKey: Keys.textG)
        d.set(manualTextColor.blue, forKey: Keys.textB)
        d.set(fontStyle.rawValue, forKey: Keys.fontStyle)
    }
}

/// .translationTask 클로저에 전달되는 한 번의 스트리밍 번역 작업.
/// clientIdentifier는 "세대:줄ID" 형식이라 응답 순서가 달라도 원래 줄(바운딩
/// 박스)에 정확히 대응된다. 원문 언어를 직접 고르면 묶음은 하나이고, 자동 인식이면
/// 감지한 언어별로 묶음을 나눈다(한 묶음에는 한 언어만, 언어 미상 줄은 한 줄씩).
struct TranslationJob {
    let generation: Int
    let batches: [[TranslationSession.Request]]
}

/// 줄·문단 단위 원문 언어 추정(화면 번역 자동 인식, 메일 짧은 단위 보정 공용).
/// 단어 단위로 쪼개지 않고 한 줄(문단)을 한 언어로 본다. 추정은 완벽하지 않으며,
/// 정하지 못한 줄은 특정 언어로 억지로 넣지 않고 '언어 미상'으로 둔다.
enum LanguageDetection {
    enum Script { case latin, han }

    enum Result: Equatable {
        /// 글자가 없음(숫자·기호만). 번역하지 않고 그대로 둔다.
        case noLetters
        case language(String)
        /// 짧은 라틴 문자 줄·한자만 있는 줄처럼 같은 캡처(문서)의 다른 줄을 보고 정할 줄. guess는 단독 추정값.
        case ambiguous(Script, guess: String?)
        case unknown
    }

    static func classify(_ text: String) -> Result {
        var kana = 0, hangul = 0, han = 0, latin = 0, other = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: kana += 1
            case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7AF: hangul += 1
            case 0x3005, 0x3007, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3134F: han += 1
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF, 0xFF21...0xFF3A, 0xFF41...0xFF5A: latin += 1
            default: other += 1
            }
        }
        guard kana + hangul + han + latin + other > 0 else { return .noLetters }
        // 가나·한글은 각각 일본어·한국어에만 쓰이므로 아주 짧은 줄에서도 강한 단서로 쓴다.
        if kana > 0 && kana >= hangul { return .language("ja") }
        if hangul > 0 { return .language("ko") }
        let sample = String(text.prefix(2000))
        if han > 0 && han >= latin + other {
            // 한자만 있는 줄은 일본어·중국어를 가리기 어렵다. 길고 확실할 때만 정하고 나머지는 주변 줄에 맡긴다.
            let guess = hypothesis(sample, constraints: [.japanese, .simplifiedChinese, .traditionalChinese])
            if han >= 12, let guess, guess.confidence >= 0.8 { return .language(guess.key) }
            // 짧아도(han>=4) 중국어로 매우 강하게 판별되면 같은 캡처의 일본어 다수 줄에 묻혀 지워지지 않도록
            // 바로 확정한다(resolveAmbiguous의 일본어 전용 강한 문맥이 이 확정 줄을 덮어쓰지 않게 함).
            if han >= 4, let guess, Locale.Language(identifier: guess.key).languageCode?.identifier == "zh",
               guess.confidence >= 0.95 { return .language(guess.key) }
            return .ambiguous(.han, guess: (guess?.confidence ?? 0) >= 0.6 ? guess?.key : nil)
        }
        if latin >= other {
            // 짧은 라틴 문자 줄(메뉴·버튼 이름 등)은 영어 쪽으로 약하게 기울여 추정한다.
            let guess = hypothesis(sample, hints: latin < 12 ? [.english: 0.5] : [:])
            if latin >= 12, let guess, guess.confidence >= 0.6 { return .language(guess.key) }
            return .ambiguous(.latin, guess: (guess?.confidence ?? 0) >= 0.5 ? guess?.key : nil)
        }
        if other >= 12, let guess = hypothesis(sample), guess.confidence >= 0.6 { return .language(guess.key) }
        return .unknown
    }

    /// 같은 캡처(문서)의 확실한 줄을 근거로 애매한 줄을 정한다. 짧은 라틴 문자 줄은 일본어처럼 다른 문자를
    /// 쓰는 우세 언어를 물려받지 않고 확실한 라틴 문자 줄의 언어를 따른다. 한자만 있는 줄은 확실한 줄 중
    /// 일본어만 있으면 일본어, 중국어만 있으면 중국어를 따르며, 둘 다 있거나 근거가 없으면 단독 추정값,
    /// 그것도 없으면 언어 미상으로 둔다.
    static func resolveAmbiguous(_ results: [Result]) -> [Result] {
        var latinCounts: [String: Int] = [:]
        var hasJapanese = false
        var chineseKeys: [String: Int] = [:]
        for case .language(let key) in results {
            if key == "ja" {
                hasJapanese = true
            } else if Locale.Language(identifier: key).languageCode?.identifier == "zh" {
                chineseKeys[key, default: 0] += 1
            } else if usesLatinScript(key) {
                latinCounts[key, default: 0] += 1
            }
        }
        let latinContext = mostFrequent(latinCounts)
        let hanContext: String? = hasJapanese
            ? (chineseKeys.isEmpty ? "ja" : nil)
            : mostFrequent(chineseKeys)
        return results.map { result in
            guard case .ambiguous(let script, let guess) = result else { return result }
            let context = script == .latin ? latinContext : hanContext
            if let key = context ?? guess { return .language(key) }
            return .unknown
        }
    }

    /// 같은 언어인지(중국어는 간체/번체까지 비교).
    static func isSameLanguage(_ lhs: String, _ rhs: String) -> Bool {
        let a = Locale.Language(identifier: lhs), b = Locale.Language(identifier: rhs)
        guard a.languageCode == b.languageCode else { return false }
        if a.languageCode?.identifier == "zh" { return a.maximalIdentifier == b.maximalIdentifier }
        return true
    }

    static func usesLatinScript(_ key: String) -> Bool {
        Locale.Language(identifier: Locale.Language(identifier: key).maximalIdentifier).script?.identifier == "Latn"
    }

    static func normalizedKey(_ raw: String) -> String {
        Locale.Language(identifier: raw).minimalIdentifier
    }

    private static func mostFrequent(_ counts: [String: Int]) -> String? {
        counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
    }

    private static func hypothesis(_ text: String, constraints: [NLLanguage] = [],
                                   hints: [NLLanguage: Double] = [:]) -> (key: String, confidence: Double)? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = constraints
        recognizer.languageHints = hints
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first else { return nil }
        return (normalizedKey(language.rawValue), confidence)
    }
}
