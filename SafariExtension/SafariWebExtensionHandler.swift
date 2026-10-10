import AppKit
import Foundation
import SafariServices

// Safari 웹 확장의 네이티브 처리기(Barobogi.app/Contents/PlugIns 안의 .appex, 샌드박스).
// 확장 백그라운드의 browser.runtime.sendNativeMessage 요청을 앱 본체와 같은 엔진 코드(BrowserEngineCore)로
// 이 확장 프로세스 안에서 처리한다. 앱 그룹·임시 예외 권한 없이 동작하도록 앱과 통신하지 않으며,
// 화면 없이 쓸 수 있는 기기 내 번역 세션(macOS 26 이상)만 쓴다. 요청 내용은 저장하거나 기록하지 않는다.

@objc(SafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private static let engine: BrowserEngine = {
        let translator: BrowserTextTranslating
        if #available(macOS 26.0, *) {
            translator = BrowserDirectTranslator()
        } else {
            translator = BrowserUnavailableTranslator()
        }
        // Safari에서는 확장 켜기·사이트 허용(Safari 설정)과 확장 안의 첫 동의가 연결 허용 역할을 한다.
        // 이 확장은 앱 본체와 통신하지 않으므로(위 설명) 실제 번역 언어 팩 다운로드 화면을 이 확장이 직접 열 수
        // 없다. 언어 및 지역 설정을 실제 다운로드 화면인 것처럼 조용히 여는 대신, 이미 지원하는 방식(번들 ID로
        // 앱 실행, 새 URL 프로토콜이나 권한 없음)으로 Barobogi 앱 자체를 열고, 앱에 있는 통합 언어 팩 다운로드 기능을
        // 쓰라고 분명히 안내한다.
        return BrowserEngine(translator: translator, isEnabled: { true }, openLanguagePack: {
            let launched = await MainActor.run { () -> Bool in
                guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: BrowserBridge.appBundleID) else {
                    return false
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: appURL, configuration: configuration, completionHandler: nil)
                return true
            }
            return launched
                ? "Barobogi 앱을 열었습니다. 앱의 설정 › 브라우저 번역에서 번역 언어 팩을 받아 주세요(이 Safari 확장은 다운로드 화면을 직접 열 수 없습니다)."
                : "Barobogi 앱을 찾지 못했습니다. Barobogi 앱을 직접 열어 설정 › 브라우저 번역에서 번역 언어 팩을 받아 주세요."
        })
    }()

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey]
        // 프로필마다 요청 ID 범위를 나눠 한 프로필의 취소가 다른 프로필 요청을 건드리지 않게 한다.
        let profile = item?.userInfo?[SFExtensionProfileKey].map { String(describing: $0) } ?? "default"
        let scope = "safari-\(profile)"

        guard let message, JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message),
              data.count <= BrowserBridge.maxIncomingFrame else {
            Self.complete(context, with: BrowserBridge.errorFrame(code: "bad_request", message: "잘못된 요청입니다."))
            return
        }
        Task {
            let response = await Self.engine.handle(data, scope: scope)
            Self.complete(context, with: response)
        }
    }

    private static func complete(_ context: NSExtensionContext, with json: Data) {
        let object = (try? JSONSerialization.jsonObject(with: json))
            ?? ["type": "error", "ok": false, "code": "internal", "message": "응답을 만들지 못했습니다."]
        let reply = NSExtensionItem()
        reply.userInfo = [SFExtensionMessageKey: object]
        context.completeRequest(returningItems: [reply], completionHandler: nil)
    }
}
