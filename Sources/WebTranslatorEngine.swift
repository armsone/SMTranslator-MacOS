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
                navigationHosts: ["translate.google.com", "consent.google.com"], maxCharacters: 5000,
                source: ["textarea[jsname=\"BJE2fc\"]", "textarea.er8xn"],
                target: ["span[jsname=\"jqKxS\"]"],
                outputParts: ["span[jsname=\"W297wb\"]"], targetOptional: true,
                sourceLanguage: nil,
                targetLanguage: LanguageProbe(selector: nil, attribute: "lang"))
        case .deepl:
            return WebTranslatorSite(
                translator: .deepl, host: "www.deepl.com",
                navigationHosts: ["www.deepl.com"], maxCharacters: 1500,
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
    @ObservationIgnored private var unsupportedPairs: [String: String] = [:]
    @ObservationIgnored private var navigationFailed = false
    @ObservationIgnored private var idleTask: Task<Void, Never>?

    private static let readyTimeout: TimeInterval = 30
    private static let userActionTimeout: TimeInterval = 300
    private static let languageSettleTime: TimeInterval = 8
    private static let idleTeardown: Duration = .seconds(90)

    private init() {}

    /// 실행(번역 버튼 한 번·브라우저 요청 하나)을 시작할 때 받는 표. 그 뒤 cancel(owner:)가 불리면 같은 표의 남은 항목은 보내지 않는다.
    func ticket(for owner: Owner) -> Int { tickets[owner, default: 0] }

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
                   owner: Owner, ticket: Int, surface: AIBIHostView? = nil) async -> Result<String, Failure> {
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

        let chunks = text.count > site.maxCharacters ? TextChunker.chunks(text) : [TextChunk(text: text, separator: "")]
        var joined = ""
        for chunk in chunks {
            switch await translateChunk(chunk.text, src: src, tgt: tgt, pair: pair, site: site,
                                        owner: owner, ticket: ticket, surface: surface) {
            case .success(let value): joined += value + chunk.separator
            case .failure(let failure): return .failure(failure)
            }
        }
        let result = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? .failure(.item("\(translator.title) 결과가 비어 있어 적용하지 않았습니다.")) : .success(result)
    }

    // MARK: 단계

    private func translateChunk(_ text: String, src: String, tgt: String, pair: String, site: WebTranslatorSite,
                                owner: Owner, ticket: Int, surface: AIBIHostView?) async -> Result<String, Failure> {
        let title = site.translator.title
        prepareWebView(site, owner: owner)
        mount(owner: owner, surface: surface)
        if loadedPair != pair || !(webView?.url.map(site.allowsScript) ?? false) {
            guard let url = site.pageURL(source: src, target: tgt) else { return .failure(.unsupported("\(title) 주소를 만들지 못했습니다.")) }
            setStage("\(title) 여는 중")
            navigationFailed = false
            loadedPair = pair
            webView?.load(URLRequest(url: url))
        }

        // 1) 페이지 준비(입력창·결과 칸)와 고른 언어 확인
        let started = Date()
        var tookOver = false
        var mismatchSince: Date?
        setStage("\(title) 화면 준비 중")
        ready: while true {
            guard isCurrent(owner, ticket) else { return .failure(.cancelled) }
            let elapsed = Date().timeIntervalSince(started)
            if !tookOver && elapsed > Self.readyTimeout {
                tookOver = true
                reveal("\(title) 페이지에서 직접 확인이 필요합니다(쿠키 동의·보안 확인 등). 확인되면 이어서 번역합니다.", needsUser: true)
            }
            if elapsed > Self.readyTimeout + Self.userActionTimeout {
                return .failure(.fatal("\(title) 페이지가 준비되지 않아 중단했습니다(최대 5분 대기)."))
            }
            await pause(0.4)
            guard isCurrent(owner, ticket), let webView else { return .failure(.cancelled) }
            if navigationFailed {
                loadedPair = nil
                return .failure(.fatal("네트워크 오류로 \(title) 페이지를 열지 못했습니다. 인터넷 연결을 확인한 뒤 다시 시도하세요."))
            }
            guard let url = webView.url, site.allowsScript(url), !webView.isLoading,
                  let probe = await page("probe", site: site, owner: owner, ticket: ticket), probe.ready else { continue }
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
        if tookOver { status?.needsUser = false }

        // 2) 이전 항목 지우기 → 결과 칸이 비는지 확인(이전 결과를 이번 결과로 오인하지 않도록)
        setStage("원문 입력 중")
        _ = await page("clear", site: site, owner: owner, ticket: ticket)
        var baseline = ""
        let clearStarted = Date()
        while Date().timeIntervalSince(clearStarted) < 5 {
            guard isCurrent(owner, ticket) else { return .failure(.cancelled) }
            await pause(0.3)
            guard let probe = await page("probe", site: site, owner: owner, ticket: ticket) else { continue }
            baseline = probe.output
            if baseline.isEmpty { break }
        }

        // 3) 입력 후 입력창 내용이 원문과 같은지 확인. 편집기는 붙여넣기를 비동기로 반영하므로 잠시 확인한 뒤에만
        //    전체 선택 + 글자 입력으로 바꿔 넣는다(전체를 바꾸므로 두 번 들어가지 않는다).
        var filled = false
        attempts: for action in ["fill", "insert"] {
            guard isCurrent(owner, ticket) else { return .failure(.cancelled) }
            _ = await page(action, text: text, site: site, owner: owner, ticket: ticket)
            let attempted = Date()
            while Date().timeIntervalSince(attempted) < 1.5 {
                await pause(0.3)
                guard isCurrent(owner, ticket) else { return .failure(.cancelled) }
                if let probe = await page("probe", site: site, owner: owner, ticket: ticket),
                   Self.normalized(probe.source) == Self.normalized(text) {
                    filled = true
                    break attempts
                }
            }
        }
        guard isCurrent(owner, ticket) else { return .failure(.cancelled) }
        guard filled else {
            reveal("\(title) 입력창에 원문을 넣지 못했습니다.", needsUser: false)
            return .failure(.fatal("\(title) 입력창에 원문을 넣지 못했습니다. 페이지 구성이 바뀌었을 수 있습니다."))
        }

        // 4) 결과가 생기고 3회 연속 같을 때 완료로 본다.
        setStage("번역 결과 기다리는 중")
        let limit = 30 + Double(text.count) / 100
        let waitStarted = Date()
        var last: String?
        var stable = 0
        var sourceChanged = 0
        while true {
            guard isCurrent(owner, ticket) else { return .failure(.cancelled) }
            if Date().timeIntervalSince(waitStarted) > limit {
                reveal("\(title) 번역 결과를 받지 못했습니다. 페이지 상태를 확인하세요.", needsUser: false)
                return .failure(.fatal("제한 시간(\(Int(limit))초) 안에 \(title) 번역 결과를 받지 못했습니다. 열린 창에서 사용 한도·보안 확인 등 페이지 상태를 확인한 뒤 다시 시도하세요."))
            }
            await pause(0.4)
            guard let probe = await page("probe", site: site, owner: owner, ticket: ticket) else { continue }
            if Self.normalized(probe.source) != Self.normalized(text) {
                sourceChanged += 1
                if sourceChanged >= 3 {
                    return .failure(.fatal("\(title) 입력창의 원문이 바뀌어 이 항목을 적용하지 않았습니다."))
                }
                continue
            }
            sourceChanged = 0
            let output = probe.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty, baseline.isEmpty || output != baseline.trimmingCharacters(in: .whitespacesAndNewlines) else {
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
            return .success(Self.cleaned(output, source: text))
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
        // 다음 항목이 곧 이어질 수 있으므로 표시는 잠시 두고, 오래 쉬면 웹 보기를 닫는다.
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, !self.busy else { return }
            if self.window == nil { self.status = nil }
            self.panel?.hide()
            try? await Task.sleep(for: Self.idleTeardown)
            guard !Task.isCancelled, !self.busy, self.window == nil else { return }
            self.teardown()
        }
    }

    // MARK: 웹 보기 수명

    private func prepareWebView(_ site: WebTranslatorSite, owner: Owner) {
        if webView == nil || self.site?.translator != site.translator {
            teardown()
            let webView = AIBIWebView(frame: NSRect(origin: .zero, size: AIBIHiddenSurface.viewport),
                                      configuration: AIBIRegistry.makeConfiguration())
            webView.interactive = false
            webView.allowsLinkPreview = false
            let guardian = WebTranslatorNavigationGuard(site: site)
            guardian.onFailure = { [weak self] in self?.navigationFailed = true }
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

    /// 보이는 창(사용자 확인 중)이면 그대로 두고, 아니면 기능별 숨김 표면(메일 결과 창·화면 번역 창) 또는 작은 진행 창에 붙인다.
    /// 브라우저 요청은 사용자가 다른 앱에 있으므로 항상 진행 창(취소 버튼 포함)을 보여 준다.
    private func mount(owner: Owner, surface: AIBIHostView?) {
        guard let webView, window == nil else { return }
        var host: AIBIHostView?
        if owner != .browser { host = AIBIHiddenSurface.shared.availableHost(preferring: surface) }
        if let host {
            panel?.hide()
            if webView.superview !== host {
                webView.removeFromSuperview()
                host.attach(webView)
            }
        } else {
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
        navigationGuard = nil
        site = nil
        loadedPair = nil
        unsupportedPairs = [:]
        window?.close()
        window = nil
        panel?.hide()
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

    /// 허용한 번역 페이지(최상위 프레임)에서만, 페이지와 분리된 콘텐츠 월드로 어댑터를 실행한다. 값은 인자로만 넘긴다.
    private func page(_ action: String, text: String = "", site: WebTranslatorSite, owner: Owner, ticket: Int) async -> Probe? {
        guard isCurrent(owner, ticket), let webView, self.site?.translator == site.translator,
              let url = webView.url, site.allowsScript(url), !webView.isLoading else { return nil }
        let arguments: [String: Any] = ["site": site.scriptDescriptor, "action": action, "text": text]
        let probe = await withCheckedContinuation { (continuation: CheckedContinuation<Probe?, Never>) in
            webView.callAsyncJavaScript(Self.adapterScript, arguments: arguments, in: nil, in: .defaultClient) { result in
                guard case .success(let value) = result, let data = value as? [String: Any] else {
                    continuation.resume(returning: nil)
                    return
                }
                var probe = Probe()
                probe.ready = data["ready"] as? Bool ?? false
                probe.source = data["source"] as? String ?? ""
                probe.output = data["output"] as? String ?? ""
                probe.sourceLang = data["sourceLang"] as? String
                probe.targetLang = data["targetLang"] as? String
                continuation.resume(returning: probe)
            }
        }
        guard isCurrent(owner, ticket), self.webView === webView else { return nil }
        return probe
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
      if (!site.parts.length) return target.innerText || '';
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
    return {
      ready: !!source && (!!target || site.targetOptional === true),
      source: readSource(),
      output: readOutput(),
      sourceLang: readLang(site.sourceLang, source),
      targetLang: readLang(site.targetLang, target)
    };
    """
}

// MARK: - 내비게이션 보안 (메인 프레임은 허용 호스트만, 새 창 금지)

@MainActor
final class WebTranslatorNavigationGuard: NSObject, WKNavigationDelegate, WKUIDelegate {
    let site: WebTranslatorSite
    var onBlocked: (() -> Void)?
    var onFailure: (() -> Void)?

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

/// 숨김 표면이 없을 때(브라우저 요청 등) 웹 보기를 붙이는 작은 진행 창. 웹 보기는 불투명 덮개 아래에 있고, 진행 단계와 취소만 보인다.
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
                Button("취소") { runner.cancel(owner: runner.status?.owner ?? .browser) }
            }
            Text("브라우저 확장이 요청한 글자를 공식 번역 페이지로 보내는 중입니다. 자동 번역을 끄려면 확장에서 '원문 보기'를 누르세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - 브라우저 엔진 연결 (Chrome·Whale: 앱 안의 BrowserEngine이 호출)

/// BrowserEngine이 웹 번역 엔진 요청을 넘기는 어댑터. 앱의 전송 동의가 있어야 하며, 항목마다 차례로 번역한다.
final class WebTranslatorBrowserBridge: BrowserExternalTranslating {
    let engineIDs = WebTranslator.allCases.map(\.rawValue)

    func unavailableReason(engine: String) async -> String? {
        await MainActor.run {
            guard let translator = WebTranslator(rawValue: engine) else { return "알 수 없는 번역 엔진입니다." }
            guard WebTranslatorConsentStore.shared.hasConsent(translator) else {
                return "Barobogi 앱에서 \(translator.title) 전송 동의가 필요합니다. Barobogi 메뉴 막대 › 설정… › 웹 번역 전송 동의에서 동의한 뒤 다시 시도하세요."
            }
            return nil
        }
    }

    func translate(_ texts: [String], source: String, target: String, engine: String) async throws -> [String?] {
        guard let translator = WebTranslator(rawValue: engine) else { throw BrowserEngineError.badRequest("번역 엔진") }
        let ticket = await WebTranslatorRunner.shared.ticket(for: .browser)
        var output = [String?](repeating: nil, count: texts.count)
        for (index, text) in texts.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            let result = await WebTranslatorRunner.shared.translate(text, source: source, target: target, using: translator,
                                                                    owner: .browser, ticket: ticket)
            switch result {
            case .success(let value): output[index] = value
            case .failure(.item): continue
            case .failure(.cancelled): throw CancellationError()
            case .failure(.unsupported(let message)):
                throw BrowserExternalFailure(results: output, message: message, unsupported: true)
            case .failure(.fatal(let message)):
                throw BrowserExternalFailure(results: output, message: message, unsupported: false)
            }
        }
        return output
    }
}
