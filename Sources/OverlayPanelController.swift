import AppKit
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
///   (performDrag 직전)이나 첫 실제 크기 변경(첫 setFrame 직전)에서 한 번만 onRegionChanged를 알린다.
///   그 뒤에는 다음 명시적 캡처까지 didMove 관찰·프레임 비교·폴링을 전혀 하지 않는다.
///   움직이지 않은 클릭은 아무것도 바꾸지 않는다.
/// - 사용자가 크기 조절을 마쳤을 때(mouseUp 한 번)만 창 크기를 UserDefaults에 저장하고, 다음 실행에 복원한다.
@MainActor
final class OverlayPanelController: NSObject {
    let panel: OverlayPanel
    private let viewModel: AppViewModel
    private let borderView = OverlayBorderView()
    private let interiorView = NSView()
    private let originalImageView = OriginalImageView()
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
    /// true면 다음 첫 실제 이동/크기 변경에서 한 번 onRegionChanged를 알린다(명시적 캡처가 켬).
    private var isRegionWatchArmed = false
    private var cancellables: Set<AnyCancellable> = []

    /// false면 '이동·크기 잠금': 이동과 크기 조절만 막히고 툴바는 계속 동작한다.
    var isAdjustable: Bool = true {
        didSet {
            resizeHandles.forEach {
                $0.isEnabled = isAdjustable
                $0.window?.invalidateCursorRects(for: $0)
            }
            titleStrip.isDragEnabled = isAdjustable
            headerView.isDragEnabled = isAdjustable
            lastHit = .none
            updateHover()
        }
    }

    var isAlwaysOnTop: Bool = true {
        didSet { panel.level = isAlwaysOnTop ? .floating : .normal }
    }

    /// 무장 뒤 첫 실제 이동/크기 변경(또는 화면 변경으로 창을 옮김) 직전에 한 번 호출. 결과 삭제·작업 취소용.
    var onRegionChanged: (() -> Void)?
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
        let screens = NSScreen.screens
        func overlap(_ screen: NSScreen) -> CGFloat {
            let r = screen.visibleFrame.intersection(frame)
            return r.isNull ? 0 : r.width * r.height
        }
        let best = screens.max { overlap($0) < overlap($1) }
        let screen = (best.map { overlap($0) > 0 } ?? false) ? best : (NSScreen.main ?? screens.first)
        guard let visible = screen?.visibleFrame, !visible.isEmpty else { return frame }
        let minSize = OverlayGeometry.minWindowSize
        var f = frame
        f.size.width = max(minSize.width, min(f.width, visible.width))
        f.size.height = max(minSize.height, min(f.height, visible.height))
        f.origin.x = max(visible.minX, min(f.minX, visible.maxX - f.width))
        f.origin.y = min(visible.maxY - f.height, max(f.minY, visible.minY))
        return f.integral
    }

    /// 디스플레이 구성이 바뀌면 화면 밖·사용 불가 위치에 남지 않게 맞춘다. 옮기면 (무장돼 있을 때) 결과를 한 번 무효화한다.
    @objc private func screenParametersChanged() {
        guard !isResizing else { return }
        let frame = panel.frame
        let usable = Self.usableFrame(for: frame)
        guard usable != frame else { return }
        regionWillChange()
        panel.setFrame(usable, display: true)
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

        originalImageView.frame = interiorView.bounds
        originalImageView.autoresizingMask = [.width, .height]
        originalImageView.imageScaling = .scaleAxesIndependently
        originalImageView.isEditable = false
        originalImageView.isHidden = true
        patchesView.frame = interiorView.bounds
        patchesView.autoresizingMask = [.width, .height]
        interiorView.addSubview(originalImageView)
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
        titleStrip.onDragWillMove = { [weak self] in self?.regionWillChange() }
        headerView.onDragWillMove = { [weak self] in self?.regionWillChange() }
        titleStrip.onDragFinished = { [weak self] in self?.resetHover() }
        headerView.onDragFinished = { [weak self] in self?.resetHover() }
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
                self?.resetHover()
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
                        ? "캡처한 원본 화면을 같은 자리에 보여줍니다 (Enter). Space는 다시 번역하지 않고 저장된 번역↔원본을 오갑니다"
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
        if isResizing { resizeEnded() }
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

    /// 패치 뷰(behindWindow 블러 포함)를 모두 제거하고 원본 이미지를 놓아 레이어를 해제한다.
    func clearResultDisplay() {
        patchesView.removeAllPatches()
        originalImageView.image = nil
        originalImageView.isHidden = true
        patchesView.isHidden = false
    }

    /// 새 캡처의 OCR 메타데이터가 준비된 뒤 호출된다. 이후 줄 단위로 패치가 추가된다.
    func beginTranslationDisplay() {
        originalImageView.isHidden = true
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

    func showOriginal(image: CGImage) {
        originalImageView.image = NSImage(cgImage: image, size: interiorView.bounds.size)
        originalImageView.isHidden = false
        patchesView.isHidden = true
    }

    /// Space: 보관 중인 번역 패치를 그대로 다시 보인다(다시 인식·번역하지 않음).
    func showTranslation() {
        originalImageView.isHidden = true
        patchesView.isHidden = false
    }

    // MARK: - 영역 변경(1회용 무효화)

    /// 명시적 캡처가 시작될 때 호출된다. 이 캡처 영역에 대해 다음 첫 실제 이동/크기 변경을 한 번만 알린다.
    func armRegionInvalidation() {
        isRegionWatchArmed = true
    }

    /// 첫 실제 이동(performDrag 직전)·첫 실제 크기 변경(첫 setFrame 직전)에서 불린다. 무장돼 있을 때만
    /// 한 번 알리고 곧바로 해제하므로, 이후 같은 끌기·다음 끌기에서는 즉시 돌아온다.
    private func regionWillChange() {
        guard isRegionWatchArmed else { return }
        isRegionWatchArmed = false
        onRegionChanged?()
    }

    // MARK: - 크기 조절

    private func resizeBegan() {
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

    // MARK: - 마우스 통과/커서

    private func startMonitoring() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseUp]) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.updateHover() }
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
