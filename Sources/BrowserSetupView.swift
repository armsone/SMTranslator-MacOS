import SwiftUI
import Translation

// 브라우저 연결 확인, Chrome·Whale 설치 준비, Safari 확장 켜기 안내.
// 확장 로드와 Safari 확장 켜기는 브라우저 화면에서 사용자가 직접 확인해야 한다(앱이 대신 켜지 않는다).

struct BrowserSetupView: View {
    @ObservedObject private var integration = BrowserIntegration.shared
    @ObservedObject var settingsStore: SettingsSectionStore

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("브라우저 연결")
                    Spacer()
                    Button("연결 다시 확인") { integration.recoverConnection() }
                        .help("SMT와 브라우저의 연결을 확인하고 복구합니다.")
                }
                if TranslationBackend.externalOptionsVisible {
                    HStack {
                        Text("웹 번역(DeepL·Google·Papago) 전송 동의")
                        Spacer()
                        Button("설정 열기") { MailWindowCoordinator.shared.showSettings(section: .general) }
                    }
                }
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

            Section {
                Button("언어팩") { settingsStore.showLanguagePackSheet = true }
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
        .sheet(isPresented: $settingsStore.showLanguagePackSheet) {
            LanguagePackDownloadView()
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
            .disabled(state == .browserMissing)

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

/// 언어팩 다운로드 전용 화면: 원문은 항상 자동 인식되며, 여기서는 받을 번역 언어팩만 고른다
/// (소스 언어 자동 인식 동작을 바꾸지 않는다). Apple Translation 프레임워크가 언어쌍 단위로만
/// prepareTranslation()을 제공하므로 쌍을 고르지만, 이는 다운로드 대상 선택일 뿐 원문 인식 제한이 아니다.
private struct LanguagePackDownloadView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var packSource: AppLanguage = .english
    @State private var packTarget: AppLanguage = .korean
    @State private var packConfiguration: TranslationSession.Configuration?
    @State private var packStatus = ""

    var body: some View {
        Form {
            Section {
                Text("원문은 자동 인식하며, 여기서는 받을 언어팩만 선택합니다.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Picker("", selection: $packSource) {
                        ForEach(AppLanguage.allCases) { Text($0.displayNameKorean).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Picker("", selection: $packTarget) {
                        ForEach(AppLanguage.allCases) { Text($0.displayNameKorean).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    Button("받기") { requestLanguagePackDownload() }
                }
                if !packStatus.isEmpty {
                    Text(packStatus).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("언어팩 다운로드")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 220)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("닫기") { dismiss() }
            }
        }
        // 세션이 시작되면 Translation 프레임워크가 그 언어쌍의 팩이 없을 때만 실제 다운로드 시트를 띄운다.
        // 이미 설치돼 있으면 화면 변화 없이 바로 끝난다(가짜 성공 주장 없음).
        .translationTask(packConfiguration) { session in
            do {
                try await session.prepareTranslation()
                await MainActor.run { packStatus = "준비 완료: 이 언어쌍은 설치돼 있거나 방금 받았습니다." }
            } catch {
                await MainActor.run { packStatus = "언어 팩을 받지 못했습니다: \(error.localizedDescription)" }
            }
        }
    }

    /// 같은 언어쌍을 다시 눌러도 .translationTask가 재시작되도록(Configuration이 값으로 같으면 SwiftUI가
    /// 다시 부르지 않는다) invalidate()로 값을 바꾼다. AppViewModel.advanceGroupQueue()와 같은 패턴.
    private func requestLanguagePackDownload() {
        guard packSource != packTarget else {
            packStatus = "원문과 번역 언어가 같습니다. 다른 언어를 골라주세요."
            return
        }
        packStatus = ""
        let newConfig = TranslationSession.Configuration(source: packSource.localeLanguage, target: packTarget.localeLanguage)
        if var config = packConfiguration, config == newConfig {
            config.invalidate()
            packConfiguration = config
        } else {
            packConfiguration = newConfig
        }
    }
}
