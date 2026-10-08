import CoreGraphics
import Foundation
import ImageIO
import Translation

// 브라우저 번역 엔진(앱 본체와 Safari 확장 공용). 확장이 보낸 요청을 검증하고, 페이지 글자 조각과
// 보이는 탭 캡처 중 이미지 영역만 잘라 OCR한 글자를 Mac 기본 번역(기기 내)으로 번역해 텍스트만 돌려준다.
// - 브라우저 번역은 앱의 번역 방식 설정(외부 AI 포함)을 읽거나 바꾸지 않는다. 기본은 Mac 기본 번역이며, 확장에서 사용자가
//   웹 번역 엔진(DeepL·Google·Papago)을 따로 고르고 동의한 요청만 앱이 연결한 외부 번역기(external)로 넘긴다(Safari 확장에는 없음).
// - 요청·응답 내용과 이미지는 메모리에서만 쓰고 디스크에 저장하거나 기록하지 않는다.
// - 요청 ID는 연결(scope)마다 따로 관리해 한 브라우저의 취소가 다른 브라우저 요청을 건드리지 않는다.

enum BrowserEngineError: Error {
    case badRequest(String)
    case disabled
    case busy
    case imageTooLarge
    case languageNotInstalled(String)
    case unsupportedPair(String)
    case requiresNewerMacOS
    case translationFailed(String)
    case externalUnavailable
    case externalBlocked(String)

    var code: String {
        switch self {
        case .badRequest: return "bad_request"
        case .disabled: return "app_disabled"
        case .busy: return "busy"
        case .imageTooLarge: return "image_too_large"
        case .languageNotInstalled: return "language_not_installed"
        case .unsupportedPair: return "unsupported_language"
        case .requiresNewerMacOS: return "requires_macos26"
        case .translationFailed: return "translation_failed"
        case .externalUnavailable: return "external_unavailable"
        case .externalBlocked: return "external_consent_required"
        }
    }

    var message: String {
        switch self {
        case .badRequest(let reason): return "잘못된 요청입니다(\(reason))."
        case .disabled: return "SMT 메뉴 막대 › '브라우저 번역…'에서 '브라우저 확장 연결 허용'을 켜 주세요."
        case .busy: return "처리 중인 요청이 많습니다. 잠시 뒤 다시 시도하세요."
        case .imageTooLarge: return "캡처 이미지가 너무 큽니다. 브라우저 창을 줄인 뒤 다시 시도하세요."
        case .languageNotInstalled(let pair):
            return "번역 언어 팩(\(pair))이 아직 없습니다. 시스템 설정 › 일반 › 언어 및 지역 › 번역 언어에서 내려받은 뒤 다시 번역하세요."
        case .unsupportedPair(let pair): return "Mac 기본 번역이 지원하지 않는 언어 조합입니다(\(pair))."
        case .requiresNewerMacOS: return "Safari 번역에는 macOS 26 이상이 필요합니다. Chrome·Whale 확장을 사용하세요."
        case .translationFailed(let reason): return "번역 실패: \(reason)"
        case .externalUnavailable:
            return "이 연결에서는 웹 번역(DeepL·Google·Papago)을 쓸 수 없습니다. Safari는 Mac 기본 번역만 지원합니다. 확장의 번역 엔진을 Mac 기본 번역으로 바꾸세요."
        case .externalBlocked(let reason): return reason
        }
    }
}

/// 언어 하나(source) → target 번역. 결과는 입력과 같은 개수이며, 받지 못한 항목은 nil이다.
protocol BrowserTextTranslating: AnyObject, Sendable {
    func supportedLanguageIDs() async -> [String]
    func translate(_ texts: [String], source: String, target: String) async throws -> [String?]
}

/// 웹 번역 엔진(앱 본체 전용). 항목마다 하나씩 번역하며, 결과는 입력과 같은 개수이고 받지 못한 항목은 nil이다.
/// 실행을 멈춰야 하는 오류는 그때까지 받은 결과와 함께 BrowserExternalFailure로 알린다.
protocol BrowserExternalTranslating: AnyObject, Sendable {
    var engineIDs: [String] { get }
    /// 지금 보낼 수 없으면(앱 쪽 동의 없음 등) 사용자에게 보여줄 이유
    func unavailableReason(engine: String) async -> String?
    func translate(_ texts: [String], source: String, target: String, engine: String) async throws -> [String?]
}

struct BrowserExternalFailure: Error {
    let results: [String?]
    let message: String
    /// true면 이 언어 조합만 실패(다른 언어 묶음은 계속)
    let unsupported: Bool
}

/// Apple Intelligence(기기 내) 다듬기(앱 본체의 Chrome·Whale 엔진 전용). Safari 확장은 앱 설정을 읽을 수 없어
/// 이 프로토콜을 쓰지 않는다(의도된 범위 제한). Mac 기본 번역 결과만 다듬으며, 거부·오류·취소·형식 오류는
/// 조용히 건너뛴다(기존 초안 유지). key가 없는 항목은 결과 딕셔너리에 담기지 않는다.
struct BrowserRefineItem: Sendable {
    let key: String
    let original: String
    let draft: String
}

protocol BrowserTextRefining: AnyObject, Sendable {
    var isAvailable: Bool { get }
    func refine(_ items: [BrowserRefineItem], targetLanguageName: String) async -> [String: String]
}

/// 지원하지 않는 환경(예: macOS 26 미만의 Safari 확장)에서 쓰는 번역기. 항상 실행 가능한 안내 오류를 낸다.
final class BrowserUnavailableTranslator: BrowserTextTranslating {
    func supportedLanguageIDs() async -> [String] { [] }
    func translate(_ texts: [String], source: String, target: String) async throws -> [String?] {
        throw BrowserEngineError.requiresNewerMacOS
    }
}

// MARK: - 요청 형식

struct BrowserImageRegionInput: Decodable {
    let k: String
    let x: Double
    let y: Double
    let w: Double
    let h: Double
}

private struct BrowserViewportInput: Decodable {
    let w: Double
    let h: Double
}

private struct BrowserRefineItemInput: Decodable {
    let k: String
    let o: String
    let d: String
}

private struct BrowserRawRequest: Decodable {
    let v: Int?
    let type: String
    let id: String?
    let target: String?
    let texts: [String]?
    let image: String?
    let viewport: BrowserViewportInput?
    let regions: [BrowserImageRegionInput]?
    let engine: String?
    let items: [BrowserRefineItemInput]?
}

enum BrowserRequest {
    case hello(id: String?)
    case cancel(id: String)
    case translate(id: String, target: AppLanguage, texts: [String], engine: String)
    case ocr(id: String, target: AppLanguage, image: Data, viewport: CGSize, regions: [BrowserImageRegionInput], engine: String)
    /// 이미 화면에 그려진 Mac 기본 번역 초안을 다듬는 작은 후속 요청(앱 본체의 Chrome·Whale 전용).
    case refine(id: String, target: AppLanguage, items: [BrowserRefineItem])

    static let maxTexts = 150
    static let maxTextLength = 5000
    static let maxTotalCharacters = 40_000
    static let maxRegions = 16
    static let maxImagePixels = 60_000_000
    static let maxImageSide = 12_000
    /// 기본 엔진(Mac 기본 번역). 확장이 engine을 보내지 않으면(구버전) 이 값이다.
    static let localEngine = "apple"
    static let externalEngines = ["deepl", "google", "papago"]
    /// 웹 번역 엔진은 항목마다 차례로 처리하므로 한 요청을 작게 받는다.
    static let maxExternalTexts = 12
    static let maxExternalCharacters = 15_000
    /// Apple Intelligence 후속 다듬기 요청(이미 그려진 결과만 소소하게 고침, 큰 묶음이 아니다).
    static let maxRefineItems = 8
    static let maxRefineItemCharacters = 700
    static let maxRefineCharacters = 4000

    static func parse(_ data: Data) throws -> BrowserRequest {
        let raw: BrowserRawRequest
        do {
            raw = try JSONDecoder().decode(BrowserRawRequest.self, from: data)
        } catch {
            throw BrowserEngineError.badRequest("형식")
        }
        guard raw.v == nil || raw.v == 1 else { throw BrowserEngineError.badRequest("버전") }
        switch raw.type {
        case "hello":
            return .hello(id: raw.id.flatMap { validKey($0) ? $0 : nil })
        case "cancel":
            return .cancel(id: try validID(raw.id))
        case "translate":
            let id = try validID(raw.id)
            let target = try validTarget(raw.target)
            let engine = try validEngine(raw.engine)
            let external = engine != localEngine
            guard let texts = raw.texts, !texts.isEmpty, texts.count <= (external ? maxExternalTexts : maxTexts) else {
                throw BrowserEngineError.badRequest("항목 수")
            }
            var total = 0
            for text in texts {
                guard text.count <= maxTextLength else { throw BrowserEngineError.badRequest("항목 길이") }
                total += text.count
            }
            guard total <= (external ? maxExternalCharacters : maxTotalCharacters) else { throw BrowserEngineError.badRequest("전체 길이") }
            return .translate(id: id, target: target, texts: texts, engine: engine)
        case "ocr":
            let id = try validID(raw.id)
            let target = try validTarget(raw.target)
            guard let viewport = raw.viewport, viewport.w.isFinite, viewport.h.isFinite,
                  (1...20_000).contains(viewport.w), (1...20_000).contains(viewport.h) else {
                throw BrowserEngineError.badRequest("화면 크기")
            }
            guard let regions = raw.regions, !regions.isEmpty, regions.count <= maxRegions else {
                throw BrowserEngineError.badRequest("이미지 영역 수")
            }
            for region in regions {
                guard validKey(region.k),
                      [region.x, region.y, region.w, region.h].allSatisfy({ $0.isFinite && abs($0) <= 100_000 }),
                      region.w >= 1, region.h >= 1 else { throw BrowserEngineError.badRequest("이미지 영역") }
            }
            guard let image = raw.image else { throw BrowserEngineError.badRequest("이미지") }
            let prefixes = ["data:image/jpeg;base64,", "data:image/png;base64,"]
            guard let prefix = prefixes.first(where: { image.hasPrefix($0) }),
                  let bytes = Data(base64Encoded: String(image.dropFirst(prefix.count))) else {
                throw BrowserEngineError.badRequest("이미지 형식")
            }
            return .ocr(id: id, target: target, image: bytes, viewport: CGSize(width: viewport.w, height: viewport.h), regions: regions,
                        engine: try validEngine(raw.engine))
        case "refine":
            let id = try validID(raw.id)
            let target = try validTarget(raw.target)
            guard let rawItems = raw.items, !rawItems.isEmpty, rawItems.count <= maxRefineItems else {
                throw BrowserEngineError.badRequest("다듬기 항목 수")
            }
            var total = 0
            var items: [BrowserRefineItem] = []
            for item in rawItems {
                guard validKey(item.k), item.o.count <= maxRefineItemCharacters, item.d.count <= maxRefineItemCharacters else {
                    throw BrowserEngineError.badRequest("다듬기 항목")
                }
                total += item.o.count + item.d.count
                items.append(BrowserRefineItem(key: item.k, original: item.o, draft: item.d))
            }
            guard total <= maxRefineCharacters else { throw BrowserEngineError.badRequest("다듬기 전체 길이") }
            return .refine(id: id, target: target, items: items)
        default:
            throw BrowserEngineError.badRequest("종류")
        }
    }

    private static func validID(_ id: String?) throws -> String {
        guard let id, validKey(id) else { throw BrowserEngineError.badRequest("요청 ID") }
        return id
    }

    private static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 64
            && key.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_:.".unicodeScalars.contains($0) }
            && key.unicodeScalars.allSatisfy(\.isASCII)
    }

    private static func validEngine(_ engine: String?) throws -> String {
        guard let engine else { return localEngine }
        guard engine == localEngine || externalEngines.contains(engine) else { throw BrowserEngineError.badRequest("번역 엔진") }
        return engine
    }

    private static func validTarget(_ target: String?) throws -> AppLanguage {
        guard let target, let language = AppLanguage(rawValue: target) else { throw BrowserEngineError.badRequest("번역 언어") }
        return language
    }
}

// MARK: - 엔진

actor BrowserEngine {
    static let engineID = "apple-local"
    static let engineTitle = "Mac 기본 번역(기기 내)"
    /// 연결 하나에서 동시에 처리하는 요청 수 상한
    private static let maxTasksPerScope = 6
    private static let batchSize = 40
    private static let maxOCRItems = 300
    /// 웹 번역 엔진으로 보내는 이미지 글자 상한(요청 하나). 넘는 조각은 번역하지 않는다.
    private static let maxExternalOCRItems = 24
    /// recognizeAndTranslate 응답 하나에서 내보내는 글자 상자(g) 총 개수 상한(항목당 128개와 별도).
    /// maxOCRItems(최대 300) × 항목당 최대 128개면 38,400개까지 가능해 메타데이터만으로 1MB 프레임 상한을
    /// 넘길 수 있으므로, 전체 응답 크기를 데이터 기준으로 묶어 둔다.
    private static let maxOutgoingGlyphBoxes = 8192

    private let translator: BrowserTextTranslating
    private let external: BrowserExternalTranslating?
    /// Apple Intelligence 다듬기(앱 본체의 Chrome·Whale 엔진에서만 nil이 아니다. Safari는 항상 nil).
    private let refiner: BrowserTextRefining?
    private let isEnabled: @Sendable () async -> Bool
    private var tasks: [String: Task<Data, Never>] = [:]
    private var supportedIDs: [String]?

    init(translator: BrowserTextTranslating, external: BrowserExternalTranslating? = nil,
         refiner: BrowserTextRefining? = nil, isEnabled: @escaping @Sendable () async -> Bool) {
        self.translator = translator
        self.external = external
        self.refiner = refiner
        self.isEnabled = isEnabled
    }

    /// 요청 한 개를 처리해 응답 JSON을 돌려준다. 응답은 항상 Chrome 상한(1MB) 이하다.
    func handle(_ data: Data, scope: String) async -> Data {
        let request: BrowserRequest
        do {
            request = try BrowserRequest.parse(data)
        } catch {
            return Self.encodeError(error, id: nil)
        }

        switch request {
        case .hello(let id):
            var response: [String: Any] = [
                "type": "hello", "ok": true, "engine": Self.engineID, "engineTitle": Self.engineTitle,
                "enabled": await isEnabled(),
                "externalEngines": external?.engineIDs ?? [],
                "aiRefine": refiner?.isAvailable ?? false,
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            ]
            if let id { response["id"] = id }
            return Self.encode(response)
        case .cancel(let id):
            tasks["\(scope)|\(id)"]?.cancel()
            return Self.encode(["type": "ack", "ok": true, "id": id])
        case .translate(let id, _, _, _), .ocr(let id, _, _, _, _, _), .refine(let id, _, _):
            guard await isEnabled() else { return Self.encodeError(BrowserEngineError.disabled, id: id) }
            let key = "\(scope)|\(id)"
            tasks[key]?.cancel()
            guard tasks.keys.filter({ $0.hasPrefix("\(scope)|") }).count < Self.maxTasksPerScope else {
                return Self.encodeError(BrowserEngineError.busy, id: id)
            }
            let task = Task { await self.run(request, id: id) }
            tasks[key] = task
            let result = await task.value
            if tasks[key] == task { tasks[key] = nil }
            return result
        }
    }

    /// 연결이 끊기면 그 연결의 요청만 모두 취소한다.
    func cancelAll(scope: String) {
        for (key, task) in tasks where key.hasPrefix("\(scope)|") {
            task.cancel()
            tasks[key] = nil
        }
    }

    private func run(_ request: BrowserRequest, id: String) async -> Data {
        do {
            let response: [String: Any]
            switch request {
            case .translate(_, let target, let texts, let engine):
                let (results, missing, langs, warning) = try await translateTexts(texts, target: target, engine: engine)
                var object: [String: Any] = ["type": "result", "ok": true, "id": id,
                            "texts": results.map { $0.map { $0 as Any } ?? NSNull() }, "missing": missing,
                            "langs": langs.map { $0.map { $0 as Any } ?? NSNull() }, "aiRefine": engine == BrowserRequest.localEngine && (refiner?.isAvailable ?? false)]
                if let warning { object["warning"] = warning }
                response = object
            case .ocr(_, let target, let image, let viewport, let regions, let engine):
                let (images, missing, warning) = try await recognizeAndTranslate(image, viewport: viewport, regions: regions,
                                                                                 target: target, engine: engine)
                var object: [String: Any] = ["type": "ocrResult", "ok": true, "id": id, "images": images, "missing": missing,
                            "aiRefine": engine == BrowserRequest.localEngine && (refiner?.isAvailable ?? false)]
                if let warning { object["warning"] = warning }
                response = object
            case .refine(_, let target, let items):
                let refined = await refineItems(items, target: target)
                response = ["type": "refineResult", "ok": true, "id": id,
                            "items": refined.map { ["k": $0.key, "t": $0.value] }]
            default:
                throw BrowserEngineError.badRequest("종류")
            }
            try Task.checkCancellation()
            let data = Self.encode(response)
            guard data.count <= BrowserBridge.maxOutgoingFrame else {
                return BrowserBridge.errorFrame(code: "response_too_large", message: "번역 결과가 너무 큽니다. 다시 시도하면 더 작은 묶음으로 나눕니다.", id: id)
            }
            return data
        } catch is CancellationError {
            return Self.encode(["type": "cancelled", "ok": false, "code": "cancelled", "id": id])
        } catch {
            if Task.isCancelled { return Self.encode(["type": "cancelled", "ok": false, "code": "cancelled", "id": id]) }
            return Self.encodeError(error, id: id)
        }
    }

    // MARK: 텍스트 번역 (언어별 묶음)

    /// 조각마다 언어를 판별해 같은 언어끼리 그 언어를 명시한 세션으로 번역한다(원문 언어가 nil인 세션을 쓰지 않아
    /// 언어 선택 창이 뜨지 않는다). 글자가 없거나 이미 번역 언어이거나 판별·지원되지 않는 조각은 nil(원문 유지).
    /// 세 번째 결과는 조각마다 실제로 쓴 판별 언어(글자 없음은 nil, 판별 못 하면 "unknown")로, 번역 성공 여부와 무관하게
    /// 확장이 인식 통계를 보여주는 데 쓴다. 네 번째 결과는 웹 번역 엔진이 도중에 멈췄을 때의 안내(받은 결과는 유지)다.
    /// 웹 번역 엔진도 같은 언어 판별을 거쳐, 판별한 언어를 원문 언어로 지정해 보낸다(판별 못 한 조각은 보내지 않는다).
    private func translateTexts(_ texts: [String], target: AppLanguage, engine: String) async throws -> ([String?], [String], [String?], String?) {
        let isExternal = engine != BrowserRequest.localEngine
        if isExternal {
            guard let external, external.engineIDs.contains(engine) else { throw BrowserEngineError.externalUnavailable }
            if let reason = await external.unavailableReason(engine: engine) { throw BrowserEngineError.externalBlocked(reason) }
        }
        let classified = texts.map { LanguageDetection.classify($0) }
        let detected = LanguageDetection.resolveAmbiguous(classified)
        let langs: [String?] = detected.map { result in
            switch result {
            case .language(let key): return key
            case .unknown: return "unknown"
            case .noLetters, .ambiguous: return nil
            }
        }
        if !isExternal && (supportedIDs == nil || supportedIDs?.isEmpty == true) {
            supportedIDs = await translator.supportedLanguageIDs()
        }
        var order: [String] = []
        var groups: [String: [Int]] = [:]
        for (index, result) in detected.enumerated() {
            guard case .language(let key) = result,
                  !LanguageDetection.isSameLanguage(key, target.rawValue), isExternal || isSupported(key) else { continue }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(index)
        }

        var results = [String?](repeating: nil, count: texts.count)
        var missing: [String] = []
        var firstError: Error?
        var warning: String?
        groups: for key in order {
            let indices = groups[key] ?? []
            var start = 0
            groupLoop: while start < indices.count {
                try Task.checkCancellation()
                let chunk = Array(indices[start..<min(start + Self.batchSize, indices.count)])
                start += Self.batchSize
                do {
                    let output: [String?]
                    if isExternal, let external {
                        output = try await external.translate(chunk.map { texts[$0] }, source: key, target: target.rawValue, engine: engine)
                    } else {
                        output = try await translator.translate(chunk.map { texts[$0] }, source: key, target: target.rawValue)
                    }
                    for (offset, index) in chunk.enumerated() where offset < output.count {
                        results[index] = output[offset]
                    }
                } catch let failure as BrowserExternalFailure {
                    // 받은 결과는 유지한다. 언어 조합 실패는 그 묶음만, 그 밖의 실패는 남은 묶음을 보내지 않고 멈춘다.
                    for (offset, index) in chunk.enumerated() where offset < failure.results.count {
                        results[index] = failure.results[offset]
                    }
                    if warning == nil { warning = failure.message }
                    if failure.unsupported { break groupLoop }
                    if firstError == nil { firstError = BrowserEngineError.translationFailed(failure.message) }
                    break groups
                } catch BrowserEngineError.languageNotInstalled(let pair) {
                    missing.append(pair)
                    break groupLoop
                } catch BrowserEngineError.unsupportedPair {
                    break groupLoop
                } catch let error as CancellationError {
                    throw error
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    if firstError == nil { firstError = error }
                    break groupLoop
                }
            }
        }
        try Task.checkCancellation()
        if results.allSatisfy({ $0 == nil }) {
            if let firstError { throw firstError }
            if let pair = missing.first, missing.count == order.count { throw BrowserEngineError.languageNotInstalled(pair) }
        }
        return (results, missing, langs, warning)
    }

    private func isSupported(_ key: String) -> Bool {
        guard let ids = supportedIDs, !ids.isEmpty else { return true }
        return ids.contains { LanguageDetection.isSameLanguage($0, key) }
    }

    // MARK: 다듬기 후속 요청 (앱 본체의 Chrome·Whale 전용, Mac 기본 번역 결과만)

    private func refineItems(_ items: [BrowserRefineItem], target: AppLanguage) async -> [String: String] {
        guard let refiner, refiner.isAvailable, AppleTranslationRefiner.supportsTarget(target.rawValue) else { return [:] }
        return await refiner.refine(items, targetLanguageName: target.displayNameKorean)
    }

    // MARK: 이미지 영역 OCR

    /// 보이는 탭 캡처에서 확장이 지정한 이미지 영역만 잘라 OCR하고, 번역된 조각의 위치(영역 기준 0...1)와 번역문만 돌려준다.
    private func recognizeAndTranslate(_ imageData: Data, viewport: CGSize, regions: [BrowserImageRegionInput],
                                       target: AppLanguage, engine: String) async throws -> ([[String: Any]], [String], String?) {
        let itemLimit = engine == BrowserRequest.localEngine ? Self.maxOCRItems : Self.maxExternalOCRItems
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(imageData as CFData, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw BrowserEngineError.badRequest("이미지 해석")
        }
        guard width <= BrowserRequest.maxImageSide, height <= BrowserRequest.maxImageSide,
              width * height <= BrowserRequest.maxImagePixels else { throw BrowserEngineError.imageTooLarge }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options) else {
            throw BrowserEngineError.badRequest("이미지 해석")
        }

        let sx = Double(image.width) / Double(viewport.width)
        let sy = Double(image.height) / Double(viewport.height)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)

        struct Found {
            let imageKey: String; let box: CGRect; let text: String; let bg: String; let fg: String
            /// box와 같은 요청 영역 기준 0...1 좌표로 변환한 원본 글자 상자(마스킹·글꼴 추정용)
            let glyphBoxes: [CGRect]
            /// 원본 글자 획 통계로 추정한 글꼴 갈래("gothic"/"myeongjo"/"hand"). 미판별이면 nil.
            let fontStyle: String?
        }
        var found: [Found] = []
        var keys: [String] = []
        for region in regions {
            try Task.checkCancellation()
            keys.append(region.k)
            let crop = CGRect(x: region.x * sx, y: region.y * sy, width: region.w * sx, height: region.h * sy)
                .integral.intersection(bounds)
            guard !crop.isNull, crop.width >= 24, crop.height >= 24, let cropped = image.cropping(to: crop) else { continue }
            let recognized = try await ImageTextRecognizer.recognize(cropped, assetID: region.k)
            // 잘라낸 픽셀 좌표 → 뷰포트 CSS 좌표 → 요청 영역 기준 0...1. item.box와 글자 상자 모두 같은 변환을 쓴다.
            func mapRect(_ r: CGRect) -> CGRect {
                let px = (crop.minX + r.minX * crop.width) / sx
                let py = (crop.minY + r.minY * crop.height) / sy
                let pw = r.width * crop.width / sx
                let ph = r.height * crop.height / sy
                return CGRect(x: (px - region.x) / region.w, y: (py - region.y) / region.h,
                             width: pw / region.w, height: ph / region.h)
            }
            for item in recognized where item.hasMeaningfulLetters {
                guard found.count < itemLimit else { break }
                let box = mapRect(item.box)
                let glyphBoxes = item.glyphBoxes.map(mapRect)
                found.append(Found(imageKey: region.k, box: box, text: item.text, bg: item.backgroundHex, fg: item.foregroundHex,
                                    glyphBoxes: glyphBoxes, fontStyle: item.fontStyle))
            }
        }

        var translated = [String?](repeating: nil, count: found.count)
        var missing: [String] = []
        var langs = [String?](repeating: nil, count: found.count)
        var warning: String?
        if !found.isEmpty {
            (translated, missing, langs, warning) = try await translateTexts(found.map(\.text), target: target, engine: engine)
        }
        func rounded(_ value: CGFloat) -> Double { (Double(value) * 10_000).rounded() / 10_000 }
        var itemsByKey: [String: [[String: Any]]] = [:]
        // 응답 전체(이 recognizeAndTranslate 호출 하나)에서 보내는 글자 상자(g) 총 개수 상한. 항목별 128개
        // 상한(ImageTextRecognizer.maxGlyphsPerItem)은 그대로 둔 채, 번역에 성공해 실제로 내보내는 항목만 이
        // 예산을 소모한다. 예산을 넘는 항목은 "g"만 생략한다(그 글자의 마스킹은 건너뛰고 원본 픽셀이 남는다).
        // 넓은 배경 마스킹으로 대신하지 않는다. 전체 응답은 여전히 BrowserBridge.maxOutgoingFrame(1MB)로 보호된다.
        var glyphBudget = Self.maxOutgoingGlyphBoxes
        for (item, text) in zip(found, translated) {
            guard let text, !text.isEmpty else { continue }
            var dict: [String: Any] = [
                "x": rounded(item.box.minX), "y": rounded(item.box.minY),
                "w": rounded(item.box.width), "h": rounded(item.box.height),
                "t": text, "bg": item.bg, "fg": item.fg,
                // 다듬기 후속 요청에만 쓰는 인식 원문(짧게 자름). Chrome·Whale에서 아이콘·화면 번역과 달리
                // 이 원문을 저장하거나 기록하지 않고, 같은 패스의 후속 요청 한 번에만 메모리에서 쓴다.
                "o": String(item.text.prefix(700))
            ]
            // 원본 글자 획 통계로 추정한 글꼴 갈래("fs"). 미판별이면 생략(확장이 고딕으로 대체).
            if let fontStyle = item.fontStyle { dict["fs"] = fontStyle }
            // 원본 글자 상자([x,y,w,h] 배열의 배열). 없으면("g" 생략) 확장이 그 조각의 배경을 마스킹하지 않는다.
            if !item.glyphBoxes.isEmpty && item.glyphBoxes.count <= glyphBudget {
                dict["g"] = item.glyphBoxes.map { [rounded($0.minX), rounded($0.minY), rounded($0.width), rounded($0.height)] }
                glyphBudget -= item.glyphBoxes.count
            }
            itemsByKey[item.imageKey, default: []].append(dict)
        }
        // 번역 성공 여부와 무관하게(건너뛴 조각 포함) 이미지마다 인식한 언어 개수를 센다.
        var langCountsByKey: [String: [String: Int]] = [:]
        for (item, lang) in zip(found, langs) {
            guard let lang else { continue }
            langCountsByKey[item.imageKey, default: [:]][lang, default: 0] += 1
        }
        let images: [[String: Any]] = keys.map { ["k": $0, "items": itemsByKey[$0] ?? [], "langs": langCountsByKey[$0] ?? [:]] }
        return (images, missing, warning)
    }

    // MARK: 인코딩

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? BrowserBridge.errorFrame(code: "internal", message: "응답을 만들지 못했습니다.")
    }

    private static func encodeError(_ error: Error, id: String?) -> Data {
        if let engineError = error as? BrowserEngineError {
            return BrowserBridge.errorFrame(code: engineError.code, message: engineError.message, id: id)
        }
        return BrowserBridge.errorFrame(code: "translation_failed", message: describe(error), id: id)
    }

    static func describe(_ error: Error) -> String {
        if TranslationError.unsupportedLanguagePairing ~= error { return "Mac 기본 번역이 지원하지 않는 언어 조합입니다." }
        if TranslationError.unableToIdentifyLanguage ~= error { return "언어를 판별하지 못했습니다." }
        if #available(macOS 26.0, *), TranslationError.notInstalled ~= error {
            return "번역 언어 팩이 설치되지 않았습니다. 시스템 설정 › 일반 › 언어 및 지역 › 번역 언어에서 내려받으세요."
        }
        return "번역 실패: \(error.localizedDescription)"
    }
}

// MARK: - macOS 26 이상: 화면 없이 쓰는 기기 내 번역 세션

/// 설치된 언어 팩만 쓰는 TranslationSession(installedSource:target:)을 언어 조합마다 재사용한다. 화면(UI)이 필요 없어
/// 앱이 화면 번역 창을 띄우지 않은 채로, 또 Safari 확장 안에서도 동작한다. 언어 팩이 없으면 내려받기 창을
/// 숨은 채로 띄우지 않고 실행 가능한 안내 오류를 낸다. 같은 세션에 동시에 요청하지 않도록 조합마다 차례로 처리한다.
@available(macOS 26.0, *)
actor BrowserDirectTranslator: BrowserTextTranslating {
    private static let maxSessions = 6
    private var sessions: [String: TranslationSession] = [:]
    private var sessionOrder: [String] = []
    private var busyKeys: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func supportedLanguageIDs() async -> [String] {
        await makeAvailability().supportedLanguages.map(\.minimalIdentifier)
    }

    func translate(_ texts: [String], source: String, target: String) async throws -> [String?] {
        let key = "\(source)>\(target)"
        await acquire(key)
        defer { release(key) }
        try Task.checkCancellation()
        let session = try await session(for: key, source: source, target: target)
        let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
        let responses: [TranslationSession.Response]
        do {
            responses = try await session.translations(from: requests)
        } catch {
            // 세션이 망가졌을 수 있으므로 다음 요청에서 새로 만든다.
            dropSession(key)
            if TranslationError.notInstalled ~= error { throw BrowserEngineError.languageNotInstalled("\(source)→\(target)") }
            if TranslationError.unsupportedLanguagePairing ~= error { throw BrowserEngineError.unsupportedPair("\(source)→\(target)") }
            throw error
        }
        var output = [String?](repeating: nil, count: texts.count)
        for response in responses {
            guard let identifier = response.clientIdentifier, let index = Int(identifier), output.indices.contains(index) else { continue }
            output[index] = response.targetText
        }
        return output
    }

    private func session(for key: String, source: String, target: String) async throws -> TranslationSession {
        if let session = sessions[key] { return session }
        let from = Locale.Language(identifier: source), to = Locale.Language(identifier: target)
        switch await makeAvailability().status(from: from, to: to) {
        case .installed: break
        case .supported: throw BrowserEngineError.languageNotInstalled("\(source)→\(target)")
        case .unsupported: throw BrowserEngineError.unsupportedPair("\(source)→\(target)")
        @unknown default: throw BrowserEngineError.unsupportedPair("\(source)→\(target)")
        }
        let session: TranslationSession
        if #available(macOS 26.4, *) {
            session = TranslationSession(installedSource: from, target: to, preferredStrategy: .lowLatency)
        } else {
            session = TranslationSession(installedSource: from, target: to)
        }
        sessions[key] = session
        sessionOrder.append(key)
        while sessionOrder.count > Self.maxSessions, let oldest = sessionOrder.first, !busyKeys.contains(oldest) {
            dropSession(oldest)
        }
        return session
    }

    private func makeAvailability() -> LanguageAvailability {
        if #available(macOS 26.4, *) { return LanguageAvailability(preferredStrategy: .lowLatency) }
        return LanguageAvailability()
    }

    private func dropSession(_ key: String) {
        sessions[key] = nil
        sessionOrder.removeAll { $0 == key }
    }

    private func acquire(_ key: String) async {
        if !busyKeys.contains(key) {
            busyKeys.insert(key)
            return
        }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    private func release(_ key: String) {
        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[key] = queue.isEmpty ? nil : queue
            next.resume()
        } else {
            busyKeys.remove(key)
        }
    }
}
