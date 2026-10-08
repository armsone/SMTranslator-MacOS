import SwiftUI

// 설정: 번역 방식(메일·화면 공용), Mail 번역 버튼, 외부 AI 웹 계정 로그인 상태·로그인 창·브라우저 표시 방식·전송 동의·세션 삭제·진단 로그 공유.
// 앱 업데이트·로그인 시 자동 시작은 메뉴 막대 메뉴의 기존 항목이 담당한다(업데이터는 하나만 둔다).

struct AISettingsView: View {
    @State private var accounts = AIBIAccounts.shared
    @State private var webConsents = WebTranslatorConsentStore.shared
    @State private var webConsentRequest: WebTranslator?
    @ObservedObject private var diagnostics = AIBIDiagnosticsStore.shared
    @State private var methods = TranslationBackendStore.shared
    @State private var dockVisibility = DockVisibilityStore.shared
    @State private var mailButtonEnabled = MailToolbarButton.shared.isEnabled
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Picker("번역 방식", selection: $methods.backend) {
                    ForEach(TranslationBackend.allCases.filter { !$0.isExternal }) { backend in
                        Text("\(backend.title) — \(backend.detail)")
                            .tag(backend)
                            .selectionDisabled(backend == .intelligence && !TranslationBackend.intelligenceSupported)
                    }
                    Divider()
                    ForEach(TranslationBackend.allCases.filter { $0.provider != nil }) { backend in
                        Text("\(backend.title) — \(backend.detail)").tag(backend)
                    }
                    Divider()
                    ForEach(TranslationBackend.allCases.filter { $0.webTranslator != nil }) { backend in
                        Text("\(backend.title) — \(backend.detail)").tag(backend)
                    }
                }
            } header: {
                Text("번역 방식")
            } footer: {
                Text("화면 번역과 메일 번역이 같은 방식을 씁니다. 기본값은 Mac 기본 번역입니다. Apple Intelligence 우선은 macOS 26.4 이상에서만 고를 수 있습니다. ChatGPT·Claude·Gemini(웹 계정)와 DeepL·Google 번역·Papago(공식 웹페이지, 로그인 없음)는 고르기만 해서는 아무것도 보내지 않으며, 번역을 실행할 때만 텍스트를 보냅니다. 다른 방식으로 자동 대체하지 않습니다.")
            }

            Section {
                Toggle("Dock에 아이콘 표시", isOn: $dockVisibility.showDockIcon)
            } header: {
                Text("Dock")
            } footer: {
                Text("기본값은 꺼짐이며, 메뉴 막대 아이콘만으로 앱을 사용합니다. 켜면 Dock에도 아이콘이 나타나며, 메뉴 막대의 'Dock에 아이콘 표시'와 값을 공유합니다. 창·단축키·Mail 연동·설정은 두 경우 모두 그대로 동작합니다.")
            }

            Section {
                Toggle("Mail 위에 번역 버튼 표시", isOn: Binding(
                    get: { mailButtonEnabled },
                    set: { enabled in
                        if enabled { MailToolbarButton.shared.enable() } else { MailToolbarButton.shared.disable() }
                        mailButtonEnabled = MailToolbarButton.shared.isEnabled
                    }
                ))
            } header: {
                Text("Mail 연동")
            } footer: {
                Text("Mail을 볼 때 '번역' 버튼이 떠 있습니다(기본 켜짐). 누르면 Mail에서 선택한 메시지를 번역합니다. 손쉬운 사용 권한이 없어도 버튼은 수동 위치에 표시되고 끌어서 옮길 수 있습니다. 메뉴 막대의 '선택한 메일 번역'과 전역 단축키 \(GlobalHotKey.mailDisplayString)도 같은 동작입니다.")
            }

            Section {
                ForEach(AIProvider.allCases) { provider in
                    HStack {
                        Text(provider.title).frame(width: 80, alignment: .leading)
                        statusLabel(accounts.statuses[provider])
                        Spacer()
                        Button(accounts.statuses[provider] == .authenticated ? "로그인 화면 열기" : "로그인…") {
                            accounts.openLogin(provider)
                        }
                        .disabled(accounts.isClearing)
                    }
                }
                HStack {
                    Spacer()
                    Button("상태 다시 확인") { accounts.refreshAll() }
                        .disabled(accounts.isClearing || accounts.statuses.values.contains(.checking))
                }
            } header: {
                Text("외부 AI 웹 계정")
            } footer: {
                Text("API 키 없이 각 서비스의 공식 웹 페이지에 직접 로그인한 세션을 사용합니다. 앱은 비밀번호를 읽거나 저장하지 않습니다. 상태는 계정 메뉴 같은 로그인 표식이 보일 때만 '로그인됨'으로 표시하며, 20초 안에 확인하지 못하면 '확인 안 됨'입니다.")
            }

            Section {
                Toggle("AI 브라우저 항상 보기", isOn: $accounts.alwaysShowBrowser)
            } header: {
                Text("표시 방식")
            } footer: {
                Text("끄면(기본값) 브라우저를 숨긴 채 진행하고 메일 결과 창 상단이나 화면 번역 창 제목줄에 단계·남은 시간·취소를 표시합니다. 로그인·보안 확인이 필요하거나 자동 입력이 맞지 않을 때만 브라우저 창을 띄웁니다. 켜면 처음부터 브라우저 창을 보여 줍니다.")
            }

            Section {
                ForEach(AIProvider.allCases) { provider in
                    HStack {
                        Text(provider.title).frame(width: 80, alignment: .leading)
                        Text(accounts.hasConsent(provider) ? "동의함" : "아직 동의하지 않음")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("동의 철회") { accounts.revokeConsent(provider) }
                            .disabled(!accounts.hasConsent(provider))
                    }
                }
            } header: {
                Text("외부 AI 전송 동의")
            } footer: {
                Text("동의한 제공사는 번역을 실행할 때 메일의 제목·본문 텍스트·이미지 글자(OCR), 또는 화면 번역 영역에서 인식한 글자를 바로 보냅니다. 스크린샷 이미지와 메일 원본 HTML·이미지 파일·주소는 보내지 않습니다. 철회하면 다음 번역 실행 때 다시 묻습니다.")
            }

            Section {
                ForEach(WebTranslator.allCases) { translator in
                    HStack {
                        Text(translator.title).frame(width: 90, alignment: .leading)
                        Text(webConsents.hasConsent(translator) ? "동의함" : "아직 동의하지 않음")
                            .foregroundStyle(.secondary)
                        Spacer()
                        if webConsents.hasConsent(translator) {
                            Button("동의 철회") { webConsents.revoke(translator) }
                        } else {
                            Button("동의…") { webConsentRequest = translator }
                        }
                    }
                }
            } header: {
                Text("웹 번역 전송 동의")
            } footer: {
                Text("DeepL·Google 번역·Papago는 API 키 없이 각 서비스의 공식 번역 웹페이지에 항목을 하나씩 입력해 번역합니다. 동의한 서비스만 메일·화면 번역 실행 때, 그리고 브라우저 확장(Chrome·Whale)에서 그 서비스를 따로 골라 동의한 경우에만 텍스트를 보냅니다. 페이지에 쿠키 동의·보안 확인이 나타나면 창을 띄워 직접 확인하게 하며, 앱이 대신 누르거나 우회하지 않습니다. 철회하면 진행 중인 웹 번역을 멈춥니다.")
            }

            Section {
                Button("외부 AI·웹 번역 세션 모두 지우기…", role: .destructive) { confirmClear = true }
                    .disabled(accounts.isClearing)
            } header: {
                Text("세션")
            } footer: {
                Text("이 앱의 외부 AI와 웹 번역기(DeepL·Google 번역·Papago)가 함께 쓰는 저장소의 쿠키·로그인 정보를 모두 지웁니다(Safari, 다른 앱, 메일 서식 보기에는 영향 없음). 진행 중인 웹 번역도 함께 취소됩니다. 지운 뒤 각 외부 AI 제공사는 '로그인 필요'로 표시되며 '로그인…'으로 다시 로그인할 수 있습니다. 웹 번역기는 로그인이 필요하지 않습니다.")
            }

            Section {
                if let url = diagnostics.exportURL {
                    ShareLink(item: url) { Label("최근 외부 AI 진단 로그 공유…", systemImage: "square.and.arrow.up") }
                } else {
                    Text("아직 기록된 외부 AI 실행이 없습니다.").foregroundStyle(.secondary)
                }
                if let error = diagnostics.storageError {
                    Text(error).foregroundStyle(.orange)
                }
            } header: {
                Text("진단")
            } footer: {
                Text("최근 10회 실행의 단계 이름, 경과 시간, 개수만 이 Mac에 보관합니다. 메일·화면 내용·요청문·답변·계정·쿠키·주소·오류 원문은 기록하지 않으며, 공유를 누를 때만 내보냅니다.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .frame(minHeight: 620)
        .aibiHiddenSurface()
        .confirmationDialog("외부 AI·웹 번역 세션을 모두 지울까요?", isPresented: $confirmClear) {
            Button("모두 지우기", role: .destructive) {
                Task { await accounts.clearAllSessions() }
            }
        } message: {
            Text("ChatGPT·Claude·Gemini 모두 다시 로그인해야 합니다. 진행 중인 외부 AI 번역과 웹 번역(DeepL·Google 번역·Papago)이 모두 취소됩니다.")
        }
        .alert(webConsentRequest.map { "\($0.title) 전송에 동의할까요?" } ?? "",
               isPresented: Binding(get: { webConsentRequest != nil }, set: { if !$0 { webConsentRequest = nil } }),
               presenting: webConsentRequest) { translator in
            Button("동의") { webConsents.grant(translator) }
            Button("취소", role: .cancel) {}
        } message: { translator in
            Text(WebTranslatorConsentStore.message(for: translator))
        }
        .onAppear {
            mailButtonEnabled = MailToolbarButton.shared.isEnabled
            accounts.refreshAll()
        }
    }

    @ViewBuilder
    private func statusLabel(_ status: AIBILoginStatus?) -> some View {
        switch status {
        case .authenticated?:
            Label(AIBILoginStatus.authenticated.label, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .loginRequired?:
            Label(AIBILoginStatus.loginRequired.label, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .checking?:
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text(AIBILoginStatus.checking.label) }.foregroundStyle(.secondary)
        case .unknown?, nil:
            Label(AIBILoginStatus.unknown.label, systemImage: "questionmark.circle").foregroundStyle(.secondary)
        }
    }
}
