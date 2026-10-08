import AppKit
import Combine
import SafariServices

/// 브라우저 번역 연동(Chrome·Whale·Safari)의 설정, 엔진 연결 서버 수명, 설치 준비를 맡는다.
/// - 저장하는 값은 '브라우저 확장 연결 허용' 여부(UserDefaults)뿐이다. 페이지 내용은 저장하지 않는다.
/// - 설치 준비는 사용자가 누를 때만 한다: 번들 확장을 앱 지원 폴더에 풀고, Chrome/Whale 사용자 폴더에 이 앱의
///   네이티브 메시징 호스트 매니페스트(허용 확장 ID 고정) 하나만 쓴다. 확장 로드·Safari 확장 켜기는 브라우저 화면에서
///   사용자가 직접 확인해야 하며, 앱이 브라우저 프로필이나 보안 설정을 바꾸지 않는다.
@MainActor
final class BrowserIntegration: ObservableObject {
    static let shared = BrowserIntegration()
    static let enabledKey = "BrowserBridge.enabled"

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
            case .stale: return "다른 위치의 SMT로 등록됨 — 설치 시작을 다시 누르세요"
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
            case .missing: return "이 SMT 빌드에 Safari 확장이 없습니다"
            case .disabled: return "꺼져 있음 — Safari 설정에서 켜 주세요"
            case .enabled: return "켜져 있음"
            case .error(let message): return message
            }
        }
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var serverStatus = "꺼짐"
    @Published private(set) var registrations: [ChromiumBrowser: RegistrationState] = [:]
    @Published private(set) var safariState: SafariState = .unknown
    @Published var lastMessage: String?

    /// 도우미가 브라우저 요청으로 앱을 실행했으면 true(화면 번역 창을 띄우지 않는다).
    let launchedByBrowser = CommandLine.arguments.contains(BrowserBridge.launchArgument)

    private var server: BrowserBridgeServer?

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    // MARK: - 수명

    /// 앱 시작 시 호출. 연결을 허용했거나 브라우저가 앱을 실행한 경우에만 서버를 연다
    /// (허용 전이면 서버는 모든 번역 요청에 '연결 허용 필요' 안내만 돌려준다).
    func applicationDidLaunch() {
        if isEnabled || launchedByBrowser { startServer() }
        refreshRegistrations()
    }

    func applicationWillTerminate() {
        server?.stop()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            startServer()
        } else {
            server?.stop()
            serverStatus = "꺼짐"
        }
    }

    private func startServer() {
        if server == nil {
            let translator: BrowserTextTranslating
            if #available(macOS 26.0, *) {
                translator = BrowserDirectTranslator()
            } else {
                translator = BrowserHostedTranslator()
            }
            let key = Self.enabledKey
            let engine = BrowserEngine(translator: translator, isEnabled: { UserDefaults.standard.bool(forKey: key) })
            server = BrowserBridgeServer(engine: engine)
        }
        if let failure = server?.start() {
            serverStatus = failure
        } else {
            serverStatus = isEnabled ? "대기 중 (Mac 기본 번역)" : "연결 허용 전 — 요청을 처리하지 않음"
        }
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
            guard isEnabled else { throw SetupError("먼저 '브라우저 확장 연결 허용'을 켜 주세요.") }
            guard browser.applicationURL != nil else { throw SetupError("\(browser.title)이(가) 설치되어 있지 않습니다.") }
            guard isInstalledInApplications else {
                throw SetupError("SMT를 응용 프로그램 폴더로 옮겨 실행한 뒤 다시 시작하세요(등록 경로가 이 앱 위치에 고정됩니다).")
            }
            guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
                throw SetupError("이 SMT 빌드에 브라우저 도우미가 없습니다. 최신 SMT를 설치하세요.")
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

    private func stageExtension() throws {
        let fileManager = FileManager.default
        guard let source = bundledChromiumExtension,
              fileManager.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else {
            throw SetupError("이 SMT 빌드에 브라우저 확장이 들어 있지 않습니다.")
        }
        let destination = stagedExtensionURL
        if fileManager.fileExists(atPath: destination.path) {
            // 이 앱이 만든 폴더(표식 파일 있음)만 교체한다. 다른 파일이 있으면 지우지 않고 멈춘다.
            guard fileManager.fileExists(atPath: destination.appendingPathComponent(Self.stagingMarker).path) else {
                throw SetupError("\(destination.path) 에 SMT가 만들지 않은 파일이 있어 덮어쓰지 않았습니다.")
            }
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: destination)
        try Data("SMTranslator browser extension\n".utf8).write(to: destination.appendingPathComponent(Self.stagingMarker))
    }

    private func writeHostManifest(for browser: ChromiumBrowser) throws {
        let manifest: [String: Any] = [
            "name": BrowserBridge.hostName,
            "description": "SMTranslator 브라우저 번역 엔진 연결",
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
                    self?.safariState = .error("Safari가 확장을 아직 인식하지 못했습니다. SMT를 응용 프로그램 폴더에서 실행한 뒤 Safari를 다시 열어 주세요." + (error.map { " (\($0.localizedDescription))" } ?? ""))
                }
            }
        }
    }

    func openSafariExtensionSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: BrowserBridge.safariExtensionBundleID) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.lastMessage = "Safari 설정을 열지 못했습니다. Safari › 설정 › 확장 프로그램에서 'SMT 웹 번역'을 켜 주세요. (\(error.localizedDescription))"
            }
        }
    }

    private struct SetupError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
