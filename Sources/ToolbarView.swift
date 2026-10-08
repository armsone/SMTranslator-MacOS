import SwiftUI
import Translation
import AppKit

/// 통합 창 헤더 아래쪽 툴바 행. 언어 선택, 항상 위, 이동·크기 잠금, 복사, 그리고
/// 가장 오른쪽 주 버튼('캡처·번역' ↔ '원문보기')을 담는다. 닫기(숨기기)는 위쪽 제목
/// 스트립과 메뉴 막대 메뉴에 있다.
struct ToolbarView: View {
    @ObservedObject var viewModel: AppViewModel

    private var isLocked: Binding<Bool> {
        Binding(get: { !viewModel.isAdjustable }, set: { viewModel.isAdjustable = !$0 })
    }

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $viewModel.sourceLanguage) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.displayNameKorean).tag(lang)
                }
            }
            .labelsHidden()
            .frame(width: 92)
            .help("원문 언어")

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
            .help("이동·크기 잠금: 켜면 창 이동과 가장자리 크기 조절만 막힙니다. 캡처·번역과 툴바는 계속 동작합니다.")

            Button(action: { viewModel.copyTranslatedText() }) {
                Image(systemName: "doc.on.doc")
            }
            .disabled(viewModel.translatedPatches.isEmpty)
            .help("번역문 복사")

            Spacer(minLength: 4)

            // 가장 오른쪽 주 버튼. 창에 포커스가 있을 때 Space/Return/키패드 Enter도
            // 같은 동작을 실행한다(OverlayPanel.sendEvent).
            Button(action: { viewModel.performPrimaryAction() }) {
                HStack(spacing: 4) {
                    if viewModel.isProcessing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: viewModel.primaryAction.systemImage)
                    }
                    Text(viewModel.primaryAction.title)
                }
                .frame(minWidth: 78)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isProcessing)
            .help(viewModel.primaryAction == .showOriginal
                  ? "방금 캡처한 원본 화면을 같은 자리에 보여줍니다 (Space 또는 Enter)"
                  : "현재 영역을 한 번 캡처해 인식·번역합니다 (Space 또는 Enter)")
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
                do {
                    // 스트리밍 배치: 각 줄 번역이 끝나는 즉시 응답이 도착한다.
                    for try await response in session.translate(batch: job.requests) {
                        guard viewModel.isJobCurrent(job.generation) else { break }
                        viewModel.receiveTranslation(response, generation: job.generation)
                    }
                    viewModel.finishTranslation(generation: job.generation, error: nil)
                } catch {
                    viewModel.finishTranslation(generation: job.generation, error: error)
                }
            }
        }
    }
}
