import AppKit

/// 캡처 영역(인터리어) 내부에서 원문 OCR 줄의 위치에 맞춰 번역문을 겹쳐 그리는 뷰.
/// 각 패치는 창 뒤 화면을 흐리게 비추는 네이티브 behindWindow 머티리얼 위에 사용자가 고른
/// (또는 캡처 이미지에서 추출한) 배경색을 얹어 원문 글자는 흐려 보이게 하고, 번역문은 완전
/// 불투명 고대비로 그린다. 패치가 없는 나머지 영역은 완전히 투명하다.
/// 스트리밍 번역 응답이 올 때마다 add(patch:)로 한 줄씩 즉시 추가된다.
final class TranslationPatchesView: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static let horizontalPadding: CGFloat = 3
    private static let verticalPadding: CGFloat = 2

    /// 글자색/배경색/진하기 설정. 바뀌면 이미 표시된 패치도 즉시 다시 칠한다.
    /// 뷰 몸체(draw)가 아니라 설정이 바뀔 때만 계산하므로 매 프레임 비용이 없다.
    var colorSettings = PatchColorSettings() {
        didSet { if oldValue != colorSettings { restyleAll() } }
    }

    private struct PatchRecord {
        let patch: TranslatedPatch
        let tint: NSView
        let label: NSTextField
    }

    private var records: [PatchRecord] = []

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    func removeAllPatches() {
        subviews.forEach { $0.removeFromSuperview() }
        records.removeAll()
    }

    /// 자동/수동 설정과 줄의 추출 배경색으로부터 실제 배경색·글자색을 계산한다.
    /// 실제 픽셀 추출이 불가능했던 줄(autoBackgroundColor == nil)은 중립 대체색을 쓴다.
    private func resolvedColors(for patch: TranslatedPatch) -> (background: NSColor, text: NSColor) {
        let opacity = CGFloat(max(0, min(1, colorSettings.backgroundOpacity)))
        if colorSettings.useAutoColors {
            let rgb = patch.autoBackgroundColor ?? .neutralFallback(isDark: isDark)
            let backgroundColor = rgb.nsColor.withAlphaComponent(opacity)
            let textColor: NSColor = rgb.luminance > 0.5 ? .black : .white
            return (backgroundColor, textColor)
        } else {
            let backgroundColor = colorSettings.manualBackgroundColor.nsColor.withAlphaComponent(opacity)
            return (backgroundColor, colorSettings.manualTextColor.nsColor)
        }
    }

    private func restyleAll() {
        for record in records {
            let colors = resolvedColors(for: record.patch)
            record.tint.layer?.backgroundColor = colors.background.cgColor
            record.label.textColor = colors.text
        }
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

        let container = NSView(frame: frame)
        container.wantsLayer = true
        container.layer?.cornerRadius = 4

        let blur = NSVisualEffectView(frame: container.bounds)
        blur.autoresizingMask = [.width, .height]
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 3
        blur.layer?.masksToBounds = true

        let tint = NSView(frame: blur.bounds)
        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]
        blur.addSubview(tint)

        let font = fittingFont(for: patch.translatedText, in: frame.size)
        let label = NSTextField(wrappingLabelWithString: patch.translatedText)
        label.font = font
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
        container.addSubview(blur)
        addSubview(container)

        let colors = resolvedColors(for: patch)
        tint.layer?.backgroundColor = colors.background.cgColor
        label.textColor = colors.text

        records.append(PatchRecord(patch: patch, tint: tint, label: label))
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
