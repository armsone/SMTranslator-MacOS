import AppKit
import ApplicationServices
import Combine
import SwiftUI
import WebKit

/// nonactivatingPanel이지만 툴바 컨트롤과 키 입력이 동작하도록 키 윈도우가 될 수 있다.
/// 수정키 없는 Space는 저장된 번역↔원본 전환(onSpaceKey), Return/키패드 Enter는 새 캡처·번역↔원본
/// 전환(onEnterKey), Esc는 창 숨기기로 처리한다. 이 창이 키 윈도우일 때만 동작하며 전역 키 모니터는
/// 쓰지 않는다. 팝오버·메뉴·다른 창은 자기 창에서 키를 받으므로 여기로 오지 않고, 이 창 안에서도
/// 글자 입력 중(필드 편집기)이거나 웹 보기에 포커스가 있으면 가로채지 않는다.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var onSpaceKey: (() -> Void)?
    var onEnterKey: (() -> Void)?
    var onEscapeKey: (() -> Void)?

    private var isTextInputFocused: Bool {
        guard let responder = firstResponder else { return false }
        if let text = responder as? NSText, text.isEditable { return true }
        var view = responder as? NSView
        while let current = view {
            if current is WKWebView { return true }
            view = current.superview
        }
        return false
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !isTextInputFocused {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if modifiers.isEmpty {
                switch event.keyCode {
                case 49: // Space
                    if !event.isARepeat { onSpaceKey?() }
                    return
                case 36, 76: // Return, 키패드 Enter
                    if !event.isARepeat { onEnterKey?() }
                    return
                case 53: // Esc
                    onEscapeKey?()
                    return
                default:
                    break
                }
            }
        }
        super.sendEvent(event)
    }
}

/// 테두리 + 헤더(제목 스트립·툴바) + 번역 패치가 모두 들어 있는 하나의 투명 창.
/// - 중앙 캡처 영역은 항상 클릭 통과. 헤더와 가장자리 크기 조절 밴드 위에서만
///   창이 마우스를 받도록 ignoresMouseEvents를 값이 바뀔 때만 토글한다.
/// - 이동은 네이티브 performDrag(with:)(HeaderDrag), 크기 조절은 ResizeHandleView의 스냅샷+이동량 계산.
/// - 영역 변경 감지는 1회용이다. 명시적 캡처가 armRegionInvalidation()으로 무장하고, 첫 실제 이동
///   (performDrag 직전)이나 첫 실제 크기 변경(첫 setFrame 직전)에서 한 번만 결과를 숨기고 onRegionWillChange
///   (세대 무효화·취소만)를 알린다. 무거운 정리(패치 뷰 해제·버튼/상태 갱신·외부 AI 정리)는 그 끌기의
///   mouseUp에서 한 번 onRegionChangeEnded로 한다. 그 뒤에는 다음 명시적 캡처까지 didMove 관찰·프레임
///   비교·폴링을 전혀 하지 않는다. 움직이지 않은 클릭은 아무것도 바꾸지 않는다.
/// - 사용자가 크기 조절을 마쳤을 때(mouseUp 한 번)만 창 크기를 UserDefaults에 저장하고, 다음 실행에 복원한다.
/// - 맞추기(메뉴 '화면에/현재 창에 맞추기', Shift+헤더 끌기)도 같은 1회용 무효화를 거쳐 프레임을 바꾸고 크기를 한 번 저장한다.
///   다른 앱 창 목록은 그 동작에서 한 번만 읽으며(WindowGeometry), 일반 끌기는 창 목록을 조회하지 않는다.
///   Shift 끌기를 놓을 때만 읽기 영역(Mail 본문 등)을 백그라운드에서 한 번 찾아, 늦지 않고 그 사이 아무 조작이 없을 때만 적용한다.
/// - 원문보기는 번역 패치만 숨겨 투명한 캡처 영역 너머의 실제 화면을 그대로 보이게 한다(캡처 이미지를 그리지 않음).
@MainActor
final class OverlayPanelController: NSObject {
    let panel: OverlayPanel
    private let viewModel: AppViewModel
    private let borderView = OverlayBorderView()
    private let interiorView = NSView()
    private let patchesView = TranslationPatchesView()
    private let headerView = HeaderBackgroundView(frame: .zero)
    private let titleStrip = TitleDragStripView(frame: .zero)
    private let toolbarHostingView: NSHostingView<ToolbarView>
    /// 외부 AI 숨김 실행용 실제 크기 웹 보기 표면. 머리글 배경과 같은 불투명 덮개 아래에 두고 머리글 영역으로 잘라 보인다.
    private let aibiClipView = NSView()
    private let aibiHost = AIBIHostView(frame: NSRect(origin: .zero, size: AIBIHiddenSurface.viewport),
                                        coverColor: NSColor(calibratedWhite: 0.22, alpha: 1))
    private var resizeHandles: [ResizeHandleView] = []

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var lastHit: HitRegion = .none
    private var isResizing = false
    private var resizeStartSize: NSSize = .zero
    /// true면 다음 첫 실제 이동/크기 변경에서 한 번 onRegionWillChange를 알린다(명시적 캡처가 켬).
    private var isRegionWatchArmed = false
    /// 첫 이동 때 알린 뒤 mouseUp에서 onRegionChangeEnded를 한 번 부를 때까지 true
    private var isRegionChangeEndPending = false
    private var cancellables: Set<AnyCancellable> = []
    /// 읽기 영역 보정 요청 번호. 새 끌기·크기 조절·맞추기·캡처·잠금·숨김 때 올려 늦게 온 결과를 버린다.
    private var paneRequest = 0

    /// false면 '이동·크기 잠금': 이동과 크기 조절만 막히고 툴바는 계속 동작한다.
    var isAdjustable: Bool = true {
        didSet {
            resizeHandles.forEach {
                $0.isEnabled = isAdjustable
                $0.window?.invalidateCursorRects(for: $0)
            }
            titleStrip.isDragEnabled = isAdjustable
            headerView.isDragEnabled = isAdjustable
            cancelPaneRefinement()
            lastHit = .none
            updateHover()
        }
    }

    var isAlwaysOnTop: Bool = true {
        didSet { panel.level = isAlwaysOnTop ? .floating : .normal }
    }

    /// 무장 뒤 첫 실제 이동/크기 변경(또는 화면 변경으로 창을 옮김) 직전에 한 번 호출. 값싼 무효화(세대·취소)만 해야 한다.
    var onRegionWillChange: (() -> Void)?
    /// 그 이동/크기 조절이 끝난 뒤(mouseUp 한 번) 호출. 미뤄 둔 결과 해제·상태 갱신용.
    var onRegionChangeEnded: (() -> Void)?
    /// 창이 숨겨지기 직전에 호출 (진행 중 작업 취소용)
    var onWillHide: (() -> Void)?

    init(initialFrame: NSRect, viewModel: AppViewModel) {
        self.viewModel = viewModel
        toolbarHostingView = NSHostingView(rootView: ToolbarView(viewModel: viewModel))
        let startFrame = Self.restoredFrame(default: initialFrame)
        panel = OverlayPanel(contentRect: startFrame,
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered,
                             defer: false)
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = false
        panel.isMovable = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.minSize = OverlayGeometry.minWindowSize

        buildViewHierarchy(size: startFrame.size)
        bindViewModel()
        startMonitoring()

        panel.onSpaceKey = { [weak viewModel] in viewModel?.performCachedToggle() }
        panel.onEnterKey = { [weak viewModel] in viewModel?.performPrimaryAction() }
        panel.onEscapeKey = { [weak viewModel] in viewModel?.requestHide() }

        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // MARK: - 창 크기 저장/복원

    /// 사용자가 마지막으로 조절한 창 전체 크기(글로우 여백 포함, pt). 위치·화면 내용은 저장하지 않는다.
    private enum SizeKeys {
        static let width = "ScreenOverlay.windowWidth"
        static let height = "ScreenOverlay.windowHeight"
    }

    private static func savedSize() -> NSSize? {
        let d = UserDefaults.standard
        guard d.object(forKey: SizeKeys.width) != nil, d.object(forKey: SizeKeys.height) != nil else { return nil }
        let size = NSSize(width: d.double(forKey: SizeKeys.width), height: d.double(forKey: SizeKeys.height))
        return isValidSize(size) ? size : nil
    }

    private static func isValidSize(_ size: NSSize) -> Bool {
        let minSize = OverlayGeometry.minWindowSize
        return size.width.isFinite && size.height.isFinite
            && size.width >= minSize.width && size.height >= minSize.height
            && size.width <= 20_000 && size.height <= 20_000
    }

    private func saveSize(_ size: NSSize) {
        guard Self.isValidSize(size) else { return }
        let d = UserDefaults.standard
        d.set(Double(size.width), forKey: SizeKeys.width)
        d.set(Double(size.height), forKey: SizeKeys.height)
    }

    /// 실행 시 기본 프레임의 중심에 저장된 크기를 적용하고 현재 화면 안으로 맞춘다.
    /// 화면에 맞추느라 줄어든 크기는 저장하지 않는다(저장값은 사용자가 다시 조절할 때만 바뀜).
    private static func restoredFrame(default frame: NSRect) -> NSRect {
        guard let size = savedSize() else { return frame }
        let restored = NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                              width: size.width, height: size.height)
        return usableFrame(for: restored)
    }

    /// 프레임과 가장 많이 겹치는 화면(없으면 주 화면)의 사용 가능 영역 안으로 크기·위치를 맞춘다.
    /// 최소 크기보다는 작게 줄이지 않으며, 그래도 넘치면 위쪽(헤더)이 보이도록 위·왼쪽에 맞춘다.
    private static func usableFrame(for frame: NSRect) -> NSRect {
        let screen = WindowGeometry.screen(mostOverlapping: frame) ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame, !visible.isEmpty else { return frame }
        return WindowGeometry.clamp(frame, into: visible)
    }

    /// 디스플레이 구성이 바뀌면 화면 밖·사용 불가 위치에 남지 않게 맞춘다. 옮기면 (무장돼 있을 때) 결과를 한 번 무효화한다.
    @objc private func screenParametersChanged() {
        guard !isResizing else { return }
        cancelPaneRefinement()
        let frame = panel.frame
        let usable = Self.usableFrame(for: frame)
        guard usable != frame else { return }
        regionWillChange()
        panel.setFrame(usable, display: true)
        regionChangeEnded()
    }

    // MARK: - 구성

    private func buildViewHierarchy(size: NSSize) {
        let bounds = NSRect(origin: .zero, size: size)
        let container = NSView(frame: bounds)
        container.wantsLayer = true
        container.autoresizesSubviews = true

        interiorView.frame = OverlayGeometry.interiorRect(in: bounds)
        interiorView.autoresizingMask = [.width, .height]
        interiorView.wantsLayer = true
        interiorView.layer?.cornerRadius = OverlayGeometry.cornerRadius - OverlayGeometry.strokeWidth
        interiorView.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        interiorView.layer?.masksToBounds = true

        patchesView.frame = interiorView.bounds
        patchesView.autoresizingMask = [.width, .height]
        interiorView.addSubview(patchesView)

        headerView.frame = OverlayGeometry.headerRect(in: bounds)
        headerView.autoresizingMask = [.width, .minYMargin]
        let headerBounds = headerView.bounds
        toolbarHostingView.frame = NSRect(x: 0, y: 0, width: headerBounds.width, height: OverlayGeometry.toolbarHeight)
        toolbarHostingView.autoresizingMask = [.width]
        titleStrip.frame = NSRect(x: 0, y: OverlayGeometry.toolbarHeight, width: headerBounds.width, height: OverlayGeometry.titleStripHeight)
        titleStrip.autoresizingMask = [.width]
        titleStrip.closeButton.target = self
        titleStrip.closeButton.action = #selector(closeButtonPressed)
        titleStrip.primaryButton.target = self
        titleStrip.primaryButton.action = #selector(primaryButtonPressed)
        titleStrip.onDragWillMove = { [weak self] in self?.dragWillMove() }
        headerView.onDragWillMove = { [weak self] in self?.dragWillMove() }
        titleStrip.onDragFinished = { [weak self] in self?.dragFinished() }
        headerView.onDragFinished = { [weak self] in self?.dragFinished() }
        titleStrip.onShiftDrag = { [weak self] event in self?.trackShiftSnapDrag(from: event) ?? false }
        headerView.onShiftDrag = { [weak self] event in self?.trackShiftSnapDrag(from: event) ?? false }
        aibiClipView.frame = headerBounds
        aibiClipView.autoresizingMask = [.width, .height]
        aibiClipView.wantsLayer = true
        aibiClipView.layer?.masksToBounds = true
        aibiClipView.layer?.cornerRadius = OverlayGeometry.cornerRadius
        aibiClipView.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        aibiHost.frame = NSRect(origin: .zero, size: AIBIHiddenSurface.viewport)
        aibiClipView.addSubview(aibiHost)
        AIBIHiddenSurface.shared.register(aibiHost, isMain: false)
        viewModel.aibiSurface = aibiHost
        headerView.addSubview(aibiClipView)
        headerView.addSubview(toolbarHostingView)
        headerView.addSubview(titleStrip)

        borderView.frame = bounds
        borderView.autoresizingMask = [.width, .height]

        container.addSubview(interiorView)
        container.addSubview(headerView)
        container.addSubview(borderView)

        // 크기 조절 핸들: 가장자리 전체 + 모서리. 모서리를 맨 위에 둔다.
        let g = OverlayGeometry.glowMargin
        let band = g + OverlayGeometry.resizeBand
        let topBand = g + OverlayGeometry.topResizeStrip
        let corner = g + OverlayGeometry.cornerHitSize
        let W = size.width, H = size.height
        let specs: [(HitRegion, NSRect, NSView.AutoresizingMask)] = [
            (.resizeLeft, NSRect(x: 0, y: 0, width: band, height: H), [.height, .maxXMargin]),
            (.resizeRight, NSRect(x: W - band, y: 0, width: band, height: H), [.height, .minXMargin]),
            (.resizeBottom, NSRect(x: 0, y: 0, width: W, height: band), [.width, .maxYMargin]),
            (.resizeTop, NSRect(x: 0, y: H - topBand, width: W, height: topBand), [.width, .minYMargin]),
            (.resizeBottomLeft, NSRect(x: 0, y: 0, width: corner, height: corner), [.maxXMargin, .maxYMargin]),
            (.resizeBottomRight, NSRect(x: W - corner, y: 0, width: corner, height: corner), [.minXMargin, .maxYMargin]),
            (.resizeTopLeft, NSRect(x: 0, y: H - corner, width: corner, height: corner), [.maxXMargin, .minYMargin]),
            (.resizeTopRight, NSRect(x: W - corner, y: H - corner, width: corner, height: corner), [.minXMargin, .minYMargin])
        ]
        for (region, frame, mask) in specs {
            let handle = ResizeHandleView(region: region)
            handle.frame = frame
            handle.autoresizingMask = mask
            handle.onResizeBegan = { [weak self] in self?.resizeBegan() }
            handle.onResizeWillChange = { [weak self] in self?.regionWillChange() }
            handle.onResizeEnded = { [weak self] in
                self?.resizeEnded()
                self?.dragFinished()
            }
            container.addSubview(handle)
            resizeHandles.append(handle)
        }

        panel.contentView = container
    }

    private func bindViewModel() {
        viewModel.statusPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] status in self?.applyStatus(status) }
            .store(in: &cancellables)

        // 주 버튼(Enter와 같은 동작): '번역' ↔ '원문보기', 외부 AI 실행 중에는 '취소'(항상 누를 수 있음)
        Publishers.CombineLatest3(viewModel.$primaryAction, viewModel.$isProcessing, viewModel.$isExternalRunning)
            .receive(on: RunLoop.main)
            .sink { [weak self] action, isProcessing, isExternalRunning in
                guard let self else { return }
                let button = self.titleStrip.primaryButton
                if isExternalRunning {
                    button.title = "취소"
                    button.toolTip = "진행 중인 외부 AI 번역을 취소합니다"
                    button.isEnabled = true
                } else {
                    button.title = action.title
                    button.toolTip = action == .showOriginal
                        ? "번역을 숨기고 창 아래 실제 화면을 그대로 보여줍니다 (Enter). Space는 다시 번역하지 않고 저장된 번역↔실제 화면을 오갑니다"
                        : "현재 영역을 새로 캡처해 인식·번역합니다 (Enter). 완료된 번역이 있으면 Space로 저장된 번역을 다시 보여줍니다"
                    button.isEnabled = !isProcessing
                }
                self.titleStrip.needsLayout = true
            }
            .store(in: &cancellables)
    }

    private func applyStatus(_ status: AppStatus) {
        titleStrip.statusLabel.stringValue = status.koreanText
        titleStrip.statusLabel.toolTip = status.koreanText
        titleStrip.statusLabel.textColor = status.isError
            ? NSColor.systemOrange
            : NSColor(calibratedWhite: 0.78, alpha: 1)
        var remainingFraction: Double?
        if case .externalTranslating(_, _, let remaining?, _, _) = status {
            remainingFraction = remaining / AIBIRunner.observationLimit
        }
        let barHidden = remainingFraction == nil
        if let remainingFraction { titleStrip.remainingBar.doubleValue = min(1, max(0, remainingFraction)) }
        if titleStrip.remainingBar.isHidden != barHidden {
            titleStrip.remainingBar.isHidden = barHidden
            titleStrip.needsLayout = true
        }
    }

    @objc private func primaryButtonPressed() {
        if viewModel.isExternalRunning {
            viewModel.cancelExternalTranslation()
        } else {
            viewModel.performPrimaryAction()
        }
    }

    // MARK: - 표시/숨김

    var isVisible: Bool { panel.isVisible }
    var ownWindowNumbers: [Int] { [panel.windowNumber] }

    func show(activate: Bool) {
        panel.orderFrontRegardless()
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKey()
        }
        lastHit = .none
        updateHover()
    }

    /// 숨기기·종료(applicationWillTerminate도 여기를 거침): 크기 조절 중이면 먼저 마무리해 크기 저장을
    /// 놓치지 않는다. 프레임은 그대로 두어 다시 보일 때 같은 자리에 나타난다.
    func hide() {
        cancelPaneRefinement()
        if isResizing { resizeEnded() }
        if isRegionChangeEndPending {
            isRegionChangeEndPending = false
            onRegionChangeEnded?()
        }
        onWillHide?()
        panel.orderOut(nil)
        panel.ignoresMouseEvents = true
        lastHit = .none
    }

    @objc private func closeButtonPressed() {
        viewModel.requestHide()
    }

    /// 캡처해야 하는 실제 화면 영역(헤더·테두리를 제외한 인터리어)을 화면 좌표로 반환.
    var captureScreenFrame: CGRect {
        let interior = OverlayGeometry.interiorRect(in: NSRect(origin: .zero, size: panel.frame.size))
        return interior.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
    }

    // MARK: - 결과 표시

    /// 패치 뷰(behindWindow 블러 포함)를 모두 제거해 레이어를 해제한다.
    func clearResultDisplay() {
        patchesView.removeAllPatches()
        patchesView.isHidden = false
    }

    /// 새 캡처의 OCR 메타데이터가 준비된 뒤 호출된다. 이후 줄 단위로 패치가 추가된다.
    func beginTranslationDisplay() {
        patchesView.removeAllPatches()
        patchesView.isHidden = false
    }

    func addTranslationPatch(_ patch: TranslatedPatch) {
        patchesView.add(patch: patch)
    }

    /// 글자색/배경색/진하기 설정이 바뀔 때 호출된다. 이미 표시된 패치도 즉시 다시 칠한다.
    func updatePatchColorSettings(_ settings: PatchColorSettings) {
        patchesView.colorSettings = settings
    }

    /// 원문보기: 번역 패치만 숨긴다. 캡처 영역은 투명·클릭 통과라 아래 앱의 실제(라이브) 화면이 그대로 보인다.
    /// 캡처 이미지를 그리지 않고, 새로 캡처·인식·번역하지 않는다. 패치는 보관돼 showTranslation()으로 그대로 돌아온다.
    func showOriginal() {
        patchesView.isHidden = true
    }

    /// Space: 보관 중인 번역 패치를 그대로 다시 보인다(다시 인식·번역하지 않음).
    func showTranslation() {
        patchesView.isHidden = false
    }

    // MARK: - 영역 변경(1회용 무효화)

    /// 명시적 캡처가 시작될 때 호출된다. 이 캡처 영역에 대해 다음 첫 실제 이동/크기 변경을 한 번만 알린다.
    func armRegionInvalidation() {
        cancelPaneRefinement()
        isRegionWatchArmed = true
    }

    /// 첫 실제 이동(performDrag 직전)·첫 실제 크기 변경(첫 setFrame 직전)에서 불린다. 무장돼 있을 때만
    /// 한 번 알리고 곧바로 해제하므로, 이후 같은 끌기·다음 끌기에서는 즉시 돌아온다.
    /// 이 시점에는 결과를 숨기기만 한다(레이어 hidden 플래그). 패치 뷰 제거·이미지 해제·버튼/상태 갱신은
    /// regionChangeEnded()(mouseUp 한 번)로 미룬다.
    private func regionWillChange() {
        guard isRegionWatchArmed else { return }
        isRegionWatchArmed = false
        isRegionChangeEndPending = true
        patchesView.isHidden = true
        onRegionWillChange?()
    }

    /// 끌기·크기 조절이 끝났을 때(mouseUp) 미뤄 둔 정리를 한 번만 알린다. 버튼이 아직 눌려 있으면
    /// (performDrag가 끝나기 전에 돌아온 경우) 기다렸다가 다음 leftMouseUp 모니터에서 부른다.
    private func regionChangeEnded() {
        guard isRegionChangeEndPending, NSEvent.pressedMouseButtons & 1 == 0 else { return }
        isRegionChangeEndPending = false
        onRegionChangeEnded?()
    }

    /// 일반 끌기의 첫 실제 이동. 늦게 올 읽기 영역 보정을 버리고(정수 증가) 1회용 무효화만 한다.
    private func dragWillMove() {
        cancelPaneRefinement()
        regionWillChange()
    }

    private func dragFinished() {
        regionChangeEnded()
        resetHover()
    }

    // MARK: - 크기 조절

    private func resizeBegan() {
        cancelPaneRefinement()
        isResizing = true
        resizeStartSize = panel.frame.size
    }

    /// mouseUp에서 한 번: 크기가 실제로 바뀐 경우에만 저장한다.
    private func resizeEnded() {
        guard isResizing else { return }
        isResizing = false
        let size = panel.frame.size
        if size != resizeStartSize { saveSize(size) }
    }

    // MARK: - 화면·다른 창에 맞추기

    /// 'Shift를 누른 채 헤더 끌기로 창에 맞추기' 사용 여부(기본 켜짐). 끄면 Shift 끌기도 일반 이동이다.
    private static let shiftSnapKey = "ScreenOverlay.shiftSnapToWindow"
    var isShiftSnapEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.shiftSnapKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.shiftSnapKey) }
    }

    /// 마지막 맞추기 직전 프레임(메모리에만). '맞추기 전 크기로'가 한 번 되돌린다.
    private var frameBeforeFit: NSRect?
    var canRestoreFrameBeforeFit: Bool { frameBeforeFit != nil }

    /// 포인터가 있는 화면(없으면 이 창이 가장 많이 걸친 화면)의 사용 가능 영역 전체에 맞춘다.
    /// macOS 전체 화면 Space가 아니라 메뉴 막대·Dock을 뺀 visibleFrame이다.
    @discardableResult
    func fitToScreen() -> Bool {
        let screen = WindowGeometry.screen(containing: NSEvent.mouseLocation)
            ?? WindowGeometry.screen(mostOverlapping: panel.frame)
        guard let visible = screen?.visibleFrame, !visible.isEmpty else { return false }
        return applyFittedFrame(WindowGeometry.clamp(visible, into: visible))
    }

    /// 다른 앱의 보이는 일반 창에 맞춘다. 창 목록은 이 호출에서 한 번만 읽는다.
    /// 선택 규칙: 이 창 캡처 영역 중심 아래에 있는 맨 위 창 → 없으면 가장 앞에 있는 창. 후보가 없으면 그대로 둔다.
    @discardableResult
    func fitToWindowBehind() -> Bool {
        let candidates = WindowGeometry.otherAppWindows()
        let center = NSPoint(x: captureScreenFrame.midX, y: captureScreenFrame.midY)
        guard let target = candidates.first(where: { $0.frame.contains(center) }) ?? candidates.first,
              let frame = WindowGeometry.fittedFrame(for: target.frame, preferring: center) else { return false }
        return applyFittedFrame(frame)
    }

    /// 마지막 맞추기 직전의 위치·크기로 한 번 되돌린다(현재 화면 안으로 맞춤).
    @discardableResult
    func restoreFrameBeforeFit() -> Bool {
        guard let previous = frameBeforeFit else { return false }
        let applied = applyFittedFrame(Self.usableFrame(for: previous))
        frameBeforeFit = nil
        return applied
    }

    /// 메뉴 맞추기 공통: 잠금이면 아무것도 하지 않는다. 무장돼 있으면 크기 조절과 같은 1회용 무효화를 거친 뒤
    /// 프레임을 한 번 바꾸고 크기를 한 번 저장한다. 번역·캡처는 시작하지 않는다.
    private func applyFittedFrame(_ frame: NSRect) -> Bool {
        guard isAdjustable, !isResizing, frame != panel.frame else { return false }
        cancelPaneRefinement()
        frameBeforeFit = panel.frame
        regionWillChange()
        panel.setFrame(frame, display: true)
        saveSize(frame.size)
        regionChangeEnded()
        resetHover()
        return true
    }

    /// Shift를 누른 채 헤더(제목 스트립·툴바 빈 곳)를 끌 때. 기능이 꺼져 있으면 false를 돌려 일반 이동으로 넘긴다.
    /// - 움직이지 않은 클릭은 아무것도 하지 않는다. 첫 실제 이동에서 1회용 무효화를 한 뒤 다른 앱 창 목록을 딱 한 번 읽어
    ///   이 끌기 동안만 보관한다(이후 이벤트에서는 메모리의 경계와 포인터만 비교).
    /// - 포인터 아래 맨 위 후보 창이 바뀔 때만 그 창 경계에 맞춰 프레임을 한 번 바꾼다(같은 창 위에서는 프레임 변경 없음).
    /// - 후보가 없는 곳(바탕화면·이 앱 창 위 등)에서는 시작 크기로 돌아가 잡은 지점을 유지한 채 일반 이동처럼 따라온다.
    ///   포인터를 옮기지(워프하지) 않는다. 놓으면 그 상태로 끝나고, 크기가 바뀌었으면 한 번 저장한다.
    /// - 다른 앱 창에 맞춘 채 놓았으면 그때 한 번만 읽기 영역 보정을 시작한다(끌기 이벤트마다 손쉬운 사용 API를 부르지 않음).
    private func trackShiftSnapDrag(from mouseDown: NSEvent) -> Bool {
        guard isShiftSnapEnabled else { return false }
        cancelPaneRefinement()
        let startMouse = NSEvent.mouseLocation
        let startFrame = panel.frame
        let grab = NSPoint(x: startMouse.x - startFrame.minX, y: startMouse.y - startFrame.minY)
        var candidates: [WindowGeometry.Candidate] = []
        var snapped: WindowGeometry.Candidate?
        var didMove = false
        while let event = panel.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            guard event.type == .leftMouseDragged else { break }
            let mouse = NSEvent.mouseLocation
            if !didMove {
                guard mouse != startMouse else { continue }
                didMove = true
                regionWillChange()
                candidates = WindowGeometry.otherAppWindows()
            }
            if let hit = candidates.first(where: { $0.frame.contains(mouse) }) {
                if hit.id == snapped?.id { continue }
                if let fitted = WindowGeometry.fittedFrame(for: hit.frame, preferring: mouse) {
                    snapped = hit
                    if fitted != panel.frame { panel.setFrame(fitted, display: true) }
                    continue
                }
            }
            let origin = NSPoint(x: mouse.x - grab.x, y: mouse.y - grab.y)
            if snapped != nil || panel.frame.size != startFrame.size {
                snapped = nil
                panel.setFrame(NSRect(origin: origin, size: startFrame.size), display: true)
            } else {
                panel.setFrameOrigin(origin)
            }
        }
        if didMove, panel.frame != startFrame {
            frameBeforeFit = startFrame
            if panel.frame.size != startFrame.size { saveSize(panel.frame.size) }
        }
        if didMove, let snapped { refineToContentPane(of: snapped, at: NSEvent.mouseLocation) }
        return true
    }

    // MARK: - 읽기 영역 보정(Shift 끌기를 놓을 때 한 번)

    /// 보정 결과를 받아들이는 최대 시간(놓은 뒤). 넘으면 늦은 결과로 보고 버린다.
    private static let paneApplyLimit: TimeInterval = 0.8

    private func cancelPaneRefinement() {
        paneRequest &+= 1
    }

    /// 놓은 지점의 읽기 영역을 메인 스레드 밖에서 한 번 찾는다. 손쉬운 사용 권한이 이미 없으면 아무것도 하지 않는다
    /// (권한 요청 없음, 창 전체 맞추기 유지). 찾은 영역은 메모리에서 프레임 계산에만 쓰고 버린다.
    private func refineToContentPane(of target: WindowGeometry.Candidate, at pointer: NSPoint) {
        guard AXIsProcessTrusted(),
              let query = WindowGeometry.paneQuery(pid: target.pid, pointer: pointer, windowFrame: target.frame) else { return }
        cancelPaneRefinement()
        let request = paneRequest
        let releasedFrame = panel.frame
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let pane = ContentPaneResolver.resolve(query)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let pane, request == self.paneRequest else { return }
                    self.applyContentPane(pane, pointer: pointer, releasedFrame: releasedFrame, started: started)
                }
            }
        }
    }

    /// 놓은 뒤 아무 조작이 없었을 때만(같은 프레임·버튼 안 눌림·잠금 아님·제한 시간 안) 한 번 적용한다.
    private func applyContentPane(_ paneTopLeft: CGRect, pointer: NSPoint, releasedFrame: NSRect, started: Date) {
        guard panel.isVisible, isAdjustable, !isResizing, NSEvent.pressedMouseButtons == 0,
              panel.frame == releasedFrame, Date().timeIntervalSince(started) < Self.paneApplyLimit,
              let pane = WindowGeometry.appKitRect(fromTopLeft: paneTopLeft),
              let frame = WindowGeometry.paneFittedFrame(for: pane, preferring: pointer),
              frame != panel.frame else { return }
        cancelPaneRefinement()
        regionWillChange()
        panel.setFrame(frame, display: true)
        saveSize(frame.size)
        regionChangeEnded()
        resetHover()
    }

    // MARK: - 마우스 통과/커서

    private func startMonitoring() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .leftMouseUp { self?.regionChangeEnded() }
                self?.updateHover()
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .leftMouseUp { self?.regionChangeEnded() }
                self?.updateHover()
            }
            return event
        }
    }

    func stopMonitoring() {
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m) }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
    }

    private func resetHover() {
        lastHit = .none
        updateHover()
    }

    /// 마우스 위치의 히트 영역이 바뀔 때만 ignoresMouseEvents를 바꾼다.
    /// 버튼이 눌린 동안(이동/크기 조절/다른 앱 드래그)에는 갱신하지 않는다.
    private func updateHover() {
        guard panel.isVisible, !isResizing, NSEvent.pressedMouseButtons == 0 else { return }
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        let local = NSPoint(x: mouse.x - frame.minX, y: mouse.y - frame.minY)
        let hit = OverlayGeometry.hitRegion(for: local, in: NSRect(origin: .zero, size: frame.size), adjustable: isAdjustable)

        if hit != lastHit {
            let previous = lastHit
            lastHit = hit
            let ignore = (hit == .none)
            if panel.ignoresMouseEvents != ignore {
                panel.ignoresMouseEvents = ignore
            }
            if hit.isResize {
                hit.cursor.set()
            } else if previous.isResize {
                NSCursor.arrow.set()
            }
        } else if hit.isResize {
            hit.cursor.set()
        }
    }
}
