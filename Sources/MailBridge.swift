import AppKit
import ApplicationServices
import Foundation

// 사용자가 버튼을 눌렀을 때만 Apple Mail의 "현재 선택된 메시지" 원본을 가져온다.
// 메시지를 보내거나 수정하지 않으며, 가져온 내용은 기록하지 않는다.

enum MailBridgeError: LocalizedError, Equatable {
    case mailNotRunning
    case notAuthorized
    case noSelection
    case emptySource
    case scriptFailed(code: Int)

    var errorDescription: String? {
        switch self {
        case .mailNotRunning:
            return "Mail 앱이 실행 중이 아닙니다. Mail을 열고 번역할 메시지를 선택한 뒤 다시 시도하세요."
        case .notAuthorized:
            return "Mail 접근이 허용되지 않았습니다. 시스템 설정 › 개인정보 보호 및 보안 › 자동화에서 '바로보기'의 Mail 항목에 허용이 필요합니다, 또는 '.eml 파일 열기'를 사용하세요. (이 앱은 보안 설정을 변경하지 않습니다.)"
        case .noSelection:
            return "Mail에서 선택된 메시지가 없습니다. 메시지 목록에서 메시지 하나를 선택하세요."
        case .emptySource:
            return "선택한 메시지의 원본을 가져오지 못했습니다. 메시지가 아직 다운로드되지 않았을 수 있습니다. '.eml 파일 열기'를 사용해 보세요."
        case .scriptFailed(let code):
            return "Mail에서 메시지를 가져오지 못했습니다(오류 \(code)). '.eml 파일 열기'로 대신 열 수 있습니다."
        }
    }
}

struct MailSelection {
    let source: String
    let selectionCount: Int
}

@MainActor
enum MailBridge {
    static let mailBundleID = "com.apple.mail"

    private static let scriptSource = """
    tell application id "com.apple.mail"
        set selectedMessages to selection
        set messageCount to count of selectedMessages
        if messageCount is 0 then return {"", 0}
        set theMessage to item 1 of selectedMessages
        return {source of theMessage, messageCount}
    end tell
    """

    /// com.apple.security.automation.apple-events 항목이 있어야 macOS가 이 확인을 처음 할 때
    /// 권한 요청 창을 띄운다(그래야 자동화 목록에 '바로보기'가 나타난다). 이미 결정된 뒤에는
    /// 즉시 결과만 돌려주며, 이 호출이 권한을 임의로 바꾸거나 설정을 여는 일은 없다.
    private static func automationPermissionStatus() -> OSStatus {
        var target = AEAddressDesc()
        let createStatus = mailBundleID.withCString { pointer in
            AECreateDesc(typeApplicationBundleID, pointer, mailBundleID.utf8.count, &target)
        }
        guard createStatus == noErr else { return OSStatus(createStatus) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, true)
    }

    static func fetchSelectedMessage() throws -> MailSelection {
        // Mail을 임의로 실행하지 않도록 실행 여부를 먼저 확인
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: mailBundleID).isEmpty else {
            throw MailBridgeError.mailNotRunning
        }
        let permission = automationPermissionStatus()
        switch permission {
        case noErr:
            break
        case OSStatus(procNotFound):
            throw MailBridgeError.mailNotRunning
        case -1743: // errAEEventNotPermitted: 실제 거부. 설정에서 직접 허용해야 한다.
            throw MailBridgeError.notAuthorized
        default:
            // 그 외 코드는 권한 거부로 단정하지 않고 원래 코드를 그대로 전달한다.
            throw MailBridgeError.scriptFailed(code: Int(permission))
        }
        guard let script = NSAppleScript(source: scriptSource) else {
            throw MailBridgeError.scriptFailed(code: -1)
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -1
            switch code {
            case -1743, -10004: throw MailBridgeError.notAuthorized
            case -600, -609, -10810: throw MailBridgeError.mailNotRunning
            case -1728, -1719: throw MailBridgeError.noSelection
            default: throw MailBridgeError.scriptFailed(code: code)
            }
        }
        let count = Int(result.atIndex(2)?.int32Value ?? 0)
        guard count > 0 else { throw MailBridgeError.noSelection }
        guard let source = result.atIndex(1)?.stringValue, !source.isEmpty else {
            throw MailBridgeError.emptySource
        }
        return MailSelection(source: source, selectionCount: count)
    }
}
