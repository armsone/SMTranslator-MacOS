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
                HStack {
                    Text("번역 언어 팩")
                    Spacer()
                    Button("번역 언어 관리") { openTranslationLanguageSettings() }
                }
                HStack {
                    Text("웹 번역(DeepL·Google·Papago) 전송 동의")
                    Spacer()
                    Button("설정 열기") { MailWindowCoordinator.shared.showSettings() }
                }
            } header: {
                Text("브라우저 번역")
            } footer: {
                Text("켜면 SMT 웹 번역 확장이 보낸 페이지 글자와 보이는 탭 화면(이미지 글자 인식용)을 이 Mac의 SMT가 받아 번역합니다. 브라우저 번역은 앱의 번역 방식(지금: \(methods.backend.title))과 별개이며, 기본값은 Mac 기본 번역(기기 내)입니다. Chrome·Whale 확장의 '번역 엔진'에서 DeepL·Google 번역·Papago를 직접 고르고 확장과 이 앱(설정 › 웹 번역 전송 동의) 모두에서 동의한 경우에만, 페이지 글자와 이 Mac에서 이미지로부터 인식한 글자를 그 서비스의 공식 웹페이지로 보냅니다. 캡처 이미지·페이지 HTML·페이지 주소는 보내지 않으며 외부 AI로는 보내지 않습니다. Safari는 Mac 기본 번역만 지원합니다. 받은 내용은 번역 후 바로 버리고 저장하지 않습니다. 번역 언어 관리를 열고 '번역 언어'에서 필요한 언어를 내려받거나 제거하세요.")
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
                Text("Safari 확장은 SMT 앱 안에 들어 있습니다. SMT를 응용 프로그램 폴더에서 한 번 실행한 뒤 Safari › 설정 › 확장 프로그램에서 'SMT 웹 번역'을 켜고, 웹 사이트 접근을 허용하세요. Safari는 확장 안에서 직접 번역하므로 macOS 26 이상과 내려받은 번역 언어 팩이 필요합니다. Safari 확장은 샌드박스 안에서 네트워크에 접속하지 않으므로 웹 번역(DeepL·Google·Papago)은 지원하지 않습니다."
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
            Text("스토어 배포 전이라 확장 로드는 \(browser.title)에서 직접 확인해야 합니다. '설치 시작'이 실패하면 아래 단계도, 성공 안내도 나오지 않습니다. SMT를 업데이트한 뒤에는 '설치 시작'을 다시 눌러 확장 관리 화면에서 새로고침하세요.")
        }
    }

    private func installSteps(_ browser: BrowserIntegration.ChromiumBrowser) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            installStep(1, "gearshape.2", "\(browser.extensionsPage) 화면 오른쪽 위에서 '개발자 모드'를 켜고 '압축해제된 확장 프로그램을 로드합니다'를 누릅니다.")
            installStep(2, "folder", "폴더 선택 창이 열리면 ⌘⇧G를 눌러 경로 입력창을 띄웁니다.")
            installStep(3, "doc.on.clipboard", "복사된 경로를 ⌘V로 붙여넣고 엔터를 누릅니다.")
            installStep(4, "checkmark.circle", "폴더가 선택되면 '선택'을 눌러 확장을 로드합니다.")
            installStep(5, "puzzlepiece.extension", "툴바의 SMT 아이콘을 눌러 동의하면 사용할 수 있습니다.")
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
