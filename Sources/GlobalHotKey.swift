import AppKit
import Carbon.HIToolbox

/// Carbon RegisterEventHotKey로 등록하는 단 하나의 전역 단축키(⌃⌥⇧⌘T).
/// 모든 키를 감시하지 않으므로 손쉬운 사용/입력 모니터링 권한이 필요 없다.
/// 콜백에는 자기 자신을 unretained로 넘기므로, 소유자(AppDelegate)가 앱 수명 동안
/// 이 객체를 강하게 붙잡고 종료 시 unregister()를 호출해야 한다.
@MainActor
final class GlobalHotKey {
    static let displayString = "⌃⌥⇧⌘T"

    private static let signature: OSType = 0x5354_524E // 'STRN'
    private static let hotKeyID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    /// 등록 결과를 메뉴/진단에 표시하기 위한 상태 문구
    private(set) var statusDescription = "등록 전"
    private(set) var isRegistered = false

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func register() {
        guard !isRegistered else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &id)
            guard status == noErr, id.signature == GlobalHotKey.signature, id.id == GlobalHotKey.hotKeyID else {
                return OSStatus(eventNotHandledErr)
            }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { hotKey.action() }
            }
            return noErr
        }, 1, &eventType, userData, &handlerRef)

        guard installStatus == noErr else {
            statusDescription = "단축키 처리기 설치 실패 (OSStatus \(installStatus))"
            return
        }

        let modifiers = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_T), modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr {
            isRegistered = true
            statusDescription = "\(Self.displayString) 등록됨"
        } else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            handlerRef = nil
            hotKeyRef = nil
            if status == OSStatus(eventHotKeyExistsErr) {
                statusDescription = "\(Self.displayString) 사용 불가: 다른 앱이 이미 사용 중입니다. 해당 앱의 단축키를 바꾼 뒤 앱을 다시 실행하세요."
            } else {
                statusDescription = "\(Self.displayString) 등록 실패 (OSStatus \(status))"
            }
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        isRegistered = false
        statusDescription = "해제됨"
    }
}
