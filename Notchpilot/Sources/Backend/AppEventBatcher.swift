import NotchpilotCore
import Foundation

/// Coalesces backend events before they reach `AppState`. Streaming deltas are flushed at most every 50 ms
/// with only the newest update per entry; every other event is applied on the next main-actor turn.
@MainActor
final class AppEventBatcher {
    private let deliver: @MainActor (AppEvent) -> Void
    private let interval: Duration
    private var pending: [AppEvent] = []
    private var scheduled = false
    private var lastFlush: ContinuousClock.Instant = .now - .seconds(1)

    init(interval: Duration = .milliseconds(50), deliver: @escaping @MainActor (AppEvent) -> Void) {
        self.interval = interval
        self.deliver = deliver
    }

    func push(_ event: AppEvent) {
        pending.append(event)
        guard !scheduled else { return }
        scheduled = true
        let streaming = AppEventCoalescer.isStreamingOnly(pending)
        let wait = streaming ? max(.zero, interval - (.now - lastFlush)) : .zero
        Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) } else { await Task.yield() }
            self?.flush()
        }
    }

    /// Drops queued events, for example when the backend is replaced.
    func discard() {
        pending.removeAll()
        scheduled = false
    }

    func flush() {
        scheduled = false
        guard !pending.isEmpty else { return }
        let batch = AppEventCoalescer.coalesce(pending)
        pending.removeAll(keepingCapacity: true)
        lastFlush = .now
        for event in batch { deliver(event) }
    }
}
