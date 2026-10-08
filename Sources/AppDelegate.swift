import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var overlay: OverlayPanelController!
    private let viewModel = AppViewModel()
    private let loginItem = LoginItemManager()
    private let updater = UpdaterManager()
    private var hotKey: GlobalHotKey?
    private var mailHotKey: GlobalHotKey?
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

        // 선택한 메일 번역 전역 단축키(⌃⌥⇧⌘M). 화면 번역 단축키와 독립적으로 등록·실패 처리한다.
        // 이 앱을 앞으로 가져오기 전에 Mail의 선택 메시지를 먼저 읽는다(AppModel.translateSelectedMail).
        let mailHotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_M), id: GlobalHotKey.mailHotKeyID,
                                      display: GlobalHotKey.mailDisplayString) {
            AppModel.shared.translateSelectedMail()
        }
        mailHotKey.register()
        self.mailHotKey = mailHotKey

        // 메일 번역: Mail › 서비스 메뉴, Mail 위 번역 버튼(기본 켜짐)
        MailWindowCoordinator.shared.start()

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

    /// .eml·이미지 파일 열기(Finder '다음으로 열기', Dock 아이콘으로 끌어놓기)
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        AppModel.shared.open(url: url)
        AppModel.shared.showMainWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel.stop()
        AppModel.shared.closeDocument()
        hotKey?.unregister()
        mailHotKey?.unregister()
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
            let image = NSImage(systemSymbolName: "translate", accessibilityDescription: "스크린 메일 번역기")
                ?? NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "스크린 메일 번역기")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "스크린 메일 번역기 (화면 \(GlobalHotKey.displayString) · 메일 \(GlobalHotKey.mailDisplayString))"
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

        menu.addItem(item(overlay.isVisible ? "화면 번역 창 숨기기" : "화면 번역 (\(GlobalHotKey.displayString))", #selector(toggleOverlay)))
        let primary = item(viewModel.primaryAction.title, #selector(performPrimaryAction))
        primary.isEnabled = !viewModel.isProcessing
        menu.addItem(primary)
        menu.addItem(info("상태: \(viewModel.status.koreanText)"))

        menu.addItem(.separator())
        menu.addItem(item("선택한 메일 번역 (\(GlobalHotKey.mailDisplayString))", #selector(translateSelectedMail)))
        menu.addItem(item("메일 번역 창 열기", #selector(showMailWindow)))
        let mailButton = item("Mail 위 번역 버튼 표시", #selector(toggleMailToolbarButton))
        mailButton.state = MailToolbarButton.shared.isEnabled ? .on : .off
        menu.addItem(mailButton)

        menu.addItem(.separator())
        let methodItem = NSMenuItem(title: "번역 방식: \(TranslationBackendStore.shared.backend.title)", action: nil, keyEquivalent: "")
        methodItem.submenu = backendMenu()
        menu.addItem(methodItem)
        menu.addItem(item("설정 (외부 AI 로그인·동의)…", #selector(showSettings)))

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
        menu.addItem(info("화면 번역 단축키: \(hotKey?.statusDescription ?? "없음")"))
        menu.addItem(info("메일 번역 단축키: \(mailHotKey?.statusDescription ?? "없음")"))
        menu.addItem(item("스크린 메일 번역기 정보", #selector(showAbout)))
        menu.addItem(item("스크린 메일 번역기 종료", #selector(NSApplication.terminate(_:)), target: NSApp))
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

    /// 메일 번역과 화면 번역이 함께 쓰는 번역 방식 하위 메뉴
    private func backendMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let current = TranslationBackendStore.shared.backend
        for backend in TranslationBackend.allCases {
            if backend == .chatgpt { submenu.addItem(.separator()) }
            let entry = NSMenuItem(title: "\(backend.title) — \(backend.detail)", action: #selector(selectBackend(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = backend.rawValue
            entry.state = backend == current ? .on : .off
            entry.isEnabled = backend != .intelligence || TranslationBackend.intelligenceSupported
            submenu.addItem(entry)
        }
        return submenu
    }

    @objc private func selectBackend(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let backend = TranslationBackend(rawValue: raw) else { return }
        TranslationBackendStore.shared.backend = backend
    }

    @objc private func translateSelectedMail() {
        AppModel.shared.translateSelectedMail()
    }

    @objc private func showMailWindow() {
        AppModel.shared.showMainWindow()
    }

    @objc private func openMailFile() {
        AppModel.shared.showMainWindow()
        AppModel.shared.showImporter = true
    }

    @objc private func clearMailDocument() {
        AppModel.shared.closeDocument()
    }

    @objc private func toggleMailToolbarButton() {
        if MailToolbarButton.shared.isEnabled {
            MailToolbarButton.shared.disable()
        } else {
            MailToolbarButton.shared.enable()
        }
    }

    @objc private func showSettings() {
        MailWindowCoordinator.shared.showSettings()
    }

    /// ⌘W: 메일·설정·AI 브라우저 창이 앞에 있으면 그 창을 닫고, 아니면 화면 번역 창을 숨긴다.
    @objc private func closeFrontWindow() {
        if let key = NSApp.keyWindow, key !== overlay.panel, key.styleMask.contains(.closable) {
            key.performClose(nil)
        } else {
            overlay.hide()
        }
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
        appMenu.addItem(item("스크린 메일 번역기 정보", #selector(showAbout)))
        appMenu.addItem(item("업데이트 확인…", #selector(checkForUpdates)))
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "설정…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "스크린 메일 번역기 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // 메일 번역(원래 메일 번역기의 파일 메뉴 항목)
        let mailMenuItem = NSMenuItem()
        let mailMenu = NSMenu(title: "메일")
        let translateMail = NSMenuItem(title: "선택한 메일 번역", action: #selector(translateSelectedMail), keyEquivalent: "t")
        translateMail.keyEquivalentModifierMask = [.command, .shift]
        translateMail.target = self
        mailMenu.addItem(translateMail)
        let openFile = NSMenuItem(title: "파일 열기…", action: #selector(openMailFile), keyEquivalent: "o")
        openFile.target = self
        mailMenu.addItem(openFile)
        mailMenu.addItem(item("메일 번역 창 열기", #selector(showMailWindow)))
        mailMenu.addItem(.separator())
        mailMenu.addItem(item("Mail 위 번역 버튼 켜기/끄기", #selector(toggleMailToolbarButton)))
        mailMenu.addItem(.separator())
        let clear = NSMenuItem(title: "현재 내용 지우기", action: #selector(clearMailDocument), keyEquivalent: String(UnicodeScalar(NSBackspaceCharacter)!))
        clear.keyEquivalentModifierMask = [.command]
        clear.target = self
        mailMenu.addItem(clear)
        mailMenuItem.submenu = mailMenu
        mainMenu.addItem(mailMenuItem)

        // 편집: 메일 결과의 텍스트 선택·복사, 외부 AI 로그인 창 입력, 수동 응답 붙여넣기에 필요하다.
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "편집")
        editMenu.addItem(NSMenuItem(title: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "실행 복귀", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "오려두기", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "복사하기", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "윈도우")
        let show = NSMenuItem(title: "화면 번역 창 보이기", action: #selector(showOverlay), keyEquivalent: "0")
        show.target = self
        windowMenu.addItem(show)
        let hide = NSMenuItem(title: "화면 번역 창 숨기기", action: #selector(hideOverlay), keyEquivalent: "")
        hide.target = self
        windowMenu.addItem(hide)
        let close = NSMenuItem(title: "창 닫기", action: #selector(closeFrontWindow), keyEquivalent: "w")
        close.target = self
        windowMenu.addItem(close)
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - 진단 로그 (비밀 정보 없음)

    /// 설치 경로, 버전, 로그인 항목/단축키/업데이터/번역 방식 이름만 기록한다. 화면·메일 내용과 텍스트는 기록하지 않는다.
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
            "mailHotKey=\(mailHotKey?.statusDescription ?? "none")",
            "mailToolbarButton=\(MailToolbarButton.shared.isEnabled)",
            "translationBackend=\(TranslationBackendStore.shared.backend.rawValue)",
            "updater=\(updater.statusDescription)",
            "feedURL=\(info["SUFeedURL"] as? String ?? "none")",
            "publicKeyPresent=\(!((info["SUPublicEDKey"] as? String) ?? "").isEmpty)"
        ]
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ScreenTranslator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("diagnostics.log"), atomically: true, encoding: .utf8)
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// '현재 내용 지우기'(⌘⌫)는 메일 번역 창이 앞에 있을 때만 동작한다(다른 창의 입력 중 실수로 지우지 않게).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(clearMailDocument) {
            return NSApp.keyWindow.map { MailWindowCoordinator.shared.isMailWindow($0) } ?? false
        }
        return true
    }
}
