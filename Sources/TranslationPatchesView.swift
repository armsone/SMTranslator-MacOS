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
            // 글꼴 선택이 바뀌었을 수 있으므로(색상과 달리 글자 크기 재계산이 필요) 같은 자리에서 다시 맞춘다.
            guard let blur = record.label.superview else { continue }
            let frameSize = blur.bounds.size
            let font = fittingFont(for: record.patch.translatedText, in: frameSize, fontStyleHint: record.patch.fontStyleHint)
            let textWidth = frameSize.width - Self.horizontalPadding * 2
            let textHeight = min(frameSize.height, textBoundingHeight(record.patch.translatedText, font: font, width: textWidth))
            record.label.font = font
            record.label.frame = NSRect(x: Self.horizontalPadding, y: (frameSize.height - textHeight) / 2,
                                        width: textWidth, height: textHeight)
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

        let font = fittingFont(for: patch.translatedText, in: frame.size, fontStyleHint: patch.fontStyleHint)
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

    /// Apple Intelligence 다듬기 등으로 같은 줄의 번역문만 바꾼다. 새 패치를 추가하지 않고(받은 줄 수에 영향 없음),
    /// 위치·크기·글꼴·색상 계산은 그대로 두고 글자만 바꾼다.
    func updateText(id: Int, text: String) {
        guard !text.isEmpty, let index = records.firstIndex(where: { $0.patch.id == id }) else { return }
        let record = records[index]
        guard let blur = record.label.superview else { return }
        let frameSize = blur.bounds.size
        let font = fittingFont(for: text, in: frameSize, fontStyleHint: record.patch.fontStyleHint)
        let textWidth = frameSize.width - Self.horizontalPadding * 2
        let textHeight = min(frameSize.height, textBoundingHeight(text, font: font, width: textWidth))
        record.label.font = font
        record.label.stringValue = text
        record.label.frame = NSRect(
            x: Self.horizontalPadding,
            y: (frameSize.height - textHeight) / 2,
            width: textWidth,
            height: textHeight
        )
        records[index] = PatchRecord(patch: TranslatedPatch(id: record.patch.id, translatedText: text,
                                                             boundingBox: record.patch.boundingBox,
                                                             autoBackgroundColor: record.patch.autoBackgroundColor,
                                                             fontStyleHint: record.patch.fontStyleHint),
                                      tint: record.tint, label: record.label)
    }

    private func textBoundingHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        ceil((text as NSString).boundingRect(
            with: NSSize(width: max(1, width - 4), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).height) + 2
    }

    /// 지금 쓸 글꼴 갈래: 사용자가 고딕/명조/손글씨를 직접 골랐으면 그대로, 자동이면 이 줄의 원본 글자
    /// 통계 힌트(fontStyleHint)로 고르고 미판별이면 고딕으로 대체한다(가짜 정확 식별이 아님).
    private func effectiveFontStyle(for fontStyleHint: String?) -> FontStyle {
        guard colorSettings.fontStyle == .auto else { return colorSettings.fontStyle }
        switch fontStyleHint {
        case "myeongjo": return .myeongjo
        case "hand": return .hand
        default: return .gothic
        }
    }

    /// 박스 높이에 맞춰 폰트 크기를 줄여가며 줄바꿈으로 채워지도록 크기를 고른다.
    private func fittingFont(for text: String, in size: NSSize, fontStyleHint: String?) -> NSFont {
        let style = effectiveFontStyle(for: fontStyleHint)
        // 손글씨처럼 같은 pointSize에서 실제 글자 몸통(capHeight)이 더 작게 찍히는 글꼴은, 실측 비율만큼
        // 요청 크기를 키워 체감 크기를 고딕과 맞춘다(임의 상수가 아니라 번들 글꼴 자신의 capHeight 비율).
        let scale = BundledFonts.opticalScale(for: style)
        var fontSize = (max(11, min(22, size.height * 0.847)) * scale).rounded()
        let minFontSize: CGFloat = (8 * scale).rounded()
        while fontSize > minFontSize {
            let font = BundledFonts.font(for: style, size: fontSize)
            if textBoundingHeight(text, font: font, width: size.width - Self.horizontalPadding * 2) <= size.height {
                return font
            }
            fontSize -= 1
        }
        return BundledFonts.font(for: style, size: minFontSize)
    }
}

/// '원문보기' 시 방금 캡처해 메모리에 보관한 원본 이미지를 같은 영역에 그대로 보여준다.
final class OriginalImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
