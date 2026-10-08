import AppKit

/// 캡처 영역(인터리어) 내부에서 원문 OCR 줄의 위치에 맞춰 번역문을 겹쳐 그리는 뷰.
/// 각 패치는 창 뒤 화면을 흐리게 비추는 네이티브 behindWindow 머티리얼 위에 약 70%
/// 중립 틴트를 얹어 배경과 어우러지되 원문 글자는 흐려 보이게 하고, 번역문은 완전
/// 불투명 고대비로 그린다. 패치가 없는 나머지 영역은 완전히 투명하다.
/// 스트리밍 번역 응답이 올 때마다 add(patch:)로 한 줄씩 즉시 추가된다.
final class TranslationPatchesView: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static let horizontalPadding: CGFloat = 3
    private static let verticalPadding: CGFloat = 2
    private static let tintOpacity: CGFloat = 0.70

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    func removeAllPatches() {
        subviews.forEach { $0.removeFromSuperview() }
    }

    func add(patch: TranslatedPatch) {
        guard !patch.translatedText.isEmpty else { return }

        let rawFrame = NSRect(
            x: patch.boundingBox.minX * bounds.width,
            y: patch.boundingBox.minY * bounds.height,
            width: max(1, patch.boundingBox.width * bounds.width),
            height: max(1, patch.boundingBox.height * bounds.height)
        )
        let frame = rawFrame.insetBy(dx: -Self.horizontalPadding, dy: -Self.verticalPadding).integral

        let blur = NSVisualEffectView(frame: frame)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 4
        blur.layer?.masksToBounds = true

        let tint = NSView(frame: blur.bounds)
        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]
        tint.layer?.backgroundColor = (isDark
            ? NSColor(calibratedWhite: 0.12, alpha: Self.tintOpacity)
            : NSColor(calibratedWhite: 0.96, alpha: Self.tintOpacity)).cgColor
        blur.addSubview(tint)

        let font = fittingFont(for: patch.translatedText, in: frame.size)
        let label = NSTextField(wrappingLabelWithString: patch.translatedText)
        label.font = font
        label.textColor = isDark ? .white : .black
        label.alignment = .left
        label.maximumNumberOfLines = 0
        label.drawsBackground = false
        let textWidth = frame.width - Self.horizontalPadding * 2
        let textHeight = min(frame.height, textBoundingHeight(patch.translatedText, font: font, width: textWidth))
        label.frame = NSRect(
            x: Self.horizontalPadding,
            y: (frame.height - textHeight) / 2,
            width: textWidth,
            height: textHeight
        )
        blur.addSubview(label)

        addSubview(blur)
    }

    private func textBoundingHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        ceil((text as NSString).boundingRect(
            with: NSSize(width: max(1, width - 4), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).height) + 2
    }

    /// 박스 높이에 맞춰 폰트 크기를 줄여가며 줄바꿈으로 채워지도록 크기를 고른다.
    private func fittingFont(for text: String, in size: NSSize) -> NSFont {
        var fontSize = max(9, min(18, size.height * 0.7))
        let minFontSize: CGFloat = 8
        while fontSize > minFontSize {
            let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
            if textBoundingHeight(text, font: font, width: size.width - Self.horizontalPadding * 2) <= size.height {
                return font
            }
            fontSize -= 1
        }
        return NSFont.systemFont(ofSize: minFontSize, weight: .medium)
    }
}

/// '원문보기' 시 방금 캡처해 메모리에 보관한 원본 이미지를 같은 영역에 그대로 보여준다.
final class OriginalImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
