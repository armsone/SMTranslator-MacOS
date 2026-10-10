import Darwin
import Foundation

/// Chrome·Whale 네이티브 메시징 도우미(SMTBrowserHost)가 접속하는 앱 쪽 Unix 도메인 소켓 서버.
/// - 네트워크 포트를 열지 않는다. 소켓은 사용자별 임시 폴더(0700)에 0600으로 만든다.
/// - 접속마다 같은 사용자 + 같은 팀으로 서명된 도우미(식별자 고정)인지 확인하고, 아니면 안내 오류 후 끊는다.
/// - 접속(브라우저 연결) 하나가 엔진의 scope 하나다. 끊기면 그 접속의 요청만 취소한다.
/// - 요청·응답 내용은 기록하지 않는다.
final class BrowserBridgeServer: @unchecked Sendable {
    private static let maxConnections = 8

    private let engine: BrowserEngine
    private let lock = NSLock()
    private let acceptQueue = DispatchQueue(label: "com.local.screentranslator.browser.accept")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int: Int32] = [:]
    private var nextConnectionID = 0
    private var socketPath: String?
    private var teamID: String?

    init(engine: BrowserEngine) {
        self.engine = engine
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return listenFD >= 0
    }

    /// 성공하면 nil, 실패하면 사용자에게 보여줄 이유를 돌려준다.
    func start() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard listenFD < 0 else { return nil }
        guard let team = BrowserCodeSigning.ownTeamID() else {
            return "이 앱 빌드에 Developer ID 서명(팀 ID)이 없어 브라우저 연결을 열지 않았습니다. 서명된 Barobogi를 /Applications에 설치해 실행하세요."
        }
        guard let path = BrowserBridge.socketPath() else {
            return "브라우저 연결용 소켓 경로를 만들 수 없습니다."
        }
        if let reason = removeStaleSocket(at: path) { return reason }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return "브라우저 연결 소켓을 만들지 못했습니다(\(errno))." }
        var address = BrowserBridge.socketAddress(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            return "브라우저 연결 소켓을 열지 못했습니다(\(code))."
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()
        listenFD = fd
        acceptSource = source
        socketPath = path
        teamID = team
        return nil
    }

    func stop() {
        lock.lock()
        let source = acceptSource
        let fd = listenFD
        let path = socketPath
        let open = Array(connections.values)
        acceptSource = nil
        listenFD = -1
        socketPath = nil
        lock.unlock()

        source?.cancel()
        if fd >= 0 { close(fd) }
        if let path { unlink(path) }
        // 읽기 스레드를 깨워 각자 정리(요청 취소·닫기)하게 한다.
        for connection in open { shutdown(connection, SHUT_RDWR) }
    }

    /// 리스너 소켓만 죽었을 때(치명적 accept 오류 등) 리스너만 내린다. `stop()`과 달리 이미 접속된 연결
    /// (`connections`)에는 손대지 않는다 — 그 연결들은 각자 스레드에서 독립적으로 계속 번역을 이어 간다.
    /// 이후 `start()`를 다시 부르면(앱 쪽 자동 복구 트리거) 리스너만 다시 연다.
    private func handleListenerFailure() {
        lock.lock()
        guard listenFD >= 0 else { lock.unlock(); return }
        let source = acceptSource
        let fd = listenFD
        let path = socketPath
        acceptSource = nil
        listenFD = -1
        socketPath = nil
        lock.unlock()

        source?.cancel()
        close(fd)
        if let path { unlink(path) }
    }

    // MARK: - 접속 처리

    private func acceptPending() {
        while true {
            lock.lock()
            let fd = listenFD
            let team = teamID
            lock.unlock()
            guard fd >= 0, let team else { return }
            let client = accept(fd, nil, nil)
            if client < 0 {
                // 논블로킹 소켓에서 더 받을 접속이 없을 때는 정상(EAGAIN). 그 밖의 오류는 리스너 자체가
                // 죽었다는 뜻이므로 리스너만 내리고 돌아간다(이미 접속된 연결은 그대로 둔다). 이후 자동 복구
                // 트리거(시스템 깨어남, 도우미의 복구 요청, 새로고침)가 리스너를 다시 연다.
                if errno != EAGAIN && errno != EWOULDBLOCK { handleListenerFailure() }
                return
            }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

            guard BrowserCodeSigning.peerIsTrusted(fd: client, identifier: BrowserBridge.helperIdentifier, teamID: team) else {
                try? BrowserFrameIO.writeFrame(client, BrowserBridge.errorFrame(
                    code: "untrusted_client",
                    message: "Barobogi와 같은 서명을 가진 도우미만 연결할 수 있습니다. Barobogi를 다시 설치하고 '브라우저 번역…'에서 다시 준비하세요."))
                close(client)
                continue
            }

            lock.lock()
            guard connections.count < Self.maxConnections else {
                lock.unlock()
                try? BrowserFrameIO.writeFrame(client, BrowserBridge.errorFrame(code: "busy", message: "브라우저 연결이 너무 많습니다. 사용하지 않는 브라우저를 닫아 주세요."))
                close(client)
                continue
            }
            nextConnectionID += 1
            let id = nextConnectionID
            connections[id] = client
            lock.unlock()

            let thread = Thread { [weak self] in self?.serve(connectionID: id, fd: client) }
            thread.name = "Barobogi browser connection \(id)"
            thread.start()
        }
    }

    /// 접속 하나의 읽기 루프(블로킹). 요청마다 엔진 작업을 띄우고 응답은 직렬 큐에서 순서대로 쓴다.
    ///
    /// `writer`는 단순 큐가 아니라 이 접속의 "열림/닫힘"을 소유하는 직렬 게이트다. 닫힘 표시와 fd close는
    /// 반드시 같은 직렬 큐의 한 블록 안에서 일어나며, 그 블록이 실행된 뒤 큐에 들어오는 모든 쓰기 블록은
    /// closed를 보고 그대로 버려진다. 네이티브 번역 Task는 취소할 수 없고 끝나는 시점도 알 수 없지만, 그 Task가
    /// 끝나 writer.async로 쓰기를 넣는 시점이 close 블록보다 먼저인지 나중인지에 따라 FIFO로만 결정되므로
    /// fd가 재사용된 뒤에도 그 fd로 쓰는 일이 없다. close 자체는 Task 완료를 기다리지 않고 즉시 일어난다.
    private func serve(connectionID: Int, fd: Int32) {
        let scope = "c\(connectionID)"
        let writer = DispatchQueue(label: "com.local.screentranslator.browser.write.\(connectionID)")
        let gate = WriterGate()
        let engine = self.engine
        while true {
            let frame: Data
            do {
                frame = try BrowserFrameIO.readFrame(fd, maxLength: BrowserBridge.maxIncomingFrame)
            } catch BrowserFrameError.tooLarge {
                writer.async {
                    guard !gate.closed else { return }
                    try? BrowserFrameIO.writeFrame(fd, BrowserBridge.errorFrame(code: "frame_too_large", message: "요청이 너무 큽니다."))
                }
                break
            } catch {
                break
            }
            Task.detached(priority: .userInitiated) {
                let response = await engine.handle(frame, scope: scope)
                writer.async {
                    guard !gate.closed else { return }
                    try? BrowserFrameIO.writeFrame(fd, response)
                }
            }
        }
        Task.detached { await engine.cancelAll(scope: scope) }
        lock.lock()
        connections[connectionID] = nil
        lock.unlock()
        // closed 표시와 close(fd)를 같은 직렬 블록에서 묶어, 이후 큐에 들어오는 쓰기는 모두 버려지게 한다.
        writer.async {
            gate.closed = true
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
    }

    /// 접속 하나의 writer 직렬 큐 위에서만 읽고 쓰는 닫힘 표시. 큐가 FIFO로 직렬화하므로 잠금이 필요 없다.
    private final class WriterGate {
        var closed = false
    }

    // MARK: - 소켓 경로

    /// 남아 있는 소켓 파일이 살아 있는 서버면 시작하지 않고, 죽은 소켓이면 지운다. 소켓이 아닌 파일은 지우지 않는다.
    private func removeStaleSocket(at path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else {
            return "브라우저 연결 경로에 다른 파일이 있어 시작하지 않았습니다."
        }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return nil }
        defer { close(probe) }
        var address = BrowserBridge.socketAddress(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connected == 0 { return "다른 Barobogi 실행본이 이미 브라우저 연결을 제공하고 있습니다." }
        unlink(path)
        return nil
    }
}
