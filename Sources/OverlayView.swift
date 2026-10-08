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
    static let glowMargin: CGFloat = 10
    static let cornerRadius: CGFloat = 12
    static let strokeWidth: CGFloat = 1.5
    static let resizeBand: CGFloat = 8
    static let topResizeStrip: CGFloat = 6
    static let titleStripHeight: CGFloat = 20
    static let toolbarHeight: CGFloat = 32
    static let cornerHitSize: CGFloat = 18
    static var headerHeight: CGFloat { topResizeStrip + titleStripHeight + toolbarHeight }
    /// 툴바 컨트롤이 잘리지 않는 최소 크기(창 전체 기준)
    static let minWindowSize = NSSize(width: 620, height: 220)

    /// 둥근 테두리 사각형(시각적 창 본체)
    static func frameRect(in bounds: NSRect) -> NSRect {
        bounds.insetBy(dx: glowMargin, dy: glowMargin)
    }

    static func headerRect(in bounds: NSRect) -> NSRect {
        let f = frameRect(in: bounds)
        return NSRect(x: f.minX, y: f.maxY - headerHeight, width: f.width, height: headerHeight)
    }

    /// 캡처 영역(헤더 아래, 테두리 안쪽). 이 영역만 캡처하고 번역 패치를 그린다.
    static func interiorRect(in bounds: NSRect) -> NSRect {
        let f = frameRect(in: bounds)
        return NSRect(
            x: f.minX + strokeWidth,
            y: f.minY + strokeWidth,
            width: max(1, f.width - strokeWidth * 2),
            height: max(1, f.height - headerHeight - strokeWidth)
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
    private static let verticalCap: CGFloat = OverlayGeometry.glowMargin + OverlayGeometry.headerHeight + 2
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
enum HeaderDrag {
    @MainActor
    static func begin(from mouseDown: NSEvent, in window: NSWindow, onWillMove: (() -> Void)?,
                      onDoubleClick: (() -> Void)?) {
        if mouseDown.clickCount == 2 {
            onDoubleClick?()
            return
        }
        track(from: mouseDown, in: window, onWillMove: onWillMove)
    }

    @MainActor
    static func track(from mouseDown: NSEvent, in window: NSWindow, onWillMove: (() -> Void)?) {
        let start = window.convertPoint(toScreen: mouseDown.locationInWindow)
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            guard event.type == .leftMouseDragged else { return }
            let point = window.convertPoint(toScreen: event.locationInWindow)
            guard point != start else { continue }
            onWillMove?()
            // performDrag(with:)는 파라미터가 마우스 다운 "원본" 이벤트여야 한다는 API 계약 때문에 mouseDown을 그대로 넘긴다.
            window.performDrag(with: mouseDown)
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
        onResizeBegan?()
        region.cursor.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, let window else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - startMouse.x
        let dy = mouse.y - startMouse.y
        let minSize = OverlayGeometry.minWindowSize
        var f = startFrame

        switch region {
        case .resizeLeft, .resizeTopLeft, .resizeBottomLeft:
            f.size.width = max(minSize.width, startFrame.width - dx)
            f.origin.x = startFrame.maxX - f.size.width
        case .resizeRight, .resizeTopRight, .resizeBottomRight:
            f.size.width = max(minSize.width, startFrame.width + dx)
        default:
            break
        }
        switch region {
        case .resizeBottom, .resizeBottomLeft, .resizeBottomRight:
            f.size.height = max(minSize.height, startFrame.height - dy)
            f.origin.y = startFrame.maxY - f.size.height
        case .resizeTop, .resizeTopLeft, .resizeTopRight:
            f.size.height = max(minSize.height, startFrame.height + dy)
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.rasterizationScale = window?.backingScaleFactor ?? layer?.rasterizationScale ?? 2
    }

    /// 툴바의 SwiftUI 컨트롤이 소비하지 않은 빈 곳 클릭이 여기로 오면 창을 이동한다.
    var isDragEnabled = true
    /// 실제로 움직이기 시작한 첫 끌기에서 performDrag(with:) 직전에 한 번 호출된다(그냥 클릭이면 호출되지 않음).
    var onDragWillMove: (() -> Void)?
    var onDragFinished: (() -> Void)?
    /// 제목줄 빈 곳을 더블클릭했을 때 호출(겹쳐진 다른 앱 창에 맞추기).
    var onDoubleClick: (() -> Void)?

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isDragEnabled, let window else { return }
        HeaderDrag.begin(from: event, in: window, onWillMove: onDragWillMove, onDoubleClick: onDoubleClick)
        onDragFinished?()
    }
}

/// 헤더 맨 위 전체 너비의 제목/이동 스트립. 닫기(숨기기)·주 버튼 외의 어디를 끌어도
/// 네이티브 NSWindow.performDrag(with:)로 창을 이동한다(HeaderDrag, 이동·크기 잠금 시 비활성).
/// 주 버튼('번역' ↔ '원문보기')은 단축키(Space/Enter)가 있어 작게 두며, 창 이동을
/// 가로채지 않도록 closeButton과 같은 방식으로 hitTest에서 직접 가로챈다.
final class TitleDragStripView: NSView {
    var isDragEnabled = true
    /// 실제로 움직이기 시작한 첫 끌기에서 performDrag(with:) 직전에 한 번 호출된다(그냥 클릭이면 호출되지 않음).
    var onDragWillMove: (() -> Void)?
    var onDragFinished: (() -> Void)?
    /// 제목줄 빈 곳을 더블클릭했을 때 호출(겹쳐진 다른 앱 창에 맞추기).
    var onDoubleClick: (() -> Void)?

    let closeButton: NSButton
    let primaryButton: NSButton
    private let titleLabel = NSTextField(labelWithString: "스크린 메일 번역기")
    let statusLabel = NSTextField(labelWithString: "")
    /// 외부 AI 답변 대기 남은 시간(1:59 → 0:00)을 줄어드는 막대로 보여준다. 그 외에는 숨긴다.
    let remainingBar = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        let image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "창 숨기기") ?? NSImage()
        closeButton = NSButton(image: image, target: nil, action: nil)
        primaryButton = NSButton(title: "번역", target: nil, action: nil)
        super.init(frame: frameRect)

        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.contentTintColor = NSColor(calibratedWhite: 0.85, alpha: 1)
        closeButton.toolTip = "창 숨기기 (Esc) — 메뉴 막대 아이콘이나 ⌃⌥⇧⌘T로 다시 열 수 있습니다"

        primaryButton.bezelStyle = .rounded
        primaryButton.controlSize = .mini
        primaryButton.font = .systemFont(ofSize: 10, weight: .semibold)
        primaryButton.imageScaling = .scaleProportionallyDown
        primaryButton.toolTip = "현재 영역을 한 번 캡처해 인식·번역합니다 (Space 또는 Enter)"
        primaryButton.bezelColor = .systemBlue
        primaryButton.contentTintColor = .white

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedWhite: 0.92, alpha: 1)
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

        [closeButton, titleLabel, statusLabel, remainingBar, primaryButton].forEach(addSubview)
        toolTip = "이 줄이나 툴바 위 빈 곳을 끌어 창을 이동합니다 (이동·크기 잠금 시 이동 불가). 더블클릭하면 겹쳐진 다른 앱 창의 크기에 맞춥니다"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let h = bounds.height
        let x0: CGFloat = 12
        closeButton.frame = NSRect(x: x0, y: (h - 14) / 2, width: 14, height: 14)
        titleLabel.sizeToFit()
        titleLabel.frame.origin = NSPoint(x: closeButton.frame.maxX + 8, y: (h - titleLabel.frame.height) / 2)

        primaryButton.sizeToFit()
        let buttonWidth = max(44, primaryButton.frame.width)
        let buttonFrame = NSRect(x: bounds.width - buttonWidth - 10,
                                  y: (h - primaryButton.frame.height) / 2,
                                  width: buttonWidth,
                                  height: primaryButton.frame.height)
        primaryButton.frame = buttonFrame

        var trailingX = buttonFrame.minX
        if !remainingBar.isHidden {
            let barWidth: CGFloat = 60
            remainingBar.frame = NSRect(x: trailingX - 8 - barWidth, y: (h - 10) / 2, width: barWidth, height: 10)
            trailingX = remainingBar.frame.minX
        }
        let statusX = titleLabel.frame.maxX + 10
        let statusHeight = statusLabel.intrinsicContentSize.height
        let statusWidth = max(0, trailingX - 8 - statusX)
        statusLabel.frame = NSRect(x: statusX, y: (h - statusHeight) / 2, width: statusWidth, height: statusHeight)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if closeButton.frame.contains(local) { return closeButton }
        if primaryButton.frame.contains(local) { return primaryButton }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard isDragEnabled, let window else { return }
        HeaderDrag.begin(from: event, in: window, onWillMove: onDragWillMove, onDoubleClick: onDoubleClick)
        onDragFinished?()
    }
}
