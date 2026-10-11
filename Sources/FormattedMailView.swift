import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// HTML 메일을 원본 서식(표·색·글꼴·버튼·간격·이미지 위치) 그대로 보여 주고, 텍스트 노드만 번역문으로 바꾼다.
// 방어선(하나가 뚫려도 나머지가 막도록 겹쳐 둔다):
// 1. HTMLSanitizer: 허용 목록 기반 재직렬화(스크립트·프레임·폼·이벤트 처리기·외부 CSS/글꼴/url() 제거)
// 2. CSP: 문서 응답 헤더 + <head> 첫 meta. default-src 'none', 이미지는 앱 스킴/data:만
// 3. WKContentRuleList: http/https/ws/ftp/file/blob 요청 차단. 첫 문서를 불러오기 전에 컴파일되어 있어야 한다.
// 4. 내비게이션 대리자: 최초 문서 1회만 허용, 링크·폼·팝업·새 창·다운로드는 모두 취소
// 5. 페이지 스크립트 비활성화(allowsContentJavaScript = false), 비영구 데이터 저장소, 링크 미리보기 끔
// 앱 스크립트는 격리된 WKContentWorld.defaultClient에서만 실행되며, 페이지(메일)에서는 접근할 수 없다.
// 이미지는 메모리에 있는 ImageAsset만 앱 전용 스킴으로 내보낸다(파일 경로·네트워크 노출 없음, 디스크 캐시 없음).

enum MailWebSecurity {
    static let ruleListIdentifier = "MailTranslatorBlockExternalLoadsV1"
    // WebKit 콘텐츠 차단 규칙의 정규식은 '|'를 지원하지 않으므로 스킴마다 규칙을 둔다(대소문자 무시가 기본).
    static let encodedRules = """
    [
      {"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^wss?:"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^ftp:"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^file:"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^blob:"},"action":{"type":"block"}}
    ]
    """

    @MainActor private static var cached: WKContentRuleList?

    struct CompileError: LocalizedError {
        var errorDescription: String? { "외부 요청 차단 규칙을 준비하지 못했습니다." }
    }

    /// 규칙 목록은 메일 내용과 무관한 고정 규칙이다(WebKit 기본 저장소에 컴파일 결과만 보관).
    @MainActor static func ruleList() async throws -> WKContentRuleList {
        if let cached { return cached }
        guard let store = WKContentRuleListStore.default() else { throw CompileError() }
        let list: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: ruleListIdentifier, encodedContentRuleList: encodedRules) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: error ?? CompileError())
                }
            }
        }
        cached = list
        return list
    }
}

// MARK: - SwiftUI 래퍼

struct FormattedBodyView: View {
    let document: MailDocument
    let formatted: FormattedHTML
    let model: AppModel
    @State private var height: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let ruleList = model.formattedRuleList {
                FormattedMailWebView(
                    documentID: document.id,
                    formatted: formatted,
                    ruleList: ruleList,
                    model: model,
                    segmentStates: model.segmentStates,
                    ocrStates: model.ocrStates,
                    remoteStates: model.remoteStates,
                    displayMode: model.displayMode,
                    showOCRBoxes: model.showOCRBoxes,
                    showOCRDetails: model.showOCRDetails,
                    pendingLabel: model.pendingLabel,
                    height: $height
                )
                .frame(height: height)
            } else {
                ProgressView("원본 서식을 준비하는 중…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
            Text("원본 서식 보기 · 메일 속 스크립트와 외부 연결은 차단되며 링크·버튼은 열리지 않습니다.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

struct FormattedMailWebView: NSViewRepresentable {
    let documentID: UUID
    let formatted: FormattedHTML
    let ruleList: WKContentRuleList
    let model: AppModel
    let segmentStates: [String: SegmentState]
    let ocrStates: [String: OCRState]
    let remoteStates: [String: RemoteImageState]
    let displayMode: DisplayMode
    let showOCRBoxes: Bool
    let showOCRDetails: Bool
    /// 대기 중인 OCR 캡션 문구(외부 AI는 실행 전까지 '번역 대기')
    let pendingLabel: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(documentID: documentID, model: model)
    }

    func makeNSView(context: Context) -> MailWebView {
        let coordinator = context.coordinator
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false

        let documentID = documentID
        let handler = MailAssetSchemeHandler(html: formatted.html, documentID: documentID) { [weak model] assetID in
            model?.assetImage(documentID: documentID, assetID: assetID)
        }
        configuration.setURLSchemeHandler(handler, forURLScheme: FormattedHTML.scheme)

        let controller = configuration.userContentController
        // 규칙 목록은 문서를 불러오기 전에 반드시 붙인다.
        controller.add(ruleList)
        controller.add(WeakScriptMessageHandler(coordinator), contentWorld: .defaultClient, name: Coordinator.handlerName)
        controller.addUserScript(WKUserScript(source: MailWebScript.source(token: coordinator.token),
                                              injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))

        let webView = MailWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 240), configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.allowsLinkPreview = false
        webView.appearance = NSAppearance(named: .aqua) // 메일 고유 색을 유지(앱 다크 모드가 메일을 바꾸지 않게)
        webView.unregisterDraggedTypes() // 파일을 끌어다 놓아도 웹 보기가 열지 않게(창의 .eml 놓기로 전달)
        webView.onWidthChange = { [weak coordinator] width in coordinator?.viewWidthChanged(width) }

        coordinator.attach(webView, documentURL: handler.documentURL, height: $height)
        coordinator.latest = self
        webView.load(URLRequest(url: handler.documentURL))
        return webView
    }

    func updateNSView(_ webView: MailWebView, context: Context) {
        context.coordinator.height = $height
        context.coordinator.latest = self
        context.coordinator.sync()
    }

    static func dismantleNSView(_ webView: MailWebView, coordinator: Coordinator) {
        coordinator.detach()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.onWidthChange = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.configuration.userContentController.removeAllUserScripts()
        webView.configuration.userContentController.removeAllContentRuleLists()
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        static let handlerName = "mailTranslator"
        private static let minZoom = 0.4
        private static let maxHeight: CGFloat = 60_000

        /// 웹 보기 하나마다 새로 만든다. 이전 문서/웹 보기의 메시지와 결과를 구분한다.
        let token = UUID().uuidString
        let documentID: UUID
        weak var model: AppModel?
        var height: Binding<CGFloat>?
        var latest: FormattedMailWebView?

        private weak var webView: MailWebView?
        private var documentURL: URL?
        private var initialNavigationUsed = false
        private var domReady = false
        private var failed = false
        private var unitIDs: [String] = []
        private var sentMode: String?
        private var sentBoxes: Bool?
        private var sentDetails: Bool?
        private var sentUnits: [String: String] = [:]
        private var sentSlots: [String: String] = [:]
        private var metricsTimer: Timer?
        private var timeoutWork: DispatchWorkItem?

        init(documentID: UUID, model: AppModel) {
            self.documentID = documentID
            self.model = model
        }

        func attach(_ webView: MailWebView, documentURL: URL, height: Binding<CGFloat>) {
            self.webView = webView
            self.documentURL = documentURL
            self.height = height
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.domReady else { return }
                self.fail("원본 서식 본문을 분석하지 못했습니다(시간 초과).")
            }
            timeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: work)
        }

        func detach() {
            metricsTimer?.invalidate()
            metricsTimer = nil
            timeoutWork?.cancel()
            timeoutWork = nil
            webView = nil
        }

        private func fail(_ reason: String) {
            guard !failed else { return }
            failed = true
            detach()
            model?.formattedBodyFailed(documentID: documentID, reason: reason)
        }

        // MARK: 스크립트 메시지 (격리된 앱 world에서만 옴)

        func receive(_ message: WKScriptMessage) {
            guard !failed, message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any], body["token"] as? String == token,
                  let type = body["type"] as? String else { return }
            switch type {
            case "segments":
                guard !domReady, let raw = body["items"] as? [Any] else { return }
                var items: [(id: String, text: String)] = []
                var seen = Set<String>()
                for case let pair as [Any] in raw.prefix(4000) {
                    guard pair.count == 2, let id = pair[0] as? String, let text = pair[1] as? String,
                          id.hasPrefix("html-"), Int(id.dropFirst(5)) != nil, text.count <= 20_000,
                          seen.insert(id).inserted else { continue }
                    items.append((id, text))
                }
                domReady = true
                timeoutWork?.cancel()
                unitIDs = items.map(\.id)
                model?.htmlSegmentsExtracted(documentID: documentID, items: items)
                startMetricsPolling()
                sync()
            case "metrics":
                handleMetrics(body["metrics"])
            case "failed":
                fail("원본 서식 본문을 분석하지 못했습니다.")
            default:
                break
            }
        }

        // MARK: 크기 맞춤

        private func startMetricsPolling() {
            metricsTimer?.invalidate()
            // 이미지가 늦게 로드되어 높이가 바뀌는 경우까지 반영하도록 주기적으로 측정한다(문서 다시 불러오기 없음).
            metricsTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollMetrics() }
            }
        }

        private func pollMetrics() {
            guard let webView, domReady, !failed else { return }
            webView.callAsyncJavaScript("return window.__mailTranslator ? window.__mailTranslator.measure() : null;",
                                        arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
                if case .success(let value) = result { self?.handleMetrics(value) }
            }
        }

        private func handleMetrics(_ value: Any?) {
            guard let webView, let numbers = value as? [Any], numbers.count == 3,
                  let contentWidth = (numbers[0] as? NSNumber)?.doubleValue,
                  let viewportWidth = (numbers[1] as? NSNumber)?.doubleValue,
                  let contentHeight = (numbers[2] as? NSNumber)?.doubleValue,
                  contentWidth.isFinite, viewportWidth.isFinite, contentHeight.isFinite, viewportWidth > 0 else { return }
            let zoom = Double(webView.pageZoom)
            // 고정 폭 메일이 창보다 넓으면 CSS를 덮어쓰지 않고 배율만 줄여 맞춘다.
            if contentWidth > viewportWidth + 1, zoom > Self.minZoom + 0.001 {
                let fitted = max(Self.minZoom, zoom * viewportWidth / contentWidth)
                if abs(fitted - zoom) > 0.005 {
                    webView.pageZoom = CGFloat(fitted)
                    return
                }
            }
            let points = min(Self.maxHeight, CGFloat((contentHeight * zoom).rounded(.up)) + 2)
            guard let height, abs(height.wrappedValue - points) > 0.5 else { return }
            DispatchQueue.main.async { height.wrappedValue = points }
        }

        func viewWidthChanged(_ width: CGFloat) {
            // 창 폭이 바뀌면 배율을 원래대로 돌린 뒤 다시 측정해 맞춘다.
            guard let webView, webView.pageZoom != 1 else { return }
            webView.pageZoom = 1
        }

        // MARK: DOM 갱신 (문서를 다시 불러오지 않고 바뀐 부분만 전달)

        func sync() {
            guard domReady, !failed, let webView, let state = latest else { return }
            var payload: [String: Any] = ["token": token]

            let mode: String = {
                switch state.displayMode {
                case .translation: return "translation"
                case .both: return "both"
                case .original: return "original"
                }
            }()
            if sentMode != mode {
                payload["mode"] = mode
                sentMode = mode
            }
            if sentBoxes != state.showOCRBoxes {
                payload["boxes"] = state.showOCRBoxes
                sentBoxes = state.showOCRBoxes
            }
            if sentDetails != state.showOCRDetails {
                payload["details"] = state.showOCRDetails
                sentDetails = state.showOCRDetails
            }

            var units: [String: Any] = [:]
            for id in unitIDs {
                let encoded = Self.encode(state.segmentStates[id], pending: state.pendingLabel)
                let signature = Self.signature(encoded)
                if sentUnits[id] != signature {
                    units[id] = encoded
                    sentUnits[id] = signature
                }
            }
            if !units.isEmpty { payload["units"] = units }

            var slots: [String: Any] = [:]
            for slot in state.formatted.slots {
                let encoded = slotPayload(slot, state: state)
                let signature = Self.signature(encoded)
                if sentSlots[slot.key] != signature {
                    slots[slot.key] = encoded
                    sentSlots[slot.key] = signature
                }
            }
            if !slots.isEmpty { payload["slots"] = slots }

            guard payload.count > 1 else { return }
            // 번역문은 인자로만 전달된다(스크립트 문자열에 끼워 넣지 않음). DOM에는 textContent로만 들어간다.
            webView.callAsyncJavaScript("return window.__mailTranslator ? window.__mailTranslator.apply(p) : false;",
                                        arguments: ["p": payload], in: nil, in: .defaultClient) { [weak self] result in
                guard let self else { return }
                if case .success(let value) = result, (value as? NSNumber)?.boolValue == true { return }
                // 반영되지 않았으면 다음 갱신 때 전체를 다시 보낸다.
                self.sentMode = nil
                self.sentBoxes = nil
                self.sentDetails = nil
                self.sentUnits = [:]
                self.sentSlots = [:]
            }
        }

        private static func encode(_ state: SegmentState?, pending: String) -> [Any] {
            switch state {
            case .done(let text)?: return ["d", text]
            case .failed(let message)?: return ["f", message]
            case .pending?: return ["p", pending]
            case .skipped?: return ["s"]
            case nil: return ["n"]
            }
        }

        private static func signature(_ value: Any) -> String {
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }

        private func slotPayload(_ slot: HTMLImageSlot, state: FormattedMailWebView) -> [String: Any] {
            var status = "ok"
            var message = ""
            var assetID: String?
            switch slot.source {
            case .asset(let id):
                assetID = id
            case .remote(let blockID):
                switch state.remoteStates[blockID] {
                case .loaded(let id)?: assetID = id
                case .loading?: status = "loading"
                case .failed(let text)?:
                    status = "failed"
                    message = text
                case nil: status = "idle"
                }
            case .unfetchedRemote:
                status = "idle"
            case .missing, .tracking:
                status = "missing"
            }
            var payload: [String: Any] = [
                "st": status,
                "m": message,
                "alt": slot.alt ?? "",
                "a": assetID ?? "",
                "src": assetID.map(FormattedHTML.assetURL) ?? "",
            ]
            if let assetID, let ocr = state.ocrStates[assetID] {
                switch ocr {
                case .running:
                    payload["ocr"] = ["s": "running"]
                case .failed(let text):
                    payload["ocr"] = ["s": "failed", "m": text]
                case .done(let regions):
                    let list: [[Any]] = regions.enumerated().map { index, region in
                        [index + 1, Double(region.box.minX), Double(region.box.minY), Double(region.box.width),
                         Double(region.box.height), region.text, Self.encode(state.segmentStates[region.id], pending: state.pendingLabel),
                         region.backgroundHex, region.foregroundHex]
                    }
                    payload["ocr"] = ["s": "done", "r": list]
                }
            }
            return payload
        }

        // MARK: 내비게이션 (최초 문서 한 번만 허용)

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     preferences: WKWebpagePreferences,
                     decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
            preferences.allowsContentJavaScript = false
            let isInitial = !initialNavigationUsed
                && navigationAction.targetFrame?.isMainFrame == true
                && navigationAction.navigationType == .other
                && navigationAction.request.url != nil
                && navigationAction.request.url == documentURL
            if isInitial {
                initialNavigationUsed = true
                decisionHandler(.allow, preferences)
            } else {
                decisionHandler(.cancel, preferences)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            let allowed = navigationResponse.isForMainFrame && navigationResponse.response.url == documentURL
            decisionHandler(allowed ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 사용자 스크립트가 이미 시작했으면 무시된다(중복 시작 방지는 스크립트 안에서).
            webView.callAsyncJavaScript("if (window.__mailTranslator) { window.__mailTranslator.start(); }",
                                        arguments: [:], in: nil, in: .defaultClient, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if !domReady { fail("원본 서식 본문을 불러오지 못했습니다.") }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if !domReady { fail("원본 서식 본문을 불러오지 못했습니다.") }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            fail("원본 서식 보기 프로세스가 중단되었습니다.")
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            nil // 새 창/팝업 금지
        }
    }
}

/// WKUserContentController가 처리기를 강하게 붙잡으므로 Coordinator와의 순환 참조를 피한다.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: FormattedMailWebView.Coordinator?

    init(_ target: FormattedMailWebView.Coordinator) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { target?.receive(message) }
    }
}

// MARK: - 웹 보기

final class MailWebView: WKWebView {
    var onWidthChange: ((CGFloat) -> Void)?
    private var lastWidth: CGFloat = -1

    override func layout() {
        super.layout()
        if abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            onWidthChange?(bounds.width)
        }
    }

    /// 웹 보기는 내용 높이에 맞춰지므로, 스크롤은 바깥 문서 스크롤 뷰가 처리한다.
    override func scrollWheel(with event: NSEvent) {
        if let outer = enclosingScrollView {
            outer.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    /// 링크 열기·이미지 다운로드·새로 고침 등은 빼고 복사/찾아보기/말하기만 남긴다.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        let allowed: Set<String> = [
            "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierCopyImage", "WKMenuItemIdentifierLookUp",
            "WKMenuItemIdentifierSpeechMenu",
        ]
        for item in menu.items.reversed() where !item.isSeparatorItem {
            if !allowed.contains(item.identifier?.rawValue ?? "") { menu.removeItem(item) }
        }
        while let first = menu.items.first, first.isSeparatorItem { menu.removeItem(first) }
        while let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
        super.willOpenMenu(menu, with: event)
    }
}

// MARK: - 앱 전용 스킴 (메모리 전용)

/// 정제된 문서와 이 메일의 이미지(ImageAsset)만 메모리에서 내보낸다. 임의 파일을 읽지 않고 네트워크에 접근하지 않는다.
@MainActor
final class MailAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    let documentURL: URL
    private let html: Data
    private let assetImage: (String) -> CGImage?
    private var pngCache: [String: Data] = [:]
    private var active = Set<ObjectIdentifier>()

    init(html: String, documentID: UUID, assetImage: @escaping (String) -> CGImage?) {
        self.html = Data(html.utf8)
        self.assetImage = assetImage
        documentURL = URL(string: "\(FormattedHTML.scheme)://\(FormattedHTML.host)/doc/\(documentID.uuidString).html")!
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        active.insert(ObjectIdentifier(urlSchemeTask))
        guard let url = urlSchemeTask.request.url, url.host == FormattedHTML.host else {
            fail(urlSchemeTask)
            return
        }
        if url == documentURL {
            respond(urlSchemeTask, url: url, data: html, type: "text/html; charset=utf-8", isDocument: true)
            return
        }
        let parts = url.pathComponents
        guard parts.count == 3, parts[1] == "a" else {
            fail(urlSchemeTask)
            return
        }
        let assetID = parts[2]
        if let png = pngCache[assetID] {
            respond(urlSchemeTask, url: url, data: png, type: "image/png", isDocument: false)
            return
        }
        guard let image = assetImage(assetID) else {
            fail(urlSchemeTask)
            return
        }
        Task { @MainActor [weak self] in
            // PNG 인코딩은 메모리에서만, 주 스레드 밖에서 한다.
            let png = await Task.detached(priority: .userInitiated) { Self.pngData(image) }.value
            guard let self else { return }
            guard let png else {
                self.fail(urlSchemeTask)
                return
            }
            self.pngCache[assetID] = png
            self.respond(urlSchemeTask, url: url, data: png, type: "image/png", isDocument: false)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        active.remove(ObjectIdentifier(urlSchemeTask))
    }

    private func respond(_ task: any WKURLSchemeTask, url: URL, data: Data, type: String, isDocument: Bool) {
        guard active.remove(ObjectIdentifier(task)) != nil else { return } // 이미 중단된 요청
        var headers = [
            "Content-Type": type,
            "Content-Length": String(data.count),
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
        ]
        if isDocument {
            headers["Content-Security-Policy"] = FormattedHTML.contentSecurityPolicy
            headers["Referrer-Policy"] = "no-referrer"
        }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
            task.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: any WKURLSchemeTask) {
        guard active.remove(ObjectIdentifier(task)) != nil else { return }
        task.didFailWithError(URLError(.fileDoesNotExist))
    }

    nonisolated private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

// MARK: - 격리된 앱 world 스크립트

enum MailWebScript {
    static func source(token: String) -> String {
        let literal = (try? JSONEncoder().encode(token)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        return template.replacingOccurrences(of: "__MT_TOKEN__", with: literal)
    }

    // 페이지 스크립트는 꺼져 있고, 이 코드는 WKContentWorld.defaultClient에서만 실행된다.
    // 번역문·OCR 텍스트는 모두 textContent/Text.data로만 넣는다(innerHTML 사용 안 함).
    private static let template = #"""
    (() => {
      'use strict';
      if (window.__mailTranslator) return;
      const TOKEN = __MT_TOKEN__;
      const SKIP = new Set(['SCRIPT', 'STYLE', 'HEAD', 'TITLE', 'NOSCRIPT', 'TEMPLATE', 'SVG', 'MATH', 'TEXTAREA',
        'SELECT', 'OPTION', 'IFRAME', 'OBJECT', 'EMBED', 'CANVAS']);
      const LETTER = /\p{L}/u;
      const INVISIBLE = /[​-‍⁠﻿͏­]/g;
      const styleCache = new WeakMap();
      const units = new Map();
      const slots = [];
      const states = new Map();
      let mode = 'translation';
      let showBoxes = true;
      let showDetails = false;
      let started = false;
      let layer = null;
      let sentinel = null;
      let lastMetrics = '';

      function post(message) {
        message.token = TOKEN;
        try { window.webkit.messageHandlers.mailTranslator.postMessage(message); } catch (e) {}
      }
      function style(el) {
        let s = styleCache.get(el);
        if (!s) { s = getComputedStyle(el); styleCache.set(el, s); }
        return s;
      }
      function px(v) { return parseFloat(v) || 0; }
      function transparent(c) { return !c || c === 'transparent' || /^rgba\(.*,\s*0(\.0+)?\)$/.test(c); }
      function create(tag, text) {
        const el = document.createElement(tag);
        if (text !== undefined && text !== null) el.textContent = String(text);
        return el;
      }
      function insertAfter(ref, el) { if (ref && ref.parentNode) ref.parentNode.insertBefore(el, ref.nextSibling); }

      // 숨김 판정: display/visibility/opacity/aria-hidden/hidden, 크기 0으로 잘린 요소(프리헤더 등), 화면 밖 절대 위치
      function hidden(el, s) {
        if (el.hidden || el.getAttribute('aria-hidden') === 'true') return true;
        if (s.display === 'none' || s.visibility === 'hidden' || s.visibility === 'collapse') return true;
        if (parseFloat(s.opacity) === 0) return true;
        const clips = /hidden|clip/.test(s.overflowX + ' ' + s.overflowY);
        const positioned = s.position === 'absolute' || s.position === 'fixed';
        if (clips || positioned) {
          const r = el.getBoundingClientRect();
          if (clips && (r.width <= 1 || r.height <= 1)) return true;
          if (positioned && (r.right <= 0 || r.bottom <= 0)) return true;
        }
        return false;
      }
      function hiddenByAncestor(el) {
        for (let e = el; e && e !== document.body && e !== document.documentElement; e = e.parentElement) {
          if (hidden(e, style(e))) return true;
        }
        return false;
      }
      function buttonLike(s) {
        const pad = px(s.paddingTop) + px(s.paddingBottom) + px(s.paddingLeft) + px(s.paddingRight);
        const border = px(s.borderTopWidth) + px(s.borderBottomWidth) + px(s.borderLeftWidth) + px(s.borderRightWidth);
        return pad > 0 || border > 0 || !transparent(s.backgroundColor);
      }

      // 1) 보이는 텍스트 노드를 블록(또는 버튼 모양 링크) 단위로 묶는다. 굵게/링크 같은 인라인 요소는 같은 단위 안에 남는다.
      let current = null;
      const collected = [];
      function addText(node, container) {
        const data = node.data;
        if (!/\S/.test(data.replace(INVISIBLE, ''))) { if (current) current.gap = true; return; }
        const parent = node.parentElement;
        if (!parent) return;
        const s = style(parent);
        if (px(s.fontSize) < 2 || transparent(s.color)) { if (current) current.gap = true; return; }
        if (!current || current.container !== container) {
          current = { container, nodes: [], orig: [], text: '', gap: false, extra: null, host: 0, id: '' };
          collected.push(current);
        }
        if (current.gap && current.text) current.text += ' ';
        current.text += data;
        current.gap = false;
        current.nodes.push(node);
        current.orig.push(data);
      }
      function walk(node, container, depth) {
        if (depth > 300) return;
        for (let child = node.firstChild; child; child = child.nextSibling) {
          if (child.nodeType === 3) { addText(child, container); continue; }
          if (child.nodeType !== 1) continue;
          const tag = child.tagName.toUpperCase();
          if (SKIP.has(tag) || tag.startsWith('MT-')) continue;
          if (tag === 'BR') { current = null; continue; }
          const s = style(child);
          if (hidden(child, s)) { if (current) current.gap = true; continue; }
          const inline = s.display === 'inline' || s.display === 'contents';
          if (!inline || tag === 'BUTTON' || (tag === 'A' && buttonLike(s))) {
            current = null;
            walk(child, child, depth + 1);
            current = null;
          } else {
            walk(child, container, depth + 1);
          }
        }
      }
      function extract() {
        if (document.body) walk(document.body, document.body, 0);
        const items = [];
        for (const u of collected) {
          const source = u.text.replace(INVISIBLE, '').replace(/\s+/g, ' ').trim();
          if (!source || !LETTER.test(source)) continue;
          if (items.length >= 4000) break;
          // 번역문은 블록에 직접 속한 가장 긴 텍스트 노드(없으면 가장 긴 노드)에 넣고 나머지는 비운다.
          let host = 0, bestLen = -1, bestDirect = false;
          u.nodes.forEach((n, i) => {
            const direct = n.parentElement === u.container;
            const len = n.data.trim().length;
            if ((direct && !bestDirect) || (direct === bestDirect && len > bestLen)) { host = i; bestLen = len; bestDirect = direct; }
          });
          u.host = host;
          u.id = 'html-' + (items.length + 1);
          units.set(u.id, u);
          items.push([u.id, source]);
        }
        return items;
      }

      // 2) 번역 상태 반영
      function applyUnit(u) {
        for (let i = 0; i < u.nodes.length; i++) {
          if (u.nodes[i].data !== u.orig[i]) u.nodes[i].data = u.orig[i];
        }
        if (u.extra) { u.extra.remove(); u.extra = null; }
        const st = states.get(u.id);
        if (!st || mode === 'original') return;
        const last = u.nodes[u.nodes.length - 1];
        if (st[0] === 'd') {
          const text = String(st[1] === undefined ? '' : st[1]);
          if (mode === 'both') {
            u.extra = create('mt-tr', text);
            insertAfter(last, u.extra);
          } else {
            u.nodes.forEach((node, i) => {
              if (i === u.host) {
                const o = u.orig[i];
                node.data = o.match(/^\s*/)[0] + text + o.match(/\s*$/)[0];
              } else {
                node.data = '';
              }
            });
          }
        } else if (st[0] === 'f') {
          u.extra = create('mt-warn', '⚠');
          u.extra.title = '번역 실패: ' + String(st[1] || '');
          insertAfter(last, u.extra);
        }
      }

      // 3) 이미지: 원래 위치의 <img>에 메모리 이미지를 연결하고, 상태 안내와 OCR 번역 캡션을 이미지 바로 아래에 둔다.
      function collectSlots() {
        document.querySelectorAll('img[data-mt-img]').forEach((img) => {
          slots.push({ key: img.getAttribute('data-mt-img'), img, data: null, visible: false, note: null, cap: null, sig: '' });
        });
      }
      function regionView(r) {
        const st = Array.isArray(r[6]) ? r[6] : [];
        return {
          original: String(r[5]),
          translated: st[0] === 'd' ? String(st[1]) : null,
          failed: st[0] === 'f' ? String(st[1] || '') : null,
          pending: st[0] === 'p' ? String(st[1] || '번역 중…') : null,
        };
      }
      // 숫자/코드 조각처럼 의미 있는 글자가 없는 영역은 목록·오버레이에서 뺀다.
      function isMeaningfulRegion(r) {
        const text = String(r[5]).trim();
        return LETTER.test(text) && text.length > 2 && !/^[{\[]/.test(text) && !/^"[^"\n]+"\s*:/.test(text);
      }
      function normalizedEqual(a, b) {
        return a.trim().toLowerCase() === b.trim().toLowerCase();
      }
      function buildCaption(o) {
        if (!showDetails) return null;
        if (o.s === 'running') return create('mt-cap', '이미지 속 글자 인식 중…');
        if (o.s === 'failed') return create('mt-cap', o.m || '이미지 속 글자를 인식하지 못했습니다.');
        if (o.s !== 'done' || !Array.isArray(o.r)) return null;
        const rows = o.r.filter(isMeaningfulRegion);
        if (!rows.length) return null;
        const cap = create('mt-cap');
        const head = create('mt-caph');
        const arrow = create('mt-arrow', '▸');
        const title = create('mt-title', (mode === 'original' ? '이미지 속 텍스트' : '이미지 번역 상세') + ' (' + rows.length + '개) · 원본 이미지는 그대로 표시');
        head.append(arrow, title);
        head.classList.add('mt-toggle');
        const body = create('mt-rows');
        body.style.setProperty('display', 'none', 'important');
        head.addEventListener('click', () => {
          const open = body.style.display === 'none';
          body.style.setProperty('display', open ? 'block' : 'none', 'important');
          arrow.textContent = open ? '▾' : '▸';
        });
        for (const r of rows) {
          const v = regionView(r);
          const row = create('mt-row');
          row.append(create('mt-num', r[0]));
          const txt = create('mt-txt');
          if (mode === 'original' || v.translated === null) {
            txt.append(create('mt-main', v.original));
            if (mode !== 'original' && v.pending !== null) txt.append(create('mt-sub', v.pending));
            if (mode !== 'original' && v.failed !== null) txt.append(create('mt-sub', '⚠ ' + v.failed));
          } else {
            txt.append(create('mt-main', v.translated));
            if (mode === 'both') txt.append(create('mt-sub', v.original));
          }
          row.append(txt);
          body.append(row);
        }
        cap.append(head, body);
        return cap;
      }
      function renderSlot(sl, owner) {
        const d = sl.data;
        if (!d) return;
        if (d.src && sl.img.getAttribute('src') !== d.src) sl.img.setAttribute('src', d.src);
        const sig = JSON.stringify([d, mode, owner, sl.visible, showDetails]);
        if (sig === sl.sig) return;
        sl.sig = sig;
        if (sl.note) { sl.note.remove(); sl.note = null; }
        if (sl.cap) { sl.cap.remove(); sl.cap = null; }
        if (!sl.visible) return;
        let anchor = sl.img;
        const label = d.st === 'failed' ? '원격 이미지: ' + (d.m || '불러오지 못했습니다.')
          : d.st === 'idle' ? '원격 이미지 (불러오지 않음)'
          : d.st === 'missing' ? '메일 안에서 찾을 수 없는 이미지' : '';
        if (label) {
          sl.note = create('mt-note', d.alt ? label + ' — 대체 텍스트: ' + d.alt : label);
          insertAfter(anchor, sl.note);
          anchor = sl.note;
        }
        if (owner && d.ocr) {
          const cap = buildCaption(d.ocr);
          if (cap) { insertAfter(anchor, cap); sl.cap = cap; }
        }
      }
      function renderSlots() {
        // 같은 이미지가 여러 번 쓰이면 처음 보이는 위치에만 캡션을 단다.
        const owners = new Map();
        for (const sl of slots) {
          sl.visible = sl.img.isConnected && !hiddenByAncestor(sl.img);
          if (sl.visible && sl.data && sl.data.a && !owners.has(sl.data.a)) owners.set(sl.data.a, sl);
        }
        for (const sl of slots) renderSlot(sl, !!(sl.data && sl.data.a) && owners.get(sl.data.a) === sl);
      }
      function place(el, left, top, width, height) {
        el.style.setProperty('left', left + 'px', 'important');
        el.style.setProperty('top', top + 'px', 'important');
        if (width !== undefined) {
          el.style.setProperty('width', width + 'px', 'important');
          el.style.setProperty('height', height + 'px', 'important');
        }
      }
      // 번역이 실제로 바뀌고 의미 있는 글자가 있는 영역만, 원본 위치 그대로 제자리에 덮어 보여 준다.
      // 완벽한 자연스러운 인페인팅은 흉내 내지 않는, 안전한 사각형 오버레이다(원본/둘 다 모드는 그대로 전환 가능).
      function layoutTextOverlays(sl, rect, ox, oy, rows) {
        if (mode === 'original') return;
        for (const r of rows) {
          const st = Array.isArray(r[6]) ? r[6] : [];
          if (st[0] !== 'd') continue;
          const translated = String(st[1] || '').trim();
          const original = String(r[5]).trim();
          if (!translated || normalizedEqual(translated, original)) continue;
          const bw = r[3] * rect.width, bh = r[4] * rect.height;
          if (bw < 10 || bh < 8) continue;
          const bx = ox + r[1] * rect.width, by = oy + r[2] * rect.height;
          const ov = create('mt-ov', translated);
          place(ov, bx, by, bw, bh);
          const bg = (r[7] && /^#[0-9a-fA-F]{6}$/.test(r[7])) ? r[7] : '#ffffff';
          // 반투명이면 원문 글자가 비친다. 인식한 배경색으로 불투명하게 가린다(원본 그림 복원이 아닌 단색 가림).
          ov.style.background = bg;
          ov.style.color = (r[8] && /^#[0-9a-fA-F]{6}$/.test(r[8])) ? r[8] : '#000000';
          ov.style.fontSize = Math.max(8, Math.min(bh * 0.62, (bw / Math.max(translated.length, 1)) * 1.7)) + 'px';
          layer.append(ov);
        }
      }
      function layoutOverlays() {
        if (!layer || !layer.isConnected) { layer = create('mt-layer'); document.documentElement.appendChild(layer); }
        layer.textContent = '';
        for (const sl of slots) {
          const o = sl.data && sl.data.ocr;
          if (!sl.visible || !o || o.s !== 'done' || !Array.isArray(o.r) || !o.r.length) continue;
          const rect = sl.img.getBoundingClientRect();
          if (rect.width < 8 || rect.height < 8) continue;
          const ox = rect.left + window.scrollX, oy = rect.top + window.scrollY;
          const rows = o.r.filter(isMeaningfulRegion);
          layoutTextOverlays(sl, rect, ox, oy, rows);
          if (!showBoxes) continue;
          for (const r of o.r) {
            const box = create('mt-box');
            place(box, ox + r[1] * rect.width, oy + r[2] * rect.height, r[3] * rect.width, r[4] * rect.height);
            const label = create('mt-lbl', r[0]);
            place(label, ox + r[1] * rect.width, oy + r[2] * rect.height);
            layer.append(box, label);
          }
        }
      }

      // 4) 높이·폭 측정 (네이티브가 웹 보기 크기와 배율을 맞춘다)
      function measure() {
        const de = document.documentElement, body = document.body;
        if (!body) return null;
        if (!sentinel || !sentinel.isConnected) { sentinel = create('mt-end'); body.appendChild(sentinel); }
        const bs = style(body);
        const end = sentinel.getBoundingClientRect().bottom + px(bs.paddingBottom) + px(bs.borderBottomWidth);
        // body 높이는 height/min-height:100% 등에 의해 웹 보기 높이를 따라갈 수 있다.
        // 이를 다시 네이티브 높이로 쓰면 여유 공간(+2)이 매번 누적되므로 본문 끝만 측정한다.
        const bottom = end + px(bs.marginBottom) + window.scrollY;
        const metrics = [de.scrollWidth, de.clientWidth, Math.ceil(Math.max(bottom, 1))];
        const sig = metrics.join(',');
        if (sig !== lastMetrics) {
          lastMetrics = sig;
          layoutOverlays();
          post({ type: 'metrics', metrics });
        }
        return metrics;
      }

      function start(attempt) {
        if (started) return;
        attempt = attempt || 0;
        if (document.documentElement.clientWidth < 40 && attempt < 60) {
          setTimeout(() => start(attempt + 1), 50);
          return;
        }
        started = true;
        let items;
        try {
          items = extract();
          collectSlots();
        } catch (e) {
          post({ type: 'failed' });
          return;
        }
        post({ type: 'segments', items });
        measure();
        document.addEventListener('load', () => measure(), true);
        try { new ResizeObserver(() => measure()).observe(document.documentElement); } catch (e) {}
      }

      function apply(p) {
        if (!started || !p || p.token !== TOKEN) return false;
        let all = false;
        if (typeof p.mode === 'string' && p.mode !== mode) { mode = p.mode; all = true; }
        if (typeof p.boxes === 'boolean') showBoxes = p.boxes;
        if (typeof p.details === 'boolean') showDetails = p.details;
        if (p.units && typeof p.units === 'object') {
          for (const id of Object.keys(p.units)) {
            states.set(id, p.units[id]);
            if (!all) { const u = units.get(id); if (u) applyUnit(u); }
          }
        }
        if (all) units.forEach(applyUnit);
        if (p.slots && typeof p.slots === 'object') {
          for (const sl of slots) {
            if (Object.prototype.hasOwnProperty.call(p.slots, sl.key)) sl.data = p.slots[sl.key];
          }
        }
        renderSlots();
        lastMetrics = '';
        measure();
        return true;
      }

      window.__mailTranslator = Object.freeze({ apply, measure, start: () => start(0) });
      start(0);
    })();
    """#
}
