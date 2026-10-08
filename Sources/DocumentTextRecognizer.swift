import CoreGraphics
import Foundation
import Vision

/// RecognizeDocumentsRequest(macOS 26+)로 인식한 문단 하나.
/// box는 Vision 원본 정규화 좌표(원점 좌하단, 0...1)이며, 호출자가 자신의 좌표계(화면 좌하단 vs
/// 이미지 좌상단)로 변환해 쓴다. 문서 API가 이미 세로쓰기 줄 순서를 보존해 묶은 문단이므로
/// 호출자는 이 문단을 다시 잘게 쪼개거나 가로 기준으로 재조합하지 않아야 한다.
struct DocumentTextParagraph {
    let text: String
    let box: CGRect
}

/// 공용 문서 텍스트 인식 헬퍼. 세로쓰기 일본어처럼 줄 순서가 중요한 콘텐츠를 위해
/// VNRecognizeTextRequest의 단순 줄 목록 대신 문서 구조(문단) 단위로 인식한다.
/// mac 15~25에서는 사용할 수 없으므로 호출자가 결과가 비었거나 에러(취소 제외)일 때
/// 기존 VNRecognizeTextRequest 경로로 폴백해야 한다.
@available(macOS 26.0, *)
enum DocumentTextRecognizer {
    /// 자동 인식 때 우선순위로 넘기는 언어 목록. 일본어로 고정하지 않고 앱이 지원하는
    /// 언어(ja/en/zh-Hans/zh-Hant/ko) 전체를 후보로 둔다. 기기가 지원하지 않는 후보는
    /// 호출부의 supportedRecognitionLanguages 필터에서 걸러진다.
    static let automaticLanguages: [Locale.Language] = [
        AppLanguage.japanese, .english, .chineseSimplified, .chineseTraditional, .korean
    ].map(\.localeLanguage)

    /// - Parameters:
    ///   - recognitionLanguages: 원문 언어를 직접 고른 경우 그 언어로 고정. nil이면 자동 인식(automaticLanguages 우선순위).
    static func recognizeParagraphs(
        in image: CGImage,
        recognitionLanguages: [Locale.Language]? = nil,
        useLanguageCorrection: Bool = true
    ) async throws -> [DocumentTextParagraph] {
        var request = RecognizeDocumentsRequest()
        request.barcodeDetectionOptions.enabled = false
        request.textRecognitionOptions.useLanguageCorrection = useLanguageCorrection
        if let recognitionLanguages, !recognitionLanguages.isEmpty {
            request.textRecognitionOptions.automaticallyDetectLanguage = false
            request.textRecognitionOptions.recognitionLanguages = recognitionLanguages
        } else {
            request.textRecognitionOptions.automaticallyDetectLanguage = true
            let supported = Set(request.supportedRecognitionLanguages)
            request.textRecognitionOptions.recognitionLanguages = automaticLanguages.filter(supported.contains)
        }

        let observations = try await request.perform(on: image)
        try Task.checkCancellation()
        return observations.flatMap(paragraphs(of:))
    }

    /// 문서의 문단을 그대로 텍스트 단위로 돌린다. 말풍선마다 보통 별도 문단이므로
    /// 서로 떨어진 문단을 다시 하나로 합치지 않는다.
    private static func paragraphs(of observation: DocumentObservation) -> [DocumentTextParagraph] {
        observation.document.paragraphs.compactMap { paragraph -> DocumentTextParagraph? in
            let text = paragraph.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let confidences = paragraph.lines.map(\.confidence)
            let averageConfidence = confidences.isEmpty ? 1 : confidences.reduce(0, +) / Float(confidences.count)
            guard averageConfidence >= 0.3 else { return nil }
            let box = paragraph.boundingRegion.normalizedPath.boundingBoxOfPath
            guard !box.isEmpty else { return nil }
            return DocumentTextParagraph(text: text, box: box)
        }
    }
}
