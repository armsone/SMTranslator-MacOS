import Darwin
import Foundation
import Security

// 브라우저 확장 ↔ Barobogi 연결의 공통 상수·프레임 입출력·서명 확인.
// 앱 본체, Chrome/Whale 네이티브 메시징 도우미(SMTBrowserHost), Safari 확장(.appex)이 함께 컴파일한다.
// 이 파일은 다른 앱 소스에 의존하지 않는다(도우미는 이 파일만 함께 빌드한다).

enum BrowserBridge {
    /// Chrome/Whale 네이티브 메시징 호스트 이름(호스트 매니페스트 파일 이름과 같다)
    static let hostName = "com.local.screentranslator.browser"
    static let appBundleID = "com.local.screentranslator"
    static let helperIdentifier = "com.local.screentranslator.browserhost"
    static let helperExecutableName = "SMTBrowserHost"
    static let safariExtensionBundleID = "com.local.screentranslator.safari-extension"

    /// 압축 해제 확장(manifest의 공개 key)에서 계산한 고정 ID. 스토어 게시 ID는 실제 게시 후에만 추가한다.
    static let chromiumExtensionIDs = ["gnadnpjfjkipjbapbnhakfebncdkidai"]
    static var allowedOrigins: [String] { chromiumExtensionIDs.map { "chrome-extension://\($0)/" } }

    /// 도우미가 앱을 대신 실행할 때 붙이는 인자. 이 인자로 실행되면 화면 번역 창을 띄우지 않는다.
    static let launchArgument = "--browser-engine"

    /// 확장 → 엔진 한 메시지 최대 크기(보이는 탭 JPEG 포함). Chrome 상한(64MB)보다 훨씬 작게 둔다.
    static let maxIncomingFrame = 16 * 1024 * 1024
    /// 엔진 → 확장 한 메시지 최대 크기. Chrome 네이티브 메시징의 호스트→브라우저 상한은 1MB다.
    static let maxOutgoingFrame = 1_000_000

    /// 사용자별 임시 폴더(DARWIN_USER_TEMP_DIR, 본인만 접근 가능한 0700 폴더) 안의 Unix 도메인 소켓.
    /// 네트워크 포트를 열지 않는다. 경로가 sockaddr_un 한도(104바이트)를 넘으면 nil.
    static func socketPath() -> String? {
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) > 0 else { return nil }
        var dir = String(cString: buffer)
        if !dir.hasSuffix("/") { dir += "/" }
        let path = dir + "smt-browser-engine.sock"
        return path.utf8.count < 104 ? path : nil
    }

    static func socketAddress(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(103))
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    /// 확장에 보내는 오류 메시지(JSON). 원문·번역 내용은 담지 않는다.
    static func errorFrame(code: String, message: String, id: String? = nil) -> Data {
        var object: [String: Any] = ["type": "error", "ok": false, "code": code, "message": message]
        if let id { object["id"] = id }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{\"type\":\"error\",\"ok\":false}".utf8)
    }
}

// MARK: - 프레임 입출력 (4바이트 길이 + JSON, 길이는 Chrome 규약과 같은 호스트 바이트 순서)

enum BrowserFrameError: Error {
    case closed
    case tooLarge(Int)
    case io(Int32)
}

enum BrowserFrameIO {
    static func readExactly(_ fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let n = data.withUnsafeMutableBytes { raw -> Int in
                read(fd, raw.baseAddress!.advanced(by: offset), count - offset)
            }
            if n == 0 { throw BrowserFrameError.closed }
            if n < 0 {
                if errno == EINTR { continue }
                throw BrowserFrameError.io(errno)
            }
            offset += n
        }
        return data
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base.advanced(by: offset), raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw BrowserFrameError.io(errno)
                }
                offset += n
            }
        }
    }

    /// 한 프레임을 읽는다. 상한을 넘는 길이는 본문을 읽지 않고 오류로 끊는다(연결을 닫아야 한다).
    static func readFrame(_ fd: Int32, maxLength: Int) throws -> Data {
        let header = try readExactly(fd, count: 4)
        let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        guard length <= maxLength else { throw BrowserFrameError.tooLarge(length) }
        if length == 0 { return Data() }
        return try readExactly(fd, count: length)
    }

    static func writeFrame(_ fd: Int32, _ payload: Data) throws {
        var length = UInt32(payload.count)
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        try writeAll(fd, frame)
    }
}

// MARK: - 소켓 상대 확인 (같은 사용자 + 같은 팀 Developer ID 서명 + 지정한 식별자)

enum BrowserCodeSigning {
    /// 이 프로세스 서명의 팀 ID. 임시(ad hoc)·미서명 빌드면 nil이며, 이때는 연결을 모두 거부한다.
    static func ownTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// 연결된 Unix 소켓 상대 프로세스가 같은 사용자이고, 같은 팀의 Apple 발급 인증서로 서명된 `identifier`인지 확인한다.
    static func peerIsTrusted(fd: Int32, identifier: String, teamID: String) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return false }

        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }

        var guest: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: tokenData] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest else { return false }

        let safeTeam = teamID.filter { $0.isLetter || $0.isNumber }
        let requirementText = "anchor apple generic and certificate leaf[subject.OU] = \"\(safeTeam)\" and identifier \"\(identifier)\""
        var requirement: SecRequirement?
        guard !safeTeam.isEmpty,
              SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
    }
}
