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

        DockVisibilityStore.shared.applyInitial()
        loginItem.applyInitialDefaultIfNeeded()
        updater.start()
        // 브라우저 번역 엔진 연결(허용했거나 브라우저 도우미가 실행한 경우에만 연다)
        BrowserIntegration.shared.applicationDidLaunch()
        writeDiagnostics()

        // 브라우저 도우미가 엔진으로 실행했으면 화면 번역 창을 띄우지 않고 메뉴 막대에서만 대기한다.
        guard !BrowserIntegration.shared.launchedByBrowser else { return }
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
        BrowserIntegration.shared.applicationWillTerminate()
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

        menu.addItem(headerItem())
        menu.addItem(.separator())

        let overlayVisible = overlay.isVisible
        let screenItem = item(overlayVisible ? "화면 번역 창 숨기기" : "화면 번역", #selector(toggleOverlay),
                               symbol: "text.viewfinder")
        // 전역 단축키는 항상 '보이기'만 수행하므로, 숨기기로 바뀌는 상태에서는 단축키 표기를 붙이지 않는다.
        if !overlayVisible {
            applyKeyEquivalent(screenItem, GlobalHotKey.screenKeyEquivalent, GlobalHotKey.screenModifierMask)
        }
        menu.addItem(screenItem)
        let primary = item(viewModel.primaryAction.title, #selector(performPrimaryAction), symbol: viewModel.primaryAction.systemImage)
        primary.isEnabled = !viewModel.isProcessing
        menu.addItem(primary)
        let fitItem = item("영역 맞추기", nil, symbol: "rectangle.dashed")
        fitItem.submenu = fitMenu()
        menu.addItem(fitItem)
        menu.addItem(info(viewModel.status.koreanText))

        menu.addItem(.separator())
        let mailItem = item("선택한 메일 번역", #selector(translateSelectedMail), symbol: "envelope")
        applyKeyEquivalent(mailItem, GlobalHotKey.mailKeyEquivalent, GlobalHotKey.mailModifierMask)
        menu.addItem(mailItem)
        menu.addItem(item("메일 번역 창 열기", #selector(showMailWindow), symbol: "envelope.open"))

        menu.addItem(.separator())
        let methodItem = item("번역 방식: \(TranslationBackendStore.shared.backend.title)", nil, symbol: "arrow.left.arrow.right")
        methodItem.submenu = backendMenu()
        menu.addItem(methodItem)
        menu.addItem(item("설정…", #selector(showSettings), symbol: "gearshape"))
        menu.addItem(item("브라우저 번역…", #selector(showBrowserSetup), symbol: "globe"))

        menu.addItem(.separator())
        let dockItem = item("Dock에 아이콘 표시", #selector(toggleDockIcon), symbol: "dock.rectangle")
        dockItem.state = DockVisibilityStore.shared.showDockIcon ? .on : .off
        menu.addItem(dockItem)

        menu.addItem(.separator())
        if let warning = actionNeededWarningItem() {
            menu.addItem(warning)
        }
        let options = item("옵션", nil, symbol: "switch.2")
        options.submenu = optionsMenu()
        menu.addItem(options)
        let status = item("앱 상태", nil, symbol: "info.circle")
        status.submenu = statusMenu()
        menu.addItem(status)

        menu.addItem(.separator())
        menu.addItem(item("스크린 메일 번역기 정보", #selector(showAbout), symbol: "questionmark.circle"))
        menu.addItem(item("스크린 메일 번역기 종료", #selector(NSApplication.terminate(_:)), target: NSApp, symbol: "power"))
    }

    /// 앱 아이콘·이름·버전을 보여주는 비활성 머리글 행
    private func headerItem() -> NSMenuItem {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let title = version.isEmpty ? "SMTranslator" : "SMTranslator v\(version)"
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        if let icon = NSApp.applicationIconImage {
            let resized = NSImage(size: NSSize(width: 18, height: 18))
            resized.lockFocus()
            icon.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
            resized.unlockFocus()
            header.image = resized
            if #available(macOS 27.0, *) {
                header.preferredImageVisibility = .visible
            }
        }
        return header
    }

    /// 실패·조치 필요 상태만 눈에 띄게 올린다(정상일 때는 표시하지 않는다).
    private func actionNeededWarningItem() -> NSMenuItem? {
        let hotKeyFailed = hotKey?.isRegistered == false || mailHotKey?.isRegistered == false
        let loginNeedsApproval = loginItem.status == .requiresApproval
        guard hotKeyFailed || loginNeedsApproval else { return nil }
        let text = hotKeyFailed ? "단축키 등록 실패 — 앱 상태 확인" : "로그인 항목 승인 필요"
        let warning = item(text, hotKeyFailed ? nil : #selector(openLoginItemsSettings), symbol: "exclamationmark.triangle")
        warning.isEnabled = !hotKeyFailed
        return warning
    }

    /// 켜고 끄는 항목(토글)과 업데이트 조작을 모아 메인 목록 길이를 줄인다.
    private func optionsMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let mailButton = item("Mail 위 번역 버튼 표시", #selector(toggleMailToolbarButton), symbol: nil)
        mailButton.state = MailToolbarButton.shared.isEnabled ? .on : .off
        submenu.addItem(mailButton)

        submenu.addItem(.separator())
        let login = item("로그인 시 자동 시작", #selector(toggleLoginItem), symbol: nil)
        login.isEnabled = loginItem.isInstalledInApplications
        switch loginItem.status {
        case .enabled: login.state = .on
        case .requiresApproval: login.state = .mixed
        default: login.state = .off
        }
        submenu.addItem(login)
        if loginItem.status == .requiresApproval {
            submenu.addItem(item("로그인 항목 설정 열기…", #selector(openLoginItemsSettings), symbol: nil))
        }

        submenu.addItem(.separator())
        let check = item("업데이트 확인…", #selector(checkForUpdates), symbol: nil)
        check.isEnabled = updater.canCheckForUpdates
        submenu.addItem(check)
        let auto = item("자동 업데이트", #selector(toggleAutomaticUpdates), symbol: nil)
        auto.isEnabled = updater.isAvailable
        auto.state = updater.automaticallyUpdates ? .on : .off
        submenu.addItem(auto)
        return submenu
    }

    /// 화면 번역 창을 화면·다른 앱 창 크기에 맞춘다. 번역은 시작하지 않는다.
    private func fitMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let screen = item("화면에 맞추기", #selector(fitOverlayToScreen), symbol: "display")
        screen.toolTip = "포인터가 있는 화면의 메뉴 막대와 Dock을 제외한 화면에 맞춥니다"
        submenu.addItem(screen)
        let window = item("현재 창에 맞추기", #selector(fitOverlayToWindow), symbol: "macwindow")
        window.toolTip = "이 창 가운데 아래에 있는 다른 앱 창(없으면 맨 앞 창)의 크기와 위치에 맞춥니다"
        submenu.addItem(window)
        let restore = item("맞추기 전 크기로", #selector(restoreOverlayFrame), symbol: "arrow.uturn.backward")
        restore.isEnabled = overlay.canRestoreFrameBeforeFit
        submenu.addItem(restore)
        submenu.addItem(.separator())
        let tip = info("제목줄 빈 곳을 더블클릭하면 뒤에 겹쳐진 다른 앱 창 크기에 맞춥니다")
        submenu.addItem(tip)
        return submenu
    }

    @objc private func fitOverlayToScreen() {
        if !overlay.isVisible { overlay.show(activate: true) }
        overlay.fitToScreen()
    }

    @objc private func fitOverlayToWindow() {
        if !overlay.isVisible { overlay.show(activate: true) }
        if !overlay.fitToWindowBehind() { NSSound.beep() }
    }

    @objc private func restoreOverlayFrame() {
        overlay.restoreFrameBeforeFit()
    }

    /// 단축키 등록, 로그인 항목, 업데이트의 세부 진단 텍스트(평상시 숨겨둠)
    private func statusMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(info("화면 번역 단축키: \(hotKey?.statusDescription ?? "없음")"))
        submenu.addItem(info("메일 번역 단축키: \(mailHotKey?.statusDescription ?? "없음")"))
        submenu.addItem(.separator())
        submenu.addItem(info("로그인 항목: \(loginItem.lastError ?? loginItem.statusDescription)"))
        submenu.addItem(.separator())
        submenu.addItem(info("업데이트: \(updater.lastCheckResult ?? updater.statusDescription)"))
        return submenu
    }

    private func item(_ title: String, _ action: Selector?, target: AnyObject? = nil, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = action == nil ? nil : (target ?? self)
        item.isEnabled = true
        if let symbol {
            item.image = symbolImage(symbol)
            if #available(macOS 27.0, *) {
                item.preferredImageVisibility = .visible
            }
        }
        return item
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func symbolImage(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    /// 전역 단축키(⌃⌥⇧⌘)와 같은 글자·보조키를 메뉴에도 그대로 보여준다(실제 단축키 의미를 바꾸지 않음).
    private func applyKeyEquivalent(_ item: NSMenuItem, _ key: String, _ mask: NSEvent.ModifierFlags) {
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = mask
    }

    /// 메일 번역과 화면 번역이 함께 쓰는 번역 방식 하위 메뉴
    private func backendMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let current = TranslationBackendStore.shared.backend
        for backend in TranslationBackend.allCases {
            if backend == .chatgpt || backend == .deepl { submenu.addItem(.separator()) }
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

    @objc private func showBrowserSetup() {
        BrowserSetupWindowController.shared.show()
    }

    @objc private func toggleDockIcon() {
        DockVisibilityStore.shared.showDockIcon.toggle()
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
            "browserBridgeEnabled=\(BrowserIntegration.shared.isEnabled) launchedByBrowser=\(BrowserIntegration.shared.launchedByBrowser)",
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
