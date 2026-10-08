import AppKit
import Carbon.HIToolbox

/// Carbon RegisterEventHotKey로 등록하는 전역 단축키 하나. 화면 번역(⌃⌥⇧⌘T)과
/// 선택한 메일 번역(⌃⌥⇧⌘M)이 각자 인스턴스를 가지며, 등록 실패(다른 앱과 충돌)와 해제를 따로 처리한다.
/// 모든 키를 감시하지 않으므로 손쉬운 사용/입력 모니터링 권한이 필요 없다.
/// 콜백에는 자기 자신을 unretained로 넘기므로, 소유자(AppDelegate)가 앱 수명 동안
/// 이 객체를 강하게 붙잡고 종료 시 unregister()를 호출해야 한다.
@MainActor
final class GlobalHotKey {
    nonisolated static let displayString = "⌃⌥⇧⌘T"
    nonisolated static let mailDisplayString = "⌃⌥⇧⌘M"

    /// 메뉴 항목 keyEquivalent 표기용(실제 등록은 Carbon RegisterEventHotKey로 별도 수행됨)
    nonisolated static let screenKeyEquivalent = "t"
    nonisolated static let mailKeyEquivalent = "m"
    nonisolated static let hotKeyModifierMask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    nonisolated static let screenModifierMask = hotKeyModifierMask
    nonisolated static let mailModifierMask = hotKeyModifierMask

    private static let signature: OSType = 0x5354_524E // 'STRN'
    nonisolated static let screenHotKeyID: UInt32 = 1
    nonisolated static let mailHotKeyID: UInt32 = 2

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let keyCode: UInt32
    nonisolated private let hotKeyID: UInt32
    let display: String
    private let action: () -> Void

    /// 등록 결과를 메뉴/진단에 표시하기 위한 상태 문구
    private(set) var statusDescription = "등록 전"
    private(set) var isRegistered = false

    /// 기본값은 기존 화면 번역 단축키(⌃⌥⇧⌘T)
    init(keyCode: UInt32 = UInt32(kVK_ANSI_T), id: UInt32 = GlobalHotKey.screenHotKeyID,
         display: String = GlobalHotKey.displayString, action: @escaping () -> Void) {
        self.keyCode = keyCode
        self.hotKeyID = id
        self.display = display
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
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            // 다른 인스턴스의 단축키 이벤트는 처리하지 않고 다음 처리기로 넘긴다.
            guard status == noErr, id.signature == GlobalHotKey.signature, id.id == hotKey.hotKeyID else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { hotKey.action() }
            }
            return noErr
        }, 1, &eventType, userData, &handlerRef)

        guard installStatus == noErr else {
            statusDescription = "\(display) 처리기 설치 실패 (OSStatus \(installStatus))"
            return
        }

        let modifiers = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        let id = EventHotKeyID(signature: Self.signature, id: hotKeyID)
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr {
            isRegistered = true
            statusDescription = "\(display) 등록됨"
        } else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            handlerRef = nil
            hotKeyRef = nil
            if status == OSStatus(eventHotKeyExistsErr) {
                statusDescription = "\(display) 사용 불가: 다른 앱이 이미 사용 중입니다. 해당 앱의 단축키를 바꾼 뒤 앱을 다시 실행하세요."
            } else {
                statusDescription = "\(display) 등록 실패 (OSStatus \(status))"
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
