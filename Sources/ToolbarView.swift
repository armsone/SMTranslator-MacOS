import SwiftUI
import Translation
import AppKit

/// 통합 창 헤더 아래쪽 툴바 행. 언어 선택, 번역 방식(메일과 공용), 항상 위, 이동·크기 잠금, 복사, 색상 설정을
/// 담는다. 주 버튼('번역' ↔ '원문보기')은 위쪽 제목 스트립으로 옮겨졌으며(TitleDragStripView),
/// 닫기(숨기기)도 그 줄과 메뉴 막대 메뉴에 있다. 이 뷰의 .translationTask는 주 버튼의 위치와
/// 무관하게 창이 보이는 동안 계속 살아 있어야 하므로 버튼 유무와 분리해 HStack에 붙여 둔다.
struct ToolbarView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var isColorPopoverPresented = false
    @State private var methods = TranslationBackendStore.shared

    private var isLocked: Binding<Bool> {
        Binding(get: { !viewModel.isAdjustable }, set: { viewModel.isAdjustable = !$0 })
    }

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $viewModel.sourceLanguage) {
                ForEach(SourceSelection.allCases) { source in
                    Text(source.displayNameKorean).tag(source)
                }
            }
            .labelsHidden()
            .frame(width: 92)
            .help("원문 언어. 자동 인식(기본)은 일본어·영어처럼 섞인 화면도 줄마다 언어를 판별해 한 번에 번역합니다.")

            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Picker("", selection: $viewModel.targetLanguage) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.displayNameKorean).tag(lang)
                }
            }
            .labelsHidden()
            .frame(width: 92)
            .help("번역 언어")

            Menu {
                Picker("번역 방식", selection: $methods.backend) {
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
                .pickerStyle(.inline)
                Divider()
                Button("외부 AI 로그인·설정…") { MailWindowCoordinator.shared.showSettings() }
            } label: {
                Text(methods.backend.shortTitle)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(methods.backend.isExternal
                  ? "번역 방식: \(methods.backend.title) 웹 계정. 고르기만 해서는 보내지 않으며, 번역을 누를 때만 이 영역에서 인식한 글자(텍스트)를 보냅니다. 스크린샷 이미지는 보내지 않습니다. 메일 번역과 같은 방식을 씁니다."
                  : "번역 방식: \(methods.backend.title). 이 Mac 안에서 번역합니다. 메일 번역과 같은 방식을 씁니다.")

            Divider().frame(height: 16)

            Toggle(isOn: $viewModel.isAlwaysOnTop) {
                Image(systemName: viewModel.isAlwaysOnTop ? "pin.fill" : "pin.slash")
            }
            .toggleStyle(.button)
            .help("항상 위에 고정 (기본 켜짐)")

            Toggle(isOn: isLocked) {
                Label("이동·크기 잠금", systemImage: viewModel.isAdjustable ? "lock.open" : "lock.fill")
            }
            .toggleStyle(.button)
            .help("이동·크기 잠금: 켜면 창 이동과 가장자리 크기 조절만 막힙니다. 번역 버튼과 툴바는 계속 동작합니다.")

            Button(action: { viewModel.copyTranslatedText() }) {
                Image(systemName: "doc.on.doc")
            }
            .disabled(viewModel.translatedPatches.isEmpty)
            .help("번역문 복사")

            Button(action: { isColorPopoverPresented.toggle() }) {
                Image(systemName: "paintpalette")
            }
            .help("번역문 글자색·배경색·진하기 설정")
            .popover(isPresented: $isColorPopoverPresented, arrowEdge: .bottom) {
                PatchColorSettingsView(viewModel: viewModel)
            }

            Spacer(minLength: 4)
        }
        .controlSize(.small)
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .frame(height: OverlayGeometry.toolbarHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .translationTask(viewModel.translationConfiguration) { session in
            // 세션은 이 클로저 생명주기 동안만 유효하다. 언어 조합이 바뀌지 않는 한
            // 클로저가 유지되어 같은 세션(로드된 모델)을 캡처마다 재사용한다.
            let jobs = viewModel.openJobChannel()
            for await job in jobs {
                guard viewModel.isJobCurrent(job.generation) else { continue }
                var failure: Error?
                // 묶음마다 한 언어만 담긴다. 원문 언어가 nil(자동 인식)인 같은 세션이 묶음마다 언어를 새로 식별한다.
                for batch in job.batches {
                    guard viewModel.isJobCurrent(job.generation), !Task.isCancelled else { break }
                    do {
                        // 스트리밍 배치: 각 줄 번역이 끝나는 즉시 응답이 도착한다.
                        for try await response in session.translate(batch: batch) {
                            guard viewModel.isJobCurrent(job.generation) else { break }
                            viewModel.receiveTranslation(response, generation: job.generation)
                        }
                    } catch {
                        // 한 묶음이 실패해도 이미 받은 줄은 두고 남은 묶음을 이어 번역한다(다른 방식으로 대체하지 않음).
                        if failure == nil { failure = error }
                    }
                }
                viewModel.finishTranslation(generation: job.generation, error: failure)
            }
        }
    }
}

/// 번역문 글자색·배경색·진하기 팝오버. 자동 켜짐이 기본값이며, 끄면 수동
/// ColorPicker가 활성화된다. 진하기 슬라이더는 자동/수동 모두에서 항상 동작한다.
private struct PatchColorSettingsView: View {
    @ObservedObject var viewModel: AppViewModel

    private var useAutoColors: Binding<Bool> {
        Binding(get: { viewModel.colorSettings.useAutoColors },
                set: { viewModel.colorSettings.useAutoColors = $0 })
    }

    private var manualBackgroundColor: Binding<Color> {
        Binding(get: { Color(viewModel.colorSettings.manualBackgroundColor.nsColor) },
                set: { viewModel.colorSettings.manualBackgroundColor = $0.rgbColor })
    }

    private var manualTextColor: Binding<Color> {
        Binding(get: { Color(viewModel.colorSettings.manualTextColor.nsColor) },
                set: { viewModel.colorSettings.manualTextColor = $0.rgbColor })
    }

    private var backgroundOpacity: Binding<Double> {
        Binding(get: { viewModel.colorSettings.backgroundOpacity },
                set: { viewModel.colorSettings.backgroundOpacity = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("번역문 색상")
                .font(.headline)

            Toggle("자동 색상 (캡처 배경에서 추출)", isOn: useAutoColors)
                .toggleStyle(.checkbox)
                .help("켜면 원문 줄 뒤 배경색을 캡처 이미지에서 추출해 배경으로 쓰고, 그 밝기에 맞춰 글자색을 검정/흰색 중 자동으로 고릅니다.")

            VStack(alignment: .leading, spacing: 6) {
                ColorPicker("배경색", selection: manualBackgroundColor, supportsOpacity: false)
                ColorPicker("글자색", selection: manualTextColor, supportsOpacity: false)
            }
            .disabled(viewModel.colorSettings.useAutoColors)
            .opacity(viewModel.colorSettings.useAutoColors ? 0.4 : 1)

            VStack(alignment: .leading, spacing: 4) {
                Text("진하기 \(Int((viewModel.colorSettings.backgroundOpacity * 100).rounded()))%")
                Slider(value: backgroundOpacity, in: 0...1)
            }
        }
        .padding(14)
        .frame(width: 220)
    }
}

private extension Color {
    /// ColorPicker 결과(Color)를 저장용 RGBColor로 변환. sRGB 변환 실패 시(이론상
    /// 발생하지 않음) 중립 회색으로 안전하게 대체한다.
    var rgbColor: RGBColor {
        guard let converted = NSColor(self).usingColorSpace(.sRGB) else {
            return RGBColor(red: 0.5, green: 0.5, blue: 0.5)
        }
        return RGBColor(red: converted.redComponent, green: converted.greenComponent, blue: converted.blueComponent)
    }
}
