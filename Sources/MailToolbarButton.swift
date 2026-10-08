import AppKit
import ApplicationServices

/// Mail 소유의 NSToolbar를 변경하지 않는다. 비활성 패널을 도구막대 빈 공간에 배치한다.
/// 접근성에서는 창/도구막대의 위치와 크기만 읽으며 메시지 내용은 읽지 않는다.
@MainActor
final class MailToolbarButton: NSObject, NSWindowDelegate {
    static let shared = MailToolbarButton()
    private let preference = "attachedMailTranslationButton"
    private var timer: Timer?
    private var panel: NSPanel?
    private var manualFrame: NSRect?
    private var manualMode = false
    private var isDragging = false
    private let manualPreference = "mailTranslationButtonManualPosition"
    private let framePreference = "mailTranslationButtonManualFrame"
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: preference) }

    func enable() {
        let alert = NSAlert()
        alert.messageText = "메일 상단에 번역 버튼 붙이기"
        alert.informativeText = "Mail을 볼 때 표시되는 별도 번역 버튼입니다. 왼쪽 손잡이를 끌어 원하는 상단 위치에 놓을 수 있습니다. 위치는 기억됩니다. 이미 손쉬운 사용 권한이 연결돼 있으면 도구막대 빈 공간을 따라갑니다. 권한이 없어도 수동 위치에서 표시되며, 이 버튼은 권한 요청이나 시스템 설정 변경을 하지 않습니다. Mail의 정식 도구막대 항목은 아닙니다."
        alert.addButton(withTitle: "버튼 켜기")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        UserDefaults.standard.set(true, forKey: preference)
        start()
    }

    func resumeIfEnabled() { if isEnabled { start() } }
    func disable() {
        UserDefaults.standard.set(false, forKey: preference)
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    private func start() {
        guard timer == nil else { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 98, height: 28),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.title = "Mail 번역 버튼"
        p.delegate = self
        p.isMovable = true
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 98, height: 28))
        let handle = MailTranslationDragHandle(frame: NSRect(x: 0, y: 0, width: 20, height: 28))
        handle.toolTip = "끌어서 번역 버튼 위치 옮기기"
        handle.setAccessibilityLabel("번역 버튼 위치 손잡이")
        handle.beginDrag = { [weak self] in
            guard let self else { return }
            self.manualMode = true
            self.isDragging = true
            self.manualFrame = self.panel?.frame
            UserDefaults.standard.set(true, forKey: self.manualPreference)
        }
        handle.endDrag = { [weak self] in
            guard let self, let panel = self.panel else { return }
            self.manualFrame = panel.frame
            UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: self.framePreference)
            self.isDragging = false
        }
        content.addSubview(handle)
        let button = MovableMailTranslationButton(title: "번역", image: NSImage(systemSymbolName: "translate", accessibilityDescription: "선택한 메일 번역") ?? NSImage(), target: self, action: #selector(translate))
        button.frame = NSRect(x: 20, y: 0, width: 78, height: 28)
        button.bezelStyle = .rounded
        button.imagePosition = .imageLeading
        button.beginDrag = handle.beginDrag
        button.endDrag = handle.endDrag
        button.toolTip = "클릭: 선택한 메일 번역 · 끌기: 이 버튼 위치 이동"
        button.setAccessibilityIdentifier("mail-translation-overlay-button")
        content.addSubview(button)
        p.contentView = content
        panel = p
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePosition() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        updatePosition()
    }

    @objc private func translate() {
        panel?.orderOut(nil)
        AppModel.shared.translateSelectedMail()
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }
    private func rect(_ element: AXUIElement) -> CGRect? {
        guard let p = value(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = value(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    private func children(_ element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    func windowDidMove(_ notification: Notification) {
        guard manualMode, let panel, notification.object as? NSWindow === panel else { return }
        manualFrame = panel.frame
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: framePreference)
    }

    private func showManual(_ panel: NSPanel) {
        manualMode = true
        if manualFrame == nil {
            if let saved = UserDefaults.standard.string(forKey: framePreference) {
                let frame = NSRectFromString(saved)
                if frame.width == 98, frame.height == 28, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) { manualFrame = frame }
            }
            if manualFrame == nil, let screen = NSScreen.main ?? NSScreen.screens.first {
                let area = screen.visibleFrame
                manualFrame = NSRect(x: area.midX - 49, y: area.maxY - 38, width: 98, height: 28)
            }
        }
        guard var frame = manualFrame else { panel.orderOut(nil); return }
        let screens = NSScreen.screens
        if let screen = screens.max(by: {
            $0.visibleFrame.intersection(frame).width * $0.visibleFrame.intersection(frame).height <
            $1.visibleFrame.intersection(frame).width * $1.visibleFrame.intersection(frame).height
        }) {
            let area = screen.visibleFrame
            frame.origin.x = min(max(frame.minX, area.minX), area.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, area.minY), area.maxY - frame.height)
            manualFrame = frame
            UserDefaults.standard.set(NSStringFromRect(frame), forKey: framePreference)
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        panel.orderFrontRegardless()
    }

    private func updatePosition() {
        guard !isDragging else { return }
        guard isEnabled,
              let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == "com.apple.mail",
              let panel, let primary = NSScreen.screens.first else { panel?.orderOut(nil); return }
        guard AXIsProcessTrusted(), !UserDefaults.standard.bool(forKey: manualPreference) else { showManual(panel); return }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        guard let raw = value(app, kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            showManual(panel); return
        }
        let window = raw as! AXUIElement
        let items = children(window)
        guard !(value(window, kAXMinimizedAttribute) as? Bool ?? false),
              !items.contains(where: { value($0, kAXRoleAttribute) as? String == kAXSheetRole }),
              let toolbar = items.first(where: { value($0, kAXRoleAttribute) as? String == kAXToolbarRole }),
              let bounds = rect(toolbar), bounds.width > 100 else { showManual(panel); return }
        // 자동 배치할 빈 공간이 없으면 사용자가 옮길 수 있는 수동 위치를 유지한다.
        let occupied = children(toolbar).compactMap { rect($0) }.filter { $0.width > 0 && $0.intersects(bounds) }.sorted { $0.minX < $1.minX }
        var cursor = bounds.minX + 8
        var gaps: [CGRect] = []
        for r in occupied {
            if r.minX - cursor >= 110 { gaps.append(CGRect(x: cursor, y: bounds.minY, width: r.minX - cursor, height: bounds.height)) }
            cursor = max(cursor, r.maxX + 8)
        }
        if bounds.maxX - 8 - cursor >= 110 { gaps.append(CGRect(x: cursor, y: bounds.minY, width: bounds.maxX - 8 - cursor, height: bounds.height)) }
        guard let gap = gaps.last else { showManual(panel); return }
        manualMode = false
        let x = gap.maxX - 104
        let y = primary.frame.maxY - bounds.midY - 14
        panel.setFrame(NSRect(x: x, y: y, width: 98, height: 28), display: true)
        panel.orderFrontRegardless()
    }
}


/// Moves only this application's own panel; does not inspect another window.
private final class MailButtonDrag {
    private var mouse: NSPoint?
    private var origin = NSPoint.zero
    func begin(_ window: NSWindow?) {
        guard let window else { return }
        mouse = NSEvent.mouseLocation
        origin = window.frame.origin
    }
    func move(_ window: NSWindow?) {
        guard let mouse, let window else { return }
        let now = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: origin.x + now.x - mouse.x, y: origin.y + now.y - mouse.y))
    }
    func end() { mouse = nil }
}

private final class MailTranslationDragHandle: NSView {
    var beginDrag: (() -> Void)?
    var endDrag: (() -> Void)?
    private let drag = MailButtonDrag()
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { beginDrag?(); drag.begin(window) }
    override func mouseDragged(with event: NSEvent) { drag.move(window) }
    override func mouseUp(with event: NSEvent) { drag.move(window); drag.end(); endDrag?() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setFill()
        for y in [CGFloat(9), CGFloat(14), CGFloat(19)] {
            NSBezierPath(ovalIn: NSRect(x: 8, y: y - 1, width: 3, height: 3)).fill()
        }
    }
}

private final class MovableMailTranslationButton: NSButton {
    var beginDrag: (() -> Void)?
    var endDrag: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let startMouse = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        var moved = false
        // NSButton's default tracking consumes dragged events. Track this exact
        // button ourselves so an ordinary drag moves it and a click translates.
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let now = NSEvent.mouseLocation
            let dx = now.x - startMouse.x
            let dy = now.y - startMouse.y
            if !moved && hypot(dx, dy) >= 4 {
                moved = true
                beginDrag?()
            }
            if moved {
                window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
            }
            if next.type == .leftMouseUp {
                if moved { endDrag?() }
                else if let action, bounds.contains(convert(next.locationInWindow, from: nil)) {
                    NSApp.sendAction(action, to: target, from: self)
                }
                break
            }
        }
    }
}
