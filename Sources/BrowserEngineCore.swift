import CoreGraphics
import Foundation
import ImageIO
import Translation

// 브라우저 번역 엔진(앱 본체와 Safari 확장 공용). 확장이 보낸 요청을 검증하고, 페이지 글자 조각과
// 보이는 탭 캡처 중 이미지 영역만 잘라 OCR한 글자를 Mac 기본 번역(기기 내)으로 번역해 텍스트만 돌려준다.
// - 브라우저 번역은 앱의 번역 방식 설정(외부 AI 포함)을 읽거나 바꾸지 않고 항상 Mac 기본 번역을 쓴다.
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
        }
    }
}

/// 언어 하나(source) → target 번역. 결과는 입력과 같은 개수이며, 받지 못한 항목은 nil이다.
protocol BrowserTextTranslating: AnyObject, Sendable {
    func supportedLanguageIDs() async -> [String]
    func translate(_ texts: [String], source: String, target: String) async throws -> [String?]
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

private struct BrowserRawRequest: Decodable {
    let v: Int?
    let type: String
    let id: String?
    let target: String?
    let texts: [String]?
    let image: String?
    let viewport: BrowserViewportInput?
    let regions: [BrowserImageRegionInput]?
}

enum BrowserRequest {
    case hello(id: String?)
    case cancel(id: String)
    case translate(id: String, target: AppLanguage, texts: [String])
    case ocr(id: String, target: AppLanguage, image: Data, viewport: CGSize, regions: [BrowserImageRegionInput])

    static let maxTexts = 150
    static let maxTextLength = 5000
    static let maxTotalCharacters = 40_000
    static let maxRegions = 16
    static let maxImagePixels = 60_000_000
    static let maxImageSide = 12_000

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
            guard let texts = raw.texts, !texts.isEmpty, texts.count <= maxTexts else { throw BrowserEngineError.badRequest("항목 수") }
            var total = 0
            for text in texts {
                guard text.count <= maxTextLength else { throw BrowserEngineError.badRequest("항목 길이") }
                total += text.count
            }
            guard total <= maxTotalCharacters else { throw BrowserEngineError.badRequest("전체 길이") }
            return .translate(id: id, target: target, texts: texts)
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
            return .ocr(id: id, target: target, image: bytes, viewport: CGSize(width: viewport.w, height: viewport.h), regions: regions)
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

    private let translator: BrowserTextTranslating
    private let isEnabled: @Sendable () async -> Bool
    private var tasks: [String: Task<Data, Never>] = [:]
    private var supportedIDs: [String]?

    init(translator: BrowserTextTranslating, isEnabled: @escaping @Sendable () async -> Bool) {
        self.translator = translator
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
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            ]
            if let id { response["id"] = id }
            return Self.encode(response)
        case .cancel(let id):
            tasks["\(scope)|\(id)"]?.cancel()
            return Self.encode(["type": "ack", "ok": true, "id": id])
        case .translate(let id, _, _), .ocr(let id, _, _, _, _):
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
            case .translate(_, let target, let texts):
                let (results, missing) = try await translateTexts(texts, target: target)
                response = ["type": "result", "ok": true, "id": id,
                            "texts": results.map { $0.map { $0 as Any } ?? NSNull() }, "missing": missing]
            case .ocr(_, let target, let image, let viewport, let regions):
                let (images, missing) = try await recognizeAndTranslate(image, viewport: viewport, regions: regions, target: target)
                response = ["type": "ocrResult", "ok": true, "id": id, "images": images, "missing": missing]
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
    private func translateTexts(_ texts: [String], target: AppLanguage) async throws -> ([String?], [String]) {
        let detected = LanguageDetection.resolveAmbiguous(texts.map { LanguageDetection.classify($0) })
        if supportedIDs == nil || supportedIDs?.isEmpty == true {
            supportedIDs = await translator.supportedLanguageIDs()
        }
        var order: [String] = []
        var groups: [String: [Int]] = [:]
        for (index, result) in detected.enumerated() {
            guard case .language(let key) = result,
                  !LanguageDetection.isSameLanguage(key, target.rawValue), isSupported(key) else { continue }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(index)
        }

        var results = [String?](repeating: nil, count: texts.count)
        var missing: [String] = []
        var firstError: Error?
        for key in order {
            let indices = groups[key] ?? []
            var start = 0
            groupLoop: while start < indices.count {
                try Task.checkCancellation()
                let chunk = Array(indices[start..<min(start + Self.batchSize, indices.count)])
                start += Self.batchSize
                do {
                    let output = try await translator.translate(chunk.map { texts[$0] }, source: key, target: target.rawValue)
                    for (offset, index) in chunk.enumerated() where offset < output.count {
                        results[index] = output[offset]
                    }
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
        return (results, missing)
    }

    private func isSupported(_ key: String) -> Bool {
        guard let ids = supportedIDs, !ids.isEmpty else { return true }
        return ids.contains { LanguageDetection.isSameLanguage($0, key) }
    }

    // MARK: 이미지 영역 OCR

    /// 보이는 탭 캡처에서 확장이 지정한 이미지 영역만 잘라 OCR하고, 번역된 조각의 위치(영역 기준 0...1)와 번역문만 돌려준다.
    private func recognizeAndTranslate(_ imageData: Data, viewport: CGSize, regions: [BrowserImageRegionInput],
                                       target: AppLanguage) async throws -> ([[String: Any]], [String]) {
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

        struct Found { let imageKey: String; let box: CGRect; let text: String; let bg: String; let fg: String }
        var found: [Found] = []
        var keys: [String] = []
        for region in regions {
            try Task.checkCancellation()
            keys.append(region.k)
            let crop = CGRect(x: region.x * sx, y: region.y * sy, width: region.w * sx, height: region.h * sy)
                .integral.intersection(bounds)
            guard !crop.isNull, crop.width >= 24, crop.height >= 24, let cropped = image.cropping(to: crop) else { continue }
            let recognized = try await ImageTextRecognizer.recognize(cropped, assetID: region.k)
            for item in recognized where item.hasMeaningfulLetters {
                guard found.count < Self.maxOCRItems else { break }
                // 잘라낸 픽셀 좌표 → 뷰포트 CSS 좌표 → 요청 영역 기준 0...1
                let px = (crop.minX + item.box.minX * crop.width) / sx
                let py = (crop.minY + item.box.minY * crop.height) / sy
                let pw = item.box.width * crop.width / sx
                let ph = item.box.height * crop.height / sy
                let box = CGRect(x: (px - region.x) / region.w, y: (py - region.y) / region.h,
                                 width: pw / region.w, height: ph / region.h)
                found.append(Found(imageKey: region.k, box: box, text: item.text, bg: item.backgroundHex, fg: item.foregroundHex))
            }
        }

        var translated = [String?](repeating: nil, count: found.count)
        var missing: [String] = []
        if !found.isEmpty {
            (translated, missing) = try await translateTexts(found.map(\.text), target: target)
        }
        func rounded(_ value: CGFloat) -> Double { (Double(value) * 10_000).rounded() / 10_000 }
        var itemsByKey: [String: [[String: Any]]] = [:]
        for (item, text) in zip(found, translated) {
            guard let text, !text.isEmpty else { continue }
            itemsByKey[item.imageKey, default: []].append([
                "x": rounded(item.box.minX), "y": rounded(item.box.minY),
                "w": rounded(item.box.width), "h": rounded(item.box.height),
                "t": text, "bg": item.bg, "fg": item.fg
            ])
        }
        let images: [[String: Any]] = keys.map { ["k": $0, "items": itemsByKey[$0] ?? []] }
        return (images, missing)
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
