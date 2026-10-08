import Foundation
import ServiceManagement

/// SMAppService.mainApp 기반 '로그인 시 자동 시작'.
/// - /Applications에 설치된 경우에만 등록한다.
/// - 최초 실행 시 1회 기본 등록(사용자가 설치 시 직접 승인). 이후에는 사용자가 메뉴에서
///   명시적으로 바꿀 때만 register/unregister 하며, 매 실행마다 재등록하지 않는다.
/// - 사용자가 시스템 설정에서 끈 경우(notRegistered)도 그 선택을 존중한다.
@MainActor
final class LoginItemManager {
    private static let preferenceKey = "LoginItemEnabledPreference"
    private let service = SMAppService.mainApp
    private(set) var lastError: String?

    var isInstalledInApplications: Bool {
        Bundle.main.bundleURL.standardizedFileURL.path.hasPrefix("/Applications/")
    }

    var status: SMAppService.Status { service.status }

    /// 사용자의 마지막 명시적 선택(최초 실행 전에는 nil)
    var preference: Bool? {
        UserDefaults.standard.object(forKey: Self.preferenceKey) as? Bool
    }

    var statusDescription: String {
        if !isInstalledInApplications {
            return "/Applications에 설치된 앱에서만 사용할 수 있습니다"
        }
        switch service.status {
        case .enabled: return "켜짐"
        case .requiresApproval: return "승인 필요: 시스템 설정 > 일반 > 로그인 항목에서 허용하세요"
        case .notRegistered: return "꺼짐"
        case .notFound: return "등록 정보를 찾을 수 없음"
        @unknown default: return "알 수 없는 상태"
        }
    }

    /// 실행 시 1회 호출. 최초 실행이면 기본값(켜짐)으로 한 번만 등록한다.
    func applyInitialDefaultIfNeeded() {
        guard isInstalledInApplications else { return }
        guard preference == nil else { return }
        UserDefaults.standard.set(true, forKey: Self.preferenceKey)
        if service.status != .enabled {
            register()
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard isInstalledInApplications else { return }
        UserDefaults.standard.set(enabled, forKey: Self.preferenceKey)
        if enabled {
            register()
        } else {
            unregister()
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func register() {
        do {
            try service.register()
            lastError = nil
        } catch {
            lastError = "로그인 항목 등록 실패: \(error.localizedDescription)"
        }
    }

    private func unregister() {
        do {
            try service.unregister()
            lastError = nil
        } catch {
            lastError = "로그인 항목 해제 실패: \(error.localizedDescription)"
        }
    }
}
