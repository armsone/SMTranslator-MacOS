import AppKit

@MainActor
func runApp() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // 저장된 설정대로 시작 정책을 먼저 정해 둔다(Info.plist의 LSUIElement=true가
    // 런치 단계에서 Dock 아이콘이 깜빡 보이는 것을 막아 준다).
    app.setActivationPolicy(DockVisibilityStore.shared.showDockIcon ? .regular : .accessory)
    app.run()
}

MainActor.assumeIsolated {
    runApp()
}
