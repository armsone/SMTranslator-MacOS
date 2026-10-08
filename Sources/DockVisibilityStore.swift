import AppKit

/// Dock에 아이콘 표시 여부(기본 꺼짐: 메뉴 막대만). 메뉴 막대 상태 메뉴와 설정 모두 이 값을 공유한다.
@MainActor
@Observable
final class DockVisibilityStore {
    static let shared = DockVisibilityStore()
    private static let preferenceKey = "showDockIconPreference"

    var showDockIcon: Bool {
        didSet {
            guard oldValue != showDockIcon else { return }
            UserDefaults.standard.set(showDockIcon, forKey: Self.preferenceKey)
            apply()
        }
    }

    private init() {
        showDockIcon = UserDefaults.standard.object(forKey: Self.preferenceKey) as? Bool ?? false
    }

    /// 앱 실행 시(최초 1회) 저장된 값대로 정책을 맞춘다.
    func applyInitial() {
        apply()
    }

    /// 창·포커스를 유지한 채 Dock 아이콘 표시 정책을 전환한다.
    private func apply() {
        let policy: NSApplication.ActivationPolicy = showDockIcon ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        let keyWindow = NSApp.keyWindow
        NSApp.setActivationPolicy(policy)
        NSApp.activate(ignoringOtherApps: true)
        keyWindow?.makeKeyAndOrderFront(nil)
    }
}
