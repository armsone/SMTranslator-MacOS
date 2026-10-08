import AppKit

/// 창의 어느 부분 위에 마우스가 있는지 구분
enum HitRegion: Equatable {
    case none
    case header
    case resizeTop, resizeBottom, resizeLeft, resizeRight
    case resizeTopLeft, resizeTopRight, resizeBottomLeft, resizeBottomRight

    var isResize: Bool {
        switch self {
        case .none, .header: return false
        default: return true
        }
    }

    var cursor: NSCursor {
        switch self {
        case .resizeLeft: return .frameResize(position: .left, directions: .all)
        case .resizeRight: return .frameResize(position: .right, directions: .all)
        case .resizeTop: return .frameResize(position: .top, directions: .all)
        case .resizeBottom: return .frameResize(position: .bottom, directions: .all)
        case .resizeTopLeft: return .frameResize(position: .topLeft, directions: .all)
        case .resizeTopRight: return .frameResize(position: .topRight, directions: .all)
        case .resizeBottomLeft: return .frameResize(position: .bottomLeft, directions: .all)
        case .resizeBottomRight: return .frameResize(position: .bottomRight, directions: .all)
        case .none, .header: return .arrow
        }
    }
}

/// 창 내부 배치 상수와 좌표 계산. 시각적 테두리와 히트 영역은 독립적으로 정의된다.
/// - 창 바깥쪽 glowMargin은 파란 글로우가 잘리지 않도록 남겨 둔 투명 여백이다.
/// - 크기 조절 히트 밴드는 창 가장자리에서 glowMargin + resizeBand(안쪽 8pt)까지다.
/// - 헤더 맨 위 topResizeStrip은 세로 크기 조절, 그 아래 헤더 전체는 이동(빈 공간)이다.
enum OverlayGeometry {
    static let glowMargin: CGFloat = 2
    static let cornerRadius: CGFloat = 12
    static let strokeWidth: CGFloat = 1.5
    static let resizeBand: CGFloat = 8
    static let topResizeStrip: CGFloat = 6
    /// 모든 창 너비에서 한 줄로 고정된 헤더 행(닫기·전체화면·복원·색상·번역 버튼과 빈 이동 공간).
    static let headerRowHeight: CGFloat = 28
    static let cornerHitSize: CGFloat = 18
    /// 창 전체(글로우 여백 포함)의 최소 크기.
    static let minWindowSize = NSSize(width: 240, height: 160)

    static func headerHeight(forWidth width: CGFloat) -> CGFloat {
        topResizeStrip + headerRowHeight
    }

    /// 둥근 테두리 사각형(시각적 창 본체)
    static func frameRect(in bounds: NSRect) -> NSRect {
        bounds.insetBy(dx: glowMargin, dy: glowMargin)
    }

    static func headerRect(in bounds: NSRect) -> NSRect {
        let f = frameRect(in: bounds)
        let height = headerHeight(forWidth: f.width)
        return NSRect(x: f.minX, y: f.maxY - height, width: f.width, height: height)
    }

    /// 캡처 영역(헤더 아래, 테두리 안쪽). 이 영역만 캡처하고 번역 패치를 그린다.
    static func interiorRect(in bounds: NSRect) -> NSRect {
        let f = frameRect(in: bounds)
        let height = headerHeight(forWidth: f.width)
        return NSRect(
            x: f.minX + strokeWidth,
            y: f.minY + strokeWidth,
            width: max(1, f.width - strokeWidth * 2),
            height: max(1, f.height - height - strokeWidth)
        )
    }

    static func hitRegion(for p: NSPoint, in bounds: NSRect, adjustable: Bool) -> HitRegion {
        guard bounds.contains(p) else { return .none }
        if adjustable {
            let band = glowMargin + resizeBand
            let topBand = glowMargin + topResizeStrip
            let corner = glowMargin + cornerHitSize
            let left = p.x <= band
            let right = p.x >= bounds.maxX - band
            let bottom = p.y <= band
            let top = p.y >= bounds.maxY - topBand
            let nearLeft = p.x <= corner
            let nearRight = p.x >= bounds.maxX - corner
            let nearBottom = p.y <= corner
            let nearTop = p.y >= bounds.maxY - corner

            if (top && nearLeft) || (left && nearTop) { return .resizeTopLeft }
            if (top && nearRight) || (right && nearTop) { return .resizeTopRight }
            if (bottom && nearLeft) || (left && nearBottom) { return .resizeBottomLeft }
            if (bottom && nearRight) || (right && nearBottom) { return .resizeBottomRight }
            if top { return .resizeTop }
            if bottom { return .resizeBottom }
            if left { return .resizeLeft }
            if right { return .resizeRight }
        }
        if headerRect(in: bounds).contains(p) { return .header }
        return .none
    }
}

/// 둥근 흰색 테두리 + 아이콘과 어울리는 은은한 파란 글로우를 그리는 장식 뷰.
/// 흰 선 안쪽/바깥쪽에 아주 얇은(0.6pt) 검정 선을 덧그려 밝은 배경에서도 창 윤곽이
/// 또렷이 보이도록 한다. 마우스 이벤트는 전혀 받지 않는다(히트 영역은 ResizeHandleView/헤더가 담당).
/// 글로우(NSShadow 블러)는 CPU 비용이 커서 크기 조절마다 창 전체를 다시 그리면 버벅인다.
/// 그래서 작은 9-slice 템플릿을 배율당 한 번만 그리고, 크기 변경은 레이어 contentsCenter
/// 늘이기(GPU)로만 처리한다. 모서리·헤더 경계선은 늘어나지 않는 캡 안에 있다.
final class OverlayBorderView: NSView {
    private static let glowColor = NSColor(srgbRed: 0.36, green: 0.68, blue: 1.0, alpha: 0.85)
    /// 늘어나지 않는 가장자리 캡. 세로 캡은 헤더 경계선까지 포함하도록 위아래 동일하게 둔다.
    private static let sideCap: CGFloat = OverlayGeometry.glowMargin + OverlayGeometry.cornerRadius + 2
    private static let verticalCap: CGFloat = OverlayGeometry.glowMargin + OverlayGeometry.headerHeight(forWidth: 0) + 2
    private static let stretch: CGFloat = 2

    private var renderedScale: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerContentsPlacement = .scaleAxesIndependently
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func updateLayer() {
        guard let layer else { return }
        let scale = window?.backingScaleFactor ?? 2
        guard scale != renderedScale else { return }
        let size = NSSize(width: Self.sideCap * 2 + Self.stretch, height: Self.verticalCap * 2 + Self.stretch)
        let pixelWidth = Int(size.width * scale), pixelHeight = Int(size.height * scale)
        guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        Self.drawBorder(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return }

        layer.contents = image
        layer.contentsScale = scale
        layer.contentsCenter = CGRect(x: Self.sideCap / size.width, y: Self.verticalCap / size.height,
                                      width: Self.stretch / size.width, height: Self.stretch / size.height)
        renderedScale = scale
    }

    private static func drawBorder(in bounds: NSRect) {
        let inset = OverlayGeometry.strokeWidth / 2
        let rect = OverlayGeometry.frameRect(in: bounds).insetBy(dx: inset, dy: inset)
        let radius = OverlayGeometry.cornerRadius
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.lineWidth = OverlayGeometry.strokeWidth

        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = glowColor
        glow.shadowBlurRadius = 8
        glow.shadowOffset = .zero
        glow.set()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // 글로우 위에 선명한 흰 선을 한 번 더 그린다.
        NSColor.white.setStroke()
        path.stroke()

        // 밝은 배경 위에서도 창 윤곽이 또렷이 보이도록, 흰 선 안쪽/바깥쪽에 아주 얇은
        // (0.6pt) 검정 선을 덧그려 흰 선을 감싼다.
        let blackWidth: CGFloat = 0.6
        let halfWhite = OverlayGeometry.strokeWidth / 2
        NSColor.black.withAlphaComponent(0.55).setStroke()

        let outerOffset = halfWhite + blackWidth / 2
        let outerBlack = NSBezierPath(roundedRect: rect.insetBy(dx: -outerOffset, dy: -outerOffset),
                                       xRadius: radius + outerOffset, yRadius: radius + outerOffset)
        outerBlack.lineWidth = blackWidth
        outerBlack.stroke()

        let innerOffset = halfWhite + blackWidth / 2
        let innerRadius = max(0, radius - innerOffset)
        let innerBlack = NSBezierPath(roundedRect: rect.insetBy(dx: innerOffset, dy: innerOffset),
                                       xRadius: innerRadius, yRadius: innerRadius)
        innerBlack.lineWidth = blackWidth
        innerBlack.stroke()

        // 헤더와 캡처 영역 경계선
        let header = OverlayGeometry.headerRect(in: bounds)
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: header.minX + OverlayGeometry.strokeWidth, y: header.minY))
        separator.line(to: NSPoint(x: header.maxX - OverlayGeometry.strokeWidth, y: header.minY))
        separator.lineWidth = 1
        NSColor.white.withAlphaComponent(0.35).setStroke()
        separator.stroke()
    }
}

/// 헤더 끌기 공통 처리. onWillMove는 실제로 움직인 첫 이벤트 안에서 동기로 실행되므로 값싼 작업만 해야 하며,
/// 무거운 정리는 다음 명시적 동작(mouseUp)으로 미룬다.
///
/// 이동은 NSWindow.performDrag(with:)를 쓰지 않는다 — 이 API는 Apple 공식 문서(returns right away,
/// a mouse-up event may not get sent)에 따라 즉시 반환되는 비차단 호출이라, 반환 시점을 실제 마우스 업으로
/// 가정하고 그 뒤에 라이브 마우스 위치/보조키를 읽는 이전 구현은 틀린 전제 위에 있었다.
/// 대신 이 창의 mouseDragged/mouseUp 이벤트를 while window.nextEvent(matching:)로 직접 추적해
/// window.setFrameOrigin으로 원점만 옮긴다(크기·레이아웃 재계산 없음). 실제 leftMouseUp 이벤트를
/// 받는 시점의 마우스 위치와 그 이벤트의 보조키로 내려놓을 자리를 정한다: 화면 꼭대기 근처면
/// 맞추기(최대화), 그 외 Option이 눌려 있으면 좌/우 절반, 아니면 스냅 없음.
/// (참고: 네이티브 performDrag와 달리 끄는 도중 다른 Space로 자동 전환되는 macOS 기본 동작은 제공되지 않는다.)
enum HeaderDrag {
    /// 화면 물리 프레임 위쪽 가장자리로부터 이 거리(pt) 안쪽에서 놓으면 맞추기로 본다.
    private static let topEdgeSnapDistance: CGFloat = 16

    @MainActor
    static func begin(from mouseDown: NSEvent, in window: NSWindow, onWillMove: (() -> Void)?,
                      onDoubleClick: (() -> Void)?,
                      onSnapDrop: ((_ originalFrame: NSRect, _ target: NSRect) -> Void)? = nil) {
        if mouseDown.clickCount == 2 {
            onDoubleClick?()
            return
        }
        track(from: mouseDown, in: window, onWillMove: onWillMove, onSnapDrop: onSnapDrop)
    }

    @MainActor
    static func track(from mouseDown: NSEvent, in window: NSWindow, onWillMove: (() -> Void)?,
                      onSnapDrop: ((_ originalFrame: NSRect, _ target: NSRect) -> Void)?) {
        let startMouse = NSEvent.mouseLocation
        let originalFrame = window.frame
        var didMove = false
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - startMouse.x
            let dy = mouse.y - startMouse.y

            if event.type == .leftMouseDragged {
                guard dx != 0 || dy != 0 else { continue }
                if !didMove {
                    didMove = true
                    onWillMove?()
                }
                window.setFrameOrigin(NSPoint(x: originalFrame.origin.x + dx, y: originalFrame.origin.y + dy))
                continue
            }

            // event.type == .leftMouseUp
            guard didMove else { return }
            guard let screen = WindowGeometry.screen(containing: mouse)
                ?? WindowGeometry.screen(mostOverlapping: window.frame) else { return }
            let visible = screen.visibleFrame
            guard !visible.isEmpty else { return }
            if mouse.y >= screen.frame.maxY - topEdgeSnapDistance {
                onSnapDrop?(originalFrame, WindowGeometry.clamp(visible, into: visible))
            } else if event.modifierFlags.contains(.option) {
                let halfWidth = visible.width / 2
                let isLeftHalf = mouse.x < visible.midX
                let half = NSRect(x: isLeftHalf ? visible.minX : visible.minX + halfWidth,
                                  y: visible.minY, width: halfWidth, height: visible.height)
                onSnapDrop?(originalFrame, WindowGeometry.clamp(half, into: visible))
            }
            return
        }
    }
}

/// 크기 조절 전용 투명 히트 뷰. 마우스 다운 시점의 창 프레임/마우스 위치 스냅샷과
/// 이후 이동량만으로 새 프레임을 계산한다(OCR·레이아웃 재계산 없음).
final class ResizeHandleView: NSView {
    let region: HitRegion
    var isEnabled = true
    var onResizeBegan: (() -> Void)?
    /// 이번 끌기에서 프레임이 실제로 처음 바뀌기 직전에 한 번 호출된다(그냥 클릭이면 호출되지 않음).
    var onResizeWillChange: (() -> Void)?
    var onResizeEnded: (() -> Void)?

    private var startMouse: NSPoint = .zero
    private var startFrame: NSRect = .zero
    private var didChangeFrame = false
    private var resizeSymmetricMode = false

    init(region: HitRegion) {
        self.region = region
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isEnabled ? super.hitTest(point) : nil
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: region.cursor) }
    }

    /// 마우스 다운만으로는 결과를 지우지 않는다. 첫 실제 프레임 변경 직전에 onResizeWillChange를 부른다.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        startMouse = NSEvent.mouseLocation
        startFrame = window.frame
        didChangeFrame = false
        resizeSymmetricMode = event.modifierFlags.contains(.option)
        onResizeBegan?()
        region.cursor.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, let window else { return }
        let mouse = NSEvent.mouseLocation
        let symmetric = event.modifierFlags.contains(.option)
        /// Option을 누른 채 가장자리/모서리를 끌면 Mac의 대칭 크기 조절처럼 반대쪽 가장자리도
        /// 같은 양만큼 움직여 원래 중심을 유지한다. 대칭 모드가 끌기 도중 바뀌면 공식이 달라져
        /// 기존 스냅샷 기준 dx/dy로는 튀므로, 전환되는 순간 현재 창 프레임/마우스 위치로
        /// 스냅샷을 다시 잡아 그 지점부터 이어서 계산한다.
        if symmetric != resizeSymmetricMode {
            startFrame = window.frame
            startMouse = mouse
            resizeSymmetricMode = symmetric
        }
        let dx = mouse.x - startMouse.x
        let dy = mouse.y - startMouse.y
        let minSize = OverlayGeometry.minWindowSize
        var f = startFrame

        switch region {
        case .resizeLeft, .resizeTopLeft, .resizeBottomLeft:
            if symmetric {
                let width = max(minSize.width, startFrame.width - dx * 2)
                f.size.width = width
                f.origin.x = startFrame.midX - width / 2
            } else {
                f.size.width = max(minSize.width, startFrame.width - dx)
                f.origin.x = startFrame.maxX - f.size.width
            }
        case .resizeRight, .resizeTopRight, .resizeBottomRight:
            if symmetric {
                let width = max(minSize.width, startFrame.width + dx * 2)
                f.size.width = width
                f.origin.x = startFrame.midX - width / 2
            } else {
                f.size.width = max(minSize.width, startFrame.width + dx)
            }
        default:
            break
        }
        switch region {
        case .resizeBottom, .resizeBottomLeft, .resizeBottomRight:
            if symmetric {
                let height = max(minSize.height, startFrame.height - dy * 2)
                f.size.height = height
                f.origin.y = startFrame.midY - height / 2
            } else {
                f.size.height = max(minSize.height, startFrame.height - dy)
                f.origin.y = startFrame.maxY - f.size.height
            }
        case .resizeTop, .resizeTopLeft, .resizeTopRight:
            if symmetric {
                let height = max(minSize.height, startFrame.height + dy * 2)
                f.size.height = height
                f.origin.y = startFrame.midY - height / 2
            } else {
                f.size.height = max(minSize.height, startFrame.height + dy)
            }
        default:
            break
        }

        let target = f.integral
        if target != window.frame {
            if !didChangeFrame {
                didChangeFrame = true
                onResizeWillChange?()
            }
            window.setFrame(target, display: true)
        }
        region.cursor.set()
    }

    override func mouseUp(with event: NSEvent) {
        onResizeEnded?()
    }
}

/// 헤더(제목줄 + 툴바)의 중립 회색 배경. 윗모서리만 둥글게 테두리와 맞춘다.
final class HeaderBackgroundView: NSView {
    /// 마우스가 헤더 위에 없을 때의 옅은 알파. 올리면 1.0으로 또렷해진다.
    static let idleAlpha: CGFloat = 0.30
    static let hoverAlpha: CGFloat = 1.0

    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.22, alpha: 0.96).cgColor
        layer?.cornerRadius = OverlayGeometry.cornerRadius
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        appearance = NSAppearance(named: .darkAqua)
        // 창을 끌 때 내용은 전혀 바뀌지 않는데도, SwiftUI 툴바·제목줄·AIBI 숨김 표면이 각자
        // 레이어라서 WindowServer가 매 프레임 따로 합성한다. 이 서브트리를 한 번만 비트맵으로
        // 캐싱해(shouldRasterize) 비투명 창을 끄는 동안의 프레임당 합성 비용을 줄인다.
        // 캡처 영역(interiorView)은 번역 스트리밍 중 내용이 계속 바뀌므로 묶지 않는다.
        layer?.shouldRasterize = true
        layer?.rasterizationScale = NSScreen.main?.backingScaleFactor ?? 2
        alphaValue = Self.idleAlpha
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.rasterizationScale = window?.backingScaleFactor ?? layer?.rasterizationScale ?? 2
    }

    /// 헤더 전체(배경 + 그 위 제목줄 버튼들)에 대한 단일 트래킹 영역. 폴링·SwiftUI 상태 없이
    /// 네이티브 mouseEntered/mouseExited만으로 알파를 오간다. 끌기 중에도 창은 그대로 움직이고
    /// 버튼·메뉴·팝오버의 히트 테스트는 알파 변경과 무관하게 그대로 동작한다.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        alphaValue = Self.hoverAlpha
    }

    override func mouseExited(with event: NSEvent) {
        alphaValue = Self.idleAlpha
    }

    /// 툴바의 SwiftUI 컨트롤이 소비하지 않은 빈 곳 클릭이 여기로 오면 창을 이동한다.
    var isDragEnabled = true
    /// 실제로 움직이기 시작한 첫 끌기(HeaderDrag.track 내부)에서 한 번 호출된다(그냥 클릭이면 호출되지 않음).
    var onDragWillMove: (() -> Void)?
    var onDragFinished: (() -> Void)?
    /// 제목줄 빈 곳을 더블클릭했을 때 호출(겹쳐진 다른 앱 창에 맞추기).
    var onDoubleClick: (() -> Void)?
    /// 이 끌기가 놓인 자리에서 화면 꼭대기 맞추기나 Option 반쪽 맞추기로 스냅될 때 한 번 호출된다
    /// (원래 끌기 시작 프레임, 적용할 최종 프레임).
    var onSnapDrop: ((_ originalFrame: NSRect, _ target: NSRect) -> Void)?

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isDragEnabled, let window else { return }
        HeaderDrag.begin(from: event, in: window, onWillMove: onDragWillMove, onDoubleClick: onDoubleClick,
                         onSnapDrop: onSnapDrop)
        onDragFinished?()
    }
}

/// 헤더 전체가 한 줄로 된 제목/이동 스트립. 아이콘 버튼 외의 어디를 끌어도
/// HeaderDrag.track이 직접 추적하는 mouseDragged/mouseUp 루프로 창을 이동한다(이동·크기 잠금 시 비활성).
/// 왼쪽부터 닫기·전체화면 맞추기·맞추기 전 크기로, 가운데는 상태 문구만 보이는 빈 끌기 공간,
/// 오른쪽은 색상·고정(핀)·이동잠금(자물쇠)·주 버튼('번역' ↔ '원문보기')이다. 버튼들은 창 이동을
/// 가로채지 않도록 hitTest에서 직접 가로챈다.
final class TitleDragStripView: NSView {
    var isDragEnabled = true
    /// 실제로 움직이기 시작한 첫 끌기(HeaderDrag.track 내부)에서 한 번 호출된다(그냥 클릭이면 호출되지 않음).
    var onDragWillMove: (() -> Void)?
    var onDragFinished: (() -> Void)?
    /// 제목줄 빈 곳을 더블클릭했을 때 호출(겹쳐진 다른 앱 창에 맞추기).
    var onDoubleClick: (() -> Void)?
    /// 이 끌기가 놓인 자리에서 화면 꼭대기 맞추기나 Option 반쪽 맞추기로 스냅될 때 한 번 호출된다
    /// (원래 끌기 시작 프레임, 적용할 최종 프레임).
    var onSnapDrop: ((_ originalFrame: NSRect, _ target: NSRect) -> Void)?

    let closeButton: NSButton
    let fullDisplayButton: NSButton
    let restoreButton: NSButton
    let paletteButton: NSButton
    let pinButton: NSButton
    let lockButton: NSButton
    let primaryButton: NSButton
    let statusLabel = NSTextField(labelWithString: "")
    /// 외부 AI 답변 대기 남은 시간(1:59 → 0:00)을 줄어드는 막대로 보여준다. 그 외에는 숨긴다.
    let remainingBar = NSProgressIndicator()

    private static func iconButton(_ symbol: String, help: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: help) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: nil)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = NSColor(calibratedWhite: 0.85, alpha: 1)
        button.toolTip = help
        return button
    }

    override init(frame frameRect: NSRect) {
        closeButton = Self.iconButton("xmark.circle.fill", help: "창 숨기기 (Esc) — 메뉴 막대 아이콘이나 ⌃⌥⇧⌘T로 다시 열 수 있습니다")
        fullDisplayButton = Self.iconButton("arrow.up.left.and.arrow.down.right", help: "메뉴 막대와 Dock을 제외한 화면에 맞추기")
        restoreButton = Self.iconButton("arrow.uturn.backward", help: "맞추기 전 크기로")
        paletteButton = Self.iconButton("paintpalette", help: "번역문 글자색·배경색·진하기 설정")
        pinButton = Self.iconButton("pin.fill", help: "항상 위에 고정 (기본 켜짐)")
        lockButton = Self.iconButton("lock.open", help: "이동·크기 잠금: 켜면 창 이동과 가장자리 크기 조절만 막힙니다")
        primaryButton = NSButton(title: "번역", target: nil, action: nil)
        super.init(frame: frameRect)

        primaryButton.bezelStyle = .rounded
        primaryButton.controlSize = .mini
        primaryButton.font = .systemFont(ofSize: 10, weight: .semibold)
        primaryButton.imageScaling = .scaleProportionallyDown
        primaryButton.toolTip = "현재 영역을 한 번 캡처해 인식·번역합니다 (Space 또는 Enter)"
        primaryButton.bezelColor = .systemBlue
        primaryButton.contentTintColor = .white

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = NSColor(calibratedWhite: 0.78, alpha: 1)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.cell?.truncatesLastVisibleLine = true

        remainingBar.style = .bar
        remainingBar.isIndeterminate = false
        remainingBar.controlSize = .small
        remainingBar.minValue = 0
        remainingBar.maxValue = 1
        remainingBar.isHidden = true

        [closeButton, fullDisplayButton, restoreButton, statusLabel, remainingBar,
         paletteButton, pinButton, lockButton, primaryButton].forEach(addSubview)
        toolTip = "이 줄의 빈 곳을 끌어 창을 이동합니다 (이동·크기 잠금 시 이동 불가). 더블클릭하면 겹쳐진 다른 앱 창의 크기에 맞춥니다"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let h = bounds.height
        let iconSize: CGFloat = 14
        func centeredIconFrame(x: CGFloat) -> NSRect {
            NSRect(x: x, y: (h - iconSize) / 2, width: iconSize, height: iconSize)
        }

        closeButton.frame = centeredIconFrame(x: 12)
        fullDisplayButton.frame = centeredIconFrame(x: closeButton.frame.maxX + 8)
        restoreButton.frame = centeredIconFrame(x: fullDisplayButton.frame.maxX + 8)
        let leftEnd = restoreButton.frame.maxX + 10

        primaryButton.sizeToFit()
        let buttonWidth = max(44, primaryButton.frame.width)
        let primaryFrame = NSRect(x: bounds.width - buttonWidth - 10,
                                  y: (h - primaryButton.frame.height) / 2,
                                  width: buttonWidth,
                                  height: primaryButton.frame.height)
        primaryButton.frame = primaryFrame

        var trailingX = primaryFrame.minX - 8
        for button in [lockButton, pinButton, paletteButton] {
            trailingX -= iconSize
            button.frame = centeredIconFrame(x: trailingX)
            trailingX -= 8
        }

        var rightEnd = trailingX
        if !remainingBar.isHidden {
            let barWidth: CGFloat = 60
            rightEnd -= barWidth
            remainingBar.frame = NSRect(x: rightEnd, y: (h - 10) / 2, width: barWidth, height: 10)
            rightEnd -= 8
        }
        let statusHeight = statusLabel.intrinsicContentSize.height
        let statusWidth = max(0, rightEnd - leftEnd)
        statusLabel.frame = NSRect(x: leftEnd, y: (h - statusHeight) / 2, width: statusWidth, height: statusHeight)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        for button in [closeButton, fullDisplayButton, restoreButton, paletteButton, lockButton, pinButton, primaryButton]
        where button.frame.contains(local) {
            return button
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard isDragEnabled, let window else { return }
        HeaderDrag.begin(from: event, in: window, onWillMove: onDragWillMove, onDoubleClick: onDoubleClick,
                         onSnapDrop: onSnapDrop)
        onDragFinished?()
    }
}
