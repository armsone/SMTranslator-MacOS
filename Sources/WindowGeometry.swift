import AppKit
import ApplicationServices
import CoreGraphics

/// 화면 번역 창을 화면·다른 앱 창 크기에 맞추기 위한 읽기 전용 기하 계산.
/// - 다른 앱 창 목록은 CGWindowListCopyWindowInfo(공개 CoreGraphics API)로 '창 번호·소유 PID·레이어·알파·경계'만 읽는다.
///   창 제목·소유 앱 이름 키는 읽지 않고, 결과는 호출한 동작(메뉴 한 번, Shift 끌기 한 번) 동안 메모리에만 두며
///   저장·기록·전송하지 않는다. 스크린샷을 찍지 않으며 손쉬운 사용 등 새 권한을 요청하지 않는다.
///   Shift 끌기를 놓을 때의 읽기 영역 보정만 이미 허용된 손쉬운 사용 권한으로 요소 위치·크기를 읽는다(ContentPaneResolver).
/// - 이 목록 조회는 비용이 크므로 끌기의 마우스 이벤트마다 부르지 않는다(호출 측이 동작당 한 번만 부름).
/// - kCGWindowBounds는 주 디스플레이(CGMainDisplayID, 메뉴 막대가 있는 물리 디스플레이) 왼쪽 위 원점 좌표다.
///   AppKit 전역 좌표(같은 디스플레이 왼쪽 아래 원점)로 바꿀 때 NSScreen.main(키 창이 있는 화면, 바뀜)이 아니라
///   CGMainDisplayID와 일치하는 NSScreen의 높이를 기준으로 쓴다. 음수 좌표의 보조 디스플레이도 같은 식으로 맞는다.
@MainActor
enum WindowGeometry {
    /// 다른 앱의 보이는 일반 창 하나(AppKit 전역 좌표). 앞→뒤 순서 목록의 원소로만 쓴다.
    struct Candidate {
        let id: CGWindowID
        /// 소유 프로세스 번호. Shift 끌기를 놓을 때 본문 영역 보정(ContentPaneResolver)에만 쓴다.
        let pid: pid_t
        let frame: NSRect
    }

    /// 너무 작은 창(툴팁·잔여 조각 등)은 맞출 대상에서 뺀다.
    private static let minCandidateSize: CGFloat = 40

    /// 다른 앱의 화면에 보이는 일반(레이어 0) 창을 앞→뒤 순서로 한 번 읽는다.
    /// 이 앱의 모든 창(같은 PID), 데스크톱 요소, 메뉴 막대·Dock·떠 있는 패널 같은 비일반 레이어,
    /// 완전히 투명한 창, 경계가 잘못됐거나 어느 화면과도 겹치지 않는 창은 뺀다.
    static func otherAppWindows() -> [Candidate] {
        guard let primaryHeight = primaryDisplayHeight(),
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let screenFrames = NSScreen.screens.map(\.frame)
        var result: [Candidate] = []
        for info in list {
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            if let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha <= 0 { continue }
            guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
                  bounds.width.isFinite, bounds.height.isFinite,
                  bounds.width >= minCandidateSize, bounds.height >= minCandidateSize else { continue }
            let frame = NSRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            guard screenFrames.contains(where: { $0.intersects(frame) }) else { continue }
            result.append(Candidate(id: number, pid: pid, frame: frame))
        }
        return result
    }

    /// CGMainDisplayID(전역 좌표 원점 디스플레이)의 높이(pt). AppKit 주 화면 frame은 원점이 (0, 0)이다.
    private static func primaryDisplayHeight() -> CGFloat? {
        let mainID = CGMainDisplayID()
        if let screen = NSScreen.screens.first(where: { displayID(of: $0) == mainID }) {
            return screen.frame.height
        }
        let bounds = CGDisplayBounds(mainID)
        return bounds.height > 0 ? bounds.height : nil
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    // MARK: - 화면 선택·맞추기

    /// 점이 들어 있는 화면
    static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    /// 사각형과 사용 가능 영역이 가장 많이 겹치는 화면(겹치지 않으면 nil)
    static func screen(mostOverlapping rect: NSRect) -> NSScreen? {
        func overlap(_ screen: NSScreen) -> CGFloat {
            let r = screen.visibleFrame.intersection(rect)
            return r.isNull ? 0 : r.width * r.height
        }
        guard let best = NSScreen.screens.max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 else { return nil }
        return best
    }

    /// 한 화면의 사용 가능 영역(visibleFrame, 메뉴 막대·Dock 제외) 안으로 크기·위치를 맞춘다.
    /// 최소 크기보다는 작게 줄이지 않으며, 그래도 넘치면 위쪽(헤더)이 보이도록 위·왼쪽에 맞춘다.
    static func clamp(_ frame: NSRect, into visible: NSRect) -> NSRect {
        let minSize = OverlayGeometry.minWindowSize
        var f = frame
        f.size.width = max(minSize.width, min(f.width, visible.width))
        f.size.height = max(minSize.height, min(f.height, visible.height))
        f.origin.x = max(visible.minX, min(f.minX, visible.maxX - f.width))
        f.origin.y = min(visible.maxY - f.height, max(f.minY, visible.minY))
        return f.integral
    }

    /// 대상 창 경계(바깥 프레임 기준)에 맞춘 오버레이 프레임. 대상이 여러 화면에 걸치면 기준 점(포인터 등)이 있는
    /// 화면을, 그 화면과 겹치지 않으면 가장 많이 겹치는 화면을 고른 뒤 그 화면의 사용 가능 영역으로 잘라 한 화면 안에
    /// 둔다(캡처는 한 디스플레이 안의 영역만 허용). 최소 크기보다 작은 대상은 중심을 유지한 채 최소 크기로 키운다.
    static func fittedFrame(for target: NSRect, preferring point: NSPoint? = nil) -> NSRect? {
        let pointScreen = point.flatMap { screen(containing: $0) }
        let screen = pointScreen.flatMap { $0.visibleFrame.intersects(target) ? $0 : nil } ?? screen(mostOverlapping: target)
        guard let visible = screen?.visibleFrame, !visible.isEmpty else { return nil }
        var f = target.intersection(visible)
        guard !f.isNull, !f.isEmpty else { return nil }
        let minSize = OverlayGeometry.minWindowSize
        if f.width < minSize.width {
            f.origin.x = f.midX - minSize.width / 2
            f.size.width = minSize.width
        }
        if f.height < minSize.height {
            f.origin.y = f.midY - minSize.height / 2
            f.size.height = minSize.height
        }
        return clamp(f, into: visible)
    }

    // MARK: - 읽기 영역(본문 창) 보정

    /// AppKit 전역 포인터·창 경계를 손쉬운 사용 API가 쓰는 주 디스플레이 왼쪽 위 원점 좌표로 바꾼 보정 요청.
    static func paneQuery(pid: pid_t, pointer: NSPoint, windowFrame: NSRect) -> ContentPaneResolver.Query? {
        guard let h = primaryDisplayHeight() else { return nil }
        return ContentPaneResolver.Query(
            pid: pid,
            point: CGPoint(x: pointer.x, y: h - pointer.y),
            windowBounds: CGRect(x: windowFrame.minX, y: h - windowFrame.maxY, width: windowFrame.width, height: windowFrame.height))
    }

    /// 주 디스플레이 왼쪽 위 원점 사각형 → AppKit 전역 좌표
    static func appKitRect(fromTopLeft rect: CGRect) -> NSRect? {
        guard let h = primaryDisplayHeight() else { return nil }
        return NSRect(x: rect.minX, y: h - rect.maxY, width: rect.width, height: rect.height)
    }

    /// 읽기 영역에 맞춘 오버레이 프레임. 캡처 영역(인터리어)이 읽기 영역과 겹치도록 헤더를 그 위쪽에 둔다.
    /// 그렇게 둘 자리가 화면 사용 가능 영역 안에 없으면(읽기 영역이 화면 위끝에 붙은 경우 등) 창 맞추기와 같은 방식으로
    /// 바깥 프레임을 읽기 영역에 맞춘다. 최소 크기(620×220)보다 작은 영역에는 정확히 맞지 않고 중심을 유지한 채 커진다.
    static func paneFittedFrame(for pane: NSRect, preferring point: NSPoint?) -> NSRect? {
        let g = OverlayGeometry.glowMargin
        let s = OverlayGeometry.strokeWidth
        let outer = NSRect(x: pane.minX - g - s, y: pane.minY - g - s,
                           width: pane.width + (g + s) * 2,
                           height: pane.height + g * 2 + s + OverlayGeometry.headerHeight)
        let pointScreen = point.flatMap { screen(containing: $0) }
        if let visible = (pointScreen ?? screen(mostOverlapping: outer))?.visibleFrame, visible.contains(outer) {
            return fittedFrame(for: outer, preferring: point)
        }
        return fittedFrame(for: pane, preferring: point)
    }
}

/// Shift 끌기를 놓은 지점의 '읽기 영역'(예: Mail 본문 창)을 손쉬운 사용 API로 한 번 찾는다. 메인 스레드 밖에서 실행한다.
/// - 이미 허용된 손쉬운 사용 권한이 있을 때만 동작한다(AXIsProcessTrusted, 권한 요청 대화상자를 띄우는 호출은 쓰지 않음).
/// - 대상 앱 요소(AXUIElementCreateApplication)에서 AXUIElementCopyElementAtPosition으로 그 앱의 요소만 찾으므로
///   위에 떠 있는 이 앱 창이 가로채지 않는다. 그 뒤 부모를 따라 올라가며 역할·부모·위치·크기만 읽는다.
///   값·제목·설명·문서 주소·텍스트·선택 내용·자식 목록은 읽지 않으며, 결과는 기록·저장·전송하지 않는다.
/// - 웹 본문(AXWebArea)이나 텍스트 영역(AXTextArea)을 지난 뒤 만나는 충분히 큰 스크롤 영역(보이는 창)을 읽기 영역으로 고른다.
///   메일 목록·사이드바·버튼처럼 본문 요소가 없는 곳, 지원하지 않는 앱, 실패·시간 초과는 nil(창 전체 맞추기 유지)이다.
/// - 요소마다 메시지 시간 제한을 짧게 두고, 올라가는 깊이와 전체 시간도 제한한다.
enum ContentPaneResolver {
    struct Query {
        let pid: pid_t
        /// 주 디스플레이 왼쪽 위 원점 좌표
        let point: CGPoint
        let windowBounds: CGRect
    }

    private static let messagingTimeout: Float = 0.15
    private static let maxDepth = 14
    private static let timeBudget: TimeInterval = 0.5
    private static let minPaneSize = CGSize(width: 160, height: 100)
    private static let contentRoles: Set<String> = ["AXWebArea", kAXTextAreaRole as String]
    private static let stopRoles: Set<String> = [kAXWindowRole as String, kAXSheetRole as String, kAXApplicationRole as String]

    /// 읽기 영역(주 디스플레이 왼쪽 위 원점, 대상 창 경계 안으로 자름). 찾지 못하면 nil.
    static func resolve(_ query: Query) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let deadline = Date().addingTimeInterval(timeBudget)
        let app = AXUIElementCreateApplication(query.pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(query.point.x), Float(query.point.y), &hit) == .success,
              var element = hit else { return nil }
        var content: CGRect?
        for _ in 0..<maxDepth {
            guard Date() < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            guard let role = copy(element, kAXRoleAttribute) as? String, !stopRoles.contains(role) else { break }
            if contentRoles.contains(role) {
                content = rect(element) ?? content
            } else if role == kAXScrollAreaRole as String, content != nil,
                      let pane = rect(element).map({ $0.intersection(query.windowBounds) }),
                      isUsable(pane, for: query) {
                return pane
            }
            guard let parent = copy(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            element = parent as! AXUIElement
        }
        // 스크롤 영역으로 감싸이지 않은 본문은 그 본문 경계를 대상 창 안으로 잘라 쓴다.
        if let pane = content?.intersection(query.windowBounds), isUsable(pane, for: query) { return pane }
        return nil
    }

    /// 포인터를 품고, 너무 작지 않으며, 사실상 창 전체(보정 의미 없음)가 아닌 영역만 쓴다.
    private static func isUsable(_ pane: CGRect, for query: Query) -> Bool {
        guard !pane.isNull, pane.width >= minPaneSize.width, pane.height >= minPaneSize.height,
              pane.contains(query.point) else { return false }
        let window = query.windowBounds
        return pane.width * pane.height < window.width * window.height * 0.95
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private static func rect(_ element: AXUIElement) -> CGRect? {
        guard let p = copy(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = copy(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size),
              point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite else { return nil }
        return CGRect(origin: point, size: size)
    }
}
