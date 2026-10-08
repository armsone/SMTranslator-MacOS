import AppKit
import SwiftUI
import Translation

/// macOS 15–25 전용 브라우저 번역기. 이 버전에서는 TranslationSession을 SwiftUI .translationTask 안에서만 얻을 수 있으므로,
/// 화면 번역 창과 별개인 1pt 투명 패널(클릭 통과·비활성)에 .translationTask를 두고 화면 번역 툴바와 같은 방식
/// (클로저마다 채널을 열고, 언어 조합이 바뀔 때만 Configuration을 바꿈)으로 작업을 하나씩 넘긴다.
/// 언어 팩이 설치되지 않은 조합은 보이지 않는 창에서 내려받기를 요청하지 않도록 미리 걸러 안내 오류를 낸다.
/// macOS 26 이상에서는 BrowserDirectTranslator를 쓰므로 이 패널을 만들지 않는다.
@MainActor
final class BrowserHostedTranslator: BrowserTextTranslating {
    private final class HostModel: ObservableObject {
        @Published var configuration: TranslationSession.Configuration?
    }

    private struct Work {
        let id: UUID
        let key: String
        let source: Locale.Language
        let target: Locale.Language
        let texts: [String]
        let continuation: CheckedContinuation<[String?], Error>
    }

    private struct HostView: View {
        @ObservedObject var model: HostModel
        let owner: BrowserHostedTranslator

        var body: some View {
            Color.clear
                .frame(width: 1, height: 1)
                .translationTask(model.configuration) { session in
                    // 세션은 이 클로저 생명주기 동안만 유효하다. 같은 언어 조합이면 클로저가 유지되어 세션을 재사용한다.
                    for await work in owner.openChannel() {
                        await owner.perform(work, session: session)
                    }
                }
        }
    }

    /// 세션 준비(.translationTask 시작)를 기다리는 최대 시간
    private static let startTimeout: Duration = .seconds(15)

    private let model = HostModel()
    private var panel: NSPanel?
    private var queue: [Work] = []
    private var running: Work?
    private var currentKey: String?
    private var channel: AsyncStream<Work>.Continuation?

    nonisolated func supportedLanguageIDs() async -> [String] {
        await LanguageAvailability().supportedLanguages.map(\.minimalIdentifier)
    }

    nonisolated func translate(_ texts: [String], source: String, target: String) async throws -> [String?] {
        let from = Locale.Language(identifier: source), to = Locale.Language(identifier: target)
        switch await LanguageAvailability().status(from: from, to: to) {
        case .installed: break
        case .supported: throw BrowserEngineError.languageNotInstalled("\(source)→\(target)")
        case .unsupported: throw BrowserEngineError.unsupportedPair("\(source)→\(target)")
        @unknown default: throw BrowserEngineError.unsupportedPair("\(source)→\(target)")
        }
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task { @MainActor in
                    self.enqueue(Work(id: id, key: "\(source)>\(target)", source: from, target: to,
                                      texts: texts, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelQueued(id) }
        }
    }

    // MARK: - 대기열

    private func enqueue(_ work: Work) {
        queue.append(work)
        pump()
    }

    /// 아직 시작하지 않은 작업만 빼낸다. 이미 세션에 넘긴 묶음은 끝까지 기다린다(결과는 엔진이 버린다).
    private func cancelQueued(_ id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func pump() {
        guard running == nil, let next = queue.first else { return }
        ensurePanel()
        if currentKey == next.key, let channel {
            queue.removeFirst()
            running = next
            if case .enqueued = channel.yield(next) { return }
            // 채널이 이미 닫혔으면 되돌리고 세션을 다시 연다.
            running = nil
            queue.insert(next, at: 0)
            self.channel = nil
        }
        channel?.finish()
        channel = nil
        currentKey = next.key
        let configuration = TranslationSession.Configuration(source: next.source, target: next.target)
        if var current = model.configuration, current == configuration {
            current.invalidate()
            model.configuration = current
        } else {
            model.configuration = configuration
        }
        scheduleStartWatchdog(for: next.id)
    }

    /// .translationTask 클로저가 시작될 때 부른다.
    private func openChannel() -> AsyncStream<Work> {
        channel?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: Work.self)
        channel = continuation
        Task { @MainActor in self.pump() }
        return stream
    }

    private func perform(_ work: Work, session: TranslationSession) async {
        let requests = work.texts.enumerated().map {
            TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
        }
        do {
            let responses = try await session.translations(from: requests)
            var output = [String?](repeating: nil, count: work.texts.count)
            for response in responses {
                guard let identifier = response.clientIdentifier, let index = Int(identifier),
                      output.indices.contains(index) else { continue }
                output[index] = response.targetText
            }
            work.continuation.resume(returning: output)
        } catch {
            work.continuation.resume(throwing: error)
        }
        running = nil
        pump()
    }

    /// 투명 패널에서 세션이 시작되지 않으면 무한히 기다리지 않고 대기 작업을 안내 오류로 끝낸다.
    private func scheduleStartWatchdog(for id: UUID) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.startTimeout)
            guard let self, self.running == nil, self.queue.first?.id == id else { return }
            let failed = self.queue
            self.queue = []
            self.currentKey = nil
            for work in failed {
                work.continuation.resume(throwing: BrowserEngineError.translationFailed(
                    "번역 세션을 시작하지 못했습니다. SMT 화면 번역에서 같은 언어로 한 번 번역한 뒤 다시 시도하세요."))
            }
        }
    }

    // MARK: - 호스트 패널

    private func ensurePanel() {
        guard panel == nil else { return }
        let origin = NSScreen.main?.visibleFrame.origin ?? .zero
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: NSSize(width: 1, height: 1)),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .stationary, .fullScreenAuxiliary]
        panel.identifier = NSUserInterfaceItemIdentifier("browserTranslationHost")
        panel.contentView = NSHostingView(rootView: HostView(model: model, owner: self))
        panel.orderFrontRegardless()
        self.panel = panel
    }
}
