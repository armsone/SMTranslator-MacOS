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
/// 마우스 이벤트는 전혀 받지 않는다(히트 영역은 ResizeHandleView/헤더가 담당).
final class OverlayBorderView: NSView {
    private static let glowColor = NSColor(srgbRed: 0.36, green: 0.68, blue: 1.0, alpha: 0.85)

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = OverlayGeometry.strokeWidth / 2
        let rect = OverlayGeometry.frameRect(in: bounds).insetBy(dx: inset, dy: inset)
        let radius = OverlayGeometry.cornerRadius
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.lineWidth = OverlayGeometry.strokeWidth

        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = Self.glowColor
        glow.shadowBlurRadius = 8
        glow.shadowOffset = .zero
        glow.set()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // 글로우 위에 선명한 흰 선을 한 번 더 그린다.
        NSColor.white.setStroke()
        path.stroke()

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

/// 크기 조절 전용 투명 히트 뷰. 마우스 다운 시점의 창 프레임/마우스 위치 스냅샷과
/// 이후 이동량만으로 새 프레임을 계산한다(OCR·레이아웃 재계산 없음).
final class ResizeHandleView: NSView {
    let region: HitRegion
    var isEnabled = true
    var onResizeBegan: (() -> Void)?
    var onResizeEnded: (() -> Void)?

    private var startMouse: NSPoint = .zero
    private var startFrame: NSRect = .zero

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

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        startMouse = NSEvent.mouseLocation
        startFrame = window.frame
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

        if f != window.frame {
            window.setFrame(f.integral, display: true)
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 툴바의 SwiftUI 컨트롤이 소비하지 않은 빈 곳 클릭이 여기로 오면 창을 이동한다.
    var isDragEnabled = true
    var onDragFinished: (() -> Void)?

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isDragEnabled, let window else { return }
        window.performDrag(with: event)
        onDragFinished?()
    }
}

/// 헤더 맨 위 전체 너비의 제목/이동 스트립. 닫기(숨기기) 버튼 외의 어디를 눌러도
/// 네이티브 NSWindow.performDrag(with:)로 창을 이동한다(이동·크기 잠금 시 비활성).
final class TitleDragStripView: NSView {
    var isDragEnabled = true
    var onDragFinished: (() -> Void)?

    let closeButton: NSButton
    private let titleLabel = NSTextField(labelWithString: "화면 번역기")
    let statusLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        let image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "창 숨기기") ?? NSImage()
        closeButton = NSButton(image: image, target: nil, action: nil)
        super.init(frame: frameRect)

        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.contentTintColor = NSColor(calibratedWhite: 0.85, alpha: 1)
        closeButton.toolTip = "창 숨기기 (Esc) — 메뉴 막대 아이콘이나 ⌃⌥⇧⌘T로 다시 열 수 있습니다"

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = NSColor(calibratedWhite: 0.78, alpha: 1)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.cell?.truncatesLastVisibleLine = true

        [closeButton, titleLabel, statusLabel].forEach(addSubview)
        toolTip = "이 줄이나 툴바 위 빈 곳을 끌어 창을 이동합니다 (이동·크기 잠금 시 이동 불가)"
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
        let statusX = titleLabel.frame.maxX + 10
        let statusHeight = statusLabel.intrinsicContentSize.height
        statusLabel.frame = NSRect(x: statusX, y: (h - statusHeight) / 2, width: max(0, bounds.width - statusX - 12), height: statusHeight)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if closeButton.frame.contains(local) { return closeButton }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard isDragEnabled, let window else { return }
        window.performDrag(with: event)
        onDragFinished?()
    }
}
