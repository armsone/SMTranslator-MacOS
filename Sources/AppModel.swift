import AppKit
import NaturalLanguage
import Observation
import SwiftUI
import Translation
import UniformTypeIdentifiers
import WebKit

// 앱 상태와 번역 파이프라인. 메일 내용은 메모리에만 두며 디스크/로그에 남기지 않는다.

enum DisplayMode: String, CaseIterable, Identifiable {
    case translation = "번역만"
    case both = "번역 + 원문"
    case original = "원문만"
    var id: Self { self }
}

enum SegmentState {
    case pending
    case done(String)
    case failed(String)
    case skipped
}

enum OCRState {
    case running
    case done([OCRRegion])
    case failed(String)
}

enum RemoteImageState {
    case loading
    case loaded(assetID: String)
    case failed(String)
}

/// HTML 메일의 원본 서식 보기 상태
enum FormattedBodyState: Equatable {
    case none
    case preparing      // 외부 요청 차단 규칙 컴파일 중
    case extracting     // 웹 보기에서 보이는 텍스트를 찾는 중
    case ready
    case failed(String) // 읽기용 텍스트 보기로 대체됨
}

enum TranslationPhase {
    case idle
    case preparing
    case translating
}

/// 외부 AI 번역 진행 상태(Apple 번역의 TranslationPhase와 별개)
enum ExternalPhase: Equatable {
    case idle
    case awaitingAction     // 대기 항목이 있으나 사용자의 번역 실행이 필요
    case running
    case failed(String)     // 다른 제공사나 Apple 번역으로 대체하지 않음
}

/// 전송 동의 대화상자 요청. 요청한 문서에만 묶여, 문서가 바뀌면 그 문서를 승인하지 않는다.
struct ExternalConsentRequest: Equatable {
    let service: ExternalService
    let documentID: UUID
}

/// 번역 방식(메일·화면 번역 공용). system/intelligence는 Apple Translation 프레임워크(기기 내)이며 외부 서비스·키를 쓰지 않는다.
/// Apple Intelligence 우선은 '선호'일 뿐이며, 실제로 어느 모델이 쓰였는지는 시스템이 결정하고 앱에서 확인할 수 없다.
/// chatgpt/claude/gemini는 사용자의 웹 계정 로그인 세션(AIBI)으로 번역하며 API 키를 쓰지 않는다.
/// deepl/google/papago는 각 서비스의 공식 번역 웹페이지(로그인 없음)에 항목마다 입력해 번역하며 API 키를 쓰지 않는다.
/// 외부 방식은 사용자가 번역을 실행할 때만 텍스트(메일: 제목·본문·이미지 OCR, 화면: 인식한 글자)를 해당 서비스로 보낸다.
enum TranslationBackend: String, CaseIterable, Identifiable {
    case system          // TranslationSession.Strategy.lowLatency
    case intelligence    // TranslationSession.Strategy.highFidelity (macOS 26.4+)
    case chatgpt
    case claude
    case gemini
    case deepl
    case google
    case papago

    var id: Self { self }

    /// 외부 AI(웹 계정) 제공사. 웹 번역기와 Apple 번역은 nil.
    var provider: AIProvider? { AIProvider(rawValue: rawValue) }
    var webTranslator: WebTranslator? { WebTranslator(rawValue: rawValue) }
    var isExternal: Bool { provider != nil || webTranslator != nil }

    var externalService: ExternalService? {
        if let provider { return .ai(provider) }
        if let webTranslator { return .web(webTranslator) }
        return nil
    }

    var title: String {
        switch self {
        case .system: return "Mac 기본 번역"
        case .intelligence: return "Apple Intelligence 우선"
        case .chatgpt, .claude, .gemini: return provider?.title ?? rawValue
        case .deepl, .google, .papago: return webTranslator?.title ?? rawValue
        }
    }

    var detail: String {
        switch self {
        case .system: return "기존 Mac 기기 내 번역 모델"
        case .intelligence: return "AI 사용 불가 시 기본 번역"
        case .chatgpt, .claude, .gemini: return "웹 로그인 · 실행 시 외부 전송"
        case .deepl, .google, .papago: return "공식 웹페이지 · 실행 시 외부 전송"
        }
    }

    static var intelligenceSupported: Bool {
        if #available(macOS 26.4, *) { return true }
        return false
    }

    static let defaultsKey = "translationBackend"
}

enum AppError: LocalizedError {
    case fileTooLarge
    case unreadableImage
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .fileTooLarge: return "파일이 너무 큽니다(200MB 초과)."
        case .unreadableImage: return "이미지 파일을 해석할 수 없습니다."
        case .unreadableFile: return "파일을 읽을 수 없습니다."
        }
    }
}

private struct Segment {
    let text: String
    let groupKey: String
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // 문서/로드 상태
    private(set) var document: MailDocument?
    private(set) var isLoading = false
    private(set) var loadingMessage = ""
    var errorMessage: String?
    var errorNeedsAutomationSettings = false
    var showImporter = false

    // 설정
    var sourceLanguageID = "auto" {
        didSet { if oldValue != sourceLanguageID { restartTranslation() } }
    }
    var targetLanguageID = "ko" {
        didSet { if oldValue != targetLanguageID { restartTranslation() } }
    }
    /// 메일·화면 번역이 공용으로 쓰는 고정 번역 방식(Mac 기본 번역 + 가능하면 Apple Intelligence 다듬기). 고를 수 없다.
    var backend: TranslationBackend { TranslationBackendStore.shared.backend }
    var displayMode: DisplayMode = .translation
    /// HTML 메일을 원본 서식으로 보여 줄지(끄면 기존 읽기용 텍스트 보기)
    var preferFormattedHTML = true {
        didSet {
            guard oldValue != preferFormattedHTML, let doc = document, doc.formattedHTML != nil else { return }
            if preferFormattedHTML, formattedState == .ready {
                formattedState = .extracting // 새 웹 보기가 다시 텍스트를 찾는다
                htmlSegments = []
            }
            restartTranslation()
        }
    }
    /// 디버그용 번호 사각형(기본 숨김). 기본 화면에는 제자리 번역 오버레이만 보인다.
    var showOCRBoxes = false
    /// 이미지 글자 인식 상세 목록(원문/번역 전체)을 기본적으로 펼쳐 둘지
    var showOCRDetails = false
    var keepOnTop = false {
        didSet { applyWindowLevel() }
    }
    private(set) var supportedLanguageIDs: [String] = []

    // 번역 상태
    var translationConfig: TranslationSession.Configuration?
    private(set) var segmentStates: [String: SegmentState] = [:]
    private(set) var ocrStates: [String: OCRState] = [:]
    private(set) var remoteStates: [String: RemoteImageState] = [:]
    private(set) var translationPhase: TranslationPhase = .idle
    private(set) var documentLanguageKey: String?
    private(set) var groupFailures: [String: String] = [:]
    private(set) var formattedState: FormattedBodyState = .none
    private(set) var formattedRuleList: WKContentRuleList?
    /// 원본 서식 웹 보기에서 찾은 텍스트 단위(DOM 순서)
    @ObservationIgnored private var htmlSegments: [(id: String, text: String)] = []

    @ObservationIgnored private var segments: [String: Segment] = [:]
    @ObservationIgnored private var segmentOrder: [String] = []
    @ObservationIgnored private var documentGeneration = 0
    @ObservationIgnored private var translationGeneration = 0
    @ObservationIgnored private var runToken = 0
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var currentGroupKey: String?
    @ObservationIgnored private var ocrTask: Task<Void, Never>?
    @ObservationIgnored private var remoteTask: Task<Void, Never>?
    @ObservationIgnored private var activeSession: TranslationSession?
    @ObservationIgnored private var configBackend: TranslationBackend?
    /// Apple Intelligence 다듬기 작업(설정 켜짐 + 기기 내 모델 가능 시에만). 번역 재시작·문서 교체·취소 때 함께 취소한다.
    @ObservationIgnored private var refineTasks: [Task<Void, Never>] = []

    /// Mail에서 요청한 메시지라 원격 이미지를 자동으로 불러왔는지(안내 문구용)
    private(set) var remoteAutoRequested = false

    // 외부 AI 번역 상태
    private(set) var externalPhase: ExternalPhase = .idle
    /// 전송 동의를 물어야 하는 제공사와 요청한 문서(동의 대화상자 표시용)
    var consentRequest: ExternalConsentRequest?
    /// 현재 메일을 외부 AI로 보내도 되는지(사용자가 이 메일에 대해 번역을 실행했거나 메일 요청 시 동의가 기억된 경우)
    @ObservationIgnored private var externalAuthorizedDocument: UUID?
    @ObservationIgnored private var externalBatchesInAction = 0
    /// 웹 번역기로 이번 실행에서 보낸 항목 수(WebTranslation.itemsPerAction까지)
    @ObservationIgnored private var webItemsInAction = 0
    @ObservationIgnored private var externalTask: Task<Void, Never>?
    @ObservationIgnored private var externalBatch: ExternalBatch?
    /// 누락된 항목만 같은 제공사에 한 번 더 요청한다. 완료 항목은 다시 보내지 않는다.
    @ObservationIgnored private var externalMissingAttempts: [String: Int] = [:]
    @ObservationIgnored private var externalServiceRetryCount = 0
    @ObservationIgnored private var externalFormatRetryCount = 0
    /// 외부 작업마다 증가. 취소된 이전 작업의 늦은 완료가 새 작업 상태를 바꾸지 못하게 한다.
    @ObservationIgnored private var externalRunToken = 0

    private init() {
        // 화면 번역 쪽에서 방식을 바꿔도 메일 번역이 같은 규칙으로 다시 준비되게 한다.
        TranslationBackendStore.shared.observe { [weak self] oldValue, backend in
            guard let self else { return }
            self.restartTranslation()
            if !(oldValue.isExternal && backend.isExternal) { Task { await self.loadSupportedLanguages() } }
        }
    }

    // MARK: - 언어 목록

    func loadSupportedLanguages() async {
        let availability = backend.makeLanguageAvailability()
        let languages = await availability.supportedLanguages
        var ids = Set(languages.map(\.minimalIdentifier))
        ids.insert("ko")
        supportedLanguageIDs = ids.sorted { Self.languageName($0) < Self.languageName($1) }
    }

    static func languageName(_ id: String) -> String {
        Locale(identifier: "ko").localizedString(forIdentifier: id) ?? id
    }

    // MARK: - 불러오기

    /// Mail 메뉴(서비스 › 메일 전체 번역)와 앱의 '선택한 메일 번역'이 함께 쓰는 진입점.
    /// 창을 앞으로 가져오기 전에 Mail의 선택 메시지 원본을 먼저 확보하고, 진행 중인 이전 요청은 취소한다.
    /// 사용자가 이 메시지를 직접 요청했으므로 원격 이미지는 확인 창 없이 자동으로 불러온다.
    func translateSelectedMail() {
        beginLoading("Mail에서 선택한 메시지를 가져오는 중…")
        let generation = documentGeneration
        let selection: MailSelection
        do {
            selection = try MailBridge.fetchSelectedMessage()
        } catch {
            failLoading(error)
            showMainWindow()
            return
        }
        loadingMessage = "메일 구조를 해석하는 중…"
        showMainWindow()
        Task {
            do {
                let data = Data(selection.source.utf8)
                let doc = try await Self.parseMessage(data, preferUTF8: true,
                                                      origin: .mail(selectionCount: selection.selectionCount))
                // 그사이 다른 메시지가 요청되었으면 이 결과는 버린다.
                guard generation == documentGeneration else { return }
                present(doc)
                // 이 경로는 사용자가 선택 메일 번역 버튼/서비스를 직접 실행한 경우에만 호출된다.
                if backend.isExternal { requestExternalTranslation() }
                if remoteImageCount > 0 {
                    remoteAutoRequested = true
                    loadRemoteImages()
                }
            } catch {
                guard generation == documentGeneration else { return }
                failLoading(error)
            }
        }
    }

    func open(url: URL) {
        beginLoading("파일을 여는 중…")
        let generation = documentGeneration
        Task {
            do {
                let doc = try await Self.loadFile(url)
                guard generation == documentGeneration else { return }
                present(doc)
            } catch {
                guard generation == documentGeneration else { return }
                failLoading(error)
            }
        }
    }

    func closeDocument() {
        cancelAllWork()
        consentRequest = nil
        document = nil
        isLoading = false
        resetTranslationState()
        ocrStates = [:]
        remoteStates = [:]
        remoteAutoRequested = false
        formattedState = .none
        htmlSegments = []
        translationConfig = nil
        configBackend = nil
    }

    private func beginLoading(_ message: String) {
        cancelAllWork()
        consentRequest = nil
        document = nil
        resetTranslationState()
        ocrStates = [:]
        remoteStates = [:]
        remoteAutoRequested = false
        formattedState = .none
        htmlSegments = []
        errorMessage = nil
        loadingMessage = message
        isLoading = true
    }

    private func failLoading(_ error: Error) {
        isLoading = false
        errorMessage = error.localizedDescription
        errorNeedsAutomationSettings = (error as? MailBridgeError) == .notAuthorized
    }

    /// 메일 번역 결과 창을 앞으로 가져온다. 창이 없으면 새로 만든다(MailWindowCoordinator).
    func showMainWindow() {
        MailWindowCoordinator.shared.showMailWindow()
    }

    /// 메일 내용을 지워야 하는 결과 창인지(설정 창·AI 브라우저 패널·화면 번역 창 제외)
    static func isResultWindow(_ window: NSWindow) -> Bool {
        MailWindowCoordinator.shared.isMailWindow(window)
    }

    nonisolated private static func parseMessage(_ data: Data, preferUTF8: Bool,
                                                 origin: MailDocument.Origin) async throws -> MailDocument {
        try await Task.detached(priority: .userInitiated) {
            var parser = MIMEParser(preferUTF8For8bit: preferUTF8)
            let message = try parser.parse(data)
            return MailDocumentBuilder.build(message: message, parser: parser, origin: origin)
        }.value
    }

    nonisolated private static func loadFile(_ url: URL) async throws -> MailDocument {
        try await Task.detached(priority: .userInitiated) {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
            if let size = values?.fileSize, size > MIMEParser.maxInputSize { throw AppError.fileTooLarge }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw AppError.unreadableFile }
            let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
            if let type, type.conforms(to: .image) {
                guard let doc = MailDocumentBuilder.build(imageData: data, fileName: url.lastPathComponent) else {
                    throw AppError.unreadableImage
                }
                return doc
            }
            var parser = MIMEParser()
            let message = try parser.parse(data)
            return MailDocumentBuilder.build(message: message, parser: parser, origin: .emlFile)
        }.value
    }

    private func present(_ doc: MailDocument) {
        cancelAllWork()
        consentRequest = nil
        resetTranslationState()
        ocrStates = [:]
        remoteStates = [:]
        remoteAutoRequested = false
        htmlSegments = []
        formattedState = doc.formattedHTML == nil ? .none : .preparing
        document = doc
        isLoading = false
        // 문서 표시와 외부 전송 실행은 분리한다. 저장된 동의만으로 새 문서를 전송하지 않는다.
        externalPhase = .idle
        externalBatchesInAction = 0
        webItemsInAction = 0
        externalAuthorizedDocument = nil
        if doc.formattedHTML != nil { prepareFormattedBody() }
        computeDocumentLanguage(doc)
        registerTextSegments(doc)
        scheduleTranslation()
        startOCR(doc)
    }

    // MARK: - 원본 서식 보기

    /// HTML 메일을 웹 보기로 열기 전에 외부 요청 차단 규칙을 먼저 준비한다. 실패하면 원본 HTML을 띄우지 않고 읽기용 텍스트로 대체한다.
    private func prepareFormattedBody() {
        let generation = documentGeneration
        Task {
            do {
                let list = try await MailWebSecurity.ruleList()
                guard generation == documentGeneration else { return }
                formattedRuleList = list
                if formattedState == .preparing { formattedState = .extracting }
            } catch {
                guard generation == documentGeneration, let id = document?.id else { return }
                formattedBodyFailed(documentID: id, reason: "외부 요청 차단 규칙을 준비하지 못했습니다.")
            }
        }
    }

    /// 서식 보기가 원본 HTML 본문을 대신 보여 주는지(준비·분석 중 포함)
    var usesFormattedBody: Bool {
        guard preferFormattedHTML, document?.formattedHTML != nil else { return false }
        switch formattedState {
        case .preparing, .extracting, .ready: return true
        case .none, .failed: return false
        }
    }

    /// 서식 본문 텍스트를 아직 찾는 중이면 완료로 표시하지 않는다.
    var formattedBodyPending: Bool {
        usesFormattedBody && (formattedState == .preparing || formattedState == .extracting)
    }

    var formattedFailureMessage: String? {
        if case .failed(let reason) = formattedState { return reason }
        return nil
    }

    /// 웹 보기(격리된 앱 world 스크립트)가 찾은 보이는 텍스트 단위를 번역 대상으로 등록한다.
    func htmlSegmentsExtracted(documentID: UUID, items: [(id: String, text: String)]) {
        guard document?.id == documentID, usesFormattedBody, formattedState != .ready else { return }
        htmlSegments = items
        formattedState = .ready
        items.forEach { registerSegment(id: $0.id, text: $0.text) }
        scheduleTranslation()
    }

    /// 웹 보기를 쓸 수 없으면 해당 HTML 블록을 기존 읽기용 텍스트로 번역해 보여 준다.
    func formattedBodyFailed(documentID: UUID, reason: String) {
        guard document?.id == documentID, document?.formattedHTML != nil else { return }
        if case .failed = formattedState { return }
        formattedState = .failed(reason)
        htmlSegments = []
        restartTranslation(keepExternalAuthorization: true)
    }

    /// 앱 전용 스킴 처리기가 이 메일의 메모리 이미지만 꺼내 갈 수 있게 한다.
    func assetImage(documentID: UUID, assetID: String) -> CGImage? {
        guard let doc = document, doc.id == documentID else { return nil }
        return doc.assets[assetID]?.cgImage
    }

    // MARK: - 취소

    private func cancelAllWork() {
        documentGeneration += 1
        ocrTask?.cancel()
        remoteTask?.cancel()
        ocrTask = nil
        remoteTask = nil
        cancelTranslationRun()
    }

    private func cancelTranslationRun() {
        translationGeneration += 1
        runToken += 1
        isRunning = false
        currentGroupKey = nil
        if #available(macOS 26.0, *) { activeSession?.cancel() }
        activeSession = nil
        translationPhase = .idle
        refineTasks.forEach { $0.cancel() }
        refineTasks.removeAll()
        if externalTask != nil {
            externalTask?.cancel()
            externalTask = nil
            AIBIRunner.shared.cancel(owner: .mail)
            WebTranslatorRunner.shared.cancel(owner: .mail)
        }
        externalBatch = nil
        externalPhase = .idle
        externalMissingAttempts.removeAll()
        externalServiceRetryCount = 0
        externalFormatRetryCount = 0
    }

    private func resetTranslationState() {
        segments = [:]
        segmentOrder = []
        segmentStates = [:]
        groupFailures = [:]
        documentLanguageKey = nil
    }

    /// 원본/대상 언어나 번역 방식이 바뀌면 이미 받은 이미지와 OCR 결과는 유지하고 번역만 다시 한다.
    /// 외부 AI는 설정 변경만으로 다시 보내지 않는다(사용자가 번역을 다시 실행해야 함).
    private func restartTranslation(keepExternalAuthorization: Bool = false) {
        guard let doc = document else { return }
        cancelTranslationRun()
        if !keepExternalAuthorization { externalAuthorizedDocument = nil }
        externalBatchesInAction = 0
        webItemsInAction = 0
        if backend.isExternal {
            translationConfig = nil
            configBackend = nil
        }
        resetTranslationState()
        computeDocumentLanguage(doc)
        registerTextSegments(doc)
        for block in doc.blocks {
            for assetID in assetIDs(in: block) {
                if case .done(let regions)? = ocrStates[assetID] {
                    regions.forEach { registerSegment(id: $0.id, text: $0.text) }
                }
            }
        }
        scheduleTranslation()
    }

    // MARK: - 세그먼트 등록과 언어 감지

    private func computeDocumentLanguage(_ doc: MailDocument) {
        guard sourceLanguageID == "auto" else {
            documentLanguageKey = sourceLanguageID
            return
        }
        var sample = doc.subject ?? ""
        for block in doc.blocks {
            if case .text(let style, let text) = block.kind, style != .caption { sample += "\n" + text }
            if sample.count > 8000 { break }
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        documentLanguageKey = recognizer.dominantLanguage.map { normalizedKey($0.rawValue) }
    }

    private func registerTextSegments(_ doc: MailDocument) {
        if let subject = doc.subject { registerSegment(id: "subject", text: subject) }
        // 서식 보기에서는 HTML 본문 블록 대신 웹 보기의 텍스트 노드 단위를 번역한다(같은 본문을 두 번 번역하지 않음).
        let htmlRange = usesFormattedBody ? doc.formattedHTML?.blockRange : nil
        for (index, block) in doc.blocks.enumerated() {
            if let htmlRange, htmlRange.contains(index) { continue }
            if case .text(let style, let text) = block.kind, style != .caption {
                registerSegment(id: block.id, text: text)
            }
        }
        if usesFormattedBody { htmlSegments.forEach { registerSegment(id: $0.id, text: $0.text) } }
    }

    private func registerSegment(id: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard segments[id] == nil, !trimmed.isEmpty else { return }
        let key = groupKey(for: trimmed)
        segments[id] = Segment(text: trimmed, groupKey: key)
        segmentOrder.append(id)
        // key == "auto": 문서 전체·주변 단서로도 언어를 정하지 못한 경우. 원문 언어가 nil인 세션으로
        // 보내면 Apple이 자동 판별에 실패해 '언어 선택' 팝업을 띄울 수 있어, 요청하지 않고 원문을 그대로 둔다.
        if !trimmed.contains(where: { $0.isLetter }) || isTargetLanguage(key) || key == "auto" {
            segmentStates[id] = .skipped
        } else if let message = groupFailures[key] {
            segmentStates[id] = .failed(message)
        } else {
            segmentStates[id] = .pending
        }
    }

    private func groupKey(for text: String) -> String {
        if sourceLanguageID != "auto" { return sourceLanguageID }
        let fallback = documentLanguageKey ?? "auto"
        guard text.count >= 12 else { return shortGroupKey(for: text, fallback: fallback) }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2000)))
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= 0.6 else { return fallback }
        let key = normalizedKey(language.rawValue)
        if !supportedLanguageIDs.isEmpty, !isSupported(key) { return fallback }
        return key
    }

    /// 짧은 단위는 대개 문서 언어를 따르지만, 가나·한글 같은 강한 문자 단서는 그대로 쓰고, 일본어처럼 다른 문자를
    /// 쓰는 문서 속 짧은 라틴 문자 단위는 문서 언어를 물려받지 않는다(정하지 못하면 원문 언어 nil 묶음).
    private func shortGroupKey(for text: String, fallback: String) -> String {
        switch LanguageDetection.classify(text) {
        case .language(let key):
            return supportedLanguageIDs.isEmpty || isSupported(key) ? key : fallback
        case .ambiguous(.latin, let guess) where fallback != "auto" && !LanguageDetection.usesLatinScript(fallback):
            if let guess, supportedLanguageIDs.isEmpty || isSupported(guess) { return guess }
            return "auto"
        default:
            return fallback
        }
    }

    private func normalizedKey(_ raw: String) -> String {
        Locale.Language(identifier: raw).minimalIdentifier
    }

    private func isSupported(_ key: String) -> Bool {
        let code = Locale.Language(identifier: key).languageCode
        return supportedLanguageIDs.contains { Locale.Language(identifier: $0).languageCode == code }
    }

    private func isTargetLanguage(_ key: String) -> Bool {
        guard key != "auto" else { return false }
        let a = Locale.Language(identifier: key)
        let b = Locale.Language(identifier: targetLanguageID)
        guard a.languageCode == b.languageCode else { return false }
        if a.languageCode?.identifier == "zh" { return a.maximalIdentifier == b.maximalIdentifier }
        return true
    }

    // MARK: - 번역 실행 (translationTask에서 호출)

    /// 대기 중인 세그먼트가 있으면 해당 언어 그룹으로 translationTask를 (재)시작시킨다.
    private func scheduleTranslation() {
        guard document != nil else { return }
        if backend.isExternal {
            scheduleExternal()
            return
        }
        guard !isRunning else { return }
        var seen = Set<String>()
        let pendingKeys = segmentOrder.compactMap { id -> String? in
            guard case .pending? = segmentStates[id], let key = segments[id]?.groupKey,
                  seen.insert(key).inserted else { return nil }
            return key
        }
        guard let key = pendingKeys.first else {
            translationPhase = .idle
            return
        }
        currentGroupKey = key
        let source: Locale.Language? = key == "auto" ? nil : Locale.Language(identifier: key)
        let target = Locale.Language(identifier: targetLanguageID)
        if var config = translationConfig, config.source == source, config.target == target,
           configBackend == backend {
            config.invalidate()
            translationConfig = config
        } else {
            translationConfig = backend.makeConfiguration(source: source, target: target)
            configBackend = backend
        }
        translationPhase = .preparing
    }

    func performTranslation(session: TranslationSession) async {
        guard let key = currentGroupKey, document != nil, !isRunning, !backend.isExternal else { return }
        let generation = translationGeneration
        runToken += 1
        let token = runToken
        isRunning = true
        activeSession = session

        await translateGroup(key: key, session: session, generation: generation)

        guard runToken == token else { return }
        isRunning = false
        activeSession = nil
        currentGroupKey = nil
        if generation == translationGeneration && !Task.isCancelled {
            scheduleTranslation()
        } else {
            translationPhase = .idle
        }
    }

    private func translateGroup(key: String, session: TranslationSession, generation: Int) async {
        translationPhase = .preparing
        do {
            // 언어 팩이 없으면 시스템이 사용자에게 다운로드 승인을 요청한다.
            try await session.prepareTranslation()
        } catch {
            guard generation == translationGeneration, !Self.isCancellation(error) else { return }
            let message = await Self.translationErrorMessage(error, source: key, target: targetLanguageID)
            guard generation == translationGeneration, !Task.isCancelled else { return }
            failGroup(key, message: message)
            return
        }
        translationPhase = .translating
        while generation == translationGeneration, !Task.isCancelled {
            let ids = segmentOrder.filter { id in
                guard segments[id]?.groupKey == key, case .pending? = segmentStates[id] else { return false }
                return true
            }
            guard !ids.isEmpty else { return }
            for batch in makeBatches(ids) {
                guard generation == translationGeneration, !Task.isCancelled else { return }
                await translateBatch(batch, session: session, generation: generation)
            }
            // 진전이 없으면(예: 취소 오류) 무한 반복을 피한다.
            let stillPending = ids.filter { if case .pending? = segmentStates[$0] { return true } else { return false } }
            if stillPending.count == ids.count { return }
        }
    }

    /// 서식 보기는 문단·셀마다 세그먼트를 만들어 긴 HTML 메일은 수백 개가 된다. 묶음마다 순서대로 기다리므로
    /// 예전 상한(12개·3000자)에서는 200개 메일이 17번 직렬 호출되었다. 40개·6000자로 묶어 호출 수를 줄인다(200개 → 5회).
    private static let batchItemLimit = 40
    private static let batchCharacterLimit = 6000

    private func makeBatches(_ ids: [String]) -> [[String]] {
        var batches: [[String]] = []
        var current: [String] = []
        var chars = 0
        for id in ids {
            let length = segments[id]?.text.count ?? 0
            if !current.isEmpty && (current.count >= Self.batchItemLimit || chars + length > Self.batchCharacterLimit) {
                batches.append(current)
                current = []
                chars = 0
            }
            current.append(id)
            chars += length
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    private func translateBatch(_ ids: [String], session: TranslationSession, generation: Int) async {
        var requests: [TranslationSession.Request] = []
        var chunkMap: [String: [TextChunk]] = [:]
        for id in ids {
            guard let text = segments[id]?.text else { continue }
            let chunks = TextChunker.chunks(text)
            chunkMap[id] = chunks
            for (index, chunk) in chunks.enumerated() {
                requests.append(TranslationSession.Request(sourceText: chunk.text, clientIdentifier: "\(id)|\(index)"))
            }
        }
        guard !requests.isEmpty else { return }
        do {
            let responses = try await session.translations(from: requests)
            guard generation == translationGeneration else { return }
            var pieces: [String: [Int: String]] = [:]
            for response in responses {
                guard let client = response.clientIdentifier, let bar = client.lastIndex(of: "|"),
                      let index = Int(client[client.index(after: bar)...]) else { continue }
                pieces[String(client[..<bar]), default: [:]][index] = response.targetText
            }
            var newlyDone: [String] = []
            for id in ids {
                guard let chunks = chunkMap[id] else { continue }
                let got = pieces[id] ?? [:]
                if got.count == chunks.count {
                    var joined = ""
                    for (index, chunk) in chunks.enumerated() {
                        joined += (got[index] ?? "") + chunk.separator
                    }
                    segmentStates[id] = .done(joined.trimmingCharacters(in: .whitespacesAndNewlines))
                    newlyDone.append(id)
                } else {
                    segmentStates[id] = .failed("번역 응답 일부가 누락되었습니다.")
                }
            }
            scheduleRefine(newlyDone, generation: generation)
        } catch {
            guard generation == translationGeneration, !Self.isCancellation(error), !Task.isCancelled else { return }
            if ids.count > 1 {
                // 어느 세그먼트가 문제인지 격리해 부분 실패로 처리
                for id in ids {
                    guard generation == translationGeneration, !Task.isCancelled else { return }
                    await translateBatch([id], session: session, generation: generation)
                }
            } else if let id = ids.first {
                let message = await Self.translationErrorMessage(error, source: segments[id]?.groupKey ?? "auto", target: targetLanguageID)
                guard generation == translationGeneration, !Task.isCancelled else { return }
                segmentStates[id] = .failed(message)
            }
        }
    }

    // MARK: - Apple Intelligence 다듬기 (설정 켜짐 + 기기 내 모델 가능 시에만, Mac 기본 번역 결과만)

    /// 방금 .done이 된 줄만 작은 묶음으로 나눠 비동기로 다듬는다. 번역 자체는 이미 화면에 표시된 뒤이며,
    /// 다듬기 결과가 와도 같은 줄 자리(같은 ID)만 바꾼다. 외부 AI·웹 번역기 결과는 다듬지 않는다.
    private func scheduleRefine(_ ids: [String], generation: Int) {
        guard !backend.isExternal, AppleTranslationRefiner.isEnabled, AppleTranslationRefiner.supportsTarget(targetLanguageID) else { return }
        let doneIDs = ids.filter { if case .done? = segmentStates[$0] { return true } else { return false } }
        guard !doneIDs.isEmpty else { return }
        let targetName = Self.languageName(targetLanguageID)
        var start = 0
        while start < doneIDs.count {
            let chunk = Array(doneIDs[start..<min(start + AppleTranslationRefiner.maxItemsPerBatch, doneIDs.count)])
            start += AppleTranslationRefiner.maxItemsPerBatch
            let items: [AppleTranslationRefiner.Item] = chunk.compactMap { id in
                guard let original = segments[id]?.text, case .done(let draft)? = segmentStates[id] else { return nil }
                return AppleTranslationRefiner.Item(key: id, original: original, draft: draft)
            }
            guard !items.isEmpty, let first = chunk.first else { continue }
            let (nearbyOriginal, nearbyDraft) = nearbyRefineContext(for: first)
            let task = Task { [weak self] in
                guard let self else { return }
                let result = await AppleTranslationRefiner.refine(
                    items: items, nearbyOriginal: nearbyOriginal, nearbyDraft: nearbyDraft,
                    targetLanguageName: targetName, isCurrent: { [weak self] in self?.translationGeneration == generation })
                guard self.translationGeneration == generation, AppleTranslationRefiner.isEnabled, !result.isEmpty else { return }
                for (key, text) in result {
                    guard case .done? = self.segmentStates[key] else { continue }
                    self.segmentStates[key] = .done(text)
                }
            }
            refineTasks.append(task)
        }
    }

    /// 다듬을 줄 바로 앞뒤(읽는 순서) 몇 줄의 원문·현재 번역문만 짧게 넘겨 맥락을 준다(문서 전체를 넘기지 않음).
    private func nearbyRefineContext(for id: String) -> ([String], [String]) {
        guard let index = segmentOrder.firstIndex(of: id) else { return ([], []) }
        var originals: [String] = []
        var drafts: [String] = []
        let radius = AppleTranslationRefiner.maxNearbyLines
        var offset = 1
        while originals.count < radius && (index - offset >= 0 || index + offset < segmentOrder.count) {
            for neighborIndex in [index - offset, index + offset] {
                guard originals.count < radius, segmentOrder.indices.contains(neighborIndex) else { continue }
                let neighborID = segmentOrder[neighborIndex]
                guard let original = segments[neighborID]?.text, case .done(let draft)? = segmentStates[neighborID] else { continue }
                originals.append(original)
                drafts.append(draft)
            }
            offset += 1
        }
        return (originals, drafts)
    }

    private func failGroup(_ key: String, message: String) {
        groupFailures[key] = message
        for (id, segment) in segments where segment.groupKey == key {
            if case .pending? = segmentStates[id] { segmentStates[id] = .failed(message) }
        }
    }

    // MARK: - 외부 AI 번역 (웹 로그인 · AIBI)

    var externalProvider: AIProvider? { backend.provider }
    var externalService: ExternalService? { backend.externalService }

    var externalPendingCount: Int {
        segmentStates.values.filter { if case .pending = $0 { return true } else { return false } }.count
    }

    /// 번역 대기 줄 문구: 외부 AI는 실행 전까지 '번역 중'으로 보이지 않게 한다.
    var pendingLabel: String {
        guard backend.isExternal else { return "번역 중…" }
        return externalPhase == .running ? "번역 중…" : "번역 대기 (실행 필요)"
    }

    /// 상태 표시줄의 번역 실행 버튼. 처음 쓰는 제공사면 전송 동의부터 묻는다.
    func requestExternalTranslation() {
        guard let service = externalService, let doc = document else { return }
        guard service.hasConsent else {
            consentRequest = ExternalConsentRequest(service: service, documentID: doc.id)
            return
        }
        authorizeExternal()
    }

    /// 대화상자를 띄운 그 문서일 때만 동의·실행한다. 그사이 문서가 바뀌었으면 아무것도 승인하지 않는다.
    func grantConsentAndTranslate(_ request: ExternalConsentRequest) {
        // 경고창이 닫히며 바인딩이 먼저 nil이 될 수 있으므로 표시 중 여부가 아니라 문서 ID로 확인한다.
        consentRequest = nil
        guard document?.id == request.documentID else { return }
        request.service.grantConsent()
        guard externalService == request.service else { return }
        authorizeExternal()
    }

    /// 실패·누락 항목을 다시 대기로 돌려 같은 제공사로 다시 보낸다(완료된 항목은 다시 보내지 않음).
    func retryExternalFailures() {
        guard backend.isExternal else { return }
        for (id, state) in segmentStates {
            if case .failed(let message) = state, message != ExternalTranslation.tooLongMessage {
                segmentStates[id] = .pending
            }
        }
        requestExternalTranslation()
    }

    /// 자동 입력이 제공사 화면 변화로 맞지 않을 때: 보이는 공식 화면 + 요청 복사 + 응답 붙여넣기(같은 검증)
    func startExternalManual() {
        guard let provider = externalProvider, let doc = document else { return }
        guard AIBIAccounts.shared.hasConsent(provider) else {
            consentRequest = ExternalConsentRequest(service: .ai(provider), documentID: doc.id)
            return
        }
        authorizeExternal(manual: true)
    }

    func cancelExternal() {
        externalAuthorizedDocument = nil
        guard externalTask != nil else { return }
        externalRunToken += 1
        externalTask?.cancel()
        externalTask = nil
        externalBatch = nil
        AIBIRunner.shared.cancel(owner: .mail)
        WebTranslatorRunner.shared.cancel(owner: .mail)
        externalMissingAttempts.removeAll()
        externalServiceRetryCount = 0
        externalFormatRetryCount = 0
        externalPhase = .awaitingAction
    }

    private func authorizeExternal(manual: Bool = false) {
        guard let doc = document else { return }
        externalAuthorizedDocument = doc.id
        externalBatchesInAction = 0
        webItemsInAction = 0
        externalMissingAttempts.removeAll()
        externalServiceRetryCount = 0
        externalFormatRetryCount = 0
        if case .failed = externalPhase { externalPhase = .idle }
        scheduleExternal(manual: manual)
    }

    /// 대기 항목이 있고 이 메일에 대한 실행이 허락되었을 때만 다음 묶음을 보낸다.
    /// 실행 중에 OCR로 새 항목이 생기면 지금 묶음이 끝난 뒤 이어서 보낸다(완료된 항목은 다시 보내지 않음).
    private func scheduleExternal(manual: Bool = false) {
        guard let service = externalService, let doc = document, externalTask == nil else { return }
        if case .failed = externalPhase { return }
        // 한 묶음 상한보다 긴 단락은 보내지 않고 이유를 표시한다(자르거나 다른 방식으로 대체하지 않음).
        // 웹 번역기는 항목마다 따로 보내며 긴 단락은 문장 단위로 나눠 순서대로 이어 붙인다.
        if case .ai = service {
            for (id, state) in segmentStates {
                if case .pending = state, let text = segments[id]?.text, text.count > ExternalTranslation.maxBatchCharacters {
                    segmentStates[id] = .failed(ExternalTranslation.tooLongMessage)
                }
            }
        }
        guard externalPendingCount > 0 else {
            externalPhase = .idle
            return
        }
        guard externalAuthorizedDocument == doc.id else {
            externalPhase = .awaitingAction
            return
        }
        // 서식 본문의 텍스트 단위를 아직 찾는 중이면 끝난 뒤(htmlSegmentsExtracted) 보낸다.
        guard !formattedBodyPending else { return }
        guard case .ai(let provider) = service else {
            if case .web(let translator) = service { runWebExternal(translator) }
            return
        }
        guard externalBatchesInAction < ExternalTranslation.batchesPerAction else {
            externalAuthorizedDocument = nil
            externalPhase = .awaitingAction
            return
        }
        externalBatchesInAction += 1
        externalPhase = .running
        let generation = translationGeneration
        externalRunToken += 1
        let token = externalRunToken
        externalTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await AIBIRunner.shared.run(
                provider: provider,
                owner: .mail,
                alwaysVisible: AIBIAccounts.shared.alwaysShowBrowser,
                manualOnly: manual,
                allowsFormatRetry: !manual && self.externalFormatRetryCount == 0 && self.externalBatchesInAction < ExternalTranslation.batchesPerAction,
                prompt: { [weak self] in
                    guard let self, generation == self.translationGeneration, token == self.externalRunToken else { return nil }
                    if self.externalBatch == nil { self.externalBatch = self.makeExternalBatch() }
                    return self.externalBatch?.prompt
                },
                sink: { [weak self] text in
                    guard let self, generation == self.translationGeneration, token == self.externalRunToken,
                          let batch = self.externalBatch else {
                        return "번역 요청이 바뀌어 이 응답은 적용하지 않았습니다."
                    }
                    return self.applyExternal(text, batch: batch)
                }
            )
            guard generation == self.translationGeneration, token == self.externalRunToken else { return }
            self.externalTask = nil
            self.externalBatch = nil
            switch outcome {
            case .applied:
                self.externalPhase = .idle
                self.scheduleExternal()
            case .failed(let message):
                if message == AIBIRunner.retryableFormatFailure,
                   self.externalFormatRetryCount < 1,
                   self.externalBatchesInAction < ExternalTranslation.batchesPerAction {
                    self.externalFormatRetryCount += 1
                    self.externalPhase = .idle
                    self.scheduleExternal()
                    return
                }
                // 완료된 Gemini 요청의 확인된 일시 오류만 같은 제공사에 한 번 더 요청한다.
                // 로그인·보안 확인·한도·불명확한 전송 실패는 자동 재전송하지 않는다.
                if provider == .gemini, message == AIBIRunner.geminiTemporaryFailure,
                   self.externalServiceRetryCount < 1,
                   self.externalBatchesInAction < ExternalTranslation.batchesPerAction {
                    self.externalServiceRetryCount += 1
                    self.externalPhase = .idle
                    self.scheduleExternal()
                    return
                }
                // 다른 제공사나 Apple 번역으로 대체하지 않는다. 대기 항목은 그대로 두고 다시 시도할 수 있게 한다.
                self.externalAuthorizedDocument = nil
                self.externalPhase = .failed(message)
            case .cancelled:
                self.externalAuthorizedDocument = nil
                self.externalPhase = .awaitingAction
            }
        }
    }

    /// 웹 번역기: 대기 항목을 읽는 순서대로 하나씩 보낸다(항목 = 세그먼트, 결과는 그 세그먼트에만 적용).
    /// 원문 언어는 세그먼트마다 정한 언어(직접 고른 언어 또는 판별한 언어)를 지정한다. 실패한 항목은 표시하고 다음 항목을 계속하며,
    /// 페이지 준비 실패·제한 시간 초과처럼 멈춰야 하는 오류는 받은 결과를 둔 채 중단한다. 다른 방식으로 대체하지 않는다.
    private func runWebExternal(_ translator: WebTranslator) {
        guard webItemsInAction < WebTranslation.itemsPerAction else {
            externalAuthorizedDocument = nil
            externalPhase = .awaitingAction
            return
        }
        externalPhase = .running
        let generation = translationGeneration
        externalRunToken += 1
        let token = externalRunToken
        let ticket = WebTranslatorRunner.shared.ticket(for: .mail)
        let ids = segmentOrder.filter { id in
            if case .pending? = segmentStates[id] { return true } else { return false }
        }.prefix(WebTranslation.itemsPerAction - webItemsInAction)
        externalTask = Task { [weak self] in
            guard let self else { return }
            var failure: String?
            for id in ids {
                guard generation == self.translationGeneration, token == self.externalRunToken, !Task.isCancelled else { return }
                guard case .pending? = self.segmentStates[id], let segment = self.segments[id] else { continue }
                self.webItemsInAction += 1
                let result = await WebTranslatorRunner.shared.translate(
                    segment.text, source: segment.groupKey, target: self.targetLanguageID, using: translator,
                    owner: .mail, ticket: ticket)
                guard generation == self.translationGeneration, token == self.externalRunToken else { return }
                switch result {
                case .success(let translated):
                    if case .pending? = self.segmentStates[id] { self.segmentStates[id] = .done(translated) }
                case .failure(.item(let message)), .failure(.unsupported(let message)):
                    if case .pending? = self.segmentStates[id] { self.segmentStates[id] = .failed(message) }
                case .failure(.cancelled):
                    self.externalTask = nil
                    self.externalAuthorizedDocument = nil
                    self.externalPhase = .awaitingAction
                    return
                case .failure(.fatal(let message)):
                    failure = message
                }
                if failure != nil { break }
            }
            guard generation == self.translationGeneration, token == self.externalRunToken else { return }
            self.externalTask = nil
            if let failure {
                self.externalAuthorizedDocument = nil
                self.externalPhase = .failed(failure)
                return
            }
            self.externalPhase = .idle
            // 그사이 OCR로 생긴 항목은 이어서 보내고, 한 번 실행 상한을 넘으면 사용자가 '이어서 번역'으로 보낸다.
            self.scheduleExternal()
        }
    }

    /// 입력 직전에 호출된다. 읽는 순서대로 큰 묶음(최대 9,000자·150개)을 만들고, 한 묶음보다 긴 단락은 이유와 함께 제외한다.
    private func makeExternalBatch() -> ExternalBatch? {
        var ocrIDs = Set<String>()
        for state in ocrStates.values {
            if case .done(let regions) = state { regions.forEach { ocrIDs.insert($0.id) } }
        }
        var items: [ExternalBatchItem] = []
        var characters = 0
        for id in segmentOrder {
            guard case .pending? = segmentStates[id], let text = segments[id]?.text else { continue }
            if text.count > ExternalTranslation.maxBatchCharacters {
                segmentStates[id] = .failed(ExternalTranslation.tooLongMessage)
                continue
            }
            if !items.isEmpty && (items.count >= ExternalTranslation.maxBatchItems
                                  || characters + text.count > ExternalTranslation.maxBatchCharacters) { break }
            let kind: ExternalBatchItem.Kind = id == "subject" ? .subject : (ocrIDs.contains(id) ? .imageText : .body)
            items.append(ExternalBatchItem(key: "t\(items.count + 1)", segmentID: id, kind: kind, text: text))
            characters += text.count
        }
        guard !items.isEmpty else { return nil }
        let responseToken = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        let prompt = ExternalTranslation.makePrompt(items: items, sourceID: sourceLanguageID, targetID: targetLanguageID, responseToken: responseToken, correctingFormat: externalFormatRetryCount > 0, content: .mail)
        return ExternalBatch(items: items, prompt: prompt, responseToken: responseToken)
    }

    /// 결과 sink: 검증된 항목만 적용한다. 누락은 한 번만 재요청하고, 반복 누락은 실패로 표시한다.
    private func applyExternal(_ text: String, batch: ExternalBatch) -> String? {
        switch ExternalTranslation.parse(text, batch: batch) {
        case .failure(let error):
            return error.message
        case .success(let translations):
            let missingCount = batch.items.filter { translations[$0.key] == nil }.count
            if let runID = AIBIDiagnosticsStore.shared.currentRunID {
                AIBIDiagnosticsStore.shared.record(runID: runID, event: "bridge_snapshot",
                    metrics: ["message_count": batch.items.count, "failed_count": missingCount])
            }
            for item in batch.items {
                guard case .pending? = segmentStates[item.segmentID] else { continue }
                if let translated = translations[item.key] {
                    segmentStates[item.segmentID] = .done(translated)
                } else {
                    let attempts = externalMissingAttempts[item.segmentID, default: 0]
                    externalMissingAttempts[item.segmentID] = attempts + 1
                    if attempts >= 1 {
                        segmentStates[item.segmentID] = .failed("외부 AI 응답에 이 항목이 반복해서 누락되어 적용하지 않았습니다.")
                    }
                }
            }
            return nil
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if #available(macOS 26.0, *), TranslationError.alreadyCancelled ~= error { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private static func translationErrorMessage(_ error: Error, source: String, target: String) async -> String {
        if #available(macOS 26.0, *), TranslationError.notInstalled ~= error {
            guard source != "auto" else {
                return "번역 준비에 실패했습니다. 원본 언어를 선택한 뒤 다시 번역하세요."
            }
            let status = await LanguageAvailability().status(from: Locale.Language(identifier: source),
                                                             to: Locale.Language(identifier: target))
            switch status {
            case .installed:
                return "언어팩은 설치되어 있지만 번역 서비스가 응답하지 않습니다. 다시 번역하세요."
            case .unsupported:
                return "이 언어 조합은 Apple 번역에서 지원하지 않습니다."
            case .supported: break
            @unknown default: return "언어팩 상태를 확인하지 못했습니다. 다시 번역하세요."
            }
        }
        return describe(error)
    }

    static func describe(_ error: Error) -> String {
        if TranslationError.unsupportedLanguagePairing ~= error {
            return "이 언어 조합은 Apple 번역에서 지원하지 않습니다."
        }
        if TranslationError.unsupportedSourceLanguage ~= error { return "원본 언어를 지원하지 않습니다." }
        if TranslationError.unsupportedTargetLanguage ~= error { return "대상 언어를 지원하지 않습니다." }
        if TranslationError.unableToIdentifyLanguage ~= error {
            return "언어를 식별하지 못했습니다. 상단에서 원본 언어를 직접 선택해 보세요."
        }
        if TranslationError.nothingToTranslate ~= error { return "번역할 텍스트가 없습니다." }
        if #available(macOS 26.0, *), TranslationError.notInstalled ~= error {
            return "번역 언어 팩이 설치되지 않았습니다. 표시되는 다운로드 요청을 승인하거나 시스템 설정 › 일반 › 언어 및 지역 › 번역 언어에서 직접 내려받으세요."
        }
        if TranslationError.internalError ~= error { return "번역 시스템 내부 오류가 발생했습니다." }
        return "번역 실패: \(error.localizedDescription)"
    }

    // MARK: - OCR

    private func assetIDs(in block: ContentBlock) -> [String] {
        switch block.kind {
        case .image(let assetID): return [assetID]
        case .remoteImage:
            if case .loaded(let assetID)? = remoteStates[block.id] { return [assetID] }
            return []
        default: return []
        }
    }

    private func startOCR(_ doc: MailDocument) {
        var seen = Set<String>()
        let ids = doc.blocks.flatMap(assetIDs).filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return }
        let generation = documentGeneration
        ocrTask = Task { [weak self] in
            for id in ids {
                guard !Task.isCancelled else { return }
                await self?.runOCR(assetID: id, generation: generation)
            }
        }
    }

    private func runOCR(assetID: String, generation: Int) async {
        guard generation == documentGeneration, ocrStates[assetID] == nil else { return }
        guard let image = document?.assets[assetID]?.cgImage else {
            // 진행 표시가 끝나지 않은 채 남지 않도록 실패로 기록
            ocrStates[assetID] = .failed("이미지를 해석하지 못해 글자 인식을 건너뛰었습니다.")
            return
        }
        ocrStates[assetID] = .running
        do {
            let regions = try await ImageTextRecognizer.recognize(image, assetID: assetID)
            guard generation == documentGeneration else { return }
            ocrStates[assetID] = .done(regions)
            regions.forEach { registerSegment(id: $0.id, text: $0.text) }
            scheduleTranslation()
        } catch {
            guard generation == documentGeneration, !Self.isCancellation(error) else { return }
            ocrStates[assetID] = .failed("이미지 속 글자를 인식하지 못했습니다.")
        }
    }

    // MARK: - 원격 이미지
    // Mail에서 선택한 메시지를 요청하면 자동으로, .eml/이미지 파일은 사용자가 확인했을 때만 불러온다.

    var remoteImageCount: Int { document?.remoteImageBlocks.count ?? 0 }

    var remoteProgress: (loading: Int, loaded: Int, failed: Int) {
        var loading = 0, loaded = 0, failed = 0
        for state in remoteStates.values {
            switch state {
            case .loading: loading += 1
            case .loaded: loaded += 1
            case .failed: failed += 1
            }
        }
        return (loading, loaded, failed)
    }

    var hasUnrequestedRemoteImages: Bool {
        document?.remoteImageBlocks.contains { remoteStates[$0.id] == nil } ?? false
    }

    /// 원격 이미지 다운로드나 OCR이 아직 끝나지 않았는지(완료로 보이지 않게 하기 위함)
    var imageWorkInProgress: Bool {
        if remoteProgress.loading > 0 { return true }
        guard let doc = document else { return false }
        return doc.blocks.flatMap(assetIDs).contains { id in
            switch ocrStates[id] {
            case nil, .running?: return true
            default: return false
            }
        }
    }

    func loadRemoteImages() {
        guard let doc = document, remoteTask == nil else { return }
        let generation = documentGeneration
        let targets: [(String, URL?)] = doc.remoteImageBlocks.compactMap { block in
            if case .remoteImage(let url, _) = block.kind { return (block.id, url) }
            return nil
        }
        for (blockID, _) in targets where remoteStates[blockID] == nil { remoteStates[blockID] = .loading }
        remoteTask = Task { [weak self] in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 40
            configuration.httpAdditionalHeaders = ["Accept": "image/*"]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            var cache: [URL: String] = [:]
            for (index, (blockID, url)) in targets.enumerated() {
                guard let self, !Task.isCancelled, generation == self.documentGeneration else { return }
                guard case .loading? = self.remoteStates[blockID] else { continue }
                guard index < 60 else {
                    self.remoteStates[blockID] = .failed("메시지당 최대 60개까지만 불러옵니다.")
                    continue
                }
                guard let url, url.scheme?.lowercased() == "https" else {
                    self.remoteStates[blockID] = .failed("암호화되지 않은(HTTP) 주소이거나 주소가 잘못되어 불러오지 않았습니다.")
                    continue
                }
                if let assetID = cache[url] {
                    self.remoteStates[blockID] = .loaded(assetID: assetID)
                    continue
                }
                do {
                    let data = try await Self.download(url, session: session)
                    guard generation == self.documentGeneration else { return }
                    let assetID = "remote-\(blockID)"
                    guard let asset = ImageAsset(id: assetID, data: data, name: nil) else {
                        self.remoteStates[blockID] = .failed("이미지 형식을 해석할 수 없습니다.")
                        continue
                    }
                    self.document?.assets[assetID] = asset
                    self.remoteStates[blockID] = .loaded(assetID: assetID)
                    cache[url] = assetID
                    await self.runOCR(assetID: assetID, generation: generation)
                } catch {
                    guard generation == self.documentGeneration, !Self.isCancellation(error) else { return }
                    self.remoteStates[blockID] = .failed("불러오지 못했습니다.")
                }
            }
            if let self, generation == self.documentGeneration { self.remoteTask = nil }
        }
    }

    nonisolated private static func download(_ url: URL, session: URLSession) async throws -> Data {
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        if response.expectedContentLength > Int64(ImageAsset.maxBytes) { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > ImageAsset.maxBytes { throw URLError(.dataLengthExceedsMaximum) }
        }
        return data
    }

    // MARK: - 화면용 도우미

    func state(for segmentID: String) -> SegmentState? { segmentStates[segmentID] }

    var progress: (done: Int, failed: Int, pending: Int, total: Int) {
        var done = 0, failed = 0, pending = 0
        for state in segmentStates.values {
            switch state {
            case .done: done += 1
            case .failed: failed += 1
            case .pending: pending += 1
            case .skipped: break
            }
        }
        return (done, failed, pending, done + failed + pending)
    }

    var runningOCRCount: Int {
        ocrStates.values.filter { if case .running = $0 { return true } else { return false } }.count
    }

    /// 사용자가 '번역 복사'를 눌렀을 때만 클립보드에 넣는다.
    func copyTranslation() {
        guard let doc = document else { return }
        var lines: [String] = []
        func text(_ id: String, _ original: String) -> String {
            if case .done(let t)? = segmentStates[id] { return t }
            return original
        }
        if let subject = doc.subject { lines.append(text("subject", subject)) }
        let htmlRange = usesFormattedBody ? doc.formattedHTML?.blockRange : nil
        var htmlCopied = false
        func appendFormattedBody(_ range: Range<Int>) {
            htmlCopied = true
            htmlSegments.forEach { lines.append(text($0.id, $0.text)) }
            var seen = Set<String>()
            for block in doc.blocks[range.clamped(to: 0..<doc.blocks.count)] {
                for assetID in assetIDs(in: block) where seen.insert(assetID).inserted {
                    if case .done(let regions)? = ocrStates[assetID], !regions.isEmpty {
                        lines.append("[이미지 속 텍스트]")
                        regions.forEach { lines.append("- " + text($0.id, $0.text)) }
                    }
                }
            }
        }
        for (index, block) in doc.blocks.enumerated() {
            if let htmlRange, htmlRange.contains(index) || index == htmlRange.lowerBound {
                if !htmlCopied { appendFormattedBody(htmlRange) }
                if htmlRange.contains(index) { continue }
            }
            switch block.kind {
            case .text(let style, let original):
                lines.append(style == .caption ? original : text(block.id, original))
            case .sectionTitle(let title):
                lines.append("[\(title)]")
            default:
                for assetID in assetIDs(in: block) {
                    if case .done(let regions)? = ocrStates[assetID], !regions.isEmpty {
                        lines.append("[이미지 속 텍스트]")
                        regions.forEach { lines.append("- " + text($0.id, $0.text)) }
                    }
                }
            }
        }
        if let htmlRange, !htmlCopied { appendFormattedBody(htmlRange) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n\n"), forType: .string)
    }

    private func applyWindowLevel() {
        for window in NSApp.windows where window.canBecomeMain {
            window.level = keepOnTop ? .floating : .normal
        }
    }
}

// MARK: - 긴 텍스트 분할

struct TextChunk {
    let text: String
    /// 번역 결과를 다시 이을 때 이 조각 뒤에 붙일 구분자
    let separator: String
}

enum TextChunker {
    static let limit = 900

    static func chunks(_ text: String, limit: Int = TextChunker.limit, measuringUTF16: Bool = false) -> [TextChunk] {
        let length: (String) -> Int = { measuringUTF16 ? $0.utf16.count : $0.count }
        guard length(text) > limit else { return [TextChunk(text: text, separator: "")] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            sentences.append(String(text[range]))
            return true
        }
        if sentences.isEmpty { sentences = [text] }

        var result: [TextChunk] = []
        var current = ""
        func emit() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let separator = current.hasSuffix("\n") ? "\n" : " "
                result.append(TextChunk(text: trimmed, separator: separator))
            }
            current = ""
        }
        for sentence in sentences {
            if length(sentence) > limit {
                emit()
                for piece in hardSplit(sentence, limit: limit, measuringUTF16: measuringUTF16) {
                    current = piece
                    emit()
                }
                continue
            }
            if length(current) + length(sentence) > limit { emit() }
            current += sentence
        }
        emit()
        return result.isEmpty ? [TextChunk(text: text, separator: "")] : result
    }

    private static func hardSplit(_ text: String, limit: Int, measuringUTF16: Bool) -> [String] {
        var pieces: [String] = []
        var rest = Substring(text)
        while (measuringUTF16 ? rest.utf16.count : rest.count) > limit {
            var remaining = limit
            let window = measuringUTF16 ? rest.prefix(while: { character in
                let units = String(character).utf16.count
                guard units <= remaining else { return false }
                remaining -= units
                return true
            }) : rest.prefix(limit)
            // 한 글자 자체가 한도보다 큰 드문 결합 문자도 쪼개 훼손하거나 무한 반복하지 않는다.
            guard !window.isEmpty else { pieces.append(String(rest)); return pieces }
            let cut = window.lastIndex(where: { $0 == " " || $0 == "\n" }) ?? window.endIndex
            let end = cut == rest.startIndex ? window.endIndex : cut
            pieces.append(String(rest[..<end]) + " ")
            rest = rest[end...]
        }
        if !rest.isEmpty { pieces.append(String(rest)) }
        return pieces
    }
}
