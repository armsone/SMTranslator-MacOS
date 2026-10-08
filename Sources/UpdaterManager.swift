import AppKit
import Sparkle

/// Sparkle 2 표준 업데이터(SPUStandardUpdaterController) 래퍼.
/// - 빌드 시 Resources/UpdatePublicKey.txt(공개키만)를 Info.plist의 SUPublicEDKey로 넣는다.
///   공개키나 HTTPS 피드 주소가 없으면 업데이터를 시작하지 않고 그 이유를 그대로 표시한다
///   (무결성 검증 없이 업데이트하지 않음).
/// - 피드가 아직 게시되지 않아(404 등) 확인에 실패하면 '업데이트 없음'이 아니라 오류로 기록한다.
@MainActor
final class UpdaterManager: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?
    private(set) var statusDescription = "초기화 전"
    private(set) var lastCheckResult: String?

    var isAvailable: Bool { controller != nil }

    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    var automaticallyUpdates: Bool {
        guard let updater = controller?.updater else { return false }
        return updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
    }

    func start() {
        let info = Bundle.main.infoDictionary ?? [:]
        let publicKey = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let feed = (info["SUFeedURL"] as? String) ?? ""

        guard !publicKey.isEmpty else {
            statusDescription = "비활성: 업데이트 서명 공개키가 빌드에 포함되지 않았습니다"
            return
        }
        guard let url = URL(string: feed), url.scheme == "https" else {
            statusDescription = "비활성: HTTPS 업데이트 피드 주소가 없습니다"
            return
        }

        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        do {
            try controller.updater.start()
            self.controller = controller
            statusDescription = "사용 가능"
        } catch {
            statusDescription = "업데이터 시작 실패: \(error.localizedDescription)"
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyUpdates(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        updater.automaticallyDownloadsUpdates = enabled
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        let message: String
        if let error = error as NSError? {
            if error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue) {
                message = "최신 버전입니다"
            } else {
                message = "확인 실패: \(error.localizedDescription)"
            }
        } else {
            message = "확인 완료"
        }
        MainActor.assumeIsolated {
            self.lastCheckResult = message
        }
    }
}
