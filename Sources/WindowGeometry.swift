import AppKit
import CoreGraphics

/// 화면 번역 창을 화면·다른 앱 창 크기에 맞추기 위한 읽기 전용 기하 계산.
/// - 다른 앱 창 목록은 CGWindowListCopyWindowInfo(공개 CoreGraphics API)로 '창 번호·소유 PID·레이어·알파·경계'만 읽는다.
///   창 제목·소유 앱 이름 키는 읽지 않고, 결과는 호출한 동작(메뉴 한 번, 제목줄 더블클릭 한 번) 동안 메모리에만 두며
///   저장·기록·전송하지 않는다. 스크린샷을 찍지 않으며 손쉬운 사용 등 새 권한을 요청하지 않는다.
/// - 이 목록 조회는 비용이 크므로 끌기의 마우스 이벤트마다 부르지 않는다(호출 측이 동작당 한 번만 부름).
/// - kCGWindowBounds는 주 디스플레이(CGMainDisplayID, 메뉴 막대가 있는 물리 디스플레이) 왼쪽 위 원점 좌표다.
///   AppKit 전역 좌표(같은 디스플레이 왼쪽 아래 원점)로 바꿀 때 NSScreen.main(키 창이 있는 화면, 바뀜)이 아니라
///   CGMainDisplayID와 일치하는 NSScreen의 높이를 기준으로 쓴다. 음수 좌표의 보조 디스플레이도 같은 식으로 맞는다.
@MainActor
enum WindowGeometry {
    /// 다른 앱의 보이는 일반 창 하나(AppKit 전역 좌표). 앞→뒤 순서 목록의 원소로만 쓴다.
    struct Candidate {
        let id: CGWindowID
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
            result.append(Candidate(id: number, frame: frame))
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
}
