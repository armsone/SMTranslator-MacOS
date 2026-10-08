import AppKit
import Combine
import SwiftUI
import Translation

/// 캡처·인식·번역 상태 기계.
/// - 자동/주기 캡처는 없다. 사용자가 주 버튼(또는 Space/Enter, 메뉴)을 누를 때만 1회 캡처한다.
/// - Enter·주 버튼·메뉴: 번역이 보이면 원문보기(패치만 숨겨 창 아래 실제 화면을 보임), 아니면(원문 표시 중·완료 결과 없음)
///   새로 캡처·번역. 원문보기는 캡처 이미지를 그리지 않고 새 캡처·인식·번역 요청도 하지 않는다.
///   모든 줄 번역이 성공해야만 '원문보기'가 된다.
/// - Space: 완료된 번역이 있으면 다시 인식·번역하지 않고 실제 화면 ↔ 보관한 같은 번역 패치를 오간다.
///   완료된 번역이 없을 때만 캡처·번역한다. 보관분은 영역 변경·언어/방식 변경·새 캡처 때 버린다.
/// - Apple 번역(Mac 기본·Apple Intelligence 우선)은 TranslationSession.translate(batch:) 스트리밍으로 받으며,
///   줄이 끝나는 즉시 clientIdentifier → 바운딩 박스로 매핑해 화면에 바로 그린다.
/// - 원문 '자동 인식'(기본): 줄마다 언어를 판별해 같은 언어끼리 묶고, 원문 언어가 nil인 같은 세션으로 묶음마다
///   번역한다. 숫자·기호만 있는 줄과 이미 번역 언어인 줄은 요청 없이 원문 그대로 둔다.
/// - 외부 AI(ChatGPT·Claude·Gemini)는 인식한 줄 텍스트만 큰 묶음(t1…tn → 줄 ID)으로 보내고, 검증된 항목만
///   해당 줄의 바운딩 박스에 그린다. 스크린샷 이미지는 보내지 않으며, 다른 방식으로 자동 대체하지 않는다.
/// - 웹 번역기(DeepL·Google·Papago)는 인식한 줄을 한 줄씩 공식 번역 페이지에 넣고, 받은 결과를 그 줄 자리에만 그린다.
@MainActor
final class AppViewModel: ObservableObject {
    /// 원문 언어. 기본값은 자동 인식(줄마다 언어를 판별해 언어별 묶음으로 번역)이다.
    @Published var sourceLanguage: SourceSelection = .automatic {
        didSet { if oldValue != sourceLanguage { languagesChanged() } }
    }
    @Published var targetLanguage: AppLanguage = .korean {
        didSet { if oldValue != targetLanguage { languagesChanged() } }
    }
    /// 제목줄 상태. @Published가 아니어서 바뀌어도 툴바(SwiftUI) 본문을 다시 계산하지 않는다.
    var status: AppStatus {
        get { statusSubject.value }
        set { statusSubject.value = newValue }
    }
    var statusPublisher: AnyPublisher<AppStatus, Never> { statusSubject.eraseToAnyPublisher() }
    private let statusSubject = CurrentValueSubject<AppStatus, Never>(.idle)
    /// 캡처·인식·번역이 진행 중인 동안 true. 주 버튼과 Space/Enter가 비활성화된다.
    @Published private(set) var isProcessing: Bool = false
    @Published private(set) var primaryAction: PrimaryAction = .captureAndTranslate
    /// 화면에 그려진 번역 패치(줄 ID 순). 복사 버튼이 사용한다.
    @Published private(set) var translatedPatches: [TranslatedPatch] = []
    /// 번역 패치 글자색/배경색/진하기 설정. 변경 즉시 이미 표시된 패치에도 다시 적용된다.
    @Published var colorSettings: PatchColorSettings = .loadFromDefaults() {
        didSet {
            colorSettings.saveToDefaults()
            overlay?.updatePatchColorSettings(colorSettings)
        }
    }
    /// 창 핀(항상 위에 고정) 토글. 기본 켜짐.
    @Published var isAlwaysOnTop: Bool = true {
        didSet { overlay?.isAlwaysOnTop = isAlwaysOnTop }
    }
    /// 이동·크기 잠금 해제 여부. false면 이동·크기 조절이 막힌다. 기본 꺼짐(이동·크기 조절 가능).
    @Published var isAdjustable: Bool = true {
        didSet { overlay?.isAdjustable = isAdjustable }
    }

    /// 언어 조합이 바뀔 때만 새로 만든다. 같은 조합이면 캡처마다 세션을 재설정하지 않고
    /// .translationTask 클로저와 그 안의 TranslationSession(모델)을 계속 재사용한다.
    @Published var translationConfiguration: TranslationSession.Configuration?

    /// Esc/닫기 버튼/메뉴로 창을 숨길 때 호출된다. AppDelegate가 설정한다.
    var onHideRequested: (() -> Void)?

    private weak var overlay: OverlayPanelController?
    private var currentCaptureTask: Task<Void, Never>?

    /// 캡처/번역 작업 세대. 새 캡처·영역 이동·숨김·언어 변경 시 증가해 이전 비동기
    /// 결과(부분 번역 포함)가 화면이나 상태를 덮어쓰지 못하게 한다.
    private var generation = 0

    /// 현재 결과에 대응하는 원본 캡처 이미지(완료 결과 확인용, 화면에 그리지 않음). 메모리에만 보관하며 디스크 저장/전송하지 않는다.
    private var capturedImage: CGImage?
    private var currentLines: [Int: OCRLine] = [:]
    /// 현재 캡처 이미지에서 줄별로 추출한 배경색(캡처당 1회 계산). 추출 실패한 줄은 없다.
    private var lineBackgroundColors: [Int: RGBColor] = [:]
    private var receivedLineIDs: Set<Int> = []
    /// 자동 인식에서 언어를 판별하지 못했거나 지원되지 않아 번역 요청 없이 원문 그대로 둔 줄.
    /// 팝업(언어 선택) 방지를 위해 이런 줄은 Apple 번역에 보내지 않는다.
    private var skippedLineIDs: Set<Int> = []
    private var hasCompleteResult = false
    private var isDisplayingResult = false
    /// 완료된 결과에서 지금 패치를 숨겨 실제 화면을 보이는 중이면 true(Space 전환 방향)
    private var isShowingOriginal = false
    /// 첫 이동 때 값싼 무효화만 하고 미뤄 둔 정리(결과·패치 해제, 버튼·상태 갱신)가 남아 있으면 true
    private var isRegionCleanupPending = false

    private var jobContinuation: AsyncStream<TranslationJob>.Continuation?
    private var pendingJob: TranslationJob?
    /// 자동 인식에서 감지한 언어가 Apple 번역 지원 언어인지 거르는 목록(방식이 바뀔 때만 다시 읽음).
    private var autoSupportedLanguageIDs: [String]?

    /// 자동 인식에서 판별된 언어마다 만든 번역 묶음 대기열. 묶음마다 그 언어를 명시한
    /// TranslationSession.Configuration을 쓰므로 Apple이 언어를 다시 추정하다 못 찾아 '언어 선택' 팝업을
    /// 띄우는 일이 없다(원문 언어가 nil인 세션을 쓰지 않음). 한 번에 한 묶음만 번역 중(現 translationConfiguration)이다.
    private struct LanguageGroupJob {
        let config: TranslationSession.Configuration
        let requests: [TranslationSession.Request]
    }
    private var groupQueue: [LanguageGroupJob] = []
    /// 대기열 처리 중 만난 첫 오류(이미 받은 줄은 유지하고 남은 언어 묶음은 이어서 진행한다).
    private var groupErrorMessage: String?

    /// 화면 기록 권한 요청 다이얼로그는 실행당 최대 1회, 명시적 캡처 동작에서만 띄운다.
    private var didRequestScreenPermission = false

    // 외부 AI 번역 상태(현재 캡처 세대에만 유효)
    /// 외부 AI 실행 중이면 true. 제목줄 주 버튼이 '취소'가 된다.
    @Published private(set) var isExternalRunning = false
    /// 숨김 실행에 쓸 이 창 머리글의 AIBI 표면(OverlayPanelController가 설정)
    weak var aibiSurface: AIBIHostView?
    private var externalTask: Task<Void, Never>?
    private var externalBatch: ExternalBatch?
    private var externalFailedLineIDs: Set<Int> = []
    /// 누락된 줄만 같은 제공사에 한 번 더 요청한다. 완료된 줄은 다시 보내지 않는다.
    private var externalMissingAttempts: [Int: Int] = [:]
    private var externalRunsInAction = 0
    private var externalFormatRetryCount = 0
    private var externalServiceRetryCount = 0
    private var externalStatusTimer: Timer?

    /// Apple Intelligence 다듬기(설정 켜짐 + 기기 내 모델 가능 시에만, Mac 기본 번역 결과만). 모아서 작은 묶음으로 보낸다.
    private var refinePendingItems: [AppleTranslationRefiner.Item] = []
    private var refineTasks: [Task<Void, Never>] = []

    /// 메일 번역과 공용인 번역 방식
    var backend: TranslationBackend { TranslationBackendStore.shared.backend }

    init() {
        // 메일 창이나 설정에서 방식을 바꿔도 같은 규칙으로 진행 중 작업을 정리한다.
        TranslationBackendStore.shared.observe { [weak self] _, _ in
            self?.resetTranslationSetup(message: "번역 방식이 바뀌었습니다. 번역을 눌러주세요")
        }
    }

    func attach(overlay: OverlayPanelController) {
        self.overlay = overlay
        overlay.updatePatchColorSettings(colorSettings)
        overlay.isAlwaysOnTop = isAlwaysOnTop
        overlay.isAdjustable = isAdjustable
        overlay.onRegionWillChange = { [weak self] in
            self?.regionWillChange()
        }
        // mouseUp에서는 아무것도 하지 않는다. 멈칫함을 피하려고 실제 정리(clearResult·idle 문구 등)는
        // 다음 명시적 동작(번역·원문보기·Space·Enter·설정 변경·숨김 등)이 finishRegionChange()를 부를 때까지 미룬다.
        overlay.onRegionChangeEnded = {}
    }

    // MARK: - 사용자 동작

    /// Return/키패드 Enter, 제목줄 주 버튼, 메뉴: 번역이 보이면 원본, 그 밖에는 새로 캡처·번역.
    func performPrimaryAction() {
        finishRegionChange()
        guard !isProcessing else { return }
        switch primaryAction {
        case .captureAndTranslate:
            captureOnce()
        case .showOriginal:
            showOriginal()
        }
    }

    /// Space: 완료된 번역이 있으면 실제 화면 ↔ 같은 번역 패치만 오간다(캡처·인식·번역 요청 없음).
    /// 완료된 번역이 없을 때만 캡처·번역한다.
    func performCachedToggle() {
        finishRegionChange()
        guard !isProcessing else { return }
        guard hasCompleteResult, capturedImage != nil else {
            captureOnce()
            return
        }
        if isShowingOriginal {
            overlay?.showTranslation()
            isShowingOriginal = false
            primaryAction = .showOriginal
            status = .completed(skipped: skippedLineIDs.count)
        } else {
            showOriginal()
        }
    }

    func requestHide() {
        onHideRequested?()
    }

    /// 제목줄 '취소' 버튼: 진행 중인 외부 AI 번역을 멈춘다(이미 받은 줄은 보이되 완료로 표시하지 않음).
    func cancelExternalTranslation() {
        finishRegionChange()
        guard isExternalRunning else { return }
        cancelInFlightWork(message: "취소됨")
    }

    /// 창이 숨겨질 때: 진행 중 작업만 취소한다(표시된 결과는 유지).
    func windowWillHide() {
        finishRegionChange()
        cancelInFlightWork(message: "취소됨")
    }

    /// 앱 종료 시 진행 중인 작업을 멈춘다.
    func stop() {
        finishRegionChange()
        cancelInFlightWork(message: nil)
        stopExternalRun()
        jobContinuation?.finish()
        jobContinuation = nil
    }

    /// 원문보기: 번역 패치만 숨겨 창 아래 실제 화면을 그대로 보인다(캡처 이미지를 그리지 않음).
    private func showOriginal() {
        guard hasCompleteResult, capturedImage != nil else {
            primaryAction = .captureAndTranslate
            return
        }
        overlay?.showOriginal()
        isShowingOriginal = true
        primaryAction = .captureAndTranslate
        status = .showingOriginal
    }

    // MARK: - 무효화

    /// 명시적 캡처 뒤 첫 실제 이동/크기 변경(창이 움직이기 직전, 끌기 첫 이벤트)에 한 번 호출된다.
    /// 끌기를 멈칫하게 하지 않도록 값싼 무효화만 한다: 세대를 올려 늦게 도착한 캡처·OCR·번역·외부 AI 결과가
    /// 화면·상태를 바꾸지 못하게 하고, 캡처 작업·진행 표시 타이머·대기 작업을 취소한다. 패치 숨김은
    /// OverlayPanelController가 같은 시점에 한다. @Published·제목줄 상태 변경, 패치 뷰 해제, 웹 보기 정리는
    /// 하지 않고 finishRegionChange()(mouseUp 한 번) 또는 다음 명시적 동작으로 미룬다. 자동 재캡처는 하지 않는다.
    private func regionWillChange() {
        guard isProcessing || isDisplayingResult || capturedImage != nil else { return }
        generation += 1
        currentCaptureTask?.cancel()
        currentCaptureTask = nil
        // 외부 AI(AIBIRunner) 작업도 즉시 취소한다. AIBIRunner.currentPrompt는 이동 뒤에도 캐시된
        // prompt를 재검증 없이 돌려줄 수 있으므로, Task.isCancelled 가드가 submit을 막게 해야 한다.
        externalTask?.cancel()
        externalStatusTimer?.invalidate()
        externalStatusTimer = nil
        pendingJob = nil
        refineTasks.forEach { $0.cancel() }
        refineTasks.removeAll()
        refinePendingItems.removeAll()
        // groupQueue·groupErrorMessage·isProcessing·그 밖의 @Published 변경은 SwiftUI 재레이아웃을
        // 일으켜 끌기를 멈칫하게 하므로 다음 명시적 동작이 finishRegionChange()를 부를 때까지 미룬다.
        isRegionCleanupPending = true
    }

    /// 다음 명시적 동작(번역·원문보기·Space·Enter·설정 변경·숨김 등)이 regionWillChange() 뒤로
    /// 미뤄 둔 정리가 남아 있으면 true. OverlayPanelController가 이 값으로 그 사이 들어오는 늦은
    /// status·버튼 갱신을 걸러 옛 상태가 다시 보이지 않게 한다.
    var hasDeferredRegionCleanup: Bool { isRegionCleanupPending }

    /// 이동/크기 조절이 끝난 뒤(mouseUp 한 번) 또는 다음 명시적 동작 직전에 미뤄 둔 정리를 한 번 한다.
    /// 옛 결과를 다시 보이지 않고 지우며, 진행 중이던 외부 AI 실행을 멈추고 '번역'을 다시 누를 수 있게 한다.
    func finishRegionChange() {
        guard isRegionCleanupPending else { return }
        isRegionCleanupPending = false
        stopExternalRun()
        isProcessing = false
        groupQueue = []
        groupErrorMessage = nil
        hasCompleteResult = false
        clearResult()
        status = .idle
    }

    /// 언어 변경: 진행 중 작업만 취소하고 자동 재번역은 하지 않는다. 세션은 다음 캡처 때
    /// 새 언어 조합으로 한 번만 구성된다.
    private func languagesChanged() {
        resetTranslationSetup(message: "언어가 바뀌었습니다. 번역을 눌러주세요")
    }

    /// 언어·번역 방식 변경 공통: 진행 중 작업을 취소하고 Apple 번역 세션 구성을 다음 캡처 때 다시 만든다.
    /// 보관한 원본·번역은 다른 언어·방식의 결과이므로 지운다(Space로 옛 번역을 다시 보이지 않게).
    private func resetTranslationSetup(message: String) {
        finishRegionChange()
        cancelInFlightWork(message: message)
        if capturedImage != nil || isDisplayingResult {
            clearResult()
            status = .info(message)
        }
        jobContinuation?.finish()
        jobContinuation = nil
        pendingJob = nil
        translationConfiguration = nil
        autoSupportedLanguageIDs = nil
    }

    /// 진행 중 작업만 취소한다. 이미 받은 부분 번역은 보이도록 두되 완료로 표시하지 않는다.
    private func cancelInFlightWork(message: String?) {
        guard isProcessing else { return }
        generation += 1
        currentCaptureTask?.cancel()
        currentCaptureTask = nil
        stopExternalRun()
        pendingJob = nil
        groupQueue = []
        groupErrorMessage = nil
        isProcessing = false
        hasCompleteResult = false
        primaryAction = .captureAndTranslate
        refineTasks.forEach { $0.cancel() }
        refineTasks.removeAll()
        refinePendingItems.removeAll()
        if let message {
            if currentLines.isEmpty {
                status = .info(message)
            } else {
                status = .info("\(message) (\(receivedLineIDs.count)/\(currentLines.count)줄)")
            }
        }
    }

    private func clearResult() {
        refineTasks.forEach { $0.cancel() }
        refineTasks.removeAll()
        refinePendingItems.removeAll()
        capturedImage = nil
        currentLines = [:]
        lineBackgroundColors = [:]
        receivedLineIDs = []
        skippedLineIDs = []
        groupQueue = []
        groupErrorMessage = nil
        translatedPatches = []
        hasCompleteResult = false
        isDisplayingResult = false
        isShowingOriginal = false
        primaryAction = .captureAndTranslate
        overlay?.clearResultDisplay()
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation && isProcessing
    }

    // MARK: - 캡처 → OCR

    /// 화면 기록 권한 확인. 승인돼 있으면 시스템 프롬프트 없이 true.
    /// 미승인이면 이번 실행에서 아직 요청하지 않은 경우에만 1회 요청한다.
    private func ensureScreenRecordingPermission() -> Bool {
        if CaptureService.hasScreenRecordingPermission() {
            return true
        }
        if !didRequestScreenPermission {
            didRequestScreenPermission = true
            if CaptureService.requestScreenRecordingPermission() {
                return true
            }
        }
        status = .error("화면 기록 권한이 필요합니다. 시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 기록에서 '스크린 메일 번역기'를 허용한 뒤, 필요하면 앱을 다시 실행하세요.")
        return false
    }

    private func captureOnce() {
        guard let overlay, overlay.isVisible else { return }
        let method = backend
        // 외부 방식은 처음 쓰는 제공사면 캡처 전에 전송 동의부터 묻는다(방식을 고르는 것만으로는 보내지 않음).
        if let service = method.externalService, !service.hasConsent {
            guard confirmExternalConsent(service) else {
                status = .info("\(service.title) 전송에 동의하지 않아 번역하지 않았습니다")
                return
            }
            guard overlay.isVisible, method == backend else { return }
        }
        guard ensureScreenRecordingPermission() else { return }

        generation += 1
        let myGeneration = generation
        isProcessing = true
        // 이 캡처 영역에 대해 첫 실제 이동/크기 변경을 한 번만 감지한다(그 뒤에는 다음 캡처까지 감지하지 않음).
        overlay.armRegionInvalidation()
        status = .capturing
        let screenFrame = overlay.captureScreenFrame
        let ownWindows = overlay.ownWindowNumbers
        let source = sourceLanguage
        let target = targetLanguage

        currentCaptureTask = Task { [weak self] in
            await self?.performCapture(generation: myGeneration, screenFrame: screenFrame, ownWindows: ownWindows, source: source, target: target, method: method)
        }
    }

    private func confirmExternalConsent(_ service: ExternalService) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "\(service.title)로 번역할까요?"
        alert.informativeText = service.consentMessage
        alert.addButton(withTitle: "동의하고 번역")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        service.grantConsent()
        return true
    }

    /// 번역 모델 다운로드 안내가 사용자의 캡처 동작 시점에만 나타나도록 세션 구성을
    /// 처음 캡처할 때 만든다. 같은 언어 조합에서는 기존 구성을 그대로 재사용한다.
    /// 원문 언어를 직접 고른 경우에만 호출된다(자동 인식은 OCR 뒤 언어 묶음별로 따로 구성한다).
    private func prepareTranslationConfigurationIfNeeded(generation: Int, explicitSource: AppLanguage, target: AppLanguage, method: TranslationBackend) async -> Bool {
        if translationConfiguration != nil { return true }
        let availability = method.makeLanguageAvailability()
        let result = await availability.status(from: explicitSource.localeLanguage, to: target.localeLanguage)
        // 기다리는 사이 영역 이동·취소로 세대가 바뀌었으면 상태·세션 구성을 건드리지 않는다.
        guard isCurrent(generation), sourceLanguage.language == explicitSource, target == targetLanguage, method == backend else { return false }
        switch result {
        case .unsupported:
            status = .error("\(explicitSource.displayNameKorean) → \(target.displayNameKorean) 조합은 이 기기에서 지원되지 않습니다.")
            return false
        case .supported, .installed:
            // 이전 채널은 닫아 둔다. 새 .translationTask 클로저가 시작되면서 채널을 연다.
            jobContinuation?.finish()
            jobContinuation = nil
            translationConfiguration = method.makeConfiguration(source: explicitSource.localeLanguage, target: target.localeLanguage)
            return true
        @unknown default:
            status = .error("번역 언어 지원 여부를 확인할 수 없습니다.")
            return false
        }
    }

    private func performCapture(generation: Int, screenFrame: CGRect, ownWindows: [Int], source: SourceSelection, target: AppLanguage, method: TranslationBackend) async {
        func failed(_ message: String) {
            guard isCurrent(generation) else { return }
            isProcessing = false
            primaryAction = .captureAndTranslate
            hasCompleteResult = false
            status = .error(message)
        }

        if let explicitSource = source.language, explicitSource != target, !method.isExternal {
            let ready = await prepareTranslationConfigurationIfNeeded(generation: generation, explicitSource: explicitSource, target: target, method: method)
            guard isCurrent(generation) else { return }
            guard ready else {
                isProcessing = false
                primaryAction = .captureAndTranslate
                if !status.isError { status = .idle }
                return
            }
        }

        let image: CGImage
        do {
            image = try await CaptureService.captureRegion(globalFrame: screenFrame, excludingWindowNumbers: ownWindows)
        } catch let error as CaptureError {
            failed(error.errorDescription ?? "화면 캡처 오류가 발생했습니다.")
            return
        } catch {
            failed("화면 캡처 오류: \(error.localizedDescription)")
            return
        }
        guard isCurrent(generation) else { return }

        status = .recognizing
        let lines: [OCRLine]
        let bgColors: [Int: RGBColor]
        let detected: [LanguageDetection.Result]
        do {
            // VNImageRequestHandler.perform은 블로킹 호출이므로 메인 액터 밖에서 실행해
            // '텍스트 인식 중' 상태가 실제로 그려지고 UI가 계속 반응하게 한다. 배경색
            // 추출도 같은 캡처 이미지로 여기서 한 번만(캡처당 1회) 계산한다. 자동 인식이면
            // 줄별 언어 판별도 여기서 메모리 안에서만 한다.
            (lines, bgColors, detected) = try await Task.detached(priority: .userInitiated) {
                let lines = try await CaptureService.recognizeText(in: image, source: source)
                let colors = CaptureService.sampleBackgroundColors(in: image, lines: lines)
                let detected = source == .automatic
                    ? LanguageDetection.resolveAmbiguous(lines.map { LanguageDetection.classify($0.text) })
                    : []
                return (lines, colors, detected)
            }.value
        } catch {
            failed("텍스트 인식 오류: \(error.localizedDescription)")
            return
        }
        guard isCurrent(generation) else { return }

        // 자동 인식 + Apple 번역: 감지한 언어가 번역 지원 언어인지 거를 목록을 처음 한 번 읽는다.
        if source == .automatic, !method.isExternal, autoSupportedLanguageIDs == nil, !lines.isEmpty {
            let supported = await method.makeLanguageAvailability().supportedLanguages
            guard isCurrent(generation), method == backend else { return }
            autoSupportedLanguageIDs = supported.map(\.minimalIdentifier)
        }

        if lines.isEmpty {
            // 인식 결과가 없으면 원문보기로 바꾸지 않는다.
            clearResult()
            isProcessing = false
            status = .info("인식된 글자가 없습니다")
            return
        }

        // OCR 메타데이터가 준비된 이 시점에만 이전 결과를 교체한다.
        clearResult()
        capturedImage = image
        currentLines = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0) })
        lineBackgroundColors = bgColors
        isDisplayingResult = true
        overlay?.beginTranslationDisplay()

        if source.language == target {
            for line in lines {
                appendPatch(TranslatedPatch(id: line.id, translatedText: line.text, boundingBox: line.boundingBox, autoBackgroundColor: bgColors[line.id], fontStyleHint: line.fontStyleHint))
            }
            completeIfAllReceived()
            return
        }

        // 자동 인식: 글자가 없는 줄(숫자·기호)과 이미 번역 언어인 줄은 번역 요청 없이 원문 그대로 둔다.
        // 언어를 판별하지 못했거나 지원 목록에 없는 줄도 번역을 요청하지 않고(언어 선택 팝업을 띄우지 않기
        // 위해 원문 언어가 nil인 세션을 쓰지 않음) 원문 그대로 두고 '건너뜀'으로 센다.
        /// 자동 인식에서 번역할 언어를 정한 줄.
        var languageByLine: [Int: String] = [:]
        if source == .automatic {
            for (line, result) in zip(lines, detected) {
                switch result {
                case .noLetters:
                    appendPatch(TranslatedPatch(id: line.id, translatedText: line.text, boundingBox: line.boundingBox, autoBackgroundColor: bgColors[line.id], fontStyleHint: line.fontStyleHint))
                case .language(let key) where LanguageDetection.isSameLanguage(key, target.rawValue):
                    appendPatch(TranslatedPatch(id: line.id, translatedText: line.text, boundingBox: line.boundingBox, autoBackgroundColor: bgColors[line.id], fontStyleHint: line.fontStyleHint))
                case .language(let key) where isAutoSupported(key):
                    languageByLine[line.id] = key
                default:
                    appendPatch(TranslatedPatch(id: line.id, translatedText: line.text, boundingBox: line.boundingBox, autoBackgroundColor: bgColors[line.id], fontStyleHint: line.fontStyleHint))
                    skippedLineIDs.insert(line.id)
                }
            }
            if receivedLineIDs.count == currentLines.count {
                completeIfAllReceived()
                return
            }
        }

        if let provider = method.provider {
            startExternal(provider: provider, generation: generation, source: source, target: target)
            return
        }
        if let translator = method.webTranslator {
            startWebExternal(translator, generation: generation, source: source, target: target, languageByLine: languageByLine)
            return
        }

        status = .translating(done: receivedLineIDs.count, total: lines.count, skipped: skippedLineIDs.count)
        let pendingLines = lines.filter { !receivedLineIDs.contains($0.id) }
        func request(_ line: OCRLine) -> TranslationSession.Request {
            TranslationSession.Request(sourceText: line.text, clientIdentifier: "\(generation):\(line.id)")
        }
        if source == .automatic {
            // 감지한 언어별로 읽는 순서대로 한 묶음씩 만든다(같은 언어는 한 번에 보내 속도를 유지). 묶음마다
            // 그 언어를 명시한 Configuration을 쓰는 대기열로 처리해 Apple이 언어를 다시 추정하지 않게 한다.
            var groupOrder: [String] = []
            var groupRequests: [String: [TranslationSession.Request]] = [:]
            for line in pendingLines {
                guard let key = languageByLine[line.id] else { continue }
                if groupRequests[key] == nil { groupOrder.append(key) }
                groupRequests[key, default: []].append(request(line))
            }
            groupQueue = groupOrder.map { key in
                LanguageGroupJob(
                    config: method.makeConfiguration(source: Locale.Language(identifier: key), target: target.localeLanguage),
                    requests: groupRequests[key] ?? [])
            }
            groupErrorMessage = nil
            advanceGroupQueue(generation: generation)
        } else {
            submit(TranslationJob(generation: generation, batches: [pendingLines.map(request)]))
        }
    }

    /// 대기열에서 다음 언어 묶음을 꺼내 그 언어를 명시한 Configuration으로 바꾼다(.translationTask가
    /// 새 세션으로 다시 시작되며 openJobChannel()이 이 묶음을 받아간다). 대기열이 비면 전체 결과를 확정한다.
    private func advanceGroupQueue(generation: Int) {
        guard isCurrent(generation) else { groupQueue = []; return }
        guard !groupQueue.isEmpty else {
            finishAllGroups(generation: generation)
            return
        }
        let next = groupQueue.removeFirst()
        status = .translating(done: receivedLineIDs.count, total: currentLines.count, skipped: skippedLineIDs.count)
        // 직전 묶음과 같은 언어(config == next.config)이고 그 .translationTask의 채널이 아직 살아 있으면
        // Configuration이 바뀌지 않아 .translationTask가 재시작되지 않는다(새 consumer가 열리지 않음).
        // 이 경우 채널을 닫지 않고 기존 소비자에 그대로 제출해 재사용한다.
        if translationConfiguration == next.config, jobContinuation != nil {
            submit(TranslationJob(generation: generation, batches: [next.requests]))
            return
        }
        // 언어가 실제로 바뀌었거나 채널이 이미 죽은 경우에만 명시적으로 무효화한다.
        jobContinuation?.finish()
        jobContinuation = nil
        if var config = translationConfiguration, config == next.config {
            // Configuration 값이 같아 보여도(채널은 죽어 있음) 그대로 대입하면 .translationTask가
            // 재시작을 건너뛸 수 있으므로, invalidate()로 값을 확실히 바꿔 새 .translationTask(새 consumer)를 강제로 연다.
            config.invalidate()
            translationConfiguration = config
        } else {
            translationConfiguration = next.config
        }
        submit(TranslationJob(generation: generation, batches: [next.requests]))
    }

    /// 모든 언어 묶음을 다 처리했을 때 한 번 호출된다. 받지 못한 줄이 있으면 오류로 남긴다.
    private func finishAllGroups(generation: Int) {
        guard isCurrent(generation) else { return }
        if let message = groupErrorMessage {
            groupErrorMessage = nil
            isProcessing = false
            hasCompleteResult = false
            primaryAction = .captureAndTranslate
            status = .error("번역 오류 (\(receivedLineIDs.count)/\(currentLines.count)줄 완료): \(message)")
            return
        }
        if receivedLineIDs.count < currentLines.count {
            isProcessing = false
            hasCompleteResult = false
            primaryAction = .captureAndTranslate
            status = .error("일부 줄을 번역하지 못했습니다 (\(receivedLineIDs.count)/\(currentLines.count)줄 완료). 다시 캡처해주세요.")
            return
        }
        completeIfAllReceived()
    }

    /// 감지한 언어가 이 방식의 Apple 번역 지원 언어인지. 목록을 읽지 못했으면 거르지 않는다.
    private func isAutoSupported(_ key: String) -> Bool {
        guard let ids = autoSupportedLanguageIDs, !ids.isEmpty else { return true }
        return ids.contains { LanguageDetection.isSameLanguage($0, key) }
    }

    // MARK: - .translationTask 연동 (스트리밍 배치)

    /// .translationTask 클로저가 시작될 때 호출한다. 클로저마다 새 채널을 만들고,
    /// 클로저가 준비되기 전에 제출된 작업이 있으면 바로 전달한다.
    func openJobChannel() -> AsyncStream<TranslationJob> {
        jobContinuation?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: TranslationJob.self)
        jobContinuation = continuation
        if let job = pendingJob {
            pendingJob = nil
            continuation.yield(job)
        }
        return stream
    }

    private func submit(_ job: TranslationJob) {
        if let continuation = jobContinuation, case .enqueued = continuation.yield(job) {
            return
        }
        jobContinuation = nil
        pendingJob = job
    }

    func isJobCurrent(_ generation: Int) -> Bool {
        isCurrent(generation)
    }

    /// 스트림에서 한 줄 번역이 끝날 때마다 즉시 호출된다. 응답 순서와 무관하게
    /// clientIdentifier로 원래 줄의 바운딩 박스를 찾아 그 자리에 그린다.
    func receiveTranslation(_ response: TranslationSession.Response, generation: Int) {
        guard isCurrent(generation),
              let identifier = response.clientIdentifier else { return }
        let parts = identifier.split(separator: ":")
        guard parts.count == 2,
              Int(parts[0]) == generation,
              let lineID = Int(parts[1]),
              let line = currentLines[lineID],
              !receivedLineIDs.contains(lineID) else { return }
        appendPatch(TranslatedPatch(id: lineID, translatedText: response.targetText, boundingBox: line.boundingBox, autoBackgroundColor: lineBackgroundColors[lineID], fontStyleHint: line.fontStyleHint))
        status = .translating(done: receivedLineIDs.count, total: currentLines.count, skipped: skippedLineIDs.count)
        noteTranslatedForRefine(id: lineID, original: line.text, draft: response.targetText, generation: generation)
    }

    // MARK: - Apple Intelligence 다듬기 (설정 켜짐 + 기기 내 모델 가능 시에만, Mac 기본 번역 결과만)

    /// 실제로 Apple 번역을 거친 줄만 모아 작은 묶음이 차면 보낸다(언어 조합이 같아 번역을 거치지 않은 줄,
    /// 외부 AI·웹 번역기 결과는 모으지 않는다).
    private func noteTranslatedForRefine(id: Int, original: String, draft: String, generation: Int) {
        guard !backend.isExternal, AppleTranslationRefiner.isEnabled,
              AppleTranslationRefiner.supportsTarget(targetLanguage.rawValue) else { return }
        refinePendingItems.append(AppleTranslationRefiner.Item(key: String(id), original: original, draft: draft))
        if refinePendingItems.count >= AppleTranslationRefiner.maxItemsPerBatch {
            flushRefineBuffer(generation: generation)
        }
    }

    private func flushRefineBuffer(generation: Int) {
        guard !refinePendingItems.isEmpty else { return }
        let items = refinePendingItems
        refinePendingItems = []
        guard let firstID = Int(items[0].key) else { return }
        let (nearbyOriginal, nearbyDraft) = nearbyRefineContext(aroundLineID: firstID)
        let targetName = AppModel.languageName(targetLanguage.rawValue)
        let task = Task { [weak self] in
            guard let self else { return }
            let result = await AppleTranslationRefiner.refine(
                items: items, nearbyOriginal: nearbyOriginal, nearbyDraft: nearbyDraft,
                targetLanguageName: targetName, isCurrent: { [weak self] in self?.isJobCurrent(generation) ?? false })
            guard self.isJobCurrent(generation), AppleTranslationRefiner.isEnabled, !result.isEmpty else { return }
            for (key, text) in result {
                guard let lineID = Int(key), self.currentLines[lineID] != nil, self.receivedLineIDs.contains(lineID) else { continue }
                if let index = self.translatedPatches.firstIndex(where: { $0.id == lineID }) {
                    let old = self.translatedPatches[index]
                    self.translatedPatches[index] = TranslatedPatch(id: old.id, translatedText: text, boundingBox: old.boundingBox,
                                                                     autoBackgroundColor: old.autoBackgroundColor, fontStyleHint: old.fontStyleHint)
                }
                self.overlay?.updateTranslationPatchText(id: lineID, text: text)
            }
        }
        refineTasks.append(task)
    }

    /// 다듬을 줄 바로 앞뒤(줄 ID 순서) 몇 줄의 원문·현재 번역문만 짧게 넘긴다(전체 화면을 넘기지 않음).
    private func nearbyRefineContext(aroundLineID lineID: Int) -> ([String], [String]) {
        let sortedIDs = currentLines.keys.sorted()
        guard let index = sortedIDs.firstIndex(of: lineID) else { return ([], []) }
        var originals: [String] = []
        var drafts: [String] = []
        let radius = AppleTranslationRefiner.maxNearbyLines
        var offset = 1
        while originals.count < radius && (index - offset >= 0 || index + offset < sortedIDs.count) {
            for neighborIndex in [index - offset, index + offset] {
                guard originals.count < radius, sortedIDs.indices.contains(neighborIndex) else { continue }
                let neighborID = sortedIDs[neighborIndex]
                guard let line = currentLines[neighborID],
                      let patch = translatedPatches.first(where: { $0.id == neighborID }) else { continue }
                originals.append(line.text)
                drafts.append(patch.translatedText)
            }
            offset += 1
        }
        return (originals, drafts)
    }

    /// 묶음(언어별 작업 또는 직접 고른 언어 하나뿐인 작업) 하나의 스트림이 끝났을 때 호출된다
    /// (error는 그 묶음의 오류). 자동 인식은 다음 언어 묶음으로 이어가고, 모든 묶음이 끝났을 때만
    /// 전체 결과를 확정한다. 이미 받은 줄은 한 묶음이 실패해도 지우지 않는다.
    func finishTranslation(generation: Int, error: Error?) {
        guard isCurrent(generation) else { return }
        if let error, groupErrorMessage == nil {
            groupErrorMessage = error.localizedDescription
        }
        flushRefineBuffer(generation: generation)
        advanceGroupQueue(generation: generation)
    }

    // MARK: - 외부 AI 번역 (웹 로그인 · AIBI)

    /// 인식한 줄을 읽는 순서대로 큰 묶음(최대 150줄·9,000자)으로 보낸다. 줄마다 따로 보내지 않는다.
    /// 메일과 같은 규칙: 누락 줄 1회 재요청, 형식 오류 1회·Gemini 일시 오류 1회 재요청, 한 번 실행에 최대 4회 요청.
    private func startExternal(provider: AIProvider, generation: Int, source: SourceSelection, target: AppLanguage) {
        externalFailedLineIDs = []
        externalMissingAttempts = [:]
        externalRunsInAction = 0
        externalFormatRetryCount = 0
        externalServiceRetryCount = 0
        externalBatch = nil
        isExternalRunning = true
        refreshExternalStatus(provider)
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshExternalStatus(provider) }
        }
        RunLoop.main.add(timer, forMode: .common)
        externalStatusTimer = timer
        runNextExternalBatch(provider: provider, generation: generation, source: source, target: target)
    }

    private var pendingExternalLineIDs: [Int] {
        currentLines.keys.sorted().filter { !receivedLineIDs.contains($0) && !externalFailedLineIDs.contains($0) }
    }

    private func runNextExternalBatch(provider: AIProvider, generation: Int, source: SourceSelection, target: AppLanguage) {
        guard isCurrent(generation) else { return }
        // 한 묶음 상한보다 긴 줄은 보내지 않는다(자르거나 다른 방식으로 대체하지 않음).
        for id in pendingExternalLineIDs where (currentLines[id]?.text.count ?? 0) > ExternalTranslation.maxBatchCharacters {
            externalFailedLineIDs.insert(id)
        }
        guard !pendingExternalLineIDs.isEmpty else {
            finishExternal(generation: generation, failure: nil)
            return
        }
        guard externalRunsInAction < ExternalTranslation.batchesPerAction else {
            finishExternal(generation: generation, failure: "한 번 실행에서 보낼 수 있는 요청 수(\(ExternalTranslation.batchesPerAction)회)를 모두 썼습니다. 번역을 다시 눌러주세요.")
            return
        }
        externalRunsInAction += 1
        let runIndex = externalRunsInAction
        externalTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await AIBIRunner.shared.run(
                provider: provider,
                owner: .screen,
                alwaysVisible: AIBIAccounts.shared.alwaysShowBrowser,
                allowsFormatRetry: self.externalFormatRetryCount == 0 && runIndex < ExternalTranslation.batchesPerAction,
                surface: self.aibiSurface,
                prompt: { [weak self] in
                    guard let self, self.isCurrent(generation) else { return nil }
                    if self.externalBatch == nil { self.externalBatch = self.makeExternalBatch(source: source, target: target) }
                    return self.externalBatch?.prompt
                },
                sink: { [weak self] text in
                    guard let self, self.isCurrent(generation), let batch = self.externalBatch else {
                        return "번역 요청이 바뀌어 이 응답은 적용하지 않았습니다."
                    }
                    return self.applyExternal(text, batch: batch)
                }
            )
            guard self.isCurrent(generation) else { return }
            self.externalTask = nil
            self.externalBatch = nil
            switch outcome {
            case .applied:
                self.runNextExternalBatch(provider: provider, generation: generation, source: source, target: target)
            case .failed(let message):
                if message == AIBIRunner.retryableFormatFailure,
                   self.externalFormatRetryCount < 1,
                   self.externalRunsInAction < ExternalTranslation.batchesPerAction {
                    self.externalFormatRetryCount += 1
                    self.runNextExternalBatch(provider: provider, generation: generation, source: source, target: target)
                    return
                }
                // 완료된 Gemini 요청의 확인된 일시 오류만 같은 제공사에 한 번 더 요청한다.
                if provider == .gemini, message == AIBIRunner.geminiTemporaryFailure,
                   self.externalServiceRetryCount < 1,
                   self.externalRunsInAction < ExternalTranslation.batchesPerAction {
                    self.externalServiceRetryCount += 1
                    self.runNextExternalBatch(provider: provider, generation: generation, source: source, target: target)
                    return
                }
                // 다른 제공사나 Apple 번역으로 대체하지 않는다.
                self.finishExternal(generation: generation, failure: message)
            case .cancelled:
                self.finishExternal(generation: generation, failure: nil, cancelled: true)
            }
        }
    }

    /// 웹 번역기: 아직 받지 못한 줄을 한 줄씩 보내고, 받은 결과는 그 줄의 바운딩 박스에만 그린다.
    /// 자동 인식이면 줄마다 판별한 언어를, 직접 고르면 그 언어를 원문 언어로 지정한다(판별 못 한 줄은 이미 원문 유지로 빠졌다).
    /// 페이지 이동을 줄이려고 같은 언어 줄을 이어서 보낸다. 실패한 줄은 표시하고 계속하며, 멈춰야 하는 오류는 받은 줄을 둔 채 끝낸다.
    private func startWebExternal(_ translator: WebTranslator, generation: Int, source: SourceSelection, target: AppLanguage,
                                  languageByLine: [Int: String]) {
        externalFailedLineIDs = []
        externalBatch = nil
        isExternalRunning = true
        refreshWebStatus(translator)
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWebStatus(translator) }
        }
        RunLoop.main.add(timer, forMode: .common)
        externalStatusTimer = timer
        let ticket = WebTranslatorRunner.shared.ticket(for: .screen)
        var order: [String] = []
        var items: [(id: Int, language: String)] = []
        for id in pendingExternalLineIDs {
            guard let language = source.language?.rawValue ?? languageByLine[id] else { continue }
            if !order.contains(language) { order.append(language) }
            items.append((id, language))
        }
        items.sort { (order.firstIndex(of: $0.language) ?? 0, $0.id) < (order.firstIndex(of: $1.language) ?? 0, $1.id) }
        let limited = items.count > WebTranslation.itemsPerAction
        externalTask = Task { [weak self] in
            guard let self else { return }
            for item in items.prefix(WebTranslation.itemsPerAction) {
                guard self.isCurrent(generation), !Task.isCancelled else { return }
                guard let line = self.currentLines[item.id], !self.receivedLineIDs.contains(item.id) else { continue }
                let result = await WebTranslatorRunner.shared.translate(
                    line.text, source: item.language, target: target.rawValue, using: translator,
                    owner: .screen, ticket: ticket, surface: self.aibiSurface)
                guard self.isCurrent(generation) else { return }
                switch result {
                case .success(let translated):
                    self.appendPatch(TranslatedPatch(id: item.id, translatedText: translated, boundingBox: line.boundingBox,
                                                     autoBackgroundColor: self.lineBackgroundColors[item.id], fontStyleHint: line.fontStyleHint))
                case .failure(.item), .failure(.unsupported):
                    self.externalFailedLineIDs.insert(item.id)
                case .failure(.cancelled):
                    self.finishExternal(generation: generation, failure: nil, cancelled: true)
                    return
                case .failure(.fatal(let message)):
                    self.finishExternal(generation: generation, failure: message)
                    return
                }
            }
            guard self.isCurrent(generation) else { return }
            self.finishExternal(generation: generation, failure: limited
                ? "한 번 실행에서 보낼 수 있는 줄 수(\(WebTranslation.itemsPerAction)줄)를 넘었습니다. 영역을 줄여 다시 번역하세요." : nil)
        }
    }

    /// 입력 직전에 한 번 호출된다. 아직 받지 못한 줄을 읽는 순서대로 묶는다.
    private func makeExternalBatch(source: SourceSelection, target: AppLanguage) -> ExternalBatch? {
        var items: [ExternalBatchItem] = []
        var characters = 0
        for id in pendingExternalLineIDs {
            guard let text = currentLines[id]?.text else { continue }
            if text.count > ExternalTranslation.maxBatchCharacters {
                externalFailedLineIDs.insert(id)
                continue
            }
            if !items.isEmpty && (items.count >= ExternalTranslation.maxBatchItems
                                  || characters + text.count > ExternalTranslation.maxBatchCharacters) { break }
            items.append(ExternalBatchItem(key: "t\(items.count + 1)", segmentID: String(id), kind: .screenText, text: text))
            characters += text.count
        }
        guard !items.isEmpty else { return nil }
        let responseToken = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        let prompt = ExternalTranslation.makePrompt(items: items, sourceID: source.languageID, targetID: target.rawValue,
                                                    responseToken: responseToken,
                                                    correctingFormat: externalFormatRetryCount > 0, content: .screen)
        return ExternalBatch(items: items, prompt: prompt, responseToken: responseToken)
    }

    /// 결과 sink: 검증된 항목만 해당 줄 자리에 그린다. 누락 줄은 한 번만 재요청하고, 반복 누락은 실패로 둔다.
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
                guard let lineID = Int(item.segmentID), let line = currentLines[lineID],
                      !receivedLineIDs.contains(lineID) else { continue }
                if let translated = translations[item.key] {
                    appendPatch(TranslatedPatch(id: lineID, translatedText: translated, boundingBox: line.boundingBox,
                                                autoBackgroundColor: lineBackgroundColors[lineID], fontStyleHint: line.fontStyleHint))
                } else {
                    let attempts = externalMissingAttempts[lineID, default: 0]
                    externalMissingAttempts[lineID] = attempts + 1
                    if attempts >= 1 { externalFailedLineIDs.insert(lineID) }
                }
            }
            return nil
        }
    }

    /// 모든 줄을 받았을 때만 '완료'·'원문보기'가 된다. 일부라도 빠지면 오류로 남긴다.
    private func finishExternal(generation: Int, failure: String?, cancelled: Bool = false) {
        guard isCurrent(generation) else { return }
        stopExternalRun()
        let progress = "\(receivedLineIDs.count)/\(currentLines.count)줄"
        if cancelled || failure != nil || receivedLineIDs.count < currentLines.count {
            isProcessing = false
            hasCompleteResult = false
            primaryAction = .captureAndTranslate
            if cancelled {
                status = .info("취소됨 (\(progress))")
            } else if let failure {
                let label = backend.webTranslator.map { "\($0.title) 번역 실패" } ?? "외부 AI 번역 실패"
                status = .error("\(label) (\(progress) 완료): \(failure)")
            } else {
                status = .error("일부 줄을 번역하지 못했습니다 (\(progress) 완료). 다시 번역을 눌러주세요.")
            }
            return
        }
        completeIfAllReceived()
    }

    /// 진행 중인 외부 AI 실행과 진행 표시를 멈춘다(이 화면 번역이 시작한 실행만 취소).
    private func stopExternalRun() {
        externalStatusTimer?.invalidate()
        externalStatusTimer = nil
        externalBatch = nil
        if isExternalRunning { isExternalRunning = false }
        if externalTask != nil {
            externalTask?.cancel()
            externalTask = nil
            AIBIRunner.shared.cancel(owner: .screen)
            WebTranslatorRunner.shared.cancel(owner: .screen)
        }
    }

    /// 제목줄 상태: 제공사 · 단계 · 남은 시간(답변 생성 확인 뒤 1:59부터) · 완료 줄 수
    private func refreshExternalStatus(_ provider: AIProvider) {
        guard isProcessing, isExternalRunning else { return }
        let run = AIBIRunner.shared.owner == .screen ? AIBIRunner.shared.status : nil
        let next = AppStatus.externalTranslating(
            provider: provider.title,
            stage: run?.stage ?? "준비 중",
            remaining: run?.observationDeadline.map { max(0, $0.timeIntervalSinceNow) },
            done: receivedLineIDs.count,
            total: currentLines.count)
        if status != next { status = next }
    }

    /// 제목줄 상태: 웹 번역기 · 단계 · 완료 줄 수
    private func refreshWebStatus(_ translator: WebTranslator) {
        guard isProcessing, isExternalRunning else { return }
        let run = WebTranslatorRunner.shared.status
        let next = AppStatus.externalTranslating(
            provider: translator.title,
            stage: run.map { $0.owner == .screen ? $0.stage : "차례 기다리는 중" } ?? "준비 중",
            remaining: nil,
            done: receivedLineIDs.count,
            total: currentLines.count)
        if status != next { status = next }
    }

    private func appendPatch(_ patch: TranslatedPatch) {
        receivedLineIDs.insert(patch.id)
        let index = translatedPatches.firstIndex { $0.id > patch.id } ?? translatedPatches.endIndex
        translatedPatches.insert(patch, at: index)
        overlay?.addTranslationPatch(patch)
    }

    private func completeIfAllReceived() {
        guard receivedLineIDs.count == currentLines.count, capturedImage != nil else { return }
        isProcessing = false
        hasCompleteResult = true
        primaryAction = .showOriginal
        status = .completed(skipped: skippedLineIDs.count)
    }
}
