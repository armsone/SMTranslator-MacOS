import AppKit
import SwiftUI

// 브라우저 번역 설정 창: 연결 허용(동의), Chrome·Whale 준비(확장 풀기 + 호스트 등록), Safari 확장 켜기 안내.
// 확장 로드와 Safari 확장 켜기는 브라우저 화면에서 사용자가 직접 확인해야 한다(앱이 대신 켜지 않는다).

struct BrowserSetupView: View {
    @ObservedObject private var integration = BrowserIntegration.shared

    var body: some View {
        Form {
            Section {
                Toggle("브라우저 확장 연결 허용", isOn: Binding(
                    get: { integration.isEnabled },
                    set: { integration.setEnabled($0) }
                ))
                LabeledContent("엔진 상태", value: integration.serverStatus)
                HStack {
                    Text("번역 언어 팩")
                    Spacer()
                    Button("번역 언어 관리") { openTranslationLanguageSettings() }
                }
                if TranslationBackend.externalOptionsVisible {
                    HStack {
                        Text("웹 번역(DeepL·Google·Papago) 전송 동의")
                        Spacer()
                        Button("설정 열기") { MailWindowCoordinator.shared.showSettings() }
                    }
                }
            } header: {
                Text("브라우저 번역")
            } footer: {
                Text("페이지와 이미지의 글자를 Mac에서 번역하고 다듬습니다.")
            }

            ForEach(BrowserIntegration.ChromiumBrowser.allCases) { browser in
                chromiumSection(browser)
            }

            Section {
                LabeledContent("상태", value: integration.safariState.text)
                HStack {
                    Spacer()
                    Button("상태 다시 확인") { integration.refreshSafariState() }
                    Button("Safari 확장 설정 열기") { integration.openSafariExtensionSettings() }
                        .disabled(!integration.hasBundledSafariExtension)
                }
            } header: {
                Text("Safari")
            } footer: {
                Text("Safari 번역은 macOS 26 이상과 확장 허용·언어 팩이 필요합니다.")
            }

            if let message = integration.lastMessage {
                Section {
                    Text(message).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 560)
        .onAppear {
            integration.refreshRegistrations()
            integration.refreshSafariState()
        }
    }

    private func chromiumSection(_ browser: BrowserIntegration.ChromiumBrowser) -> some View {
        let state = integration.registrations[browser] ?? .notRegistered
        return Section {
            LabeledContent("상태", value: state.text)
            Button {
                integration.startInstall(browser)
            } label: {
                Text("설치 시작").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!integration.isEnabled || state == .browserMissing)

            installSteps(browser)

            HStack {
                Text(integration.stagedExtensionURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button("폴더 보기") { integration.revealStagedExtension() }
                Button("경로 복사") { integration.copyStagedExtensionPath() }
                Button("확장 관리 다시 열기") { integration.openExtensionsPage(browser) }
                    .disabled(state == .browserMissing)
            }
            .controlSize(.small)

            Button("연결 해제") { integration.unregister(browser) }
                .disabled(state == .notRegistered || state == .browserMissing)
        } header: {
            Text(browser.title)
        } footer: {
            Text("설치 후 확장을 로드하고, SMT 업데이트 뒤 새로고침하세요.")
        }
    }

    private func installSteps(_ browser: BrowserIntegration.ChromiumBrowser) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            installStep(1, "gearshape.2", "개발자 모드에서 '압축해제된 확장 로드'를 누르세요.")
            installStep(2, "folder", "폴더 선택 창에서 ⌘⇧G를 누르세요.")
            installStep(3, "doc.on.clipboard", "⌘V로 경로를 붙여넣고 엔터를 누르세요.")
            installStep(4, "checkmark.circle", "'선택'을 눌러 확장을 로드하세요.")
            installStep(5, "puzzlepiece.extension", "SMT 아이콘을 눌러 Mac 연결에 동의하세요.")
        }
        .padding(.vertical, 4)
    }

    private func openTranslationLanguageSettings() {
        let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!
        if !NSWorkspace.shared.open(settingsURL) {
            let guideURL = URL(string: "https://support.apple.com/ko-kr/guide/mac-help/mchldd8b3c15/mac")!
            NSWorkspace.shared.open(guideURL)
        }
    }

    private func installStep(_ number: Int, _ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.15))
                Text("\(number)").font(.caption.bold()).foregroundStyle(Color.accentColor)
            }
            .frame(width: 22, height: 22)
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            Text(text).font(.callout)
            Spacer(minLength: 0)
        }
    }
}

@MainActor
final class BrowserSetupWindowController: NSObject, NSWindowDelegate {
    static let shared = BrowserSetupWindowController()

    private var window: NSWindow?

    func show() {
        NSApp.activate()
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: BrowserSetupView()))
            window.title = "브라우저 번역"
            window.identifier = NSUserInterfaceItemIdentifier("browserSetup")
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        BrowserIntegration.shared.lastMessage = nil
    }
}
