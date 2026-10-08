import SwiftUI
import Translation
import AppKit

/// 화면에 보이지 않는, .translationTask 전용 호스트. 창이 보이는 동안 이 뷰가 계속 뷰 트리에
/// 남아 있어야 Apple 번역 세션(.translationTask 클로저와 그 안의 모델)이 크기 조절·헤더 레이아웃
/// 변경과 무관하게 계속 살아 있는다. 언어 조합이 바뀔 때만 클로저가 다시 시작된다.
struct ToolbarView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(viewModel.translationConfiguration) { session in
                let jobs = viewModel.openJobChannel()
                for await job in jobs {
                    guard viewModel.isJobCurrent(job.generation) else { continue }
                    var failure: Error?
                    // 묶음마다 한 언어만 담긴다. 묶음마다 그 언어를 명시한 configuration으로 세션을 새로 여므로
                    // 원문 언어가 nil인 세션으로 재판별하지 않는다.
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

/// 번역문 글자색·배경색·진하기 팝오버 콘텐츠. 자동 켜짐이 기본값이며, 끄면 수동
/// ColorPicker가 활성화된다. 진하기 슬라이더는 자동/수동 모두에서 항상 동작한다.
struct PatchColorSettingsView: View {
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

    private var fontStyle: Binding<FontStyle> {
        Binding(get: { viewModel.colorSettings.fontStyle },
                set: { viewModel.colorSettings.fontStyle = $0 })
    }

    private func fontStyleLabel(_ style: FontStyle) -> String {
        switch style {
        case .auto: return "자동(기본)"
        case .gothic: return "고딕"
        case .myeongjo: return "명조"
        case .hand: return "손글씨"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("번역문 색상")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("글꼴")
                Picker("글꼴", selection: fontStyle) {
                    ForEach(FontStyle.allCases, id: \.self) { style in
                        Text(fontStyleLabel(style)).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .help("자동은 원본 글자 획의 두께·규칙성을 가볍게 보고 고릅니다. 정확한 글꼴 식별은 아니며, 애매하면 고딕을 씁니다.")
            }

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
