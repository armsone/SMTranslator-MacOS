import SwiftUI
import Translation
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model = AppModel.shared
    @State private var confirmRemoteImages = false
    @State private var isDropTargeted = false

    static let openableTypes: [UTType] = {
        var types: [UTType] = [.emailMessage, .image]
        if let eml = UTType(filenameExtension: "eml") { types.insert(eml, at: 0) }
        return types
    }()

    var body: some View {
        VStack(spacing: 0) {
            StatusBar(model: model)
            Divider()
            Group {
                if model.isLoading {
                    ProgressView(model.loadingMessage)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let doc = model.document {
                    DocumentView(document: doc, model: model)
                } else {
                    EmptyStateView(model: model)
                }
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                        .padding(8)
                }
            }
        }
        .frame(minWidth: 680, minHeight: 520)
        // 외부 AI 숨김 실행용 실제 크기 웹 보기 표면(불투명 덮개 아래, 입력을 받지 않음)
        .aibiHiddenSurface(isMain: true)
        .toolbar(id: "main-toolbar") { toolbarContent }
        // 번역 세션은 항상 존재하는 최상위 뷰에 붙여, 화면 전환으로 작업이 끊기지 않게 한다.
        .translationTask(model.translationConfig) { session in
            await model.performTranslation(session: session)
        }
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: Self.openableTypes) { result in
            if case .success(let url) = result { model.open(url: url) }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .alert("이 메시지의 원격 이미지를 불러올까요?", isPresented: $confirmRemoteImages) {
            Button("불러오기") { model.loadRemoteImages() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("원격 이미지를 불러오면 보낸 사람의 서버가 이 Mac의 IP 주소와 열람 시각을 알 수 있습니다(수신 확인 추적). 이 메시지에 한해 HTTPS 주소만, 쿠키와 캐시 없이 메모리로만 불러옵니다.")
        }
        .alert(model.consentRequest.map { "\($0.provider.title)로 번역할까요?" } ?? "",
               isPresented: Binding(get: { model.consentRequest != nil },
                                    set: { if !$0 { model.consentRequest = nil } }),
               presenting: model.consentRequest) { request in
            Button("동의하고 번역") { model.grantConsentAndTranslate(request) }
            Button("취소", role: .cancel) { model.consentRequest = nil }
        } message: { request in
            Text(ExternalConsent.message(for: request.provider))
        }
        .task { await model.loadSupportedLanguages() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some CustomizableToolbarContent {
        ToolbarItem(id: "translate-selected", placement: .primaryAction) {
            Button {
                model.translateSelectedMail()
            } label: {
                Label("선택한 메일 번역", systemImage: "envelope.badge")
            }
            .help("Mail에서 현재 선택된 메시지를 가져와 번역합니다 (⇧⌘T, 전역 \(GlobalHotKey.mailDisplayString))")
            .disabled(model.isLoading)
        }
        ToolbarItem(id: "open-file", placement: .primaryAction) {
            Button {
                model.showImporter = true
            } label: {
                Label("파일 열기", systemImage: "doc.badge.plus")
            }
            .help(".eml 파일 또는 이미지 파일을 엽니다")
        }
        ToolbarItem(id: "languages", placement: .automatic) {
            HStack(spacing: 4) {
                Picker("원본 언어", selection: $model.sourceLanguageID) {
                    Text("자동 감지").tag("auto")
                    Divider()
                    ForEach(model.supportedLanguageIDs, id: \.self) { id in
                        Text(AppModel.languageName(id)).tag(id)
                    }
                }
                .frame(width: 130)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Picker("대상 언어", selection: $model.targetLanguageID) {
                    ForEach(model.supportedLanguageIDs.isEmpty ? ["ko"] : model.supportedLanguageIDs, id: \.self) { id in
                        Text(AppModel.languageName(id)).tag(id)
                    }
                }
                .frame(width: 120)
            }
            .labelsHidden()
            .help("원본 언어와 대상 언어")
        }
        ToolbarItem(id: "backend", placement: .automatic) {
            Picker("번역 방식", selection: $model.backend) {
                ForEach(TranslationBackend.allCases.filter { !$0.isExternal }) { backend in
                    Text("\(backend.title) — \(backend.detail)")
                        .tag(backend)
                        .selectionDisabled(backend == .intelligence && !TranslationBackend.intelligenceSupported)
                }
                Divider()
                ForEach(TranslationBackend.allCases.filter(\.isExternal)) { backend in
                    Text("\(backend.title) — \(backend.detail)").tag(backend)
                }
            }
            .labelsHidden()
            .frame(width: 210)
            .help((TranslationBackend.intelligenceSupported
                  ? "번역 방식. 'Apple Intelligence 우선'은 Apple Intelligence가 켜져 있고 해당 언어를 지원하면 그 모델을 우선 쓰고, 사용할 수 없으면 Mac 기본 번역으로 처리합니다. 실제로 어느 모델이 쓰였는지는 시스템이 결정하며 앱에서 확인할 수 없습니다. 바꾸면 현재 본문과 이미지 글자를 다시 번역합니다."
                  : "Apple Intelligence 우선 번역은 macOS 26.4 이상에서만 선택할 수 있습니다.")
                  + " ChatGPT·Claude·Gemini는 설정에서 로그인한 웹 계정으로 번역하며, 고르기만 해서는 메일을 보내지 않고 번역을 실행할 때만 제목·본문·이미지 글자를 보냅니다. 고른 방식은 다음 메일과 화면 번역에도 함께 쓰입니다.")
        }
        ToolbarItem(id: "display", placement: .automatic) {
            Menu {
                Picker("표시 방식", selection: $model.displayMode) {
                    ForEach(DisplayMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("HTML 메일 원본 서식 유지", isOn: $model.preferFormattedHTML)
                Toggle("이미지 번역 상세 목록 펼치기", isOn: $model.showOCRDetails)
                Toggle("인식 영역 번호 표시(디버그)", isOn: $model.showOCRBoxes)
                Toggle("창을 항상 위에 유지", isOn: $model.keepOnTop)
            } label: {
                Label("보기", systemImage: "eye")
            }
            .help("표시 방식")
        }
        ToolbarItem(id: "remote-images", placement: .automatic) {
            Button {
                confirmRemoteImages = true
            } label: {
                Label("원격 이미지 불러오기", systemImage: "photo.on.rectangle")
            }
            .disabled(!model.hasUnrequestedRemoteImages)
            .help("이 메시지의 원격 이미지를 한 번만 불러옵니다 (Mail에서 선택해 번역한 메시지는 자동으로 불러옵니다)")
        }
        ToolbarItem(id: "copy", placement: .automatic) {
            Button {
                model.copyTranslation()
            } label: {
                Label("번역 복사", systemImage: "doc.on.doc")
            }
            .disabled(model.document == nil)
            .help("번역된 내용을 클립보드에 복사합니다")
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in AppModel.shared.open(url: url) }
        }
        return true
    }
}

// MARK: - 상태 표시줄

private struct StatusBar: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                statusContent
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)

            if let error = model.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if model.errorNeedsAutomationSettings {
                        Button("자동화 설정 열기…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    Button(".eml 파일 열기…") { model.showImporter = true }
                    Button("닫기") { model.errorMessage = nil }
                }
                .font(.callout)
                .padding(10)
                .background(Color.orange.opacity(0.12))
            }
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        if model.isLoading {
            ProgressView().controlSize(.small)
            Text(model.loadingMessage)
        } else if model.document != nil {
            let p = model.progress
            if model.formattedBodyPending {
                // 서식 본문의 텍스트를 아직 찾는 중이면 전체 진행률/완료를 표시하지 않는다.
                ProgressView().controlSize(.small)
                Text("원본 서식 본문 분석 중…")
            } else if let provider = model.externalProvider {
                externalStatus(provider, progress: p)
            } else if p.pending > 0 && model.translationPhase == .preparing {
                ProgressView().controlSize(.small)
                Text("번역 준비 중… (언어 팩 확인)")
            } else if p.pending > 0 {
                ProgressView(value: Double(p.done + p.failed), total: Double(max(p.total, 1)))
                    .frame(width: 120)
                Text("번역 중 \(p.done + p.failed)/\(p.total)")
            } else if model.imageWorkInProgress {
                // 원격 이미지·OCR이 남아 있으면 완료로 표시하지 않는다.
                ProgressView().controlSize(.small)
                Text("이미지 처리 중… (본문 \(p.done + p.failed)/\(p.total))")
            } else if p.total == 0 {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                Text("번역할 텍스트가 없거나 이미 대상 언어입니다.")
            } else {
                Image(systemName: p.failed > 0 ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundStyle(p.failed > 0 ? .orange : .green)
                Text(p.failed > 0 ? "번역 완료 · \(p.failed)개 부분 실패" : "번역 완료")
            }
            let remote = model.remoteProgress
            if remote.loading > 0 {
                Text("· 원격 이미지 불러오는 중 \(remote.loaded + remote.failed)/\(remote.loading + remote.loaded + remote.failed)")
                    .foregroundStyle(.secondary)
            }
            if remote.failed > 0 {
                Text("· 원격 이미지 \(remote.failed)개 실패")
                    .foregroundStyle(.orange)
            }
            if model.runningOCRCount > 0 {
                Text("· 이미지 글자 인식 중")
                    .foregroundStyle(.secondary)
            }
            Text("· \(model.backend.title)")
                .foregroundStyle(.secondary)
                .help(model.backend.isExternal ? "\(model.backend.title) 웹 계정 — 외부 전송"
                      : model.backend == .intelligence ? "Apple Intelligence 우선 — AI 사용 불가 시 기본 번역" : "Mac 기본 번역")
            if model.sourceLanguageID == "auto", let key = model.documentLanguageKey {
                Text("· 감지된 언어: \(AppModel.languageName(key))")
                    .foregroundStyle(.secondary)
            }
            if let failure = model.groupFailures.values.first {
                Text("· \(failure)")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        } else {
            Text("Mail에서 메시지를 선택한 뒤 Mail › 서비스 › 메일 전체 번역을 고르세요.")
                .foregroundStyle(.secondary)
        }
    }

    /// 외부 AI 번역 상태: 실행 전 대기 · 진행(남은 시간·취소) · 실패(다시 시도·수동 진행·로그인 관리) · 완료
    @ViewBuilder
    private func externalStatus(_ provider: AIProvider, progress p: (done: Int, failed: Int, pending: Int, total: Int)) -> some View {
        switch model.externalPhase {
        case .running:
            if let status = AIBIRunner.shared.status {
                AIBIProgressRow(status: status)
            } else {
                ProgressView().controlSize(.small)
                Text("\(provider.title) 준비 중")
            }
            Text("(\(p.done + p.failed)/\(p.total))").foregroundStyle(.secondary)
            Button("취소") { model.cancelExternal() }
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Button("다시 시도") { model.requestExternalTranslation() }
            Button("수동으로 진행") { model.startExternalManual() }
                .help("공식 화면을 열고 요청 복사·응답 붙여넣기로 진행합니다(응답은 같은 형식 검증을 거칩니다)")
            Button("로그인 관리") { MailWindowCoordinator.shared.showSettings() }
        case .idle, .awaitingAction:
            if p.pending > 0 {
                Image(systemName: "paperplane").foregroundStyle(.secondary)
                Text(p.done > 0 ? "\(p.pending)개 항목 남음" : "\(p.pending)개 항목 번역 대기")
                Button(p.done > 0 ? "이어서 번역" : "\(provider.title)로 번역") { model.requestExternalTranslation() }
                    .buttonStyle(.borderedProminent)
                    .help("실행하면 제목·본문 텍스트·이미지 글자(OCR)가 \(provider.title) 웹 계정 대화로 전송됩니다")
                Button("로그인 관리") { MailWindowCoordinator.shared.showSettings() }
            } else if model.imageWorkInProgress {
                ProgressView().controlSize(.small)
                Text("이미지 처리 중… (본문 \(p.done + p.failed)/\(p.total))")
            } else if p.total == 0 {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                Text("번역할 텍스트가 없거나 이미 대상 언어입니다.")
            } else {
                Image(systemName: p.failed > 0 ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundStyle(p.failed > 0 ? .orange : .green)
                Text(p.failed > 0 ? "번역 완료 · \(p.failed)개 부분 실패" : "번역 완료")
                if p.failed > 0 { Button("실패 항목 다시 번역") { model.retryExternalFailures() } }
            }
        }
    }
}

// MARK: - 빈 화면

private struct EmptyStateView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope.open")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("메일 번역")
                .font(.title2.bold())
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Mail에서 번역할 메시지를 하나 선택합니다.")
                Text("2. Mail 메뉴 막대의 Mail › 서비스 › 메일 전체 번역을 고릅니다.")
                Text("   (이 창의 '선택한 메일 번역'(⇧⌘T), 메뉴 막대의 '선택한 메일 번역', 전역 단축키 \(GlobalHotKey.mailDisplayString)도 같은 동작입니다.)")
                    .foregroundStyle(.secondary)
                Text("처음에는 'Mail 제어' 허용 여부를 묻는 시스템 창이 나타날 수 있습니다.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("선택한 메일 번역") { model.translateSelectedMail() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button(".eml/이미지 파일 열기…") { model.showImporter = true }
            }
            Text("또는 .eml 파일이나 이미지를 이 창으로 끌어다 놓으세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Group {
                if let provider = model.externalProvider {
                    Text("번역 방식: \(provider.title)(웹 로그인). 실행할 때만 메일 제목·본문·이미지 글자(OCR)가 전송됩니다. 메일 파일은 별도로 저장하지 않지만, AI 웹사이트의 캐시·대화 기록에는 남을 수 있습니다. 본문에 포함된 개인정보도 전송될 수 있습니다.")
                } else {
                    Text("번역과 글자 인식은 이 Mac 안에서 이루어지며, 메일 내용을 저장하거나 외부로 보내지 않습니다.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 문서

private struct DocumentView: View {
    let document: MailDocument
    let model: AppModel

    var body: some View {
        ScrollView {
            Group {
                if model.usesFormattedBody, let formatted = document.formattedHTML {
                    // 웹 보기는 지연 생성 스택에서 화면 밖으로 나가면 다시 만들어질 수 있으므로 일반 VStack을 쓴다.
                    let range = formatted.blockRange.clamped(to: 0..<document.blocks.count)
                    VStack(alignment: .leading, spacing: 12) {
                        header
                        notices
                        ForEach(document.blocks[..<range.lowerBound]) { block in
                            BlockView(block: block, model: model)
                        }
                        FormattedBodyView(document: document, formatted: formatted, model: model)
                        ForEach(document.blocks[range.upperBound...]) { block in
                            BlockView(block: block, model: model)
                        }
                        attachments
                        footer
                    }
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        header
                        notices
                        ForEach(document.blocks) { block in
                            BlockView(block: block, model: model)
                        }
                        attachments
                        footer
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(document.id)
    }

    private var footer: some View {
        Text("원본 메일은 변경되지 않았습니다. 창을 닫으면 앱의 메모리에서 내용이 사라집니다."
             + (model.backend.isExternal ? " 외부 AI로 이미 보낸 내용은 해당 서비스 대화 기록에 남을 수 있습니다." : ""))
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.top, 16)
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let subject = document.subject {
                TranslatedTextView(segmentID: "subject", original: subject, style: .heading(3), model: model)
            } else if case .imageFile = document.origin {
                Text("이미지 번역").font(.title3.bold())
            } else {
                Text("(제목 없음)").font(.title3.bold()).foregroundStyle(.secondary)
            }
            if !document.headerLines.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 2) {
                    ForEach(Array(document.headerLines.enumerated()), id: \.offset) { _, line in
                        GridRow {
                            Text(line.label).foregroundStyle(.secondary)
                            Text(line.value).textSelection(.enabled)
                        }
                    }
                }
                .font(.caption)
            }
            Divider().padding(.top, 4)
        }
    }

    @ViewBuilder
    private var notices: some View {
        let messages: [String] = {
            var list: [String] = []
            if case .mail(let count) = document.origin, count > 1 {
                list.append("Mail에서 메시지 \(count)개가 선택되어 있어 첫 번째 메시지만 번역했습니다.")
            }
            if let provider = model.externalProvider {
                list.append("외부 AI 번역(\(provider.title)): 번역을 실행하면 제목·본문 텍스트·이미지 속 글자(OCR)가 로그인한 \(provider.title) 웹 계정 대화로 전송되어 그 대화 기록에 남을 수 있습니다. 원본 HTML·이미지 파일·주소 헤더는 보내지 않습니다.")
            }
            if model.remoteAutoRequested {
                list.append("요청한 메시지의 원격 이미지 \(model.remoteImageCount)개를 자동으로 불러왔습니다. 이미지 서버에 이 Mac의 IP 주소와 열람 시각이 전달될 수 있습니다. (HTTPS만, 쿠키·캐시 없이 메모리로만)")
            }
            if let reason = model.formattedFailureMessage, model.preferFormattedHTML {
                list.append("원본 서식으로 표시하지 못해 읽기용 텍스트로 표시합니다. (\(reason))")
            }
            if model.usesFormattedBody, let blocked = document.formattedHTML?.blockedResources, blocked > 0 {
                list.append("원본 서식 보기에서 메일 밖 주소를 가리키는 CSS 배경 이미지·글꼴 등 \(blocked)개는 불러오지 않았습니다.")
            }
            if model.hasUnrequestedRemoteImages {
                list.append("필요하면 도구 막대의 '원격 이미지 불러오기'로 이 메시지에 한해 불러올 수 있습니다.")
            }
            return list + document.notices
        }()
        if !messages.isEmpty {
            DisclosureGroup("알림 \(messages.count)개") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(messages, id: \.self) { message in
                        Label(message, systemImage: "info.circle")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)
            .tint(.secondary)
        }
    }

    @ViewBuilder
    private var attachments: some View {
        if !document.attachments.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("첨부 파일").font(.headline)
                ForEach(document.attachments) { item in
                    HStack {
                        Image(systemName: "paperclip").foregroundStyle(.secondary)
                        Text(item.name).textSelection(.enabled)
                        Text(item.mimeType).foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                Text("이미지가 아닌 첨부 파일은 열거나 번역하지 않습니다. 첨부된 메일(.eml)은 본문에 펼쳐서 번역합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 12)
        }
    }
}

// MARK: - 블록

private struct BlockView: View {
    let block: ContentBlock
    let model: AppModel

    var body: some View {
        switch block.kind {
        case .text(let style, let original):
            if style == .caption {
                Text(original).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                TranslatedTextView(segmentID: block.id, original: original, style: style, model: model)
            }
        case .image(let assetID):
            ImageBlockView(assetID: assetID, model: model)
        case .remoteImage(let url, let alt):
            if case .loaded(let assetID)? = model.remoteStates[block.id] {
                ImageBlockView(assetID: assetID, model: model)
            } else {
                let state = model.remoteStates[block.id]
                PlaceholderView(
                    title: {
                        switch state {
                        case .loading?: return "원격 이미지"
                        case .failed?: return "원격 이미지 (불러오기 실패)"
                        default: return "원격 이미지 (불러오지 않음)"
                        }
                    }(),
                    detail: url?.host(),
                    alt: alt,
                    state: model.remoteStates[block.id]
                )
            }
        case .missingImage(let alt):
            PlaceholderView(title: "메일 안에서 찾을 수 없는 이미지", detail: nil, alt: alt, state: nil)
        case .sectionTitle(let title):
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        case .divider:
            Divider().padding(.vertical, 4)
        }
    }
}

private struct PlaceholderView: View {
    let title: String
    let detail: String?
    let alt: String?
    let state: RemoteImageState?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "photo")
                .foregroundStyle(.secondary)
            if let detail { Text(detail).font(.caption).foregroundStyle(.tertiary) }
            if let alt, !alt.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("대체 텍스트: \(alt)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            switch state {
            case .loading?:
                HStack { ProgressView().controlSize(.mini); Text("불러오는 중…") }.font(.caption)
            case .failed(let message)?:
                Text(message).font(.caption).foregroundStyle(.orange)
            default:
                EmptyView()
            }
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5]))
        )
    }
}

struct TranslatedTextView: View {
    let segmentID: String
    let original: String
    let style: TextBlockStyle
    let model: AppModel
    var compact = false

    var body: some View {
        decorated(
            VStack(alignment: .leading, spacing: 3) { content }
        )
    }

    @ViewBuilder
    private var content: some View {
        let state = model.segmentStates[segmentID]
        switch (model.displayMode, state) {
        case (.original, _):
            styled(original)
        case (.translation, .done(let translated)?):
            styled(translated)
        case (.both, .done(let translated)?):
            styled(translated)
            Text(original)
                .font(compact ? .caption : .callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        default:
            styled(original)
            statusLine(state)
        }
    }

    @ViewBuilder
    private func statusLine(_ state: SegmentState?) -> some View {
        switch state {
        case .pending?:
            HStack(spacing: 4) {
                if !model.backend.isExternal || model.externalPhase == .running {
                    ProgressView().controlSize(.mini)
                }
                Text(model.pendingLabel)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .failed(let message)?:
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }

    private func styled(_ text: String) -> some View {
        Text(text)
            .font(font)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var font: Font {
        if compact { return .callout }
        switch style {
        case .heading(1): return .title.bold()
        case .heading(2): return .title2.bold()
        case .heading(3): return .title3.bold()
        case .heading: return .headline
        case .preformatted: return .system(.body, design: .monospaced)
        case .caption: return .callout
        default: return .body
        }
    }

    @ViewBuilder
    private func decorated<V: View>(_ view: V) -> some View {
        switch style {
        case .listItem(let depth, let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).frame(minWidth: 18, alignment: .trailing)
                view
            }
            .padding(.leading, CGFloat(max(depth - 1, 0)) * 18)
        case .quote(let depth):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.4))
                    .frame(width: 3)
                view
            }
            .padding(.leading, CGFloat(max(depth - 1, 0)) * 10)
        case .preformatted, .tableRow:
            view
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.07)))
        case .heading:
            view.padding(.top, 4)
        default:
            view
        }
    }
}

// MARK: - 이미지 + OCR 번역 캡션

private struct ImageBlockView: View {
    let assetID: String
    let model: AppModel
    @State private var detailsExpanded = false

    var body: some View {
        if let asset = model.document?.assets[assetID] {
            VStack(alignment: .leading, spacing: 6) {
                Image(nsImage: asset.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .overlay { translationOverlay }
                    .overlay { debugRegionOverlay }
                    .frame(maxWidth: min(max(asset.pixelSize.width, 1), 760), alignment: .leading)
                statusLine
                if model.showOCRDetails { detailDisclosure }
            }
        }
    }

    private var regions: [OCRRegion] {
        if case .done(let regions)? = model.ocrStates[assetID] { return regions }
        return []
    }

    /// 번역이 실제로 바뀌었고 숫자·코드만이 아닌 영역만 제자리 오버레이로 그린다.
    private func overlayText(for region: OCRRegion) -> String? {
        guard model.displayMode != .original, region.hasMeaningfulLetters else { return nil }
        guard case .done(let translated)? = model.segmentStates[region.id] else { return nil }
        let a = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = region.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, a.caseInsensitiveCompare(b) != .orderedSame else { return nil }
        return a
    }

    private var meaningfulRegions: [OCRRegion] {
        regions.filter(\.hasMeaningfulLetters)
    }

    /// 원본 이미지 픽셀은 바꾸지 않고, 인식된 자리 위에 번역문을 덮어 보여 준다(완벽한 자연스러운 인페인팅은 흉내 내지 않음).
    @ViewBuilder
    private var translationOverlay: some View {
        if !regions.isEmpty {
            GeometryReader { geo in
                ForEach(Array(regions.enumerated()), id: \.element.id) { _, region in
                    if let text = overlayText(for: region) {
                        let rect = CGRect(x: region.box.minX * geo.size.width,
                                          y: region.box.minY * geo.size.height,
                                          width: region.box.width * geo.size.width,
                                          height: region.box.height * geo.size.height)
                        if rect.width >= 10, rect.height >= 8 {
                            Text(text)
                                .font(.system(size: max(8, min(rect.height * 0.62, 28))))
                                .minimumScaleFactor(0.3)
                                .lineLimit(nil)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(Color(hex: region.foregroundHex))
                                .padding(.horizontal, 2)
                                .frame(width: rect.width, height: rect.height)
                                .background(Color(hex: region.backgroundHex).opacity(0.88))
                                .cornerRadius(2)
                                .position(x: rect.midX, y: rect.midY)
                        }
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// 디버그용 번호 사각형(기본 숨김, 보기 메뉴에서 켤 수 있음)
    @ViewBuilder
    private var debugRegionOverlay: some View {
        if model.showOCRBoxes, !regions.isEmpty {
            GeometryReader { geo in
                ForEach(Array(regions.enumerated()), id: \.element.id) { index, region in
                    let rect = CGRect(x: region.box.minX * geo.size.width,
                                      y: region.box.minY * geo.size.height,
                                      width: region.box.width * geo.size.width,
                                      height: region.box.height * geo.size.height)
                    Rectangle()
                        .stroke(Color.accentColor.opacity(0.8), lineWidth: 1.5)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                    Text("\(index + 1)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 3))
                        .position(x: max(rect.minX, 8), y: max(rect.minY, 8))
                }
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.ocrStates[assetID] {
        case .running?:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("이미지 속 글자 인식 중…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .failed(let message)?:
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }

    /// 전체 OCR 원문·번역 목록은 기본적으로 접혀 있다(큰 목록 대신 필요할 때만 펼침).
    @ViewBuilder
    private var detailDisclosure: some View {
        if !meaningfulRegions.isEmpty {
            DisclosureGroup(isExpanded: Binding(
                get: { detailsExpanded || model.showOCRDetails },
                set: { detailsExpanded = $0 }
            )) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(meaningfulRegions) { region in
                        TranslatedTextView(segmentID: region.id, original: region.text,
                                           style: .paragraph, model: model, compact: true)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("이미지 번역 상세 (\(meaningfulRegions.count)개) · 원본 이미지는 그대로 표시")
            }
            .font(.caption)
            .tint(.secondary)
        }
    }
}

private extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}
