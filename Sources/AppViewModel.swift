import AppKit
import SwiftUI
import Translation

/// 캡처·인식·번역 상태 기계.
/// - 자동/주기 캡처는 없다. 사용자가 주 버튼(또는 Space/Enter, 메뉴)을 누를 때만 1회 캡처한다.
/// - 주 버튼은 '캡처·번역' ↔ '원문보기' 두 상태를 오간다. 모든 줄 번역이 성공해야만
///   '원문보기'가 되며, 누르면 방금 캡처해 메모리에 보관한 원본 이미지를 같은 영역에 보여준다.
/// - 번역은 TranslationSession.translate(batch:) 스트리밍으로 받으며, 줄이 끝나는 즉시
///   clientIdentifier → 바운딩 박스로 매핑해 화면에 바로 그린다.
@MainActor
final class AppViewModel: ObservableObject {
    @Published var sourceLanguage: AppLanguage = .english {
        didSet { if oldValue != sourceLanguage { languagesChanged() } }
    }
    @Published var targetLanguage: AppLanguage = .korean {
        didSet { if oldValue != targetLanguage { languagesChanged() } }
    }
    @Published var status: AppStatus = .idle
    /// true면 이동·크기 조절 가능, false면 '이동·크기 잠금' 상태(툴바/버튼은 계속 동작).
    @Published var isAdjustable: Bool = true {
        didSet { overlay?.isAdjustable = isAdjustable }
    }
    @Published var isAlwaysOnTop: Bool = true {
        didSet { overlay?.isAlwaysOnTop = isAlwaysOnTop }
    }
    /// 캡처·인식·번역이 진행 중인 동안 true. 주 버튼과 Space/Enter가 비활성화된다.
    @Published private(set) var isProcessing: Bool = false
    @Published private(set) var primaryAction: PrimaryAction = .captureAndTranslate
    /// 화면에 그려진 번역 패치(줄 ID 순). 복사 버튼이 사용한다.
    @Published private(set) var translatedPatches: [TranslatedPatch] = []

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

    /// 현재 결과에 대응하는 원본 캡처 이미지. 메모리에만 보관하며 디스크 저장/전송하지 않는다.
    private var capturedImage: CGImage?
    private var currentLines: [Int: OCRLine] = [:]
    private var receivedLineIDs: Set<Int> = []
    private var hasCompleteResult = false
    private var isDisplayingResult = false

    private var jobContinuation: AsyncStream<TranslationJob>.Continuation?
    private var pendingJob: TranslationJob?

    /// 화면 기록 권한 요청 다이얼로그는 실행당 최대 1회, 명시적 캡처 동작에서만 띄운다.
    private var didRequestScreenPermission = false

    func attach(overlay: OverlayPanelController) {
        self.overlay = overlay
        overlay.isAdjustable = isAdjustable
        overlay.isAlwaysOnTop = isAlwaysOnTop
        overlay.onRegionChanged = { [weak self] in
            self?.regionChanged()
        }
    }

    // MARK: - 사용자 동작

    /// 주 버튼, Space/Return/키패드 Enter, 메뉴가 공통으로 호출한다.
    func performPrimaryAction() {
        guard !isProcessing else { return }
        switch primaryAction {
        case .captureAndTranslate:
            captureOnce()
        case .showOriginal:
            showOriginal()
        }
    }

    func requestHide() {
        onHideRequested?()
    }

    /// 창이 숨겨질 때: 진행 중 작업만 취소한다(표시된 결과는 유지).
    func windowWillHide() {
        cancelInFlightWork(message: "취소됨")
    }

    /// 앱 종료 시 진행 중인 작업을 멈춘다.
    func stop() {
        cancelInFlightWork(message: nil)
        jobContinuation?.finish()
        jobContinuation = nil
    }

    func copyTranslatedText() {
        let text = translatedPatches.map(\.translatedText).joined(separator: "\n")
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func showOriginal() {
        guard hasCompleteResult, let capturedImage else {
            primaryAction = .captureAndTranslate
            return
        }
        overlay?.showOriginal(image: capturedImage)
        primaryAction = .captureAndTranslate
        status = .showingOriginal
    }

    // MARK: - 무효화

    /// 영역 이동/크기 변경: 기존 결과는 더 이상 아래 화면과 맞지 않으므로 지우고,
    /// 진행 중 작업도 취소한다. 자동 재캡처는 하지 않는다. 이동 중 반복 호출되므로
    /// 지울 것이 없으면 즉시 반환한다.
    private func regionChanged() {
        guard isProcessing || isDisplayingResult || capturedImage != nil else { return }
        generation += 1
        currentCaptureTask?.cancel()
        currentCaptureTask = nil
        isProcessing = false
        clearResult()
        status = .info("영역이 바뀌었습니다. 캡처·번역을 눌러주세요")
    }

    /// 언어 변경: 진행 중 작업만 취소하고 자동 재번역은 하지 않는다. 세션은 다음 캡처 때
    /// 새 언어 조합으로 한 번만 구성된다.
    private func languagesChanged() {
        cancelInFlightWork(message: "언어가 바뀌었습니다. 캡처·번역을 눌러주세요")
        jobContinuation?.finish()
        jobContinuation = nil
        pendingJob = nil
        translationConfiguration = nil
    }

    /// 진행 중 작업만 취소한다. 이미 받은 부분 번역은 보이도록 두되 완료로 표시하지 않는다.
    private func cancelInFlightWork(message: String?) {
        guard isProcessing else { return }
        generation += 1
        currentCaptureTask?.cancel()
        currentCaptureTask = nil
        pendingJob = nil
        isProcessing = false
        hasCompleteResult = false
        primaryAction = .captureAndTranslate
        if let message {
            if currentLines.isEmpty {
                status = .info(message)
            } else {
                status = .info("\(message) (\(receivedLineIDs.count)/\(currentLines.count)줄)")
            }
        }
    }

    private func clearResult() {
        capturedImage = nil
        currentLines = [:]
        receivedLineIDs = []
        translatedPatches = []
        hasCompleteResult = false
        isDisplayingResult = false
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
        status = .error("화면 기록 권한이 필요합니다. 시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 기록에서 '화면 번역기'를 허용한 뒤, 필요하면 앱을 다시 실행하세요.")
        return false
    }

    private func captureOnce() {
        guard let overlay, overlay.isVisible else { return }
        guard ensureScreenRecordingPermission() else { return }

        generation += 1
        let myGeneration = generation
        isProcessing = true
        status = .capturing
        let screenFrame = overlay.captureScreenFrame
        let ownWindows = overlay.ownWindowNumbers
        let source = sourceLanguage
        let target = targetLanguage

        currentCaptureTask = Task { [weak self] in
            await self?.performCapture(generation: myGeneration, screenFrame: screenFrame, ownWindows: ownWindows, source: source, target: target)
        }
    }

    /// 번역 모델 다운로드 안내가 사용자의 캡처 동작 시점에만 나타나도록 세션 구성을
    /// 처음 캡처할 때 만든다. 같은 언어 조합에서는 기존 구성을 그대로 재사용한다.
    private func prepareTranslationConfigurationIfNeeded(source: AppLanguage, target: AppLanguage) async -> Bool {
        if translationConfiguration != nil { return true }
        let availability = LanguageAvailability()
        let result = await availability.status(from: source.localeLanguage, to: target.localeLanguage)
        guard source == sourceLanguage, target == targetLanguage else { return false }
        switch result {
        case .unsupported:
            status = .error("\(source.displayNameKorean) → \(target.displayNameKorean) 조합은 이 기기에서 지원되지 않습니다.")
            return false
        case .supported, .installed:
            // 이전 채널은 닫아 둔다. 새 .translationTask 클로저가 시작되면서 채널을 연다.
            jobContinuation?.finish()
            jobContinuation = nil
            translationConfiguration = TranslationSession.Configuration(
                source: source.localeLanguage,
                target: target.localeLanguage
            )
            return true
        @unknown default:
            status = .error("번역 언어 지원 여부를 확인할 수 없습니다.")
            return false
        }
    }

    private func performCapture(generation: Int, screenFrame: CGRect, ownWindows: [Int], source: AppLanguage, target: AppLanguage) async {
        func failed(_ message: String) {
            guard isCurrent(generation) else { return }
            isProcessing = false
            primaryAction = .captureAndTranslate
            hasCompleteResult = false
            status = .error(message)
        }

        if source != target {
            let ready = await prepareTranslationConfigurationIfNeeded(source: source, target: target)
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
        do {
            // VNImageRequestHandler.perform은 블로킹 호출이므로 메인 액터 밖에서 실행해
            // '텍스트 인식 중' 상태가 실제로 그려지고 UI가 계속 반응하게 한다.
            lines = try await Task.detached(priority: .userInitiated) {
                try CaptureService.recognizeText(in: image, language: source)
            }.value
        } catch {
            failed("텍스트 인식 오류: \(error.localizedDescription)")
            return
        }
        guard isCurrent(generation) else { return }

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
        isDisplayingResult = true
        overlay?.beginTranslationDisplay()

        if source == target {
            for line in lines {
                appendPatch(TranslatedPatch(id: line.id, translatedText: line.text, boundingBox: line.boundingBox))
            }
            completeIfAllReceived()
            return
        }

        status = .translating(done: 0, total: lines.count)
        let requests = lines.map {
            TranslationSession.Request(sourceText: $0.text, clientIdentifier: "\(generation):\($0.id)")
        }
        submit(TranslationJob(generation: generation, requests: requests))
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
        appendPatch(TranslatedPatch(id: lineID, translatedText: response.targetText, boundingBox: line.boundingBox))
        status = .translating(done: receivedLineIDs.count, total: currentLines.count)
    }

    /// 스트림이 끝났을 때 호출된다. 모든 줄이 성공했을 때만 '완료'·'원문보기'가 된다.
    func finishTranslation(generation: Int, error: Error?) {
        guard isCurrent(generation) else { return }
        if let error {
            isProcessing = false
            hasCompleteResult = false
            primaryAction = .captureAndTranslate
            status = .error("번역 오류 (\(receivedLineIDs.count)/\(currentLines.count)줄 완료): \(error.localizedDescription)")
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
        status = .completed
    }
}
