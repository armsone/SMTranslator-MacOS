import AppKit
import Combine
import CoreFoundation
import SafariServices

/// 브라우저 번역 연동(Chrome·Whale·Safari)의 설정, 엔진 연결 서버 수명, 설치 준비를 맡는다.
/// - 저장하는 값은 '브라우저 확장 연결 허용' 여부(UserDefaults)뿐이다. 페이지 내용은 저장하지 않는다.
/// - 설치 준비는 사용자가 누를 때만 한다: 번들 확장을 앱 지원 폴더에 풀고, Chrome/Whale 사용자 폴더에 이 앱의
///   네이티브 메시징 호스트 매니페스트(허용 확장 ID 고정) 하나만 쓴다. 확장 로드·Safari 확장 켜기는 브라우저 화면에서
///   사용자가 직접 확인해야 하며, 앱이 브라우저 프로필이나 보안 설정을 바꾸지 않는다.
@MainActor
final class BrowserIntegration: ObservableObject {
    static let shared = BrowserIntegration()

    enum ChromiumBrowser: String, CaseIterable, Identifiable {
        case chrome
        case whale

        var id: Self { self }

        var title: String {
            switch self {
            case .chrome: return "Chrome"
            case .whale: return "Whale"
            }
        }

        var bundleIdentifier: String {
            switch self {
            case .chrome: return "com.google.Chrome"
            case .whale: return "com.naver.Whale"
            }
        }

        /// 브라우저 기본 사용자 데이터 폴더(Chromium 규칙: 그 아래 NativeMessagingHosts)
        var dataDirectory: URL {
            let base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
            switch self {
            case .chrome: return base.appendingPathComponent("Google/Chrome", isDirectory: true)
            case .whale: return base.appendingPathComponent("Naver/Whale", isDirectory: true)
            }
        }

        var hostManifestURL: URL {
            dataDirectory.appendingPathComponent("NativeMessagingHosts/\(BrowserBridge.hostName).json")
        }

        var extensionsPage: String {
            switch self {
            case .chrome: return "chrome://extensions"
            case .whale: return "whale://extensions"
            }
        }

        var applicationURL: URL? {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        }
    }

    enum RegistrationState: Equatable {
        case browserMissing
        case notRegistered
        case registered
        case stale

        var text: String {
            switch self {
            case .browserMissing: return "브라우저가 설치되어 있지 않습니다"
            case .notRegistered: return "설치 시작 전"
            case .registered: return "설치 준비됨 · 브라우저에서 추가 필요"
            case .stale: return "다른 위치의 Barobogi로 등록됨 — 설치 시작을 다시 누르세요"
            }
        }
    }

    enum SafariState: Equatable {
        case unknown
        case missing
        case disabled
        case enabled
        case error(String)

        var text: String {
            switch self {
            case .unknown: return "확인 중"
            case .missing: return "이 Barobogi 빌드에 Safari 확장이 없습니다"
            case .disabled: return "꺼져 있음 — Safari 설정에서 켜 주세요"
            case .enabled: return "켜져 있음"
            case .error(let message): return message
            }
        }
    }

    /// 사용자가 명시적으로 허용한 기존 브라우저 연결 기능이며, 항상 켜져 있다(수동 켜기/끄기 없음).
    private(set) var isEnabled = true
    @Published private(set) var serverStatus = "꺼짐"
    @Published private(set) var registrations: [ChromiumBrowser: RegistrationState] = [:]
    @Published private(set) var safariState: SafariState = .unknown
    @Published var lastMessage: String?

    /// 도우미가 브라우저 요청으로 앱을 실행했으면 true(화면 번역 창을 띄우지 않는다).
    let launchedByBrowser = CommandLine.arguments.contains(BrowserBridge.launchArgument)

    private var server: BrowserBridgeServer?
    private var recoveryAttempts = 0
    private static let maxRecoveryAttempts = 3
    /// 도우미(SMTBrowserHost)가 "앱은 떠 있는데 소켓이 없다"를 알릴 때 쓰는 신호(데이터 없음, Darwin 알림).
    /// 받는 쪽은 이 신호 내용을 그대로 믿지 않고 실제 리스너 상태를 스스로 다시 확인한 뒤에만 되살린다.
    private static let recoveryNotificationName = "com.local.screentranslator.browser.recover" as CFString

    private init() {}

    // MARK: - 수명

    /// 앱 시작 시 호출. 기존 브라우저 연결 기능은 항상 켜져 있으므로 서버를 바로 연다.
    func applicationDidLaunch() {
        startServer()
        refreshRegistrations()
        observeRecoveryTriggers()
        // 기존에 설치 준비한 확장만 갱신한다. 브라우저 등록·허용 설정은 바꾸지 않는다.
        let staged = stagedExtensionURL
        if isInstalledInApplications,
           FileManager.default.fileExists(atPath: staged.appendingPathComponent(Self.stagingMarker).path),
           let bundled = bundledChromiumExtension,
           chromiumExtensionChanged(source: bundled, staged: staged) {
            do {
                try stageExtension()
                lastMessage = "브라우저 확장 파일을 갱신했습니다. Chrome·Whale 확장 관리 화면에서 Barobogi를 새로고침한 뒤 웹페이지도 새로고침해 주세요."
            } catch {
                lastMessage = "브라우저 확장 갱신 실패: \(error.localizedDescription)"
            }
        }
    }

    func applicationWillTerminate() {
        server?.stop()
    }

    private func startServer() {
        if server == nil {
            let translator: BrowserTextTranslating
            if #available(macOS 26.0, *) {
                translator = BrowserDirectTranslator()
            } else {
                translator = BrowserHostedTranslator()
            }
            // 확장에서 웹 번역 엔진을 고른 요청만 앱의 웹 번역 실행기로 넘긴다(앱 쪽 제공사별 동의 필요).
            // 이 다리는 externalOptionsVisible(메일·화면 번역의 외부 방식 선택 UI)과 별개다 — 확장의 '이 페이지를
            // Google로' 같은 명시적 1회성 요청은 그 UI 없이도 여기로 들어오며, 엔진별 동의는 여전히 WebTranslatorBrowserBridge가
            // 확인한다(WebTranslatorConsentStore). 확장이 보통 때 고를 수 있는 엔진은 background.js의 EXTERNAL_ENGINES가 가린다.
            // Apple Intelligence 다듬기는 이 앱 본체 엔진(Chrome·Whale)에서만 연결한다. Safari 확장은 앱 설정을
            // 읽을 수 없어 별도 엔진 인스턴스(refiner 없음)를 쓰며, 여기서 손대지 않는다.
            let engine = BrowserEngine(translator: translator, external: WebTranslatorBrowserBridge(),
                                       refiner: AppleBrowserRefiner(),
                                       isEnabled: { true },
                                       openLanguagePack: {
                await MainActor.run {
                    NSApp.activate(ignoringOtherApps: true)
                    MailWindowCoordinator.shared.openLanguagePackDownload()
                }
                return nil // 이 앱 안에서 실제 다운로드 시트를 바로 열었으므로 추가 설명이 필요 없다.
            })
            server = BrowserBridgeServer(engine: engine)
        }
        if let failure = server?.start() {
            serverStatus = failure
        } else {
            serverStatus = "대기 중 (기본: Mac 기본 번역)"
            recoveryAttempts = 0
        }
    }

    /// 새로고침 버튼: 리스너가 실제로 죽어 있을 때만 리스너를 다시 연다. 이미 정상이면 아무 것도 바꾸지
    /// 않는다 — 서버 전체를 내렸다가 다시 열던 예전 방식과 달리, 다른 브라우저·탭의 접속·진행 중인 번역은
    /// 건드리지 않는다. 등록·동의·설치 상태도 바꾸지 않는다. 반복 실패 시 더 이상 자동으로 재시도하지
    /// 않고 사용자에게 이유를 보여준다(무한 재시도 방지).
    func recoverConnection() {
        if server?.isRunning == true {
            lastMessage = "브라우저 연결은 이미 정상입니다. 다른 접속에는 영향이 없습니다."
            refreshRegistrations()
            return
        }
        guard recoveryAttempts < Self.maxRecoveryAttempts else {
            lastMessage = "브라우저 연결을 다시 열지 못했습니다. Barobogi를 다시 시작해 보세요."
            return
        }
        recoveryAttempts += 1
        startServer()
        refreshRegistrations()
        lastMessage = server?.isRunning == true ? "브라우저 연결을 다시 열었습니다." : serverStatus
    }

    /// 리스너가 외부 요인으로 죽었을 때 저절로 되살리는 트리거 두 가지를 건다(타이머·반복 폴링 없음).
    /// 1) 시스템 깨어남 — 절전 복귀 후 한 번 확인한다.
    /// 2) 도우미(SMTBrowserHost)의 복구 요청 — 앱은 실행 중인데 소켓이 없을 때 도우미가 보낸다(데이터 없음).
    /// 둘 다 리스너가 이미 살아 있으면 아무 일도 하지 않고, 접속 중인 연결에는 손대지 않는다.
    private func observeRecoveryTriggers() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recoverListenerIfNeeded() }
        }
        let callback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            let integration = Unmanaged<BrowserIntegration>.fromOpaque(observer).takeUnretainedValue()
            Task { @MainActor in integration.recoverListenerIfNeeded() }
        }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                         Unmanaged.passUnretained(self).toOpaque(),
                                         callback,
                                         Self.recoveryNotificationName,
                                         nil,
                                         .deliverImmediately)
    }

    /// 자동 복구 본체: 사용자에게 보일 메시지는 남기지 않는다(조용히 되살리거나, 조용히 포기한다).
    /// 새로고침 버튼과 같은 시도 횟수 한도를 나눠 쓰므로 여기서 소모해도 무한 재시도로 번지지 않는다.
    private func recoverListenerIfNeeded() {
        guard server?.isRunning != true else { return }
        guard recoveryAttempts < Self.maxRecoveryAttempts else { return }
        recoveryAttempts += 1
        startServer()
        refreshRegistrations()
    }

    // MARK: - Chrome · Whale

    private var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(BrowserBridge.helperExecutableName)")
    }

    private var bundledChromiumExtension: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("BrowserExtension/Chromium", isDirectory: true)
    }

    /// 압축 해제 확장을 둘 고정 위치(Chrome과 Whale이 같은 폴더를 쓴다)
    var stagedExtensionURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(BrowserBridge.appBundleID)/BrowserExtension/Chromium", isDirectory: true)
    }

    private static let stagingMarker = ".smt-browser-extension"

    var isInstalledInApplications: Bool {
        let path = Bundle.main.bundlePath
        let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/"
        return path.hasPrefix("/Applications/") || path.hasPrefix(userApps)
    }

    func refreshRegistrations() {
        var result: [ChromiumBrowser: RegistrationState] = [:]
        for browser in ChromiumBrowser.allCases {
            result[browser] = registrationState(browser)
        }
        registrations = result
    }

    private func registrationState(_ browser: ChromiumBrowser) -> RegistrationState {
        guard browser.applicationURL != nil else { return .browserMissing }
        guard let data = try? Data(contentsOf: browser.hostManifestURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .notRegistered }
        let origins = object["allowed_origins"] as? [String] ?? []
        guard object["name"] as? String == BrowserBridge.hostName,
              object["path"] as? String == helperURL.path,
              Set(origins) == Set(BrowserBridge.allowedOrigins) else { return .stale }
        return .registered
    }

    /// 사용자가 '설치 시작'을 누를 때만 호출된다. 확장을 앱 지원 폴더에 풀고 호스트 매니페스트를 등록한다.
    /// 이 단계가 성공했을 때만 경로 복사와 확장 관리 열기를 이어서 한다(실패하면 후속 동작도 성공 안내도 하지 않는다).
    func startInstall(_ browser: ChromiumBrowser) {
        do {
            guard browser.applicationURL != nil else { throw SetupError("\(browser.title)이(가) 설치되어 있지 않습니다.") }
            guard isInstalledInApplications else {
                throw SetupError("Barobogi를 응용 프로그램 폴더로 옮겨 실행한 뒤 다시 시작하세요(등록 경로가 이 앱 위치에 고정됩니다).")
            }
            guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
                throw SetupError("이 Barobogi 빌드에 브라우저 도우미가 없습니다. 최신 Barobogi를 설치하세요.")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: browser.dataDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw SetupError("\(browser.title)을(를) 한 번 실행해 프로필을 만든 뒤 다시 시작하세요.")
            }
            try stageExtension()
            try writeHostManifest(for: browser)
            refreshRegistrations()
            copyStagedExtensionPath(announce: false)
            openExtensionsPage(browser)
            lastMessage = "\(browser.title) 설치 준비됨 · 브라우저에서 추가 필요. 경로를 복사했고 확장 관리 화면을 열었습니다. 아래 단계를 따라 폴더를 선택해 주세요."
        } catch {
            refreshRegistrations()
            lastMessage = "\(browser.title) 설치 준비 실패: \((error as? SetupError)?.message ?? error.localizedDescription)"
        }
    }

    /// 이 앱이 쓴 호스트 매니페스트만 지운다(이름이 같고 내용의 name이 이 호스트일 때).
    func unregister(_ browser: ChromiumBrowser) {
        let url = browser.hostManifestURL
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["name"] as? String == BrowserBridge.hostName {
            do {
                try FileManager.default.removeItem(at: url)
                lastMessage = "\(browser.title) 연결 등록을 지웠습니다. 확장은 \(browser.extensionsPage)에서 직접 삭제하세요."
            } catch {
                lastMessage = "\(browser.title) 연결 등록을 지우지 못했습니다: \(error.localizedDescription)"
            }
        }
        refreshRegistrations()
    }

    func openExtensionsPage(_ browser: ChromiumBrowser) {
        guard let appURL = browser.applicationURL, let page = URL(string: browser.extensionsPage) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([page], withApplicationAt: appURL, configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.lastMessage = "\(browser.title)에서 \(browser.extensionsPage) 를 열지 못했습니다. 주소창에 직접 입력하세요. (\(error.localizedDescription))"
            }
        }
    }

    func revealStagedExtension() {
        guard FileManager.default.fileExists(atPath: stagedExtensionURL.path) else {
            lastMessage = "아직 준비된 확장 폴더가 없습니다. 먼저 '설치 시작'을 누르세요."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([stagedExtensionURL])
    }

    func copyStagedExtensionPath(announce: Bool = true) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(stagedExtensionURL.path, forType: .string)
        if announce { lastMessage = "확장 폴더 경로를 복사했습니다." }
    }

    /// 번들 확장(이번 빌드)과 이미 설치 준비된 확장의 실제 파일(background.js·content.js·popup.html/css/js·아이콘 등)을
    /// 바이트 단위로 비교한다. manifest.json의 version만 보면 버전을 올리지 않은 개발 빌드는 파일이 바뀌어도
    /// 갱신이 전혀 되지 않으므로, 번들에 있는 모든 일반 파일을 staged 쪽 같은 상대 경로와 직접 비교한다.
    private func chromiumExtensionChanged(source: URL, staged: URL) -> Bool {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey],
                                                        options: [.skipsHiddenFiles]) else { return true }
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            guard fileURL.path.hasPrefix(source.path) else { continue }
            let relative = String(fileURL.path.dropFirst(source.path.count))
            let counterpart = staged.appendingPathComponent(relative)
            guard let sourceData = try? Data(contentsOf: fileURL),
                  let stagedData = try? Data(contentsOf: counterpart),
                  sourceData == stagedData else { return true }
        }
        return false
    }

    private func stageExtension() throws {
        let fileManager = FileManager.default
        guard let source = bundledChromiumExtension,
              fileManager.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else {
            throw SetupError("이 Barobogi 빌드에 브라우저 확장이 들어 있지 않습니다.")
        }
        let destination = stagedExtensionURL
        let existed = fileManager.fileExists(atPath: destination.path)
        if existed {
            guard fileManager.fileExists(atPath: destination.appendingPathComponent(Self.stagingMarker).path) else {
                throw SetupError("\(destination.path) 에 Barobogi가 만들지 않은 파일이 있어 덮어쓰지 않았습니다.")
            }
        }
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let prepared = parent.appendingPathComponent(".smt-extension-new-\(UUID().uuidString)")
        let backup = parent.appendingPathComponent(".smt-extension-backup-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: prepared) }
        try fileManager.copyItem(at: source, to: prepared)
        try Data("Barobogi browser extension\n".utf8).write(to: prepared.appendingPathComponent(Self.stagingMarker))
        if existed { try fileManager.moveItem(at: destination, to: backup) }
        do {
            try fileManager.moveItem(at: prepared, to: destination)
        } catch {
            if existed { try fileManager.moveItem(at: backup, to: destination) }
            throw error
        }
        if existed { try? fileManager.removeItem(at: backup) }

    }

    private func writeHostManifest(for browser: ChromiumBrowser) throws {
        let manifest: [String: Any] = [
            "name": BrowserBridge.hostName,
            "description": "Barobogi 브라우저 번역 엔진 연결",
            "path": helperURL.path,
            "type": "stdio",
            "allowed_origins": BrowserBridge.allowedOrigins
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let directory = browser.hostManifestURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: browser.hostManifestURL, options: .atomic)
    }

    // MARK: - Safari

    var hasBundledSafariExtension: Bool {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) else { return false }
        return items.contains { Bundle(url: $0)?.bundleIdentifier == BrowserBridge.safariExtensionBundleID }
    }

    var safariTranslationSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    func refreshSafariState() {
        guard hasBundledSafariExtension else {
            safariState = .missing
            return
        }
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: BrowserBridge.safariExtensionBundleID) { [weak self] state, error in
            Task { @MainActor in
                if let state {
                    self?.safariState = state.isEnabled ? .enabled : .disabled
                } else {
                    self?.safariState = .error("Safari가 확장을 아직 인식하지 못했습니다. Barobogi를 응용 프로그램 폴더에서 실행한 뒤 Safari를 다시 열어 주세요." + (error.map { " (\($0.localizedDescription))" } ?? ""))
                }
            }
        }
    }

    func openSafariExtensionSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: BrowserBridge.safariExtensionBundleID) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.lastMessage = "Safari 설정을 열지 못했습니다. Safari › 설정 › 확장 프로그램에서 'Barobogi 웹 번역'을 켜 주세요. (\(error.localizedDescription))"
            }
        }
    }

    private struct SetupError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
