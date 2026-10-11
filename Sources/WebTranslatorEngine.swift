import AppKit
import Observation
import SwiftUI
import WebKit

// 웹 번역기(DeepL·Google 번역·Papago) 어댑터. API 키·비공식 HTTP 주소·가로챈 토큰 없이 각 서비스의 공식 HTTPS 번역 페이지를
// 앱의 WKWebView(외부 AI와 같은 영구 저장소)로 열고, 원문 입력창에 항목 하나를 넣은 뒤 결과 칸의 글자만 읽는다.
// - 항목(메일 세그먼트·화면 줄·브라우저 조각)마다 한 번씩 차례로 처리한다. 여러 줄을 한 번에 넣고 줄바꿈으로 다시 나누지 않는다.
// - 스크립트는 허용한 번역 페이지(최상위 프레임)에서만, 페이지와 분리된 콘텐츠 월드로 실행한다. 다른 주소(동의·인증 등)에는 넣지 않는다.
// - 페이지가 준비되지 않거나(쿠키 동의·보안 확인 등) 결과가 오지 않으면 보이는 창으로 사용자가 직접 확인하게 하며, 자동으로 동의하거나 우회하지 않는다.
// - 원문·결과·주소(쿼리·프래그먼트 포함)는 로그·진단·디스크에 남기지 않는다. 언어는 URL의 언어 코드로만 고르고 원문을 URL에 넣지 않는다.
// - 다른 제공사나 Apple 번역으로 대체하지 않는다.

enum WebTranslator: String, CaseIterable, Identifiable {
    case deepl, google, papago
    var id: Self { self }

    var title: String {
        switch self {
        case .deepl: return "DeepL"
        case .google: return "Google 번역"
        case .papago: return "Papago"
        }
    }

    var site: WebTranslatorSite { WebTranslatorSite.site(for: self) }
}

/// 한 번 실행(번역 버튼·메일 요청)에 보내는 최대 항목 수. 나머지는 사용자가 다시 실행해 이어서 보낸다.
enum WebTranslation {
    static let itemsPerAction = 100
}

// MARK: - 공식 페이지 구성 (2026-10 실제 DOM 관찰 기준)

struct WebTranslatorSite {
    struct LanguageProbe {
        /// nil이면 입력창(원문)·결과 칸(번역) 요소 자체의 속성을 읽는다.
        let selector: String?
        let attribute: String
    }

    let translator: WebTranslator
    let host: String
    /// 메인 프레임 이동을 허용하는 호스트(스크립트는 host에서만 실행)
    let navigationHosts: [String]
    /// 한 번에 넣는 최대 글자 수. 넘으면 문장 단위 조각(TextChunker)으로 나눠 순서대로 넣고 그대로 잇는다.
    let maxCharacters: Int
    let source: [String]
    let target: [String]
    /// 비어 있지 않으면 결과 칸 안에서 이 요소들의 글자만 순서대로 모은다(대체 번역·안내 UI 제외).
    let outputParts: [String]
    /// true면 결과 칸이 번역 전에는 없어도 준비된 것으로 본다(Google은 결과가 생길 때 결과 요소를 만든다).
    let targetOptional: Bool
    let sourceLanguage: LanguageProbe?
    let targetLanguage: LanguageProbe?

    static func site(for translator: WebTranslator) -> WebTranslatorSite {
        switch translator {
        case .google:
            return WebTranslatorSite(
                translator: .google, host: "translate.google.com",
                navigationHosts: ["translate.google.com", "consent.google.com"], maxCharacters: 1400,
                source: ["textarea[jsname=\"BJE2fc\"]", "textarea.er8xn"],
                target: ["span[jsname=\"jqKxS\"]"],
                outputParts: ["span[jsname=\"W297wb\"]"], targetOptional: true,
                sourceLanguage: nil,
                targetLanguage: LanguageProbe(selector: nil, attribute: "lang"))
        case .deepl:
            return WebTranslatorSite(
                translator: .deepl, host: "www.deepl.com",
                navigationHosts: ["www.deepl.com"], maxCharacters: 1400,
                source: ["d-textarea[data-testid=\"translator-source-input\"] [role=\"textbox\"][contenteditable=\"true\"]"],
                target: ["d-textarea[data-testid=\"translator-target-input\"] [role=\"textbox\"]"],
                outputParts: [], targetOptional: false,
                sourceLanguage: LanguageProbe(selector: "[data-testid=\"translator-source-lang\"]", attribute: "dl-selected-lang"),
                targetLanguage: LanguageProbe(selector: "[data-testid=\"translator-target-lang\"]", attribute: "dl-selected-lang"))
        case .papago:
            return WebTranslatorSite(
                translator: .papago, host: "papago.naver.com",
                navigationHosts: ["papago.naver.com"], maxCharacters: 3000,
                source: ["[data-testid=\"source-editor\"][contenteditable=\"true\"]"],
                target: ["[data-testid=\"target-editor\"]"],
                outputParts: [], targetOptional: false,
                sourceLanguage: LanguageProbe(selector: nil, attribute: "lang"),
                targetLanguage: LanguageProbe(selector: nil, attribute: "lang"))
        }
    }

    /// 언어 코드만 담은 공식 페이지 주소. 원문은 넣지 않는다.
    func pageURL(source: String, target: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        switch translator {
        case .google:
            components.path = "/"
            components.queryItems = [URLQueryItem(name: "sl", value: source), URLQueryItem(name: "tl", value: target),
                                     URLQueryItem(name: "op", value: "translate")]
        case .deepl:
            components.path = "/ko/translator/l/\(source)/\(target)"
        case .papago:
            components.path = "/"
            components.queryItems = [URLQueryItem(name: "sl", value: source), URLQueryItem(name: "tl", value: target)]
        }
        return components.url
    }

    /// 앱 언어 ID(BCP 47) → 서비스 언어 코드
    func code(_ id: String, isTarget: Bool) -> String {
        let language = Locale.Language(identifier: id)
        let base = language.languageCode?.identifier ?? id
        guard base == "zh" else { return base }
        let traditional = Locale.Language(identifier: language.maximalIdentifier).script?.identifier == "Hant"
        switch translator {
        case .google, .papago: return traditional ? "zh-TW" : "zh-CN"
        case .deepl: return isTarget ? (traditional ? "zh-hant" : "zh-hans") : "zh"
        }
    }

    /// 페이지가 표시한 언어가 고른 언어와 같은지. 값이 없으면 nil(확인 불가).
    static func languageMatches(_ actual: String?, _ expected: String) -> Bool? {
        guard let actual = actual?.lowercased(), !actual.isEmpty else { return nil }
        let expected = expected.lowercased()
        if actual == expected || actual.hasPrefix(expected + "-") { return true }
        // DeepL 간체 대상은 'zh'로만 표시될 수 있다.
        if expected == "zh-hans" && actual == "zh" { return true }
        return false
    }

    func allowsScript(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == host && url.port == nil
    }

    func allowsNavigation(_ url: URL) -> Bool {
        if url.scheme == "about" { return true }
        guard url.scheme?.lowercased() == "https", url.port == nil, let urlHost = url.host?.lowercased() else { return false }
        return navigationHosts.contains(urlHost)
    }

    /// 페이지 스크립트에 넘기는 값(선택자·호스트만)
    var scriptDescriptor: [String: Any] {
        func probe(_ value: LanguageProbe?) -> Any {
            guard let value else { return NSNull() }
            return ["selector": value.selector.map { $0 as Any } ?? NSNull(), "attribute": value.attribute]
        }
        return ["host": host, "source": source, "target": target, "parts": outputParts, "targetOptional": targetOptional,
                "sourceLang": probe(sourceLanguage), "targetLang": probe(targetLanguage)]
    }
}

// MARK: - 전송 동의 (제공사마다 한 번, 메일·화면·브라우저 공용)

@MainActor
@Observable
final class WebTranslatorConsentStore {
    static let shared = WebTranslatorConsentStore()

    private(set) var consents: Set<WebTranslator>

    private static func key(_ translator: WebTranslator) -> String { "webTranslatorConsentV1.\(translator.rawValue)" }

    private init() {
        consents = Set(WebTranslator.allCases.filter { UserDefaults.standard.bool(forKey: Self.key($0)) })
    }

    func hasConsent(_ translator: WebTranslator) -> Bool { consents.contains(translator) }

    func grant(_ translator: WebTranslator) {
        UserDefaults.standard.set(true, forKey: Self.key(translator))
        consents.insert(translator)
    }

    func revoke(_ translator: WebTranslator) {
        UserDefaults.standard.removeObject(forKey: Self.key(translator))
        consents.remove(translator)
        WebTranslatorRunner.shared.cancelAll()
    }

    nonisolated static func message(for translator: WebTranslator) -> String {
        let title = translator.title
        return "번역을 실행할 때만 아래 텍스트가 \(title) 공식 웹페이지(https://\(translator.site.host), 로그인 없이 사용)의 입력창에 한 항목씩 입력되어 번역됩니다. API 키나 비공식 접속 방식은 쓰지 않습니다.\n"
            + "• 메일 번역: 메일의 제목, 본문 텍스트, 이미지에서 인식한(OCR) 텍스트. 원본 HTML, 이미지 파일, 보낸 사람·받는 사람 주소는 보내지 않습니다.\n"
            + "• 화면 번역: 선택한 화면 영역에서 인식한(OCR) 글자. 스크린샷 이미지와 위치 정보는 보내지 않습니다.\n"
            + "• 브라우저 번역(Chrome·Whale): 확장에서 \(title)을(를) 따로 고르고 동의한 경우에만 페이지 글자와 이미지에서 인식한 글자. 캡처 이미지·페이지 HTML·페이지 주소는 보내지 않습니다.\n"
            + "보낸 내용에는 \(title)의 정책이 적용되며 서비스 쪽에 기록될 수 있습니다. 앱은 원문·번역 결과·주소를 기록하거나 저장하지 않습니다. 방식이나 언어를 고르는 것만으로는 보내지 않습니다.\n\n"
            + "동의는 \(title)에 대해 기억되어 다음 번역부터 다시 묻지 않습니다. 설정 › 웹 번역 전송 동의에서 언제든 철회할 수 있습니다."
            + (translator == .deepl ? "\n\n개인정보나 기밀 내용은 DeepL 무료 웹 번역에 보내지 마세요." : "")
    }

    /// 브라우저 확장의 현재 페이지 1회성 번역 버튼(Google·DeepL)을 지원하는 서비스. 서비스마다 동의를 따로 받는다.
    nonisolated static let pageTranslators: [WebTranslator] = [.google, .deepl]

    /// 설정 › 현재 페이지 외부 번역 전송 동의(브라우저 확장의 '구글'·'DeepL' 버튼)에서만 쓰는 문구.
    /// 현재 페이지의 일반 텍스트와 이미지에서 인식한 텍스트 전송 범위를 알린다.
    nonisolated static func pageMessage(for translator: WebTranslator) -> String {
        let title = translator.title
        let button = translator == .google ? "구글" : title
        return "브라우저 확장(Chrome·Whale)에서 '\(button)' 버튼을 누를 때만, 그 탭의 현재 페이지에 있는 일반 글자와 이미지에서 이 Mac이 인식한(OCR) 글자가 "
            + "\(title) 공식 웹페이지(https://\(translator.site.host), 로그인·API 키 없이 사용)의 입력창에 문단 단위로 입력되어 번역됩니다.\n"
            + "스크린샷·캡처 화면·이미지 파일·페이지 HTML·페이지 주소는 보내지 않고 이 Mac에만 남습니다.\n"
            + "이 동의는 그 버튼의 현재 페이지 번역에만 쓰입니다. 동의해도 전역 자동 번역이나 확장의 기본 번역 방식은 바뀌지 않고, 버튼을 누르지 않으면 보내지 않습니다. "
            + "Google과 DeepL의 동의는 서로 따로이며, 다른 웹 번역 서비스·외부 AI에는 영향이 없습니다.\n"
            + "보낸 내용에는 \(title)의 정책이 적용되며 서비스 쪽에 기록될 수 있습니다. 앱은 원문·번역 결과·주소를 기록하거나 저장하지 않습니다.\n\n"
            + "동의는 기억되어 다음부터 다시 묻지 않습니다. 설정 › 현재 페이지 외부 번역 전송 동의에서 언제든 철회할 수 있습니다."
            + (translator == .deepl ? "\n\n개인정보나 기밀 내용은 DeepL 무료 웹 번역에 보내지 마세요." : "")
    }
}

/// 외부로 보내는 번역 방식(외부 AI 웹 계정 또는 웹 번역기). 동의·문구를 한곳에서 고른다.
enum ExternalService: Equatable {
    case ai(AIProvider)
    case web(WebTranslator)

    var title: String {
        switch self {
        case .ai(let provider): return provider.title
        case .web(let translator): return translator.title
        }
    }

    @MainActor var hasConsent: Bool {
        switch self {
        case .ai(let provider): return AIBIAccounts.shared.hasConsent(provider)
        case .web(let translator): return WebTranslatorConsentStore.shared.hasConsent(translator)
        }
    }

    @MainActor func grantConsent() {
        switch self {
        case .ai(let provider): AIBIAccounts.shared.grantConsent(provider)
        case .web(let translator): WebTranslatorConsentStore.shared.grant(translator)
        }
    }

    var consentMessage: String {
        switch self {
        case .ai(let provider): return ExternalConsent.message(for: provider)
        case .web(let translator): return WebTranslatorConsentStore.message(for: translator)
        }
    }
}

// MARK: - 실행기 (공식 페이지 1개, 항목 단위 직렬 처리, 제한 시간, 사용자 직접 확인, 취소)

@MainActor
@Observable
final class WebTranslatorRunner {
    static let shared = WebTranslatorRunner()

    enum Owner: Equatable {
        case mail, screen, browser
    }

    enum Failure: Error, Equatable {
        case cancelled
        /// 이 항목만 실패(다음 항목은 계속)
        case item(String)
        /// 이 언어 조합을 페이지에서 고르지 못함(같은 조합의 다른 항목도 보내지 않음)
        case unsupported(String)
        /// 실행 중단(이미 받은 결과는 호출한 쪽이 유지)
        case fatal(String)
    }

    /// 브라우저 진행 표시에 넘기는 단계(원문·결과 없이 단계 이름만). opening: 페이지 열기·준비, input: 원문 입력,
    /// waiting: 결과 대기, challenge: 사용자가 공식 페이지에서 직접 확인해야 함(쿠키 동의·보안 확인).
    enum Phase: String, Sendable {
        case opening, input, waiting, challenge
    }

    struct Status: Equatable {
        let translator: WebTranslator
        let owner: Owner
        var stage: String
        var needsUser: Bool
        var isVisible: Bool
    }

    private struct Probe: Sendable {
        var ready = false
        var source = ""
        var output = ""
        var sourceLang: String?
        var targetLang: String?
        /// Cloudflare 등 실제 보안 확인 위젯/인터스티셜 DOM이 보일 때만 true(안내 문구 검색이 아님).
        var challenge = false
        var siteError: String?
    }

    /// 페이지 스크립트 한 번의 결과. unresponsive: 제한 시간 안에 WebKit이 응답을 돌려주지 않았거나 앞선 실행이 아직
    /// 돌아오지 않아 새로 실행하지 않음. 늦게 온 응답은 버린다.
    private enum Evaluation: Sendable {
        case probe(Probe)
        /// 실행하지 않음(취소·허용 주소 아님·불러오는 중) 또는 스크립트 오류·빈 값
        case skipped
        case unresponsive

        var probe: Probe? {
            if case .probe(let value) = self { return value }
            return nil
        }
    }

    /// 콜백·제한 시간·취소 중 먼저 온 하나로 한 번만 끝낸다. 그 뒤의 늦은 콜백은 무시한다.
    @MainActor
    private final class EvaluationSlot {
        private var continuation: CheckedContinuation<Evaluation, Never>?
        private var outcome: Evaluation?

        func install(_ continuation: CheckedContinuation<Evaluation, Never>) {
            if let outcome { continuation.resume(returning: outcome) } else { self.continuation = continuation }
        }

        func finish(_ value: Evaluation) {
            guard outcome == nil else { return }
            outcome = value
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    private struct Waiter {
        let id: UUID
        let owner: Owner
        let continuation: CheckedContinuation<Bool, Never>
    }

    private(set) var status: Status?

    @ObservationIgnored private var tickets: [Owner: Int] = [:]
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var waiters: [Waiter] = []
    @ObservationIgnored private var webView: AIBIWebView?
    @ObservationIgnored private var site: WebTranslatorSite?
    @ObservationIgnored private var navigationGuard: WebTranslatorNavigationGuard?
    @ObservationIgnored private var window: AIBIBrowserWindow?
    @ObservationIgnored private var panel: WebTranslatorStatusPanel?
    @ObservationIgnored private var loadedPair: String?
    /// 같은 원문을 다시 보냈을 때 즉시 재사용되는 결과를 이전 요청의 잔여 결과와 구분한다.
    @ObservationIgnored private var lastCompleted: (pair: String, input: String, output: String)?
    @ObservationIgnored private var unsupportedPairs: [String: String] = [:]
    @ObservationIgnored private var navigationFailed = false
    @ObservationIgnored private var navigationCommitted = false
    @ObservationIgnored private var documentSerial = 0
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundWindow: WebTranslatorBackgroundWindow?
    /// 아직 응답이 오지 않은 페이지 스크립트 실행의 번호. 있는 동안에는 새 실행(특히 입력)을 쌓지 않는다.
    @ObservationIgnored private var pendingEvaluation: Int?
    @ObservationIgnored private var evaluationSerial = 0

    private static let readyTimeout: TimeInterval = 30
    private static let userActionTimeout: TimeInterval = 300
    private static let languageSettleTime: TimeInterval = 8
    private static let idleTeardown: Duration = .seconds(90)
    /// DeepL의 정상 번역 결과 대기(화면 준비·보안 확인 대기와는 별개). 보안 확인이 끝나면 이 시간부터 다시 잰다.
    /// 페이지 스크립트 한 번(확인·지우기·입력)의 응답 한도. 넘으면 응답 없음으로 보고 늦은 응답은 버린다.
    private static let evaluationTimeout: TimeInterval = 3

    private init() {}

    /// 실행(번역 버튼 한 번·브라우저 요청 하나)을 시작할 때 받는 표. 그 뒤 cancel(owner:)가 불리면 같은 표의 남은 항목은 보내지 않는다.
    func ticket(for owner: Owner) -> Int { tickets[owner, default: 0] }

    /// 인식 중 빈 공식 페이지를 준비한다. 다른 기능이 번역/사용자 확인 중이면 건드리지 않는다.
    /// 원문 입력·결과 읽기 없이 같은 언어의 실제 요청이 이 화면을 이어 쓸 수 있게 한다.
    func prepare(source: String, target: String, using translator: WebTranslator, owner: Owner, ticket: Int) {
        guard isCurrent(owner, ticket), !busy, waiters.isEmpty, pendingEvaluation == nil, window == nil,
              WebTranslatorConsentStore.shared.hasConsent(translator) else { return }
        let site = translator.site
        let src = site.code(source, isTarget: false), tgt = site.code(target, isTarget: true)
        let pair = "\(translator.rawValue):\(src)>\(tgt)"
        guard unsupportedPairs[pair] == nil else { return }
        idleTask?.cancel()
        idleTask = nil
        prepareWebView(site, owner: owner)
        mount(owner: owner, surface: nil)
        if loadedPair != pair || !(webView?.url.map(site.allowsScript) ?? false) {
            guard let url = site.pageURL(source: src, target: tgt) else { scheduleIdleTeardown(); return }
            navigationFailed = false
            navigationCommitted = false
            loadedPair = pair
            webView?.load(URLRequest(url: url))
        }
        scheduleIdleTeardown()
    }

    /// 지정한 기능의 대기·진행 중 항목만 취소한다(다른 기능의 항목은 그대로).
    func cancel(owner: Owner) {
        tickets[owner, default: 0] += 1
        let dropped = waiters.filter { $0.owner == owner }
        waiters.removeAll { $0.owner == owner }
        dropped.forEach { $0.continuation.resume(returning: false) }
    }

    /// 모든 기능의 항목을 취소하고 웹 보기를 닫는다(사용자가 창을 닫거나 동의를 철회했을 때).
    func cancelAll() {
        for owner in [Owner.mail, .screen, .browser] { cancel(owner: owner) }
        teardown()
    }

    /// 항목 하나를 번역한다. source·target은 앱 언어 ID이며 source는 이미 판별된(또는 사용자가 고른) 언어여야 한다.
    func translate(_ text: String, source: String, target: String, using translator: WebTranslator,
                   owner: Owner, ticket: Int, surface: AIBIHostView? = nil,
                   onPhase: (@Sendable (Phase) -> Void)? = nil) async -> Result<String, Failure> {
        guard isCurrent(owner, ticket) else { return .failure(.cancelled) }
        guard WebTranslatorConsentStore.shared.hasConsent(translator) else {
            return .failure(.fatal("\(translator.title) 전송 동의가 없어 보내지 않았습니다. 설정 › 웹 번역 전송 동의를 확인하세요."))
        }
        let site = translator.site
        let src = site.code(source, isTarget: false)
        let tgt = site.code(target, isTarget: true)
        let pair = "\(translator.rawValue):\(src)>\(tgt)"
        if let reason = unsupportedPairs[pair] { return .failure(.unsupported(reason)) }
        guard await acquire(owner: owner, ticket: ticket) else { return .failure(.cancelled) }
        defer { release() }
        guard isCurrent(owner, ticket) else { return .failure(.cancelled) }

        // 한도는 공식 입력창의 글자 수이므로 UTF-16 길이로 잰다(이모지 등 대체쌍은 두 칸). 넘으면 문장 단위로 나누고,
        // 그래도 한도를 넘는 조각이 있으면 잘라 보내지 않고 이 항목만 분명히 실패로 돌려준다.
        let chunks = text.utf16.count > site.maxCharacters ? TextChunker.chunks(text, limit: site.maxCharacters, measuringUTF16: true) : [TextChunk(text: text, separator: "")]
        guard chunks.allSatisfy({ $0.text.utf16.count <= site.maxCharacters }) else {
            return .failure(.item("\(translator.title) 입력 한도(\(site.maxCharacters)자)를 넘는 조각이 있어 이 항목을 보내지 않았습니다."))
        }
        var joined = ""
        for chunk in chunks {
            switch await translateChunk(chunk.text, src: src, tgt: tgt, pair: pair, site: site,
                                        owner: owner, ticket: ticket, surface: surface, onPhase: onPhase) {
            case .success(let value): joined += value + chunk.separator
            case .failure(let failure): return .failure(failure)
            }
        }
        let result = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? .failure(.item("\(translator.title) 결과가 비어 있어 적용하지 않았습니다.")) : .success(result)
    }

    /// DeepL 전용 묶음 번역: 여러 항목을 번호 식별자로 감싸 한 번만 공식 페이지에 보내고, 결과에서 식별자별로
    /// 정확히 나눈다. 식별자가 빠지거나 겹치거나 순서가 바뀌거나 비어 있으면(추측해서 채우지 않고) 묶음 전체를
    /// 항목 실패로 돌려준다. texts는 이미 DeepLBatcher.pack이 한도 안에 들어가도록 고른 묶음이어야 한다.
    func translateBatch(_ texts: [String], source: String, target: String, using translator: WebTranslator,
                        owner: Owner, ticket: Int, surface: AIBIHostView? = nil,
                        onPhase: (@Sendable (Phase) -> Void)? = nil) async -> [Result<String, Failure>] {
        guard isCurrent(owner, ticket) else { return texts.map { _ in .failure(.cancelled) } }
        guard WebTranslatorConsentStore.shared.hasConsent(translator) else {
            let failure = Failure.fatal("\(translator.title) 전송 동의가 없어 보내지 않았습니다. 설정 › 웹 번역 전송 동의를 확인하세요.")
            return texts.map { _ in .failure(failure) }
        }
        let site = translator.site
        let src = site.code(source, isTarget: false)
        let tgt = site.code(target, isTarget: true)
        let pair = "\(translator.rawValue):\(src)>\(tgt)"
        if let reason = unsupportedPairs[pair] { return texts.map { _ in .failure(.unsupported(reason)) } }
        guard await acquire(owner: owner, ticket: ticket) else { return texts.map { _ in .failure(.cancelled) } }
        defer { release() }
        guard isCurrent(owner, ticket) else { return texts.map { _ in .failure(.cancelled) } }

        let slots = texts.enumerated().map { DeepLBatcher.Slot(index: $0.offset, text: $0.element) }
        let envelope = DeepLBatcher.envelope(slots)
        switch await translateChunk(envelope, src: src, tgt: tgt, pair: pair, site: site,
                                    owner: owner, ticket: ticket, surface: surface, raw: true, onPhase: onPhase) {
        case .success(let output):
            guard let parsed = DeepLBatcher.parse(output, count: texts.count) else {
                let failure = Failure.item("\(translator.title) 묶음 번역 결과의 번호를 식별하지 못해 이 항목들을 보내지 않았습니다.")
                return texts.map { _ in .failure(failure) }
            }
            return parsed.map { .success($0) }
        case .failure(.item) where texts.count > 1:
            // 입력 길이 제한이면 번호 포장을 빼고 각 문장을 한 번씩 재시도한다. 취소·네트워크 오류는 재시도하지 않는다.
            var result: [Result<String, Failure>] = []
            for text in texts {
                guard isCurrent(owner, ticket) else { return texts.map { _ in .failure(.cancelled) } }
                result.append(await translateChunk(text, src: src, tgt: tgt, pair: pair, site: site,
                                                   owner: owner, ticket: ticket, surface: surface, onPhase: onPhase))
            }
            return result
        case .failure(let failure):
            return texts.map { _ in .failure(failure) }
        }
    }

    // MARK: 단계

    private func translateChunk(_ text: String, src: String, tgt: String, pair: String, site: WebTranslatorSite,
                                owner: Owner, ticket: Int, surface: AIBIHostView?, raw: Bool = false,
                                onPhase: (@Sendable (Phase) -> Void)? = nil) async -> Result<String, Failure> {
        let title = site.translator.title
        onPhase?(.opening)
        prepareWebView(site, owner: owner)
        mount(owner: owner, surface: surface)
        if loadedPair != pair || !(webView?.url.map(site.allowsScript) ?? false) {
            guard let url = site.pageURL(source: src, target: tgt) else { return .failure(.unsupported("\(title) 주소를 만들지 못했습니다.")) }
            setStage("\(title) 여는 중")
            navigationFailed = false
            navigationCommitted = false
            loadedPair = pair
            webView?.load(URLRequest(url: url))
        }

        // 1) 페이지 준비(입력창·결과 칸)와 고른 언어 확인
        let started = Date()
        var tookOver = false
        var challengeVisible = false
        var mismatchSince: Date?
        var unresponsiveSince: Date?
        setStage("\(title) 화면 준비 중")
        var firstProbe = true
        ready: while true {
            guard isCurrent(owner, ticket) else { return .failure(.cancelled) }
            let elapsed = Date().timeIntervalSince(started)
            if !tookOver && elapsed > Self.readyTimeout {
                tookOver = true
                onPhase?(.challenge)
                reveal("\(title) 페이지에서 직접 확인이 필요합니다(쿠키 동의·보안 확인 등). 확인되면 이어서 번역합니다.", needsUser: true)
            }
            if elapsed > Self.readyTimeout + Self.userActionTimeout {
                return .failure(.fatal("\(title) 페이지가 준비되지 않아 중단했습니다(최대 5분 대기)."))
            }
            if firstProbe { firstProbe = false } else { await pause(0.4) }
            guard isCurrent(owner, ticket), let webView else { return .failure(.cancelled) }
            if navigationFailed {
                loadedPair = nil
                return .failure(.fatal("네트워크 오류로 \(title) 페이지를 열지 못했습니다. 인터넷 연결을 확인한 뒤 다시 시도하세요."))
            }
            guard let url = webView.url, site.allowsScript(url), navigationCommitted else { continue }
            let evaluation = await page("probe", site: site, owner: owner, ticket: ticket)
            // 스크립트가 계속 응답하지 않으면(사용자 확인으로 풀리는 상태가 아님) 5분을 기다리지 않고 분명히 실패로 끝낸다.
            if case .unresponsive = evaluation {
                let since = unresponsiveSince ?? Date()
                unresponsiveSince = since
                if Date().timeIntervalSince(since) > Self.readyTimeout { return unresponsive(title) }
                continue
            }
            unresponsiveSince = nil
            guard let probe = evaluation.probe else { continue }
            // 이전 원문의 길이 경고는 새 원문을 입력한 뒤 다시 판단한다.
            if let code = probe.siteError, code != "length" { return siteFailure(code, title: title) }
            // 실제 보안 확인은 준비가 끝나기 전에도 알려 사용자가 확인한 뒤 이어 받을 수 있게 한다.
            if probe.challenge {
                if !challengeVisible {
                    challengeVisible = true
                    onPhase?(.challenge)
                    reveal("\(title)에서 보안 확인이 필요합니다. 이 창에서 직접 완료하면 번역을 이어서 받습니다.", needsUser: true)
                }
            } else if challengeVisible {
                challengeVisible = false
                status?.needsUser = false
                onPhase?(.opening)
            }
            guard probe.ready else { continue }
            let languages = [Self.check(probe.sourceLang, src), Self.check(probe.targetLang, tgt)]
            if languages.contains(false) {
                // 하이드레이션 직후 초기값이 잠시 다를 수 있어 잠시 기다린 뒤에만 판단한다.
                let since = mismatchSince ?? Date()
                mismatchSince = since
                if Date().timeIntervalSince(since) > Self.languageSettleTime {
                    let reason = "\(title)에서 \(src) → \(tgt) 언어를 고르지 못했습니다. 이 언어 조합을 지원하지 않거나 페이지 구성이 바뀌었습니다."
                    unsupportedPairs[pair] = reason
                    loadedPair = nil
                    return .failure(.unsupported(reason))
                }
                continue
            }
            break ready
        }
        if tookOver || challengeVisible { status?.needsUser = false }

        // 이전 결과를 기준값으로 보관하고 원문만 지운다. 결과 칸이 비기를 기다리지 않는다.
        // 아래 staleOutput 검사로 이전 결과를 이번 요청의 결과로 받지 않는다.
        setStage("원문 입력 중")
        onPhase?(.input)
        let cleared = await page("clear", site: site, owner: owner, ticket: ticket)
        guard isCurrent(owner, ticket) else { return .failure(.cancelled) }
        if case .unresponsive = cleared { return unresponsive(title) }
        let clearProbe: Probe
        if let probe = cleared.probe {
            clearProbe = probe
        } else {
            guard let probe = await page("probe", site: site, owner: owner, ticket: ticket).probe else {
                return unresponsive(title)
            }
            clearProbe = probe
        }
        let baseline = clearProbe.output
        guard isCurrent(owner, ticket) else { return .failure(.cancelled) }
        // 앞선 실행이 아직 돌아오지 않았으면 입력을 그 뒤에 쌓지 않는다.
        if pendingEvaluation != nil { return unresponsive(title) }

        // 3) 입력 후 입력창 내용이 원문과 같은지 확인. 편집기는 붙여넣기를 비동기로 반영하므로 잠시 확인한 뒤에만
        //    전체 선택 + 글자 입력으로 바꿔 넣는다(전체를 바꾸므로 두 번 들어가지 않는다). 입력 실행이 응답하지 않았으면
        //    늦게라도 반영될 수 있으므로 다른 방식으로 다시 넣지 않고 확인만 한다. 입력창 글자가 원문과 같아진 것을
        //    읽었을 때만 입력된 것으로 본다.
        var filled = false
        var writeUnresponsive = false
        let inputActions = site.translator == .deepl ? ["insert", "fill"] : ["fill", "insert"]
        attempts: for action in inputActions {
            guard isCurrent(owner, ticket) else { return .failure(.cancelled) }
            let write = await page(action, text: text, site: site, owner: owner, ticket: ticket)
            if let probe = write.probe, Self.normalized(probe.source) == Self.normalized(text) {
                filled = true
                break attempts
            }
            if case .unresponsive = write { writeUnresponsive = true }
            let attempted = Date()
            let checkFor = writeUnresponsive ? Self.evaluationTimeout + 1.5 : 1.5
            while Date().timeIntervalSince(attempted) < checkFor {
                await pause(0.3)
                guard isCurrent(owner, ticket) else { return .failure(.cancelled) }
                if let probe = await page("probe", site: site, owner: owner, ticket: ticket).probe,
                   Self.normalized(probe.source) == Self.normalized(text) {
                    filled = true
                    break attempts
                }
            }
            if writeUnresponsive || pendingEvaluation != nil { break }
        }
        guard isCurrent(owner, ticket) else { return .failure(.cancelled) }
        if !filled && (writeUnresponsive || pendingEvaluation != nil) { return unresponsive(title) }
        guard filled else {
            reveal("\(title) 입력창에 원문을 넣지 못했습니다.", needsUser: false)
            return .failure(.fatal("\(title) 입력창에 원문을 넣지 못했습니다. 페이지 구성이 바뀌었을 수 있습니다."))
        }

        // 4) 결과가 생기고 3회 연속 같을 때 완료로 본다. DeepL과 Google은 같은 결과 대기 규칙을 쓴다.
        setStage("번역 결과 기다리는 중")
        onPhase?(.waiting)
        let limit = 30 + Double(text.count) / 100
        var waitStarted = Date()
        var last: String?
        var stable = 0
        var sourceChanged = 0
        var challengeActive = false
        var extendedDeadline: Date?
        // 지우기 뒤에도 결과 칸이 비지 않았으면(staleOutput) 그 글자는 이전 항목의 결과일 수 있어 그대로는 받지 않는다.
        // 다만 원문을 넣은 뒤 결과 칸이 한 번이라도 비거나 다른 글자로 바뀐 것을 봤다면 그 뒤에 나온 글자는 이번 원문의
        // 결과다(같은 짧은 낱말을 다시 보내 이전과 같은 번역이 나온 경우도 받는다).
        let staleOutput = baseline.trimmingCharacters(in: .whitespacesAndNewlines)
        let sameCompletedRequest = lastCompleted.map {
            $0.pair == pair && $0.input == Self.normalized(text) && $0.output == staleOutput
        } ?? false
        var staleCleared = staleOutput.isEmpty || sameCompletedRequest
        var finalCheck = false
        var lastUnresponsive = false
        while true {
            guard isCurrent(owner, ticket) else { return .failure(.cancelled) }
            let deadline = max(waitStarted.addingTimeInterval(limit), extendedDeadline ?? .distantPast)
            if Date() > deadline {
                // 마지막 확인에서도 보안 확인이 보이지 않을 때만 실패로 끝낸다(기한 직전에 뜬 확인을 놓치고 창만 띄운 채
                // 끝나 사용자가 확인을 마친 뒤 나온 결과를 아무도 받지 않던 경우를 막는다).
                guard finalCheck else {
                    finalCheck = true
                    let evaluation = await page("probe", site: site, owner: owner, ticket: ticket)
                    if case .unresponsive = evaluation { lastUnresponsive = true }
                    if let probe = evaluation.probe {
                        lastUnresponsive = false
                        if probe.challenge {
                            challengeActive = true
                            extendedDeadline = Date().addingTimeInterval(Self.userActionTimeout)
                            onPhase?(.challenge)
                            reveal("\(title)에서 보안 확인이 필요합니다. 이 창에서 직접 완료하면 번역을 이어서 받습니다.", needsUser: true)
                        }
                    }
                    continue
                }
                guard isCurrent(owner, ticket) else { return .failure(.cancelled) }
                // 결과가 늦은 것이 아니라 페이지 스크립트가 응답하지 않은 경우는 따로 알린다.
                if lastUnresponsive || pendingEvaluation != nil { return unresponsive(title) }
                reveal("\(title) 번역 결과를 받지 못했습니다. 페이지 상태를 확인하세요.", needsUser: false)
                return .failure(.fatal("제한 시간(\(Int(limit))초) 안에 \(title) 번역 결과를 받지 못했습니다. 열린 창에서 사용 한도·보안 확인 등 페이지 상태를 확인한 뒤 다시 시도하세요."))
            }
            await pause(0.4)
            let evaluation = await page("probe", site: site, owner: owner, ticket: ticket)
            if case .unresponsive = evaluation { lastUnresponsive = true }
            guard let probe = evaluation.probe else { continue }
            if let code = probe.siteError { return siteFailure(code, title: title) }
            lastUnresponsive = false
            // 결과를 기다리는 중 실제 보안 확인 위젯이 뜨면(글자 추측이 아니라 공식 DOM으로 확인) 직접 보이는 창으로
            // 띄워 사용자가 완료하게 하고, 완료할 시간을 따로 보장한다. 앱이 대신 누르거나 우회하지 않는다.
            // 위젯은 확인을 마친 뒤('성공!')에도 페이지에 남아 있을 수 있으므로, 위젯이 보이는 동안에도 결과 칸은 계속 읽어
            // 아래의 같은 검사(이번 원문·새 결과·안정·결과 언어)를 통과한 결과는 받는다. 위젯은 기한만 늘린다.
            if probe.challenge {
                if !challengeActive {
                    challengeActive = true
                    extendedDeadline = Date().addingTimeInterval(Self.userActionTimeout)
                    onPhase?(.challenge)
                    reveal("\(title)에서 보안 확인이 필요합니다. 이 창에서 직접 완료하면 번역을 이어서 받습니다.", needsUser: true)
                }
            } else if challengeActive {
                challengeActive = false
                status?.needsUser = false
                onPhase?(.waiting)
                // 보안 확인이 끝났으니 5분 확인 대기를 끝내고 Google과 같은 결과 대기를 지금부터 다시 잰다.
                extendedDeadline = nil
                waitStarted = Date()
                finalCheck = false
            }
            if Self.normalized(probe.source) != Self.normalized(text) {
                sourceChanged += 1
                if sourceChanged >= 3 {
                    return .failure(.fatal("\(title) 입력창의 원문이 바뀌어 이 항목을 적용하지 않았습니다."))
                }
                continue
            }
            sourceChanged = 0
            let output = probe.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if output != staleOutput { staleCleared = true }
            guard !output.isEmpty, staleCleared else {
                last = nil
                stable = 0
                continue
            }
            guard output == last else {
                last = output
                stable = 0
                continue
            }
            stable += 1
            guard stable >= 2 else { continue }
            if Self.check(probe.targetLang, tgt) == false {
                let reason = "\(title) 결과 언어가 고른 번역 언어(\(tgt))와 달라 적용하지 않았습니다."
                unsupportedPairs[pair] = reason
                loadedPair = nil
                return .failure(.unsupported(reason))
            }
            setStage("번역 받음")
            lastCompleted = (pair, Self.normalized(text), output)
            return .success(raw ? output : Self.cleaned(output, source: text))
        }
    }

    // MARK: 대기열 (모든 기능이 항목 단위로 차례를 나눠 쓴다)

    private func acquire(owner: Owner, ticket: Int) async -> Bool {
        idleTask?.cancel()
        idleTask = nil
        if !busy {
            busy = true
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled || ticket != tickets[owner, default: 0] {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: id, owner: owner, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.dropWaiter(id) }
        }
    }

    private func dropWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    private func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().continuation.resume(returning: true)
            return
        }
        busy = false
        scheduleIdleTeardown()
    }

    private func scheduleIdleTeardown() {
        // 다음 항목이 곧 이어질 수 있으므로 표시는 잠시 두고, 오래 쉬면 웹 보기를 닫는다.
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, !self.busy else { return }
            if self.window == nil { self.status = nil }
            self.panel?.hide()
            self.backgroundWindow?.hide()
            try? await Task.sleep(for: Self.idleTeardown)
            guard !Task.isCancelled, !self.busy, self.window == nil else { return }
            self.teardown()
        }
    }

    // MARK: 웹 보기 수명

    private func prepareWebView(_ site: WebTranslatorSite, owner: Owner) {
        // 앞선 항목의 스크립트 실행이 끝내 돌아오지 않은 웹 보기는 다시 쓰지 않는다(늦은 입력이 새 항목에 섞이지 않게).
        if webView == nil || self.site?.translator != site.translator || pendingEvaluation != nil {
            teardown()
            let webView = AIBIWebView(frame: NSRect(origin: .zero, size: AIBIHiddenSurface.viewport),
                                      configuration: AIBIRegistry.makeConfiguration())
            webView.interactive = false
            webView.allowsLinkPreview = false
            let guardian = WebTranslatorNavigationGuard(site: site)
            guardian.onFailure = { [weak self] in self?.navigationFailed = true }
            guardian.onStart = { [weak self, weak webView] in
                guard let self, let webView, self.webView === webView else { return }
                self.navigationCommitted = false
                self.documentSerial += 1
            }
            guardian.onCommit = { [weak self, weak webView] in
                guard let self, let webView, self.webView === webView else { return }
                self.navigationCommitted = true
            }
            guardian.onBlocked = { [weak self] in
                if self?.status?.isVisible == true { self?.status?.stage = "허용 목록에 없는 주소라 열지 않았습니다" }
            }
            webView.navigationDelegate = guardian
            webView.uiDelegate = guardian
            self.webView = webView
            self.site = site
            navigationGuard = guardian
            loadedPair = nil
            unsupportedPairs = [:]
        }
        let visible = window != nil
        if status?.translator != site.translator || status?.owner != owner {
            status = Status(translator: site.translator, owner: owner, stage: "\(site.translator.title) 준비 중",
                            needsUser: false, isVisible: visible)
        }
    }

    /// 보이는 창(사용자 확인 중)이면 그대로 두고, 아니면 이미 떠 있는 앱 창(숨김 표면)에 먼저 붙인다. 브라우저
    /// 요청은 사용자가 다른 앱에 있어 그런 창이 없을 수 있으므로, 그때만 이 기능이 소유한 작은 배경 창(화면 안의
    /// 실제 창이지만 다른 창 뒤에 머무르고 불투명 덮개 아래라 보이지 않음)을 새로 만들어 붙인다. 브라우저가 아닌
    /// 기능(메일·화면)은 숨김 표면이 없을 때 기존 작은 진행 패널로 대체한다(동작 그대로 유지).
    private func mount(owner: Owner, surface: AIBIHostView?) {
        guard let webView, window == nil else { return }
        if let host = AIBIHiddenSurface.shared.availableHost(preferring: surface) {
            panel?.hide()
            backgroundWindow?.hide()
            if webView.superview !== host {
                webView.removeFromSuperview()
                host.attach(webView)
            }
        } else if owner == .browser {
            panel?.hide()
            let background = backgroundWindow ?? WebTranslatorBackgroundWindow()
            backgroundWindow = background
            if webView.superview !== background.host {
                webView.removeFromSuperview()
                background.host.attach(webView)
            }
            background.show()
        } else {
            backgroundWindow?.hide()
            let panel = self.panel ?? WebTranslatorStatusPanel()
            panel.onUserClose = { [weak self] in self?.cancelAll() }
            self.panel = panel
            if webView.superview !== panel.host {
                webView.removeFromSuperview()
                panel.host.attach(webView)
            }
            panel.show()
        }
    }

    /// 숨김 웹 보기를 보이는 창으로 옮긴다. 페이지는 다시 불러오지 않는다.
    private func reveal(_ stage: String, needsUser: Bool) {
        guard let webView, let site else { return }
        status?.stage = stage
        status?.needsUser = needsUser
        status?.isVisible = true
        if window == nil {
            panel?.hide()
            backgroundWindow?.hide()
            webView.removeFromSuperview()
            webView.interactive = true
            let window = AIBIBrowserWindow(title: "\(site.translator.title) — 바로보기 웹 번역",
                                           header: WebTranslatorTaskHeader(), webView: webView)
            window.onUserClose = { [weak self] in
                self?.window = nil
                self?.cancelAll()
            }
            self.window = window
        }
        window?.show()
    }

    private func teardown() {
        idleTask?.cancel()
        idleTask = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        pendingEvaluation = nil
        navigationGuard = nil
        navigationCommitted = false
        site = nil
        loadedPair = nil
        unsupportedPairs = [:]
        lastCompleted = nil
        window?.close()
        window = nil
        panel?.hide()
        backgroundWindow?.hide()
        backgroundWindow = nil
        if !busy { status = nil }
    }

    // MARK: 도우미

    private func isCurrent(_ owner: Owner, _ ticket: Int) -> Bool {
        ticket == tickets[owner, default: 0] && !Task.isCancelled
    }

    private func setStage(_ stage: String) {
        if status?.stage != stage { status?.stage = stage }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// nil: 확인 불가(표시 없음), true: 일치, false: 다름
    private static func check(_ actual: String?, _ expected: String) -> Bool? {
        WebTranslatorSite.languageMatches(actual, expected)
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// 문단 편집기는 줄마다 빈 줄을 더 넣어 읽힐 수 있어, 원문에 빈 줄이 없으면 결과의 빈 줄도 한 줄바꿈으로 줄인다.
    private static func cleaned(_ output: String, source: String) -> String {
        guard !source.contains("\n\n"), output.contains("\n\n") else { return output }
        var text = output
        while text.contains("\n\n") { text = text.replacingOccurrences(of: "\n\n", with: "\n") }
        return text
    }

    /// 페이지 스크립트가 응답하지 않을 때: 이 요청을 분명히 실패로 끝내고 보이는 창으로 페이지를 보여 준다.
    /// 다음 요청은 이 웹 보기를 다시 쓰지 않는다(prepareWebView가 응답이 남은 웹 보기를 새로 만든다).
    private func unresponsive(_ title: String) -> Result<String, Failure> {
        loadedPair = nil
        reveal("\(title) 페이지가 응답하지 않습니다. 페이지 상태를 확인하세요.", needsUser: false)
        return .failure(.fatal("\(title) 페이지가 응답하지 않아(페이지 스크립트 응답 없음) 이 요청을 중단했습니다. 열린 창에서 페이지 상태를 확인한 뒤 다시 시도하세요."))
    }

    /// 허용한 번역 페이지(최상위 프레임)에서만, 페이지와 분리된 콘텐츠 월드로 어댑터를 실행한다. 값은 인자로만 넘긴다.
    /// 응답은 evaluationTimeout 안에서만 기다리고, 콜백·제한 시간·취소 중 먼저 온 하나로 한 번만 끝낸다. 앞선 실행이 아직
    /// 돌아오지 않았으면 새로 실행하지 않고 응답 없음으로 돌려준다(멈춘 페이지에 입력을 쌓지 않음).
    private func page(_ action: String, text: String = "", site: WebTranslatorSite, owner: Owner, ticket: Int) async -> Evaluation {
        guard isCurrent(owner, ticket), let webView, self.site?.translator == site.translator,
              let url = webView.url, site.allowsScript(url), navigationCommitted else { return .skipped }
        guard pendingEvaluation == nil else { return .unresponsive }
        let document = documentSerial
        evaluationSerial += 1
        let token = evaluationSerial
        pendingEvaluation = token
        let arguments: [String: Any] = ["site": site.scriptDescriptor, "action": action, "text": text]
        let slot = EvaluationSlot()
        webView.callAsyncJavaScript(Self.adapterScript, arguments: arguments, in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                // 늦게 온 응답은 대기 표시만 풀고 결과는 버린다(이미 끝난 자리는 finish를 무시한다).
                if self?.pendingEvaluation == token { self?.pendingEvaluation = nil }
                slot.finish(Self.evaluation(from: result))
            }
        }
        let timeout = Self.evaluationTimeout
        let timer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            slot.finish(.unresponsive)
        }
        let evaluation = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Evaluation, Never>) in
                slot.install(continuation)
            }
        } onCancel: {
            Task { @MainActor in slot.finish(.skipped) }
        }
        timer.cancel()
        guard isCurrent(owner, ticket), self.webView === webView,
              documentSerial == document, navigationCommitted else { return .skipped }
        return evaluation
    }

    private static func evaluation(from result: Result<Any, Error>) -> Evaluation {
        guard case .success(let value) = result, let data = value as? [String: Any] else { return .skipped }
        var probe = Probe()
        probe.ready = data["ready"] as? Bool ?? false
        probe.source = data["source"] as? String ?? ""
        probe.output = data["output"] as? String ?? ""
        probe.sourceLang = data["sourceLang"] as? String
        probe.targetLang = data["targetLang"] as? String
        probe.challenge = data["challenge"] as? Bool ?? false
        probe.siteError = data["siteError"] as? String
        return .probe(probe)
    }

    private func siteFailure(_ code: String, title: String) -> Result<String, Failure> {
        let message: String
        switch code {
        case "length": message = "원문을 더 짧게 나눠 다시 시도하세요. \(title)의 입력 한도에 걸려 잘린 결과는 적용하지 않았습니다."
        case "rate": message = "잠시 뒤 다시 시도하세요. \(title)의 사용량 제한으로 중단했습니다."
        case "network": message = "인터넷 연결을 확인한 뒤 다시 시도하세요. \(title)에서 연결 오류를 표시했습니다."
        default: message = "\(title) 창의 오류 안내를 확인한 뒤 다시 시도하세요. 결과를 적용하지 않았습니다."
        }
        if code == "length" { return .failure(.item(message)) }
        reveal(message, needsUser: false)
        return .failure(.fatal(message))
    }

    /// 공식 번역 페이지 어댑터. 보이는 요소만 고르고(같은 표식의 숨은 복제본 제외), 결과는 글자로만 읽는다.
    private static let adapterScript = """
    if (window.top !== window || location.protocol !== 'https:' || location.hostname !== site.host) return null;
    const visible = (el) => {
      if (!el || !el.isConnected) return false;
      const style = getComputedStyle(el);
      if (style.display === 'none' || style.visibility === 'hidden') return false;
      const rect = el.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    };
    const pick = (list) => {
      for (const selector of list) {
        let nodes = [];
        try { nodes = document.querySelectorAll(selector); } catch (_) { continue; }
        for (const el of nodes) { if (visible(el)) return el; }
      }
      return null;
    };
    const source = pick(site.source);
    const target = pick(site.target);
    const isField = (el) => el && (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT');
    const readSource = () => !source ? '' : (isField(source) ? source.value : source.innerText);
    const readOutput = () => {
      if (!target) return '';
      if (!site.parts.length) {
        // 같은 결과 칸 선택자(새 선택자 아님)에 맞는 보이는 요소가 여럿이면 글자가 그려진 첫 요소를 읽는다. 먼저 고른 요소가
        // 빈 자리일 때 실제 결과가 그려진 같은 결과 칸을 비어 있다고 읽지 않게 한다. 렌더링된 자식 글자는 innerText에 포함된다.
        const own = target.innerText || '';
        if (own.trim()) return own;
        for (const selector of site.target) {
          let nodes = [];
          try { nodes = document.querySelectorAll(selector); } catch (_) { continue; }
          for (const el of nodes) {
            if (el === target || !visible(el)) continue;
            const value = el.innerText || '';
            if (value.trim()) return value;
          }
        }
        return own;
      }
      const matches = (el) => site.parts.some((selector) => { try { return el.matches(selector); } catch (_) { return false; } });
      const walker = document.createTreeWalker(target, NodeFilter.SHOW_ELEMENT);
      let out = '';
      let node = walker.nextNode();
      while (node) {
        if (node.tagName === 'BR') { out += '\\n'; node = walker.nextNode(); continue; }
        if (matches(node)) {
          if (node.getClientRects().length > 0) out += node.textContent || '';
          let next = null;
          while (!next) {
            next = walker.nextSibling();
            if (next) break;
            const parent = walker.parentNode();
            if (!parent || parent === target) break;
          }
          node = next;
          continue;
        }
        node = walker.nextNode();
      }
      return out;
    };
    // 실제 공식 보안 확인 위젯/인터스티셜 DOM만 본다(글자 내용으로 추측하지 않음). Cloudflare Turnstile/관리형 확인은
    // challenges.cloudflare.com iframe으로, 전체 화면 인터스티셜은 고정 id(challenge-form/challenge-running)로 나타난다.
    const detectChallenge = () => {
      const interstitial = document.getElementById('challenge-form') || document.getElementById('challenge-running');
      if (interstitial) return true;
      const frames = document.querySelectorAll('iframe');
      for (const frame of frames) {
        if (!visible(frame)) continue;
        const src = frame.getAttribute('src') || '';
        if (!/challenges\\.cloudflare\\.com/i.test(src)) continue;
        // 완료된 위젯도 화면에 남는다. 해당 위젯의 공식 응답 필드가 채워졌는지만 확인한다.
        // 값은 반환·저장·전송하지 않는다. 다른 위젯과 섞일 수 있으면 확인 대기로 보수적으로 처리한다.
        let completed = false;
        let parent = frame.parentElement;
        for (let depth = 0; parent && depth < 3; depth++, parent = parent.parentElement) {
          const responses = parent.querySelectorAll('input[name="cf-turnstile-response"]');
          const widgets = Array.from(parent.querySelectorAll('iframe')).filter((f) =>
            /challenges\\.cloudflare\\.com/i.test(f.getAttribute('src') || ''));
          if (responses.length !== 1 || widgets.length !== 1 || widgets[0] !== frame) continue;
          completed = Boolean(responses[0].value);
          break;
        }
        if (!completed) return true;
      }
      return false;
    };
    const readLang = (probe, fallback) => {
      if (!probe) return null;
      const el = probe.selector ? pick([probe.selector]) : fallback;
      const value = el ? el.getAttribute(probe.attribute) : null;
      return value ? String(value) : null;
    };
    const selectAll = () => {
      source.focus();
      const range = document.createRange();
      range.selectNodeContents(source);
      const selection = getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    };
    if (source && action === 'clear') {
      if (isField(source)) {
        const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(source), 'value').set;
        source.focus();
        setter.call(source, '');
        source.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'deleteContentBackward' }));
      } else if (readSource().trim()) {
        selectAll();
        document.execCommand('delete');
      }
    }
    if (source && (action === 'fill' || action === 'insert')) {
      if (isField(source)) {
        const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(source), 'value').set;
        source.focus();
        setter.call(source, text);
        source.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
        source.dispatchEvent(new Event('change', { bubbles: true }));
      } else if (action === 'fill') {
        selectAll();
        try {
          const data = new DataTransfer();
          data.setData('text/plain', text);
          source.dispatchEvent(new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true }));
        } catch (_) {}
      } else {
        selectAll();
        document.execCommand('insertText', false, text);
      }
    }
    // 입력문/번역문을 오류 안내로 오인하지 않도록 실제 안내 요소만 읽고 고정 코드만 돌려준다.
    const detectSiteError = () => {
      if (site.host === 'papago.naver.com') return null;
      const notices = document.querySelectorAll('[role="alert"], [data-testid="translator-character-limit-proad"]');
      for (const notice of notices) {
        if (!visible(notice) || source?.contains(notice) || target?.contains(notice) || notice.contains(source) || notice.contains(target)) continue;
        const value = (notice.innerText || '').trim();
        if (/only[\\s\\S]*out of[\\s\\S]*characters were translated|character limit|text is too long|글자.*제한|文字数.*制限/i.test(value)) return 'length';
        if (/too many requests|rate limit|usage limit|사용량.*제한|利用.*制限/i.test(value)) return 'rate';
        if (/network error|connection error|check.*connection|네트워크.*오류|연결.*오류/i.test(value)) return 'network';
        if (notice.getAttribute('role') === 'alert' && /error|failed|unavailable|오류|실패|エラー/i.test(value)) return 'service';
      }
      return null;
    };
    return {
      ready: !!source && (!!target || site.targetOptional === true),
      source: readSource(),
      output: readOutput(),
      sourceLang: readLang(site.sourceLang, source),
      targetLang: readLang(site.targetLang, target),
      challenge: detectChallenge(),
      siteError: detectSiteError()
    };
    """
}

// MARK: - 내비게이션 보안 (메인 프레임은 허용 호스트만, 새 창 금지)

@MainActor
final class WebTranslatorNavigationGuard: NSObject, WKNavigationDelegate, WKUIDelegate {
    let site: WebTranslatorSite
    var onBlocked: (() -> Void)?
    var onFailure: (() -> Void)?
    var onStart: (() -> Void)?
    var onCommit: (() -> Void)?

    init(site: WebTranslatorSite) { self.site = site }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.targetFrame?.isMainFrame != false, let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if site.allowsNavigation(url) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            onBlocked?()
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        onBlocked?()
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { onStart?() }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { onCommit?() }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    private func report(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
        onFailure?()
    }
}

// MARK: - 진행 표시

struct WebTranslatorProgressRow: View {
    let status: WebTranslatorRunner.Status

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("\(status.translator.title) · \(status.stage)")
        }
    }
}

/// 보이는 웹 번역 창 머리글: 단계, 사용자가 할 일, 취소
private struct WebTranslatorTaskHeader: View {
    private let runner = WebTranslatorRunner.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let status = runner.status {
                    Text("\(status.translator.title) · \(status.stage)")
                } else {
                    Text("진행 중인 번역이 없습니다")
                }
                Spacer()
                Button("취소하고 닫기") { runner.cancelAll() }
                    .keyboardShortcut(.cancelAction)
            }
            Text(runner.status?.needsUser == true
                 ? "이 창에서 공식 페이지의 안내(쿠키 동의·보안 확인 등)를 직접 완료하세요. 페이지가 준비되면 번역을 이어서 진행합니다. 앱은 동의 버튼을 대신 누르거나 보안 확인을 우회하지 않습니다."
                 : "공식 번역 페이지입니다. 이 창을 닫으면 진행 중인 웹 번역을 모두 취소합니다. 이미 받은 번역 결과는 유지됩니다.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .padding(12)
    }
}

/// 브라우저 요청인데 떠 있는 앱 창이 없을 때만 쓰는, 이 기능이 소유한 화면 안의 평범한 창. 화면 구석에 실제로
/// 자리 잡지만(0×0·오프스크린·미부착 금지) 활성화되지도, 다른 창 위로 뜨지도 않고 늘 뒤에 머문다. 안의 웹 보기는
/// AIBIHostView의 불투명 덮개 아래에 있어 보이지 않는다. 취소·사용자 확인(로그인·CAPTCHA)이 필요해지면
/// reveal()이 웹 보기를 이 창에서 떼어 실제 보이는 WebTranslatorTaskHeader 창으로 옮긴다(이 창의 수명과 무관).
@MainActor
final class WebTranslatorBackgroundWindow {
    /// 키·메인이 될 수 없어 사용자가 포그라운드에서 쓰는 다른 앱·창을 가리거나 가져가지 않는다.
    private final class NonactivatingWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    let host: AIBIHostView
    private let window: NSWindow

    init() {
        let size = AIBIHiddenSurface.viewport
        let visible = NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: size)
        let origin = NSPoint(x: visible.maxX - size.width, y: visible.minY)
        let window = NonactivatingWindow(contentRect: NSRect(origin: origin, size: size),
                                         styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]
        self.window = window
        host = AIBIHostView(frame: NSRect(origin: .zero, size: size))
        window.contentView = host
    }

    func show() {
        guard !window.isVisible else { return }
        window.orderBack(nil)
    }

    func hide() {
        guard window.isVisible else { return }
        window.orderOut(nil)
    }
}

/// 메일·화면 번역 요청인데 숨김 표면(열린 결과 창)이 없을 때만 쓰는 작은 진행 창. 웹 보기는 불투명 덮개 아래에 있고,
/// 진행 단계와 취소만 보인다. 브라우저 요청은 이 패널을 쓰지 않고 WebTranslatorBackgroundWindow(또는 숨김 표면)를 쓴다.
@MainActor
final class WebTranslatorStatusPanel: NSObject, NSWindowDelegate {
    let host = AIBIHostView(frame: NSRect(origin: .zero, size: AIBIHiddenSurface.viewport))
    var onUserClose: (() -> Void)?
    private let panel: NSPanel
    private var closingProgrammatically = false

    override init() {
        let size = NSSize(width: 460, height: 84)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = "Barobogi 웹 번역 진행 중"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        host.frame.origin = .zero
        container.addSubview(host)
        let status = NSHostingView(rootView: WebTranslatorPanelContent())
        status.frame = container.bounds
        status.autoresizingMask = [.width, .height]
        container.addSubview(status)
        panel.contentView = container
        panel.delegate = self
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - size.width - 24, y: screen.maxY - 24))
        }
    }

    func show() {
        closingProgrammatically = false
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        guard panel.isVisible else { return }
        closingProgrammatically = true
        panel.orderOut(nil)
        closingProgrammatically = false
    }

    func windowWillClose(_ notification: Notification) {
        if !closingProgrammatically { onUserClose?() }
    }
}

private struct WebTranslatorPanelContent: View {
    private let runner = WebTranslatorRunner.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let status = runner.status {
                    WebTranslatorProgressRow(status: status)
                } else {
                    Text("대기 중")
                }
                Spacer()
                Button("취소") { runner.cancel(owner: runner.status?.owner ?? .mail) }
            }
            Text("메일·화면 번역이 요청한 글자를 공식 번역 페이지로 보내는 중입니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - DeepL 묶음 포장 (여러 항목을 번호 식별자로 감싸 한 번의 요청에 맞춰 넣는다)

/// 브라우저가 한 번에 보내는 여러 OCR/페이지 조각을 DeepL 공식 입력 한도(바이트가 아닌 UTF-16 글자 수) 안에서
/// 번호 식별자(##N##)로 감싸 묶는다. 식별자는 글자로 추측하지 않고 결과에서 그대로 찾아 되돌린다(DeepLBatcher.parse).
/// 혼자서도(식별자 포함) 한도를 넘는 항목은 묶지 않고 기존 항목 단위 경로(문장 조각 나누기 포함)로 돌려보낸다.
enum DeepLBatcher {
    struct Slot { let index: Int; let text: String }

    static func pack(_ texts: [String], limit: Int) -> (batches: [[Slot]], singles: [Slot]) {
        var batches: [[Slot]] = []
        var singles: [Slot] = []
        var current: [Slot] = []
        var currentLength = 0

        for (index, text) in texts.enumerated() {
            let slot = Slot(index: index, text: text)
            if envelopeLength(id: 1, text: text) > limit {
                singles.append(slot)
                continue
            }
            let nextID = current.count + 1
            let separator = current.isEmpty ? 0 : 1
            let addition = separator + envelopeLength(id: nextID, text: text)
            if !current.isEmpty && currentLength + addition > limit {
                batches.append(current)
                current = []
                currentLength = 0
            }
            let finalID = current.count + 1
            let finalSeparator = current.isEmpty ? 0 : 1
            current.append(slot)
            currentLength += finalSeparator + envelopeLength(id: finalID, text: text)
        }
        if !current.isEmpty { batches.append(current) }
        return (batches, singles)
    }

    static func envelope(_ slots: [Slot]) -> String {
        slots.enumerated().map { "\(marker($0.offset + 1))\n\($0.element.text)" }.joined(separator: "\n")
    }

    /// 묶음 결과를 번호별로 정확히 나눈다. 식별자가 빠지거나 겹치거나 순서가 바뀌거나(1..count 순서가 아니면)
    /// 어느 하나라도 비어 있으면 nil을 돌려주어, 호출한 쪽이 추측해서 채우지 않고 전체를 항목 실패로 돌리게 한다.
    static func parse(_ output: String, count: Int) -> [String]? {
        var order: [Int] = []
        var texts: [Int: String] = [:]
        var currentID: Int?
        var current = ""
        func flush() {
            guard let id = currentID else { return }
            texts[id] = current.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for line in output.components(separatedBy: "\n") {
            if let id = markerID(line) {
                flush()
                order.append(id)
                currentID = id
                current = ""
            } else {
                current += line + "\n"
            }
        }
        flush()
        let expected = Array(1...max(count, 1))
        guard count > 0, order == expected, texts.count == count, texts.values.allSatisfy({ !$0.isEmpty }) else { return nil }
        return expected.map { texts[$0] ?? "" }
    }

    private static func marker(_ id: Int) -> String { "##\(id)##" }

    /// 식별자 줄 + 줄바꿈 + 본문의 UTF-16 글자 수(한도를 재는 것과 같은 단위).
    private static func envelopeLength(id: Int, text: String) -> Int {
        marker(id).utf16.count + 1 + text.utf16.count
    }

    private static func markerID(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 4, trimmed.hasPrefix("##"), trimmed.hasSuffix("##") else { return nil }
        let inner = trimmed.dropFirst(2).dropLast(2)
        guard !inner.isEmpty, inner.allSatisfy(\.isNumber) else { return nil }
        return Int(inner)
    }
}

// MARK: - 브라우저 엔진 연결 (Chrome·Whale: 앱 안의 BrowserEngine이 호출)

/// BrowserEngine이 웹 번역 엔진 요청을 넘기는 어댑터. 앱의 전송 동의가 있어야 하며, DeepL은 한도 안에서 여러
/// 항목을 한 번에 묶어 보내고(DeepLBatcher), Google도 같은 번호 검사로 묶는다. Papago와 한도를 넘는 항목은 기존처럼 항목마다
/// 차례로 번역한다.
final class WebTranslatorBrowserBridge: BrowserExternalTranslating {
    let engineIDs = WebTranslator.allCases.map(\.rawValue)

    func prepare(source: String, target: String, engine: String) async {
        guard let translator = WebTranslator(rawValue: engine), translator == .google || translator == .deepl else { return }
        let ticket = await WebTranslatorRunner.shared.ticket(for: .browser)
        await WebTranslatorRunner.shared.prepare(source: source, target: target, using: translator, owner: .browser, ticket: ticket)
    }

    func unavailableReason(engine: String) async -> String? {
        await MainActor.run {
            guard let translator = WebTranslator(rawValue: engine) else { return "알 수 없는 번역 엔진입니다." }
            guard WebTranslatorConsentStore.shared.hasConsent(translator) else {
                let section = WebTranslatorConsentStore.pageTranslators.contains(translator) ? "현재 페이지 외부 번역 전송 동의" : "웹 번역 전송 동의"
                return "Barobogi 앱에서 \(translator.title) 전송 동의가 필요합니다. Barobogi 메뉴 막대 › 설정… › \(section)에서 동의한 뒤 다시 시도하세요."
            }
            return nil
        }
    }

    func translate(_ texts: [String], source: String, target: String, engine: String,
                   progress: BrowserProgressHandler?) async throws -> [String?] {
        guard let translator = WebTranslator(rawValue: engine) else { throw BrowserEngineError.badRequest("번역 엔진") }
        let ticket = await WebTranslatorRunner.shared.ticket(for: .browser)
        var output = [String?](repeating: nil, count: texts.count)

        // 진행 표시: 지금 보내는 묶음 번호·묶음 수·묶음의 항목 수·실제로 입력창에 넣는 글자 수(UTF-16, 식별자 포함)와 단계만
        // 알린다. 원문·결과는 담지 않는다.
        func phaseReporter(batch: Int, batches: Int, items: Int, chars: Int) -> (@Sendable (WebTranslatorRunner.Phase) -> Void)? {
            guard let progress else { return nil }
            return { phase in
                progress(BrowserProgress(phase: "external", step: phase.rawValue,
                                         counts: ["batch": batch, "batches": batches, "batchItems": items, "batchChars": chars]))
            }
        }

        func runItem(_ text: String, index: Int, batch: Int, batches: Int) async throws {
            let result = await WebTranslatorRunner.shared.translate(text, source: source, target: target, using: translator,
                                                                    owner: .browser, ticket: ticket,
                                                                    onPhase: phaseReporter(batch: batch, batches: batches, items: 1,
                                                                                           chars: text.utf16.count))
            switch result {
            case .success(let value): output[index] = value
            case .failure(.item): return
            case .failure(.cancelled): throw CancellationError()
            case .failure(.unsupported(let message)):
                throw BrowserExternalFailure(results: output, message: message, unsupported: true)
            case .failure(.fatal(let message)):
                throw BrowserExternalFailure(results: output, message: message, unsupported: false)
            }
        }

        guard translator == .deepl || translator == .google else {
            for (index, text) in texts.enumerated() {
                if Task.isCancelled { throw CancellationError() }
                try await runItem(text, index: index, batch: index + 1, batches: texts.count)
            }
            return output
        }

        // DeepL·Google: 한 번의 공식 페이지 요청으로 여러 항목을 보내 순차 요청의 누적 대기를 줄인다. 묶음에
        // 넣을 수 없는(혼자서도 한도를 넘는) 항목만 기존 항목 단위 경로로 보낸다.
        let (batches, singles) = DeepLBatcher.pack(texts, limit: translator.site.maxCharacters)
        let total = batches.count + singles.count
        for (number, batch) in batches.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            let sending = DeepLBatcher.envelope(batch).utf16.count
            let results = await WebTranslatorRunner.shared.translateBatch(batch.map(\.text), source: source, target: target,
                                                                          using: translator, owner: .browser, ticket: ticket,
                                                                          onPhase: phaseReporter(batch: number + 1, batches: total,
                                                                                                 items: batch.count, chars: sending))
            for (slot, result) in zip(batch, results) {
                switch result {
                case .success(let value): output[slot.index] = value
                case .failure(.item): continue
                case .failure(.cancelled): throw CancellationError()
                case .failure(.unsupported(let message)):
                    throw BrowserExternalFailure(results: output, message: message, unsupported: true)
                case .failure(.fatal(let message)):
                    throw BrowserExternalFailure(results: output, message: message, unsupported: false)
                }
            }
        }
        for (number, single) in singles.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            try await runItem(single.text, index: single.index, batch: batches.count + number + 1, batches: total)
        }
        return output
    }
}
