import Foundation
import SafariServices

// Safari 웹 확장의 네이티브 처리기(SMTranslator.app/Contents/PlugIns 안의 .appex, 샌드박스).
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
        return BrowserEngine(translator: translator, isEnabled: { true })
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
