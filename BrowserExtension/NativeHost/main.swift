import AppKit
import Darwin
import Foundation

// SMTBrowserHost — Chrome·Whale 네이티브 메시징 호스트(SMTranslator.app/Contents/Helpers 안).
// 브라우저가 확장의 connectNative로 실행한다. 직접 번역하지 않고, 같은 팀으로 서명된 SMT 앱의
// 사용자 전용 Unix 소켓 엔진에 메시지를 그대로 중계한다. SMT가 꺼져 있으면 화면 번역 창 없이 백그라운드로 실행한다.
// - 허용된 확장 출처(argv[1])가 아니면 바로 끝낸다.
// - 요청 크기 상한(16MB)·응답 크기 상한(1MB, Chrome 규약)을 지킨다. 내용은 기록하지 않는다.

signal(SIGPIPE, SIG_IGN)

let stdoutLock = NSLock()

func send(_ payload: Data) {
    stdoutLock.lock()
    defer { stdoutLock.unlock() }
    guard payload.count <= BrowserBridge.maxOutgoingFrame else { return }
    try? BrowserFrameIO.writeFrame(STDOUT_FILENO, payload)
}

func fail(_ code: String, _ message: String) -> Never {
    send(BrowserBridge.errorFrame(code: code, message: message))
    exit(1)
}

func connectEngine() -> Int32? {
    guard let path = BrowserBridge.socketPath() else { return nil }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = BrowserBridge.socketAddress(path)
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard result == 0 else {
        close(fd)
        return nil
    }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    return fd
}

/// 이 도우미가 들어 있는 SMT 앱(…/SMTranslator.app/Contents/Helpers/SMTBrowserHost)을 활성화 없이 실행한다.
func launchContainingApp() -> Bool {
    let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
    let appURL = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard Bundle(url: appURL)?.bundleIdentifier == BrowserBridge.appBundleID else { return false }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.addsToRecentItems = false
    configuration.promptsUserIfNeeded = false
    configuration.arguments = [BrowserBridge.launchArgument]
    let done = DispatchSemaphore(value: 0)
    var launched = false
    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, _ in
        launched = app != nil
        done.signal()
    }
    guard done.wait(timeout: .now() + 15) == .success else { return false }
    return launched
}

// 1) 출처 확인 — Chrome/Whale은 첫 인자로 호출한 확장의 출처를 넘긴다.
let origin = CommandLine.arguments.dropFirst().first ?? ""
guard BrowserBridge.allowedOrigins.contains(origin) else {
    fail("origin_not_allowed", "허용되지 않은 확장에서 호출했습니다.")
}
guard let teamID = BrowserCodeSigning.ownTeamID() else {
    fail("unsigned_helper", "SMT 브라우저 도우미가 Developer ID로 서명되지 않았습니다. 서명된 SMT를 다시 설치하세요.")
}

// 2) 엔진 연결 — 없으면 SMT를 백그라운드로 실행하고 잠시 기다린다.
var engineFD = connectEngine()
if engineFD == nil {
    if !NSRunningApplication.runningApplications(withBundleIdentifier: BrowserBridge.appBundleID).isEmpty {
        fail("app_disabled", "SMT가 실행 중이지만 브라우저 연결이 꺼져 있습니다. SMT 메뉴 막대 › 브라우저 번역…에서 '브라우저 확장 연결 허용'을 켜세요.")
    }
    guard launchContainingApp() else {
        fail("app_not_found", "SMT 앱을 실행하지 못했습니다. SMT를 응용 프로그램 폴더에 설치하고 '브라우저 번역…'에서 다시 준비하세요.")
    }
    let deadline = Date().addingTimeInterval(12)
    while engineFD == nil, Date() < deadline {
        usleep(250_000)
        engineFD = connectEngine()
    }
}
guard let engine = engineFD else {
    fail("app_not_responding", "SMT 브라우저 엔진이 응답하지 않습니다. SMT를 직접 실행하고 '브라우저 번역…'에서 연결 허용을 켰는지 확인하세요.")
}

// 3) 엔진 신원 확인 — 같은 사용자 + 같은 팀으로 서명된 SMT 앱인지
guard BrowserCodeSigning.peerIsTrusted(fd: engine, identifier: BrowserBridge.appBundleID, teamID: teamID) else {
    close(engine)
    fail("untrusted_engine", "연결 상대가 서명된 SMT가 아닙니다. SMT를 다시 설치하세요.")
}

// 4) 중계 — 엔진 → 브라우저는 별도 스레드, 브라우저 → 엔진은 이 스레드.
let reader = Thread {
    while true {
        do {
            send(try BrowserFrameIO.readFrame(engine, maxLength: BrowserBridge.maxOutgoingFrame))
        } catch {
            send(BrowserBridge.errorFrame(code: "engine_disconnected", message: "SMT 브라우저 엔진 연결이 끊겼습니다. 다시 번역하면 새로 연결합니다."))
            exit(0)
        }
    }
}
reader.start()

while true {
    let frame: Data
    do {
        frame = try BrowserFrameIO.readFrame(STDIN_FILENO, maxLength: BrowserBridge.maxIncomingFrame)
    } catch BrowserFrameError.tooLarge {
        fail("frame_too_large", "요청이 너무 큽니다.")
    } catch {
        // 브라우저가 연결을 닫았다(탭·확장 종료). 엔진 쪽 요청은 소켓이 닫히면서 취소된다.
        shutdown(engine, SHUT_RDWR)
        exit(0)
    }
    do {
        try BrowserFrameIO.writeFrame(engine, frame)
    } catch {
        fail("engine_disconnected", "SMT 브라우저 엔진 연결이 끊겼습니다. 다시 번역하면 새로 연결합니다.")
    }
}
