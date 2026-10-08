import AppKit
import Combine
import SwiftUI

/// nonactivatingPanel이지만 툴바 컨트롤과 키 입력이 동작하도록 키 윈도우가 될 수 있다.
/// Space/Return/키패드 Enter(수정키 없음)는 주 버튼 동작, Esc는 창 숨기기로 처리한다.
/// 이 창이 키 윈도우일 때(앱에 포커스가 있을 때)만 동작하며 전역 키 모니터는 쓰지 않는다.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var onPrimaryKey: (() -> Void)?
    var onEscapeKey: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if modifiers.isEmpty {
                switch event.keyCode {
                case 36, 76, 49: // Return, 키패드 Enter, Space
                    if !event.isARepeat { onPrimaryKey?() }
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
/// - 이동은 네이티브 performDrag(with:), 크기 조절은 ResizeHandleView의 스냅샷+이동량 계산.
/// - 드래그/크기 조절 중에는 호버 추적을 멈춘다.
/// - 이동/크기 조절 중(버튼 눌림)에는 결과 무효화를 미루고 마우스를 놓은 뒤 한 번만 알린다.
///   네이티브 이동 루프 안에서 SwiftUI 상태 갱신·패치 제거가 일어나지 않게 하기 위함이다.
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
    private var resizeHandles: [ResizeHandleView] = []

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var lastHit: HitRegion = .none
    private var isResizing = false
    private var hasPendingRegionChange = false
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

    /// 창 이동/크기 변경이 끝났을 때 호출 (버튼을 놓은 뒤 한 번)
    var onRegionChanged: (() -> Void)?
    /// 창이 숨겨지기 직전에 호출 (진행 중 작업 취소용)
    var onWillHide: (() -> Void)?

    init(initialFrame: NSRect, viewModel: AppViewModel) {
        self.viewModel = viewModel
        toolbarHostingView = NSHostingView(rootView: ToolbarView(viewModel: viewModel))
        panel = OverlayPanel(contentRect: initialFrame,
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

        buildViewHierarchy(size: initialFrame.size)
        bindViewModel()
        startMonitoring()

        panel.onPrimaryKey = { [weak viewModel] in viewModel?.performPrimaryAction() }
        panel.onEscapeKey = { [weak viewModel] in viewModel?.requestHide() }

        NotificationCenter.default.addObserver(self, selector: #selector(windowFrameChanged), name: NSWindow.didMoveNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(windowFrameChanged), name: NSWindow.didResizeNotification, object: panel)
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
        titleStrip.onDragFinished = { [weak self] in self?.interactionEnded() }
        headerView.onDragFinished = { [weak self] in self?.interactionEnded() }
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
            handle.onResizeBegan = { [weak self] in self?.isResizing = true }
            handle.onResizeEnded = { [weak self] in
                self?.isResizing = false
                self?.interactionEnded()
            }
            container.addSubview(handle)
            resizeHandles.append(handle)
        }

        panel.contentView = container
    }

    private func bindViewModel() {
        viewModel.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self else { return }
                self.titleStrip.statusLabel.stringValue = status.koreanText
                self.titleStrip.statusLabel.toolTip = status.koreanText
                self.titleStrip.statusLabel.textColor = status.isError
                    ? NSColor.systemOrange
                    : NSColor(calibratedWhite: 0.78, alpha: 1)
            }
            .store(in: &cancellables)

        viewModel.$primaryAction
            .receive(on: RunLoop.main)
            .sink { [weak self] action in
                guard let self else { return }
                self.titleStrip.primaryButton.title = action.title
                self.titleStrip.primaryButton.toolTip = action == .showOriginal
                    ? "방금 캡처한 원본 화면을 같은 자리에 보여줍니다 (Space 또는 Enter)"
                    : "현재 영역을 한 번 캡처해 인식·번역합니다 (Space 또는 Enter)"
                self.titleStrip.needsLayout = true
            }
            .store(in: &cancellables)

        viewModel.$isProcessing
            .receive(on: RunLoop.main)
            .sink { [weak self] isProcessing in
                self?.titleStrip.primaryButton.isEnabled = !isProcessing
            }
            .store(in: &cancellables)
    }

    @objc private func primaryButtonPressed() {
        viewModel.performPrimaryAction()
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

    func hide() {
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

    func clearResultDisplay() {
        interiorView.isHidden = false
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

    // MARK: - 마우스 통과/커서

    @objc private func windowFrameChanged() {
        if isResizing || NSEvent.pressedMouseButtons != 0 {
            // 옛 결과(behindWindow 블러 패치 포함)는 화면과 맞지 않으므로 숨기기만 하고,
            // 상태 무효화는 놓은 뒤 flushPendingRegionChange에서 한 번만 한다.
            if !hasPendingRegionChange {
                hasPendingRegionChange = true
                interiorView.isHidden = true
            }
        } else {
            hasPendingRegionChange = false
            interiorView.isHidden = false
            onRegionChanged?()
        }
    }

    /// 미뤄 둔 영역 변경을 버튼이 놓였을 때 한 번 알린다. 캡처 직전에도 호출된다.
    func flushPendingRegionChange() {
        guard hasPendingRegionChange, !isResizing, NSEvent.pressedMouseButtons == 0 else { return }
        hasPendingRegionChange = false
        interiorView.isHidden = false
        onRegionChanged?()
    }

    private func startMonitoring() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseUp]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushPendingRegionChange()
                self?.updateHover()
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.flushPendingRegionChange()
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

    private func interactionEnded() {
        flushPendingRegionChange()
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
