import Foundation

public enum AppEventCoalescer {
    /// Drops `.conversationEntry` updates that a later update to the same entry replaces. Every entry event is
    /// a full snapshot of that entry, so only the newest one in a batch matters. Other events keep their order.
    public static func coalesce(_ events: [AppEvent]) -> [AppEvent] {
        var seen = Set<String>()
        var kept: [AppEvent] = []
        kept.reserveCapacity(events.count)
        for event in events.reversed() {
            if case .conversationEntry(let session, let entry) = event {
                guard seen.insert(session + "\u{0}" + entry.id).inserted else { continue }
            }
            kept.append(event)
        }
        return kept.reversed()
    }

    /// `true` when the batch holds nothing but streaming entry updates, which may wait for the next frame-ish
    /// tick; anything else should be applied promptly.
    public static func isStreamingOnly(_ events: [AppEvent]) -> Bool {
        events.allSatisfy { if case .conversationEntry = $0 { true } else { false } }
    }
}
