import AppKit
import SwiftUI

// 브라우저 번역 설정 창: 연결 허용(동의), Chrome·Whale 준비(확장 풀기 + 호스트 등록), Safari 확장 켜기 안내.
// 확장 로드와 Safari 확장 켜기는 브라우저 화면에서 사용자가 직접 확인해야 한다(앱이 대신 켜지 않는다).

struct BrowserSetupView: View {
    @ObservedObject private var integration = BrowserIntegration.shared
    @State private var methods = TranslationBackendStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("브라우저 확장 연결 허용", isOn: Binding(
                    get: { integration.isEnabled },
                    set: { integration.setEnabled($0) }
                ))
                LabeledContent("엔진 상태", value: integration.serverStatus)
            } header: {
                Text("브라우저 번역")
            } footer: {
                Text("켜면 SMT 웹 번역 확장이 보낸 페이지 글자와 보이는 탭 화면(이미지 글자 인식용)을 이 Mac의 SMT가 받아 번역합니다. 브라우저 번역은 앱의 번역 방식(지금: \(methods.backend.title))과 별개로 항상 Mac 기본 번역(기기 내)을 쓰며, 외부 AI로 보내지 않습니다. 받은 내용은 번역 후 바로 버리고 저장하지 않습니다. 확장에서도 처음 한 번 동의를 받습니다.")
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
                Text("Safari 확장은 SMT 앱 안에 들어 있습니다. SMT를 응용 프로그램 폴더에서 한 번 실행한 뒤 Safari › 설정 › 확장 프로그램에서 'SMT 웹 번역'을 켜고, 웹 사이트 접근을 허용하세요. Safari는 확장 안에서 직접 번역하므로 macOS 26 이상과 내려받은 번역 언어 팩이 필요합니다."
                     + (integration.safariTranslationSupported ? "" : " 이 Mac(macOS 26 미만)에서는 Safari 번역이 동작하지 않습니다. Chrome·Whale을 사용하세요."))
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
            HStack {
                Button("준비") { integration.prepare(browser) }
                    .disabled(!integration.isEnabled || state == .browserMissing)
                Button("확장 관리 열기") { integration.openExtensionsPage(browser) }
                    .disabled(state == .browserMissing)
                Spacer()
                Button("연결 해제") { integration.unregister(browser) }
                    .disabled(state == .notRegistered || state == .browserMissing)
            }
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
            }
            .controlSize(.small)
        } header: {
            Text(browser.title)
        } footer: {
            Text("1) '준비'를 누르면 확장 폴더를 만들고 \(browser.title)에 SMT 연결을 등록합니다. 2) '확장 관리 열기'(\(browser.extensionsPage))에서 개발자 모드를 켜고 '압축해제된 확장 프로그램을 로드합니다'로 위 폴더를 선택합니다. 3) 툴바의 SMT 아이콘에서 동의한 뒤 사용합니다. 스토어 배포 전이라 이 단계는 브라우저에서 직접 확인해야 합니다. SMT를 업데이트한 뒤에는 다시 '준비'하고 확장 관리에서 새로고침하세요.")
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
