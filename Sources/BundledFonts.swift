import AppKit
import CoreText

/// 번역문 글꼴 갈래(화면 번역·브라우저 이미지 OCR 공용 개념). 자동은 원본 글자 획 특징으로 고르고,
/// 수동 글꼴 중 하나를 고르면 항상 그 글꼴을 쓴다(정확한 글꼴 식별이 아닌 거친 추정 + 수동 전환).
enum FontStyle: String, CaseIterable, Equatable, Hashable {
    case auto, gothic, myeongjo, gungseo, hand

    static func validated(_ raw: String?) -> FontStyle {
        raw.flatMap(FontStyle.init(rawValue:)) ?? .auto
    }
}

/// 패키지에 포함한 글꼴(각 배포 라이선스 동봉)을 앱 프로세스 범위에만 등록한다(시스템 글꼴 목록에 설치하지 않고,
/// 사용자 설치 글꼴에도 의존하지 않는다). 실행 중 한 번만 등록하면 되므로 앱 시작 때 호출한다.
enum BundledFonts {
    /// (파일 이름, PostScript 이름) — 글꼴 자체는 수정·서브셋하지 않은 원본 그대로 번들에 둔다.
    private static let files: [FontStyle: (file: String, postScriptName: String)] = [
        .gothic: ("NanumGothic-Regular", "NanumGothic"),
        .myeongjo: ("NanumMyeongjo-Regular", "NanumMyeongjo"),
        .gungseo: ("ChosunGs", "ChosunGs"),
        .hand: ("NanumPenScript-Regular", "NanumPen-Regular")
    ]

    private static var didRegister = false

    static func registerIfNeeded() {
        guard !didRegister else { return }
        didRegister = true
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts") else { return }
        for (_, info) in files {
            let url = dir.appendingPathComponent("\(info.file).ttf")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        }
    }

    /// 화면 번역 패치에 쓸 NSFont. 등록 실패·파일 없음 등은 시스템 글꼴로 조용히 대체한다(크래시 금지).
    static func font(for style: FontStyle, size: CGFloat) -> NSFont {
        guard style != .auto, let info = files[style], let font = NSFont(name: info.postScriptName, size: size) else {
            return NSFont.systemFont(ofSize: size, weight: .medium)
        }
        return font
    }

    private static var opticalScaleCache: [FontStyle: CGFloat] = [:]

    /// NanumPenScript 등 손글씨 글꼴은 같은 pointSize라도 capHeight(실제 글자 몸통 높이)가 고딕보다 작아
    /// 체감상 더 작게 보인다. 임의의 배율이 아니라 번들 글꼴 자신의 실측 capHeight 비율로 보정값을 구해,
    /// 그 글꼴로 그릴 때 요청 크기에 곱해 체감 크기를 고딕과 맞춘다. 1 미만(이미 더 커 보임)은 보정하지 않는다.
    static func opticalScale(for style: FontStyle) -> CGFloat {
        guard style != .auto, style != .gothic else { return 1 }
        if let cached = opticalScaleCache[style] { return cached }
        let probeSize: CGFloat = 100
        guard let gothic = font(for: .gothic, size: probeSize) as NSFont?,
              let other = font(for: style, size: probeSize) as NSFont?,
              other.capHeight > 0 else {
            opticalScaleCache[style] = 1
            return 1
        }
        let scale = min(max(gothic.capHeight / other.capHeight, 1), 1.8)
        opticalScaleCache[style] = scale
        return scale
    }
}
