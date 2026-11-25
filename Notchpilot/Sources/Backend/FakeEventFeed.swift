import NotchpilotCore
import Foundation

@MainActor
final class FakeEventFeed {
    private var playback: Task<Void, Never>?

    func start(script: [(after: Duration, event: AppEvent)], deliver: @escaping (AppEvent) -> Void) {
        stop()
        playback = Task {
            for step in script {
                do {
                    try await Task.sleep(for: step.after)
                    try Task.checkCancellation()
                } catch {
                    return
                }
                deliver(step.event)
            }
        }
    }

    func stop() {
        playback?.cancel()
        playback = nil
    }
}
