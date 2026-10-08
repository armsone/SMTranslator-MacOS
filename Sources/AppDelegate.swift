import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var overlay: OverlayPanelController!
    private let viewModel = AppViewModel()
    private let loginItem = LoginItemManager()
    private let updater = UpdaterManager()
    private var hotKey: GlobalHotKey?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyBundleIcon()
        buildMainMenu()

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 660, height: 400)
        let initialRegion = NSRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        ).integral
        overlay = OverlayPanelController(initialFrame: initialRegion, viewModel: viewModel)
        viewModel.attach(overlay: overlay)
        overlay.onWillHide = { [weak self] in self?.viewModel.windowWillHide() }
        viewModel.onHideRequested = { [weak self] in self?.overlay.hide() }

        buildStatusItem()

        let hotKey = GlobalHotKey { [weak self] in self?.showOverlay() }
        hotKey.register()
        self.hotKey = hotKey
        if !hotKey.isRegistered {
            viewModel.status = .error(hotKey.statusDescription)
        }

        loginItem.applyInitialDefaultIfNeeded()
        updater.start()
        writeDiagnostics()

        // 실행 시에는 자동 캡처/번역/권한 요청을 하지 않고 창만 대기 상태로 보여준다.
        overlay.show(activate: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showOverlay()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel.stop()
        hotKey?.unregister()
        overlay.stopMonitoring()
        overlay.hide()
    }

    // MARK: - 아이콘

    /// Info.plist의 CFBundleIconFile(AppIcon.icns)과 같은 리소스를 Dock 아이콘에도 명시적으로 적용한다.
    private func applyBundleIcon() {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        }
    }

    // MARK: - 창 표시/숨김

    @objc private func showOverlay() {
        overlay.show(activate: true)
    }

    @objc private func toggleOverlay() {
        if overlay.isVisible {
            overlay.hide()
        } else {
            showOverlay()
        }
    }

    @objc private func hideOverlay() {
        overlay.hide()
    }

    @objc private func performPrimaryAction() {
        if !overlay.isVisible { overlay.show(activate: true) }
        viewModel.performPrimaryAction()
    }

    // MARK: - 메뉴 막대 상태 항목

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "translate", accessibilityDescription: "화면 번역기")
                ?? NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "화면 번역기")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "화면 번역기 (\(GlobalHotKey.displayString))"
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
    }

    /// 메뉴를 열 때마다 현재 상태(창 표시, 주 버튼, 로그인 항목, 업데이트)로 다시 만든다.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        menu.removeAllItems()

        menu.addItem(item(overlay.isVisible ? "번역 창 숨기기" : "번역 창 보이기 (\(GlobalHotKey.displayString))", #selector(toggleOverlay)))
        let primary = item(viewModel.primaryAction.title, #selector(performPrimaryAction))
        primary.isEnabled = !viewModel.isProcessing
        menu.addItem(primary)
        menu.addItem(info("상태: \(viewModel.status.koreanText)"))

        menu.addItem(.separator())
        let login = item("로그인 시 자동 시작", #selector(toggleLoginItem))
        login.isEnabled = loginItem.isInstalledInApplications
        switch loginItem.status {
        case .enabled: login.state = .on
        case .requiresApproval: login.state = .mixed
        default: login.state = .off
        }
        menu.addItem(login)
        menu.addItem(info("  로그인 항목: \(loginItem.lastError ?? loginItem.statusDescription)"))
        if loginItem.status == .requiresApproval {
            menu.addItem(item("  로그인 항목 설정 열기…", #selector(openLoginItemsSettings)))
        }

        menu.addItem(.separator())
        let check = item("업데이트 확인…", #selector(checkForUpdates))
        check.isEnabled = updater.canCheckForUpdates
        menu.addItem(check)
        let auto = item("자동 업데이트", #selector(toggleAutomaticUpdates))
        auto.isEnabled = updater.isAvailable
        auto.state = updater.automaticallyUpdates ? .on : .off
        menu.addItem(auto)
        menu.addItem(info("  업데이트: \(updater.lastCheckResult ?? updater.statusDescription)"))

        menu.addItem(.separator())
        menu.addItem(info("단축키: \(hotKey?.statusDescription ?? "없음")"))
        menu.addItem(item("화면 번역기 정보", #selector(showAbout)))
        menu.addItem(item("화면 번역기 종료", #selector(NSApplication.terminate(_:)), target: NSApp))
    }

    private func item(_ title: String, _ action: Selector, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target ?? self
        item.isEnabled = true
        return item
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleLoginItem() {
        let enable = loginItem.status != .enabled && loginItem.status != .requiresApproval
        loginItem.setEnabled(enable)
        writeDiagnostics()
    }

    @objc private func openLoginItemsSettings() {
        loginItem.openSystemSettings()
    }

    @objc private func checkForUpdates() {
        updater.checkForUpdates()
    }

    @objc private func toggleAutomaticUpdates() {
        updater.setAutomaticallyUpdates(!updater.automaticallyUpdates)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    // MARK: - 앱 메뉴

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(item("화면 번역기 정보", #selector(showAbout)))
        appMenu.addItem(item("업데이트 확인…", #selector(checkForUpdates)))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "화면 번역기 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "윈도우")
        let show = NSMenuItem(title: "번역 창 보이기", action: #selector(showOverlay), keyEquivalent: "0")
        show.target = self
        windowMenu.addItem(show)
        let hide = NSMenuItem(title: "번역 창 숨기기", action: #selector(hideOverlay), keyEquivalent: "w")
        hide.target = self
        windowMenu.addItem(hide)
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - 진단 로그 (비밀 정보 없음)

    /// 설치 경로, 버전, 로그인 항목/단축키/업데이터 상태만 기록한다. 화면 내용·텍스트는 기록하지 않는다.
    private func writeDiagnostics() {
        let info = Bundle.main.infoDictionary ?? [:]
        let lines = [
            "time=\(ISO8601DateFormatter().string(from: Date()))",
            "version=\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))",
            "bundleIdentifier=\(Bundle.main.bundleIdentifier ?? "?")",
            "bundlePath=\(Bundle.main.bundlePath)",
            "executable=\(Bundle.main.executablePath ?? "?")",
            "loginItemStatus=\(loginItem.status.rawValue) \(loginItem.statusDescription)",
            "loginItemPreference=\(loginItem.preference.map { String($0) } ?? "unset")",
            "loginItemError=\(loginItem.lastError ?? "none")",
            "hotKey=\(hotKey?.statusDescription ?? "none")",
            "updater=\(updater.statusDescription)",
            "feedURL=\(info["SUFeedURL"] as? String ?? "none")",
            "publicKeyPresent=\(!((info["SUPublicEDKey"] as? String) ?? "").isEmpty)"
        ]
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ScreenTranslator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("diagnostics.log"), atomically: true, encoding: .utf8)
    }
}
