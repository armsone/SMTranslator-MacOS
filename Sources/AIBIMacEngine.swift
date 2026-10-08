import AppKit
import SwiftUI
import WebKit

// AIBI(AI Browser Interface)의 macOS 네이티브 어댑터.
// 기준: /Users/armsone/git/AIBI 0.5.3 — packages/apple/AIBIEngine.swift(UIKit)의 상태 기계를 AppKit으로 옮기고,
// 제공사 선택자와 페이지 조작은 번들에 그대로 복사한 공통 런타임(aibi-browser-runtime.js)과
// 제공사 레지스트리(aibi-providers.json)를 사용한다. 이미지 첨부 경로는 이 앱에서 쓰지 않으므로 옮기지 않았다.
// 로그인·실행 웹 보기는 모두 WKWebsiteDataStore.default()를 공유한다(메일 서식 보기는 별도의 비영구 저장소).
// 프롬프트·답변·URL·쿠키·원시 오류는 로그나 진단에 남기지 않는다.
// SMTranslator(스크린 메일 번역기) 통합: 메일 어댑터를 그대로 옮기고 호스트 연결만 더했다 — 실행 주인(메일/화면)별 취소,
// 화면 번역 창 머리글의 숨김 표면 선택, 화면 글자 항목 종류. 선택자·런타임·레지스트리는 바꾸지 않았다.

enum AIProvider: String, CaseIterable, Identifiable {
    case chatgpt, claude, gemini
    var id: Self { self }

    var title: String {
        switch self {
        case .chatgpt: return "ChatGPT"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        }
    }
}

// MARK: - 제공사 레지스트리

struct AIBIProviderConfig {
    let provider: AIProvider
    let initialURL: URL
    let scriptOrigins: [URL]
    let authOrigins: [URL]
    let selectors: [String: [String]]
    /// 공통 런타임 함수에 그대로 넘기는 레지스트리 항목
    let json: [String: Any]

    /// 공식 실행 origin이면서 인증 경로(예: claude.ai/login)가 아닐 때만 스크립트를 실행한다.
    func allowsScript(_ url: URL) -> Bool {
        scriptOrigins.contains { Self.matches(url, $0) } && !isAuth(url)
    }

    func isAuth(_ url: URL) -> Bool {
        authOrigins.contains { Self.matches(url, $0) }
    }

    func allowsNavigation(_ url: URL) -> Bool {
        if url.scheme == "about" { return true }
        return scriptOrigins.contains { Self.matches(url, $0) } || isAuth(url)
    }

    private static func matches(_ url: URL, _ origin: URL) -> Bool {
        guard url.scheme?.lowercased() == origin.scheme?.lowercased(),
              url.host?.lowercased() == origin.host?.lowercased(),
              url.port == origin.port else { return false }
        let prefix = origin.path
        return prefix.isEmpty || prefix == "/" || url.path.hasPrefix(prefix)
    }
}

@MainActor
enum AIBIRegistry {
    static let runtimeSource: String? = Bundle.main.url(forResource: "aibi-browser-runtime", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// 호스트 프로필: Google 계정 로그인 중 거치는 공식 Google 인증 주소. 스크립트는 실행하지 않는다.
    private static let hostAuthOrigins = ["https://accounts.youtube.com", "https://consent.google.com"]

    private static let configs: [AIProvider: AIBIProviderConfig] = {
        guard let url = Bundle.main.url(forResource: "aibi-providers", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = root["providers"] as? [String: Any] else { return [:] }
        var result: [AIProvider: AIBIProviderConfig] = [:]
        for provider in AIProvider.allCases {
            guard let entry = providers[provider.rawValue] as? [String: Any],
                  entry["status"] as? String == "active",
                  let initial = (entry["initialUrl"] as? String).flatMap(URL.init(string:)),
                  let scripts = entry["allowedScriptOrigins"] as? [String],
                  let auths = entry["allowedAuthOrigins"] as? [String],
                  let selectors = entry["selectors"] as? [String: [String]] else { continue }
            result[provider] = AIBIProviderConfig(
                provider: provider,
                initialURL: initial,
                scriptOrigins: scripts.compactMap(URL.init(string:)),
                authOrigins: (auths + hostAuthOrigins).compactMap(URL.init(string:)),
                selectors: selectors,
                json: entry
            )
        }
        return result
    }()

    static func config(_ provider: AIProvider) -> AIBIProviderConfig? { configs[provider] }

    /// 모든 로그인·실행 웹 보기가 같은 영구 저장소(WKWebsiteDataStore.default())를 쓴다.
    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        // 기본 WKWebView 사용자 에이전트에는 Safari 버전 표기가 없어 일부 공식 로그인 화면이 지원하지 않는 브라우저로 판단한다.
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        configuration.applicationNameForUserAgent = "Version/\(major >= 26 ? major : major + 3).0 Safari/605.1.15"
        return configuration
    }

    /// 계정 표식(긍정 증거) 우선 판정. 작성기·contenteditable·전송 버튼·쿠키는 로그인 증거로 쓰지 않는다.
    static let authProbeScript = """
    const visible = (el) => {
      if (!el) return false;
      const style = window.getComputedStyle(el);
      if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
      const rect = el.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    };
    const any = (list) => {
      for (const selector of (list || [])) {
        try { for (const el of document.querySelectorAll(selector)) { if (visible(el)) return true; } } catch (_) {}
      }
      return false;
    };
    if (any(challenge)) return 'challenge';
    if (any(authenticated)) return 'authenticated';
    if (any(login)) return 'login';
    for (const el of document.querySelectorAll('a, button')) {
      if (!visible(el)) continue;
      const text = String(el.innerText || el.getAttribute('aria-label') || '').trim().toLowerCase();
      if (['log in', 'login', 'sign in', '로그인', '로그인하기'].includes(text)) return 'login';
    }
    return 'pending';
    """

    /// 반환값: "authenticated" / "login" / "challenge" / "pending", 스크립트 불가 origin이면 nil
    static func probeAuth(_ webView: WKWebView, config: AIBIProviderConfig) async -> String? {
        guard let url = webView.url, config.allowsScript(url) else { return nil }
        let arguments: [String: Any] = [
            "authenticated": config.selectors["authenticatedIndicator"] ?? [],
            "login": config.selectors["loginIndicator"] ?? [],
            "challenge": config.selectors["challengeIndicator"] ?? []
        ]
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            webView.callAsyncJavaScript(authProbeScript, arguments: arguments, in: nil, in: .defaultClient) { result in
                if case .success(let value) = result { continuation.resume(returning: value as? String) }
                else { continuation.resume(returning: nil) }
            }
        }
    }
}

// MARK: - 웹 보기와 숨김 표면

final class AIBIWebView: WKWebView {
    /// 숨김 실행·상태 확인용이면 false: 마우스·키보드 입력과 첫 응답자를 받지 않는다.
    var interactive = true
    override var acceptsFirstResponder: Bool { interactive && super.acceptsFirstResponder }
    override func hitTest(_ point: NSPoint) -> NSView? { interactive ? super.hitTest(point) : nil }
}

/// 실제 창에 붙은 기준 크기의 웹 보기를 불투명 덮개 아래에 둔다(화면 밖·0×0·창에 붙지 않은 웹 보기는 쓰지 않음).
final class AIBIHostView: NSView {
    private let cover = AIBICoverView()

    /// coverColor: 덮개를 호스트 배경과 같은 불투명 색으로 칠할 때 지정(기본은 창 배경색)
    init(frame: NSRect, coverColor: NSColor? = nil) {
        super.init(frame: frame)
        cover.fixedColor = coverColor
        cover.frame = bounds
        cover.autoresizingMask = [.width, .height]
        addSubview(cover)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    func attach(_ webView: NSView) {
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView, positioned: .below, relativeTo: cover)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { AIBIHiddenSurface.shared.hostMoved(self, to: window) }
    }
}

private final class AIBICoverView: NSView {
    var fixedColor: NSColor?
    override var wantsUpdateLayer: Bool { true }
    override var isOpaque: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (fixedColor?.withAlphaComponent(1) ?? NSColor.windowBackgroundColor).cgColor
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class AIBIHiddenSurface {
    static let shared = AIBIHiddenSurface()
    /// macOS 데스크톱 기준 화면 크기(제공사가 계정 메뉴를 펼친 데스크톱 레이아웃을 쓰도록)
    static let viewport = NSSize(width: 1100, height: 800)

    private final class WeakHost {
        weak var view: AIBIHostView?
        init(_ view: AIBIHostView) { self.view = view }
    }
    private var hosts: [WeakHost] = []
    /// 메인 창(ContentView) 쪽 표면이 붙은 창. 다른 창(설정·AI 브라우저)과 구분하는 데 쓴다.
    private(set) weak var mainWindow: NSWindow?

    func register(_ view: AIBIHostView, isMain: Bool) {
        hosts.removeAll { $0.view == nil || $0.view === view }
        hosts.append(WeakHost(view))
        if isMain { mainHost = view }
    }

    private weak var mainHost: AIBIHostView?

    fileprivate func hostMoved(_ view: AIBIHostView, to window: NSWindow) {
        if view === mainHost { mainWindow = window }
    }

    /// 보이는 창에 붙어 있는 표면. 없으면 숨김 실행을 하지 않는다.
    /// 우선순위: 호출자가 지정한 표면 → 메일 결과 창 → 가장 최근에 붙은 표면(설정 창 등).
    func availableHost(preferring preferred: AIBIHostView? = nil) -> AIBIHostView? {
        let candidates = [preferred, mainHost].compactMap { $0 } + hosts.reversed().compactMap(\.view)
        return candidates.first { view in
            guard let window = view.window else { return false }
            return window.isVisible && !window.isMiniaturized
        }
    }
}

struct AIBIHiddenHost: NSViewRepresentable {
    var isMain = false

    func makeNSView(context: Context) -> AIBIHostView {
        let view = AIBIHostView(frame: NSRect(origin: .zero, size: AIBIHiddenSurface.viewport))
        AIBIHiddenSurface.shared.register(view, isMain: isMain)
        return view
    }

    func updateNSView(_ nsView: AIBIHostView, context: Context) {}
}

extension View {
    /// 숨김 AIBI 웹 보기를 붙일 표면. 레이아웃 크기에 영향을 주지 않고, 불투명 덮개 아래에만 놓인다.
    func aibiHiddenSurface(isMain: Bool = false) -> some View {
        background(alignment: .topLeading) {
            AIBIHiddenHost(isMain: isMain)
                .frame(width: AIBIHiddenSurface.viewport.width, height: AIBIHiddenSurface.viewport.height)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - 내비게이션 보안

/// 메인 프레임은 공식 실행 origin과 인증 origin만 허용한다. 하위 프레임(제공사 CDN·보안 확인)은 스크립트를 넣지 않으므로 허용.
@MainActor
final class AIBINavigationGuard: NSObject, WKNavigationDelegate, WKUIDelegate {
    let config: AIBIProviderConfig
    var onBlocked: (() -> Void)?
    var onFinish: (() -> Void)?
    var onFailure: (() -> Void)?

    init(config: AIBIProviderConfig) { self.config = config }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.targetFrame?.isMainFrame != false, let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if config.allowsNavigation(url) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            onBlocked?()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish?() }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    private func report(_ error: Error) {
        let nsError = error as NSError
        // 리디렉션 중 정상 취소(-999)와 정책 변경으로 끊긴 로드(102)는 오류가 아니다.
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
        onFailure?()
    }

    private struct AuthPopup {
        let view: WKWebView
        let window: AIBIBrowserWindow
    }
    private var authPopups: [ObjectIdentifier: AuthPopup] = [:]

    /// Return a real child WebView so OAuth retains window.opener and postMessage.
    /// Automation is never injected in these authentication children.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url, config.allowsNavigation(url), authPopups.count < 4 else {
            onBlocked?()
            return nil
        }
        let child = AIBIWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        child.navigationDelegate = self
        child.uiDelegate = self
        let key = ObjectIdentifier(child)
        let popup = AIBIBrowserWindow(title: "\(config.provider.title) 공식 로그인", header: Text("공식 계정 로그인"), webView: child)
        popup.onUserClose = { [weak self] in self?.closePopup(key) }
        authPopups[key] = AuthPopup(view: child, window: popup)
        popup.show()
        return child
    }

    func webViewDidClose(_ webView: WKWebView) {
        closePopup(ObjectIdentifier(webView))
        onFinish?()
    }

    private func closePopup(_ key: ObjectIdentifier) {
        guard let popup = authPopups.removeValue(forKey: key) else { return }
        popup.view.stopLoading()
        popup.view.navigationDelegate = nil
        popup.view.uiDelegate = nil
        popup.window.close()
    }

    func closePopups() {
        for key in Array(authPopups.keys) { closePopup(key) }
    }

}

// MARK: - 보이는 AI 브라우저 창

@MainActor
final class AIBIBrowserWindow: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private var closingProgrammatically = false
    var onUserClose: (() -> Void)?

    init<Header: View>(title: String, header: Header, webView: WKWebView) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 860),
                        styleMask: [.titled, .closable, .resizable, .miniaturizable],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.minSize = NSSize(width: 640, height: 480)
        panel.contentView = NSHostingView(rootView: VStack(spacing: 0) {
            header
            Divider()
            AIBIWebViewContainer(webView: webView)
        })
        panel.delegate = self
        panel.center()
    }

    func show() {
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        closingProgrammatically = true
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        if !closingProgrammatically { onUserClose?() }
    }
}

private struct AIBIWebViewContainer: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - 실행 상태

enum AIBIUserAction: Equatable {
    case login      // 로그인 필요
    case challenge  // CAPTCHA·보안 확인
    case manual     // 자동 입력이 제공사 화면 변화로 실패 → 수동 진행
}

struct AIBIRunStatus: Equatable {
    let provider: AIProvider
    var stage: String
    /// 전송 후 생성이 확인된 시점부터의 마감(119초). nil이면 아직 생성 전 단계.
    var observationDeadline: Date?
    var isVisible: Bool
    var userAction: AIBIUserAction?
    var manualError: String?
}

enum AIBIOutcome {
    case applied
    case failed(String)
    case cancelled
}

/// 결과 sink: nil이면 적용 완료, 문자열이면 거부 사유
typealias AIBIResultSink = (String) -> String?

/// 실행을 시작한 기능. 한 기능의 정리 작업이 다른 기능의 진행 중 실행을 취소하지 않게 한다.
enum AIBIRunOwner {
    case mail
    case screen
}

// MARK: - 실행기 (숨김/보이기, 1회 전송, 3회 안정 관찰, 119초 상한, 취소)

@MainActor
@Observable
final class AIBIRunner {
    static let shared = AIBIRunner()
    static let observationLimit: TimeInterval = 119
    static let geminiTemporaryFailure = "Gemini가 일시적인 처리 오류를 반환했습니다."
    static let retryableFormatFailure = "외부 AI 번역 응답의 항목 형식이 맞지 않아 다시 요청합니다."

    private(set) var status: AIBIRunStatus?

    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var config: AIBIProviderConfig?
    @ObservationIgnored private var webView: AIBIWebView?
    @ObservationIgnored private var navigationGuard: AIBINavigationGuard?
    @ObservationIgnored private var window: AIBIBrowserWindow?
    @ObservationIgnored private var promptSource: (() -> String?)?
    @ObservationIgnored private var cachedPrompt: String?
    @ObservationIgnored private var sink: AIBIResultSink?
    @ObservationIgnored private var manualContinuation: CheckedContinuation<AIBIOutcome, Never>?
    @ObservationIgnored private var runID: UUID?
    @ObservationIgnored private var blockedNavigation = false
    @ObservationIgnored private var navigationFailed = false
    @ObservationIgnored private var runtimeFailureLogged = false
    @ObservationIgnored private var allowsFormatRetry = false
    /// 현재 실행을 시작한 기능(메일/화면). 실행이 없으면 nil.
    @ObservationIgnored private(set) var owner: AIBIRunOwner?

    private init() {}

    /// 작업 하나를 끝까지 진행한다. 다른 제공사나 Apple 번역으로 대체하지 않는다.
    /// - prompt: 입력 직전에 한 번만 호출된다(그 사이 끝난 OCR 결과도 포함되도록). nil이면 보낼 것이 없음.
    /// - manualOnly: 자동 입력 없이 공식 화면 + 프롬프트 복사·응답 붙여넣기로만 진행
    func run(provider: AIProvider, owner: AIBIRunOwner, alwaysVisible: Bool, manualOnly: Bool = false, allowsFormatRetry: Bool = false,
             surface: AIBIHostView? = nil,
             prompt: @escaping () -> String?, sink: @escaping AIBIResultSink) async -> AIBIOutcome {
        cancel()
        guard let config = AIBIRegistry.config(provider), AIBIRegistry.runtimeSource != nil else {
            return .failed("외부 AI 구성 파일(aibi-providers.json, aibi-browser-runtime.js)을 읽지 못했습니다. 앱을 다시 빌드·설치해 주세요.")
        }
        generation &+= 1
        let gen = generation
        self.config = config
        promptSource = prompt
        cachedPrompt = nil
        self.sink = sink
        blockedNavigation = false
        navigationFailed = false
        runtimeFailureLogged = false
        self.allowsFormatRetry = allowsFormatRetry
        self.owner = owner
        runID = AIBIDiagnosticsStore.shared.start(provider: provider.rawValue)
        status = AIBIRunStatus(provider: provider, stage: "\(provider.title) 여는 중", observationDeadline: nil,
                               isVisible: false, userAction: nil, manualError: nil)

        if !alwaysVisible && !manualOnly, let host = AIBIHiddenSurface.shared.availableHost(preferring: surface) {
            mountHidden(in: host)
        } else {
            presentVisible()
        }
        webView?.load(URLRequest(url: config.initialURL))

        let outcome: AIBIOutcome
        if manualOnly {
            outcome = await takeover(.manual, gen: gen) ?? .cancelled
        } else {
            outcome = await drive(gen: gen)
        }
        guard gen == generation else { return .cancelled }
        finish(outcome)
        return outcome
    }

    /// 지정한 기능이 시작한 실행일 때만 취소한다(다른 기능의 실행은 그대로 둔다).
    func cancel(owner: AIBIRunOwner) {
        guard self.owner == owner else { return }
        cancel()
    }

    /// 진행 중인 작업을 즉시 무효화한다(웹 보기·관찰·세대 모두). 늦게 도착한 결과는 반영되지 않는다.
    func cancel() {
        guard status != nil || manualContinuation != nil else { return }
        generation &+= 1
        log("run_cancelled")
        let continuation = manualContinuation
        manualContinuation = nil
        teardown()
        continuation?.resume(returning: .cancelled)
    }

    /// 사용자가 '프롬프트 복사'를 눌렀을 때만 클립보드에 넣는다.
    func copyPrompt() {
        guard let prompt = currentPrompt() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
    }

    /// 수동 경로: 사용자가 붙여 넣은 응답도 같은 검증(sink)을 거친다.
    func applyManual(_ text: String) {
        guard let continuation = manualContinuation, let sink else { return }
        guard currentPrompt() != nil else { return }
        if let error = sink(text) {
            log("response_rejected", ["response_length": text.count])
            status?.manualError = error
            return
        }
        log("result_applied", ["response_length": text.count])
        manualContinuation = nil
        continuation.resume(returning: .applied)
    }

    // MARK: 단계

    private enum Readiness { case ready, needs(AIBIUserAction), failed(String), cancelled }
    private enum Submission { case submitted(baseline: Int), needsManual, needsLogin, failed(String), cancelled }

    private func drive(gen: UInt64) async -> AIBIOutcome {
        while isCurrent(gen) {
            switch await waitForReadiness(gen: gen) {
            case .cancelled:
                return .cancelled
            case .failed(let message):
                return .failed(message)
            case .needs(let action):
                if let outcome = await takeover(action, gen: gen) { return outcome }
                continue // 로그인·보안 확인 완료 → 보이는 브라우저에서 이어서 자동 진행
            case .ready:
                break
            }
            switch await injectAndSubmit(gen: gen) {
            case .cancelled: return .cancelled
            case .failed(let message): return .failed(message)
            case .needsManual: return await takeover(.manual, gen: gen) ?? .cancelled
            case .needsLogin:
                if let outcome = await takeover(.login, gen: gen) { return outcome }
                continue
            case .submitted(let baseline): return await observe(gen: gen, baseline: baseline)
            }
        }
        return .cancelled
    }

    private func waitForReadiness(gen: UInt64) async -> Readiness {
        guard let config else { return .cancelled }
        let started = Date()
        var misses = 0
        setStage("\(config.provider.title) 화면 준비 중")
        while isCurrent(gen) {
            if Date().timeIntervalSince(started) > 35 {
                log("composer_missing", ["composer_present": 0, "attempt": misses])
                return .needs(.manual)
            }
            await pause(0.7)
            guard isCurrent(gen), let webView else { return .cancelled }
            if navigationFailed {
                log("browser_load_failed")
                return .failed("네트워크 오류로 \(config.provider.title) 페이지를 열지 못했습니다. 인터넷 연결을 확인한 뒤 다시 시도하세요.")
            }
            if blockedNavigation {
                blockedNavigation = false
                if status?.isVisible == false { return .needs(.login) }
            }
            guard let url = webView.url, !webView.isLoading else { continue }
            if config.isAuth(url) && !config.allowsScript(url) { return .needs(.login) }
            guard config.allowsScript(url),
                  let data = await callRuntime("checkReadiness", on: webView, gen: gen)?["data"] as? [String: Any] else { continue }
            guard isCurrent(gen) else { return .cancelled }
            if data["isLoggedIn"] as? Bool == false { return .needs(.login) }
            if data["hasChallenge"] as? Bool == true { return .needs(.challenge) }
            if data["isReady"] as? Bool == true {
                // 작성기가 있어도 로그인 화면 표식이 보이면 로그인 필요로 본다(작성기는 로그인 증거가 아님).
                let auth = await AIBIRegistry.probeAuth(webView, config: config)
                guard isCurrent(gen) else { return .cancelled }
                if auth == "login" { return .needs(.login) }
                if auth == "challenge" { return .needs(.challenge) }
                guard auth == "authenticated" else {
                    return .needs(.login)
                }
                AIBIAccounts.shared.observed(config.provider, .authenticated)
                log("composer_found", ["composer_present": 1])
                return .ready
            }
            if data["reason"] as? String == "INPUT_NOT_FOUND" {
                misses += 1
                if misses >= 12 {
                    log("composer_missing", ["composer_present": 0, "attempt": misses])
                    return .needs(.manual)
                }
            }
        }
        return .cancelled
    }

    private func injectAndSubmit(gen: UInt64) async -> Submission {
        guard let config, let webView else { return .cancelled }
        guard !webView.isLoading else { return .needsManual }
        let authenticated = await AIBIRegistry.probeAuth(webView, config: config)
        guard isCurrent(gen) else { return .cancelled }
        if authenticated == "login" { return .needsLogin }
        guard authenticated == "authenticated" else { return .needsManual }
        setStage("요청 입력 중")
        let baseline = (await callRuntime("getBaselineState", on: webView, gen: gen)?["data"] as? [String: Any])?["assistantCount"] as? Int ?? 0
        guard isCurrent(gen) else { return .cancelled }
        guard let prompt = currentPrompt() else { return .failed("보낼 번역 항목이 없습니다.") }

        // A cancelled translation may leave this app's request as a provider draft.
        // Replace only the exact instruction envelope + validated item schema; preserve other drafts.
        let draftScript = """
        const input = config.selectors.promptInput.map(s => { try { return document.querySelector(s); } catch (_) { return null; } }).find(Boolean);
        if (!input) return false;
        const current = (input.value || input.innerText || '').trim();
        const normalize = x => String(x).replace(/\\s+/g, ' ').trim();
        if (!current || normalize(current) === normalize(prompt)) return false;
        const marker = '\\nINPUT\\n';
        const boundary = prompt.indexOf(marker);
        if (boundary < 0) return false;
        const normalizeEnvelope = x => normalize(x).replace(/@@[0-9a-f]{8}:(t[1-9][0-9]*|END)@@/g, '@@TOKEN:$1@@');
        const envelope = normalizeEnvelope(prompt.slice(0, boundary));
        const match = current.match(/^(.*?)\\bINPUT\\s+(\\{.*\\})\\s+END OF INPUT$/s);
        if (!match || normalizeEnvelope(match[1]) !== envelope) return false;
        try {
          const data = JSON.parse(match[2]);
          if (Object.keys(data).length !== 1 || !Array.isArray(data.items) || !data.items.length) return false;
          const ids = new Set();
          for (const item of data.items) {
            if (Object.keys(item).sort().join(',') !== 'id,kind,text' || !/^t[1-9][0-9]*$/.test(item.id) ||
                typeof item.text !== 'string' || !['subject','body','image-text','screen-text'].includes(item.kind) || ids.has(item.id)) return false;
            ids.add(item.id);
          }
          return true;
        } catch (_) { return false; }
        """
        // 위의 계정 확인·기준 상태 확인 await 사이에 인증 경로로 이동했을 수 있으므로 공통 보호 경로로만 실행한다.
        let replaceOwnedDraft = await executePage(draftScript, arguments: ["config": config.json, "prompt": prompt],
                                                  on: webView, gen: gen, as: Bool.self) ?? false
        guard isCurrent(gen) else { return .cancelled }
        var inserted = false
        for attempt in 1...4 {
            guard isCurrent(gen) else { return .cancelled }
            guard let currentURL = webView.url else { return .needsManual }
            if config.isAuth(currentURL) && !config.allowsScript(currentURL) { return .needsLogin }
            let result = await callRuntime("injectPrompt", [prompt, replaceOwnedDraft && attempt == 1], on: webView, gen: gen)
            if let check = await callRuntime("verifyPromptInjected", [prompt], on: webView, gen: gen),
               let data = check["data"] as? [String: Any], let kind = data["differenceKind"] as? Int {
                log("bridge_snapshot", ["difference_kind": kind])
            }
            guard isCurrent(gen) else { return .cancelled }
            if result?["code"] as? String == "EXISTING_TEXT_PRESERVED" {
                // 사용자가 입력해 둔 다른 글은 덮어쓰지 않는다.
                log("prompt_failed", ["attempt": attempt, "prompt_present": 1])
                return .needsManual
            }
            if result?["success"] as? Bool == true,
               let verify = await callRuntime("verifyPromptInjected", [prompt], on: webView, gen: gen),
               (verify["data"] as? [String: Any])?["matches"] as? Bool == true {
                log("prompt_inserted", ["prompt_length": prompt.count, "attempt": attempt])
                inserted = true
                break
            }
            await pause(0.6)
        }
        guard isCurrent(gen) else { return .cancelled }
        guard inserted else {
            log("prompt_failed", ["prompt_present": 0])
            return .needsManual
        }

        // 1회 전송: 전송을 실행한 뒤에는 다시 누르거나 다시 입력하지 않고 생성 시작 증거만 확인한다.
        setStage("요청 보내는 중")
        log("send_ready")
        let started = Date()
        var dispatched = false
        var attempts = 0
        while Date().timeIntervalSince(started) < 15 {
            guard isCurrent(gen) else { return .cancelled }
            if !dispatched {
                attempts += 1
                let result = await callRuntime("submitPrompt", [attempts], on: webView, gen: gen)
                guard isCurrent(gen) else { return .cancelled }
                if result?["success"] as? Bool == true,
                   (result?["data"] as? [String: Any])?["attempted"] as? Bool == true {
                    dispatched = true
                    log("send_attempted", ["attempt": attempts])
                } else {
                    await pause(1.0)
                    continue
                }
            }
            await pause(0.7)
            guard isCurrent(gen) else { return .cancelled }
            await drainDiagnostics(webView, gen: gen)
            let verify = await callRuntime("verifySubmission", [baseline], on: webView, gen: gen)
            guard isCurrent(gen) else { return .cancelled }
            if (verify?["data"] as? [String: Any])?["submitted"] as? Bool == true {
                log("send_observed", ["attempt": attempts])
                return .submitted(baseline: baseline)
            }
            await pause(0.5)
        }
        log("send_timeout", ["attempt": attempts])
        if dispatched {
            // 이미 보냈을 수 있으므로 다시 보내지 않는다.
            return .failed("요청을 보냈지만 15초 안에 \(config.provider.title)의 답변이 시작되지 않았습니다. 제공사 화면을 확인한 뒤 다시 시도하세요. 반복되면 설정 › 외부 AI에서 진단 로그를 공유해 주세요.")
        }
        return .needsManual
    }

    private func observe(gen: UInt64, baseline: Int) async -> AIBIOutcome {
        guard let config, let webView else { return .cancelled }
        let deadline = Date().addingTimeInterval(Self.observationLimit)
        status?.observationDeadline = deadline
        setStage("답변 생성 중")
        log("generation_started", ["generation_active": 1])
        var lastText: String?
        var stableTicks = 0
        var rejected: (text: String, at: Date, reason: String)?

        while isCurrent(gen) {
            if Date() >= deadline {
                log("generation_failed", ["generation_active": 0, "stable_samples": stableTicks])
                if let rejected { return .failed(rejected.reason) }
                status?.manualError = "제한 시간(1:59) 안에 답변을 가져오지 못했습니다. 현재 답변 화면을 보존했습니다."
                return await takeover(.manual, gen: gen, preserveBrowser: true) ?? .cancelled
            }
            await pause(0.7)
            guard isCurrent(gen) else { return .cancelled }
            await drainDiagnostics(webView, gen: gen)
            guard let data = await callRuntime("observeGeneration", [baseline], on: webView, gen: gen)?["data"] as? [String: Any] else { continue }
            guard isCurrent(gen) else { return .cancelled }
            let phase = data["phase"] as? String
            if phase == "FAILED" {
                log("generation_failed", ["generation_active": 0])
                return .failed("\(config.provider.title) 화면에 오류가 표시되어 중단했습니다. 사용 한도나 연결 상태를 확인한 뒤 다시 시도하세요.")
            }
            if phase == "FALLBACK_REQUIRED" {
                log("generation_failed", ["generation_active": 0])
                return .failed("\(config.provider.title) 보안 확인이 나타나 중단했습니다. 설정 › 외부 AI에서 로그인 창을 열어 확인한 뒤 다시 시도하세요.")
            }
            let raw = data["rawText"] as? String ?? ""
            let generating = data["isGenerating"] as? Bool ?? true
            if !generating, data["hasNewAnswer"] as? Bool == true,
               config.provider == .gemini,
               raw.trimmingCharacters(in: .whitespacesAndNewlines) == "I encountered an error doing what you asked. Could you try again?" {
                log("generation_failed", ["generation_active": 0, "failure_kind": 4])
                return .failed(Self.geminiTemporaryFailure)
            }
            guard data["hasNewAnswer"] as? Bool == true, !generating,
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                lastText = nil
                stableTicks = 0
                setStage("답변 생성 중")
                continue
            }
            // 생성 중이 아닌 같은 텍스트를 3회 연속 관찰해야 완료로 본다.
            guard raw == lastText else {
                lastText = raw
                stableTicks = 0
                setStage("답변 받는 중")
                log("generation_progress", ["response_length": raw.count, "generation_active": 0])
                continue
            }
            stableTicks += 1
            guard stableTicks >= 2 else { continue }

            // Mail's result sink owns its structured protocol. Generic prose cleanup could
            // mistake translated code/OCR (print/Text/output) for diagnostics and remove it.
            let cleaned = raw
            if let previous = rejected, previous.text == cleaned {
                // 같은 응답이 계속 형식 검증에 실패하면 끝난 답변으로 보고 실패 처리한다.
                if Date().timeIntervalSince(previous.at) > 6 {
                    if allowsFormatRetry { return .failed(Self.retryableFormatFailure) }
                    status?.manualError = previous.reason
                    return await takeover(.manual, gen: gen, preserveBrowser: true) ?? .cancelled
                }
                continue
            }
            log("generation_completed", ["response_length": cleaned.count, "stable_samples": stableTicks + 1])
            if let reason = sink?(cleaned) {
                log("response_rejected", ["response_length": cleaned.count, "failure_kind": 5])
                rejected = (cleaned, Date(), reason)
                stableTicks = 0
                continue
            }
            log("result_applied", ["response_length": cleaned.count])
            return .applied
        }
        return .cancelled
    }

    /// 사용자가 해야 할 일이 있을 때만 보이는 브라우저로 전환한다.
    /// 로그인·보안 확인이 끝나면 nil(자동 진행 재개), 수동 경로는 사용자가 응답을 적용하거나 취소할 때까지 기다린다.
    private func takeover(_ action: AIBIUserAction, gen: UInt64, preserveBrowser: Bool = false) async -> AIBIOutcome? {
        guard let config else { return .cancelled }
        log("manual_takeover")
        if status?.isVisible != true {
            if preserveBrowser, let existing = webView {
                existing.removeFromSuperview()
                existing.interactive = true
                status?.isVisible = true
                let resultWindow = AIBIBrowserWindow(title: "\(config.provider.title) — 스크린 메일 번역기 외부 AI", header: AIBITaskHeader(), webView: existing)
                resultWindow.onUserClose = { [weak self] in self?.window = nil; self?.cancel() }
                window = resultWindow
                resultWindow.show()
            } else {
                // 로그인·입력 복구는 같은 저장소의 새 보이는 브라우저에서 진행한다.
                destroyWebView()
                presentVisible()
                webView?.load(URLRequest(url: config.initialURL))
            }
        } else {
            window?.show()
        }
        status?.userAction = action
        status?.observationDeadline = nil
        switch action {
        case .login:
            setStage("\(config.provider.title) 로그인이 필요합니다")
            AIBIAccounts.shared.observed(config.provider, .loginRequired)
        case .challenge:
            setStage("\(config.provider.title) 보안 확인이 필요합니다")
        case .manual:
            setStage(status?.manualError == nil ? "자동 입력을 진행하지 못했습니다 — 수동으로 진행하세요" : "답변 형식을 확인해야 합니다 — 수동으로 진행하세요")
            return await withCheckedContinuation { continuation in
                if isCurrent(gen) { manualContinuation = continuation } else { continuation.resume(returning: .cancelled) }
            }
        }

        // 로그인·보안 확인: 사용자가 끝낼 때까지 계정 표식을 확인한다(최대 10분).
        let deadline = Date().addingTimeInterval(600)
        while isCurrent(gen) && Date() < deadline {
            await pause(1.0)
            guard isCurrent(gen), let webView else { return .cancelled }
            blockedNavigation = false
            navigationFailed = false
            guard let url = webView.url, config.allowsScript(url) else { continue }
            if await AIBIRegistry.probeAuth(webView, config: config) == "authenticated" {
                guard isCurrent(gen) else { return .cancelled }
                AIBIAccounts.shared.observed(config.provider, .authenticated)
                status?.userAction = nil
                return nil
            }
        }
        guard isCurrent(gen) else { return .cancelled }
        return .failed("\(config.provider.title) 로그인을 기다리는 시간(10분)이 지나 중단했습니다.")
    }

    // MARK: 브라우저 수명

    private func mountHidden(in host: AIBIHostView) {
        let webView = makeWebView(interactive: false)
        host.attach(webView)
        self.webView = webView
        status?.isVisible = false
    }

    private func presentVisible() {
        guard let config else { return }
        let webView = makeWebView(interactive: true)
        self.webView = webView
        status?.isVisible = true
        let window = AIBIBrowserWindow(title: "\(config.provider.title) — 스크린 메일 번역기 외부 AI",
                                       header: AIBITaskHeader(), webView: webView)
        window.onUserClose = { [weak self] in
            // 사용자가 창을 닫으면 작업을 취소한다(이미 닫히는 창을 다시 닫지 않음).
            self?.window = nil
            self?.cancel()
        }
        self.window = window
        window.show()
    }

    private func makeWebView(interactive: Bool) -> AIBIWebView {
        let webView = AIBIWebView(frame: NSRect(origin: .zero, size: AIBIHiddenSurface.viewport),
                                  configuration: AIBIRegistry.makeConfiguration())
        webView.interactive = interactive
        webView.allowsLinkPreview = false
        if let config {
            let guardian = AIBINavigationGuard(config: config)
            guardian.onBlocked = { [weak self] in
                self?.blockedNavigation = true
                if self?.status?.isVisible == true {
                    self?.status?.stage = "허용 목록에 없는 주소라 열지 않았습니다"
                }
            }
            guardian.onFinish = { [weak self] in self?.log("browser_loaded") }
            guardian.onFailure = { [weak self] in self?.navigationFailed = true }
            webView.navigationDelegate = guardian
            webView.uiDelegate = guardian
            navigationGuard = guardian
        }
        return webView
    }

    private func destroyWebView() {
        navigationGuard?.closePopups()
        if let webView { drainBeforeTeardown(webView) }
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        navigationGuard = nil
        window?.close()
        window = nil
    }

    private func finish(_ outcome: AIBIOutcome) {
        generation &+= 1
        switch outcome {
        case .applied: log("run_completed")
        case .failed: log("run_failed")
        case .cancelled: log("run_cancelled")
        }
        teardown()
    }

    private func teardown() {
        destroyWebView()
        status = nil
        config = nil
        promptSource = nil
        cachedPrompt = nil
        sink = nil
        owner = nil
    }

    // MARK: 도우미

    private func currentPrompt() -> String? {
        if let cachedPrompt { return cachedPrompt }
        cachedPrompt = promptSource?()
        return cachedPrompt
    }

    private func setStage(_ stage: String) {
        if status?.stage != stage { status?.stage = stage }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func log(_ event: String, _ metrics: [String: Int] = [:]) {
        guard let runID else { return }
        AIBIDiagnosticsStore.shared.record(runID: runID, event: event, metrics: metrics)
    }

    /// 지금 실행 중인 작업(같은 세대·작업 미취소)인지
    private func isCurrent(_ gen: UInt64) -> Bool {
        gen == generation && !Task.isCancelled
    }

    /// 페이지 스크립트 실행 직전 네이티브 확인: 현재 작업·현재 웹 보기·로드 완료·공식 실행 origin(인증 경로 제외).
    private func canExecute(gen: UInt64, on webView: WKWebView) -> Bool {
        guard isCurrent(gen), let config, self.webView === webView, !webView.isLoading,
              let url = webView.url else { return false }
        return config.allowsScript(url)
    }

    /// 스크립트 첫 줄 확인: 네이티브 확인 뒤 비동기로 이동한 문서(OAuth 등)에서는 아무것도 하지 않는다.
    /// 판정은 AIBIProviderConfig.allowsScript와 같은 규칙(scheme·host·port·경로 접두사)을 실제 location에 적용한다.
    private static let locationGuard = """
    const __aibiHit = (o) => location.protocol === o.protocol && location.hostname.toLowerCase() === o.host &&
      location.port === o.port && (o.path === '' || o.path === '/' || location.pathname.startsWith(o.path));
    if (window.top !== window || !__aibiScriptOrigins.some(__aibiHit) || __aibiAuthOrigins.some(__aibiHit)) return null;

    """

    private static func originDescriptors(_ origins: [URL]) -> [[String: String]] {
        origins.map { origin in
            ["protocol": (origin.scheme ?? "").lowercased() + ":",
             "host": (origin.host ?? "").lowercased(),
             "port": origin.port.map(String.init) ?? "",
             "path": origin.path]
        }
    }

    private static func guardedArguments(_ arguments: [String: Any], config: AIBIProviderConfig) -> [String: Any] {
        var guarded = arguments
        guarded["__aibiScriptOrigins"] = originDescriptors(config.scriptOrigins)
        guarded["__aibiAuthOrigins"] = originDescriptors(config.authOrigins)
        return guarded
    }

    /// 실행 웹 보기의 모든 페이지 스크립트(프롬프트 입력·전송 포함)가 지나는 단일 경로.
    /// 네이티브 확인 직후 같은 동기 구간에서 호출하고, 페이지 안에서도 실제 location을 다시 확인한다.
    /// 실패 사유·인자는 로그나 오류에 남기지 않는다.
    private func executePage<T: Sendable>(_ body: String, arguments: [String: Any], on webView: WKWebView, gen: UInt64,
                                as type: T.Type) async -> T? {
        guard canExecute(gen: gen, on: webView), let config else { return nil }
        let value = await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            webView.callAsyncJavaScript(Self.locationGuard + body, arguments: Self.guardedArguments(arguments, config: config),
                                        in: nil, in: .page) { result in
                if case .success(let value) = result { continuation.resume(returning: value as? T) }
                else { continuation.resume(returning: nil) }
            }
        }
        // 그사이 취소·웹 보기 교체가 있었으면 늦게 도착한 결과를 쓰지 않는다.
        guard isCurrent(gen), self.webView === webView else { return nil }
        return value
    }

    /// 공식 실행 origin에서만 공통 런타임을 주입·호출한다. 값은 인자로만 넘긴다(스크립트 문자열에 끼워 넣지 않음).
    private func callRuntime(_ method: String, _ values: [Any] = [], on webView: WKWebView, gen: UInt64,
                             withConfig: Bool = true) async -> [String: Any]? {
        guard canExecute(gen: gen, on: webView) else { return nil }
        guard await ensureRuntime(webView, gen: gen) else { return nil }
        // 런타임 확인 await 동안 취소·교체·인증 경로 이동이 있었을 수 있으므로 인자를 만들기 전에 다시 확인한다.
        guard canExecute(gen: gen, on: webView), let config else { return nil }
        var arguments: [String: Any] = [:]
        var names: [String] = []
        if withConfig {
            arguments["config"] = config.json
            names.append("config")
        }
        for (index, value) in values.enumerated() {
            arguments["a\(index)"] = value
            names.append("a\(index)")
        }
        let body = "const r = window.__AIBI_RUNTIME__; return r ? r.\(method)(\(names.joined(separator: ", "))) : null;"
        let string = await executePage(body, arguments: arguments, on: webView, gen: gen, as: String.self)
        guard let data = string?.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 런타임이 준비되면 true. 매 await 뒤 executePage가 같은 확인을 다시 거친다.
    private func ensureRuntime(_ webView: WKWebView, gen: UInt64) async -> Bool {
        guard let source = AIBIRegistry.runtimeSource, canExecute(gen: gen, on: webView) else { return false }
        let check = "return typeof window.__AIBI_RUNTIME__ !== 'undefined';"
        if await executePage(check, arguments: [:], on: webView, gen: gen, as: Bool.self) == true { return true }
        guard canExecute(gen: gen, on: webView) else { return false }
        _ = await executePage(source + "\n;return null;", arguments: [:], on: webView, gen: gen, as: Bool.self)
        guard canExecute(gen: gen, on: webView) else { return false }
        if await executePage(check, arguments: [:], on: webView, gen: gen, as: Bool.self) == true {
            runtimeFailureLogged = false
            log("bridge_ready")
            return true
        }
        guard isCurrent(gen) else { return false }
        if !runtimeFailureLogged {
            runtimeFailureLogged = true
            log("bridge_failed")
        }
        return false
    }

    /// 런타임의 진단 큐(단계 이름·정수만)를 저장소로 옮긴다. 저장소가 허용 목록으로 다시 거른다.
    private func drainDiagnostics(_ webView: WKWebView, gen: UInt64) async {
        guard let runID, let data = await callRuntime("drainDiagnostics", on: webView, gen: gen)?["data"] as? [String: Any] else { return }
        for event in AIBIDiagnosticsStore.runtimeEvents(from: data["events"]) {
            AIBIDiagnosticsStore.shared.record(runID: runID, event: event.stage, metrics: event.metrics)
        }
    }

    private func drainBeforeTeardown(_ webView: WKWebView) {
        guard let runID, let config, let url = webView.url, config.allowsScript(url) else { return }
        // 정리 중 호출이라 세대 확인은 하지 않지만, 프롬프트 없이 진단 큐만 읽고 같은 location 확인을 거친다.
        webView.callAsyncJavaScript(Self.locationGuard + "const r = window.__AIBI_RUNTIME__; return r ? r.drainDiagnostics(config) : null;",
                                    arguments: Self.guardedArguments(["config": config.json], config: config),
                                    in: nil, in: .page) { result in
            _ = webView
            guard case .success(let value) = result, let string = value as? String,
                  let data = string.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let payload = json["data"] as? [String: Any] else { return }
            for event in AIBIDiagnosticsStore.runtimeEvents(from: payload["events"]) {
                AIBIDiagnosticsStore.shared.record(runID: runID, event: event.stage, metrics: event.metrics)
            }
        }
    }
}

// MARK: - 진행 표시 (메인 창 상태 표시줄과 AI 브라우저 창 공용)

struct AIBIProgressRow: View {
    let status: AIBIRunStatus

    var body: some View {
        if let deadline = status.observationDeadline {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, deadline.timeIntervalSince(context.date))
                HStack(spacing: 8) {
                    Text("\(status.provider.title) · \(status.stage)")
                    Text("남은 시간 \(Self.format(remaining))").monospacedDigit()
                    ProgressView(value: remaining, total: AIBIRunner.observationLimit)
                        .frame(width: 120)
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("\(status.provider.title) · \(status.stage)")
            }
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let value = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct AIBITaskHeader: View {
    private let runner = AIBIRunner.shared
    @State private var pasted = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let status = runner.status {
                HStack {
                    AIBIProgressRow(status: status)
                    Spacer()
                    Button("취소") { runner.cancel() }
                        .keyboardShortcut(.cancelAction)
                }
                switch status.userAction {
                case .login?:
                    Text("이 창에서 \(status.provider.title)에 직접 로그인하세요. 로그인이 확인되면 번역을 이어서 진행합니다. 앱은 비밀번호를 읽거나 저장하지 않습니다.")
                        .foregroundStyle(.secondary)
                case .challenge?:
                    Text("보안 확인(CAPTCHA 등)을 직접 완료하세요. 확인되면 번역을 이어서 진행합니다.")
                        .foregroundStyle(.secondary)
                case .manual?:
                    manualControls(status)
                case nil:
                    Text("자동으로 진행 중입니다. 완료되면 결과를 가져와 이 창을 닫습니다.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .padding(12)
    }

    @ViewBuilder
    private func manualControls(_ status: AIBIRunStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(status.provider.title) 화면이 바뀌어 자동 입력을 하지 못했습니다. ① '요청 복사'를 눌러 아래 채팅 입력창에 붙여 넣고 보냅니다. ② 답변의 코드 블록을 복사해 아래에 붙여 넣고 '응답 적용'을 누릅니다. 형식·항목이 맞을 때만 적용됩니다.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("요청 복사") { runner.copyPrompt() }
                    .help("번역할 텍스트(메일 제목·본문·이미지 글자 또는 화면에서 인식한 글자)가 포함된 번역 요청을 클립보드에 복사합니다")
                Button("응답 적용") { runner.applyManual(pasted) }
                    .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let error = status.manualError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            TextEditor(text: $pasted)
                .font(.system(.callout, design: .monospaced))
                .frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3)))
        }
    }
}

// MARK: - 로그인 상태 · 로그인 창 · 세션 삭제 · 동의

enum AIBILoginStatus: Equatable {
    case checking, authenticated, loginRequired, unknown

    var label: String {
        switch self {
        case .checking: return "확인 중"
        case .authenticated: return "로그인됨"
        case .loginRequired: return "로그인 필요"
        case .unknown: return "확인 안 됨"
        }
    }
}

@MainActor
@Observable
final class AIBIAccounts {
    static let shared = AIBIAccounts()

    private(set) var statuses: [AIProvider: AIBILoginStatus] = [:]
    private(set) var consents: Set<AIProvider>
    private(set) var isClearing = false
    /// 기본값은 '필요할 때만 표시'(숨김 실행). 켜면 처음부터 AI 브라우저 창을 보여 준다.
    var alwaysShowBrowser: Bool {
        didSet { UserDefaults.standard.set(alwaysShowBrowser, forKey: Self.alwaysShowKey) }
    }

    @ObservationIgnored private var probing = false
    @ObservationIgnored private var loginWindow: AIBIBrowserWindow?
    @ObservationIgnored private var loginWebView: AIBIWebView?
    @ObservationIgnored private var loginGuard: AIBINavigationGuard?
    @ObservationIgnored private var loginGeneration = 0

    private static let alwaysShowKey = "aibiAlwaysShowBrowser"
    /// 메일과 화면 번역을 모두 설명한 이 앱의 동의만 인정한다(다른 앱·이전 문구의 동의를 가져오지 않음).
    private static func consentKey(_ provider: AIProvider) -> String { "aibiConsentMailAndScreenV1.\(provider.rawValue)" }
    private static func logoutKey(_ provider: AIProvider) -> String { "aibiExplicitLogout.\(provider.rawValue)" }

    private init() {
        let defaults = UserDefaults.standard
        alwaysShowBrowser = defaults.bool(forKey: Self.alwaysShowKey)
        consents = Set(AIProvider.allCases.filter { defaults.bool(forKey: Self.consentKey($0)) })
    }

    // MARK: 동의 (전송 대상: 메일 제목·본문 텍스트·이미지 OCR 텍스트, 화면 번역의 인식 텍스트)

    func hasConsent(_ provider: AIProvider) -> Bool { consents.contains(provider) }

    func grantConsent(_ provider: AIProvider) {
        UserDefaults.standard.set(true, forKey: Self.consentKey(provider))
        consents.insert(provider)
    }

    func revokeConsent(_ provider: AIProvider) {
        UserDefaults.standard.removeObject(forKey: Self.consentKey(provider))
        consents.remove(provider)
    }

    // MARK: 로그인 상태 (긍정 계정 표식 기반, 제한 시간 뒤 '확인 안 됨')

    func observed(_ provider: AIProvider, _ status: AIBILoginStatus) {
        if status == .authenticated { UserDefaults.standard.removeObject(forKey: Self.logoutKey(provider)) }
        statuses[provider] = status
    }

    func refreshAll() {
        guard !probing, !isClearing else { return }
        probing = true
        for provider in AIProvider.allCases { statuses[provider] = .checking }
        Task {
            for provider in AIProvider.allCases { statuses[provider] = await probe(provider) }
            probing = false
        }
    }

    private func probe(_ provider: AIProvider) async -> AIBILoginStatus {
        // 앱이 직접 세션을 지운 제공사는 사용자가 로그인 창을 열 때까지 '로그인 필요'로 유지한다.
        if UserDefaults.standard.bool(forKey: Self.logoutKey(provider)) { return .loginRequired }
        guard let config = AIBIRegistry.config(provider), let host = AIBIHiddenSurface.shared.availableHost() else { return .unknown }
        let webView = AIBIWebView(frame: host.bounds, configuration: AIBIRegistry.makeConfiguration())
        webView.interactive = false
        let guardian = AIBINavigationGuard(config: config)
        var blocked = false
        guardian.onBlocked = { blocked = true }
        webView.navigationDelegate = guardian
        host.attach(webView)
        defer {
            // navigationDelegate는 약한 참조라, 확인이 끝날 때까지 보안 대리자를 붙잡아 둔다.
            withExtendedLifetime(guardian) {}
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.removeFromSuperview()
        }
        webView.load(URLRequest(url: config.initialURL))
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if blocked || isClearing { return .unknown }
            guard let url = webView.url, !webView.isLoading else { continue }
            if config.isAuth(url) && !config.allowsScript(url) { return .loginRequired }
            switch await AIBIRegistry.probeAuth(webView, config: config) {
            case "authenticated"?: return .authenticated
            case "login"?: return .loginRequired
            default: continue // 하이드레이션 대기 또는 보안 확인 → 제한 시간 뒤 '확인 안 됨'
            }
        }
        return .unknown
    }

    // MARK: 로그인 창

    func openLogin(_ provider: AIProvider) {
        guard let config = AIBIRegistry.config(provider) else { return }
        closeLogin()
        UserDefaults.standard.removeObject(forKey: Self.logoutKey(provider))
        loginGeneration += 1
        let generation = loginGeneration
        statuses[provider] = .checking

        let webView = AIBIWebView(frame: NSRect(origin: .zero, size: AIBIHiddenSurface.viewport),
                                  configuration: AIBIRegistry.makeConfiguration())
        let guardian = AIBINavigationGuard(config: config)
        guardian.onFinish = { [weak self] in self?.checkLogin(provider, generation: generation) }
        var didReportBlockedNavigation = false
        guardian.onBlocked = { [weak self] in
            guard let self, generation == self.loginGeneration, !didReportBlockedNavigation else { return }
            didReportBlockedNavigation = true
            self.statuses[provider] = .unknown
            let alert = NSAlert()
            alert.messageText = "이 로그인 경로를 열 수 없습니다"
            alert.informativeText = "공식 로그인 주소 목록에 없는 이동이 차단됐습니다. 다른 로그인 방법을 선택하거나 창을 닫고 다시 시도하세요."
            alert.addButton(withTitle: "확인")
            alert.runModal()
        }
        webView.navigationDelegate = guardian
        webView.uiDelegate = guardian
        loginWebView = webView
        loginGuard = guardian

        let header = HStack {
            Text("\(provider.title) 공식 페이지에서 직접 로그인하세요. 로그인이 확인되면 이 창은 자동으로 닫힙니다. 앱은 비밀번호를 읽거나 저장하지 않습니다.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.callout)
        .padding(12)
        let window = AIBIBrowserWindow(title: "\(provider.title) 로그인 — 스크린 메일 번역기", header: header, webView: webView)
        window.onUserClose = { [weak self] in
            guard let self, generation == self.loginGeneration else { return }
            self.loginGeneration += 1
            self.loginWindow = nil
            self.releaseLogin()
            Task { self.statuses[provider] = await self.probe(provider) }
        }
        loginWindow = window
        window.show()
        webView.load(URLRequest(url: config.initialURL))

        // 내비게이션 완료 외에도 SPA 하이드레이션 동안 주기적으로 다시 확인한다.
        Task { [weak self] in
            while let self, generation == self.loginGeneration {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.checkLogin(provider, generation: generation)
            }
        }
    }

    private func checkLogin(_ provider: AIProvider, generation: Int) {
        guard generation == loginGeneration, let webView = loginWebView,
              let config = AIBIRegistry.config(provider) else { return }
        Task {
            guard await AIBIRegistry.probeAuth(webView, config: config) == "authenticated",
                  generation == loginGeneration else { return }
            // 성공은 한 번만 알리고, 오래된 콜백을 무효화한 뒤 창을 한 번만 닫는다.
            loginGeneration += 1
            _ = await WKWebsiteDataStore.default().httpCookieStore.allCookies() // 저장소 동기화
            observed(provider, .authenticated)
            closeLogin()
        }
    }

    private func closeLogin() {
        loginWindow?.close()
        releaseLogin()
    }

    private func releaseLogin() {
        loginGuard?.closePopups()
        loginWebView?.stopLoading()
        loginWebView?.navigationDelegate = nil
        loginWebView?.uiDelegate = nil
        loginWebView = nil
        loginGuard = nil
        loginWindow = nil
    }

    // MARK: 세션 삭제

    /// 이 앱의 기본 웹 저장소(외부 AI 로그인 전용)를 모두 지운다. 메일 서식 보기는 비영구 저장소라 영향이 없다.
    func clearAllSessions() async {
        AIBIRunner.shared.cancel()
        WebTranslatorRunner.shared.cancelAll()
        loginGeneration += 1
        closeLogin()
        isClearing = true
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        for provider in AIProvider.allCases {
            UserDefaults.standard.set(true, forKey: Self.logoutKey(provider))
            statuses[provider] = .loginRequired
        }
        isClearing = false
    }
}
