import AppKit
import SwiftUI

/// 메일 번역 기능의 창과 진입점을 기존 앱 수명주기(AppDelegate) 안에서 관리한다.
/// - 메일 결과 창: 원래 메일 번역기의 ContentView를 그대로 띄운다(도구 막대는 SwiftUI가 관리해 사용자 지정 가능).
///   창을 닫으면 메일 내용을 메모리에서 지우고 창도 해제한다. 앱은 종료하지 않는다.
/// - 설정 창: 번역 방식, Mail 번역 버튼, 외부 AI 로그인·동의·세션·진단.
/// - Mail › 서비스 › '메일 전체 번역' 처리기.
@MainActor
final class MailWindowCoordinator: NSObject, NSWindowDelegate {
    static let shared = MailWindowCoordinator()

    private var mailWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private let settingsSection = SettingsSectionStore()

    /// NSApp.servicesProvider가 제공자를 보유한다고 가정하지 않고 이 객체가 앱 수명 동안 직접 보유한다.
    private let serviceProvider = MailServiceProvider()

    /// 앱 시작 시 1회: 서비스 메뉴 등록과 Mail 번역 버튼(기본 켜짐) 재개.
    func start() {
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()
        UserDefaults.standard.register(defaults: ["attachedMailTranslationButton": true])
        MailToolbarButton.shared.resumeIfEnabled()
    }

    // MARK: - 메일 결과 창

    func isMailWindow(_ window: NSWindow) -> Bool {
        window === mailWindow
    }

    func showMailWindow() {
        NSApp.activate()
        let window = mailWindow ?? makeMailWindow()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    private func makeMailWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: ContentView())
        // ContentView의 .toolbar(id:)를 이 창의 사용자 지정 가능한 도구 막대로 연결한다.
        hosting.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.title = "메일 번역"
        window.identifier = NSUserInterfaceItemIdentifier("mail-translation")
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 680, height: 520)
        window.delegate = self
        window.setContentSize(NSSize(width: 880, height: 820))
        if !window.setFrameUsingName("MailTranslationWindow") { window.center() }
        window.setFrameAutosaveName("MailTranslationWindow")
        if AppModel.shared.keepOnTop { window.level = .floating }
        mailWindow = window
        return window
    }

    // MARK: - 설정 창(설정·옵션·브라우저 번역을 한 창의 탭으로 모음)

    func showSettings(section: SettingsSection = .general) {
        NSApp.activate()
        settingsSection.section = section
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(store: settingsSection))
            let window = NSWindow(contentViewController: hosting)
            window.title = "스크린 메일 번역기 설정"
            // 메일 결과 창과 구분되는 설정 창 식별자
            window.identifier = NSUserInterfaceItemIdentifier("settings")
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// 브라우저 확장의 "언어팩" 버튼이 호출: 설정 창을 브라우저 탭으로 열고 그 안에서 바로 다운로드 시트를 띄운다.
    func openLanguagePackDownload() {
        showSettings(section: .browser)
        settingsSection.showLanguagePackSheet = true
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === mailWindow {
            // 결과 창을 닫으면 메일 내용(문서·이미지·번역·외부 AI 실행)을 메모리에서 지운다.
            AppModel.shared.closeDocument()
            AppModel.shared.errorMessage = nil
            // 닫히는 중에 콘텐츠를 떼지 않도록 다음 실행 루프에서 창을 놓는다(다음에 열 때 새로 만든다).
            DispatchQueue.main.async { [weak self] in
                if self?.mailWindow === window {
                    window.contentViewController = nil
                    self?.mailWindow = nil
                }
            }
        } else if window === settingsWindow {
            DispatchQueue.main.async { [weak self] in
                if self?.settingsWindow === window {
                    window.contentViewController = nil
                    self?.settingsWindow = nil
                }
            }
        }
    }
}

/// Mail 앱 메뉴 › 서비스 › '메일 전체 번역' 처리기.
/// 입력이 없는 서비스라 대지(pasteboard)는 쓰지 않고, Mail에서 선택된 메시지 원본을 AppleScript로 읽는다.
final class MailServiceProvider: NSObject {
    @objc func translateSelectedMessage(_ pboard: NSPasteboard, userData: String?,
                                        error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        // 서비스 응답을 먼저 돌려준 뒤(Mail이 기다리지 않도록) 선택 메시지를 읽는다.
        // 이 시점에는 아직 Mail이 앞에 있으므로, 창을 앞으로 가져오기 전에 선택이 확정된다.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { AppModel.shared.translateSelectedMail() }
        }
    }
}
