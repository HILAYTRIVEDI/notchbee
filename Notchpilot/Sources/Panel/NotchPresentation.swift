import NotchpilotCore
import Observation
import SwiftUI

@MainActor
@Observable
final class NotchPresentation {
    struct Notice: Equatable {
        enum Kind { case approval, input, completion, failure }
        let kind: Kind
        let sessionID: String?
        let title: String
        let provider: String?
        var count = 1

        var symbol: String {
            switch kind {
            case .approval: "exclamationmark.triangle.fill"
            case .input: "questionmark.bubble.fill"
            case .completion: "checkmark"
            case .failure: "exclamationmark.circle.fill"
            }
        }

        var tint: Color {
            switch kind {
            case .approval, .input: T3.warning
            case .completion: T3.success
            case .failure: T3.error
            }
        }

        var text: String {
            let name = provider.map { ProviderBrand.label(instanceID: $0) } ?? Product.name
            switch kind {
            case .approval: return provider == nil ? "\(title) needs approval" : "\(name) needs approval"
            case .input: return provider == nil ? "\(title) needs input" : "\(name) needs input"
            case .completion: return "\(name) finished — \(title)"
            case .failure: return sessionID == nil ? title : "\(name) failed — \(title)"
            }
        }
    }

    private(set) var notice: Notice?
    private(set) var previewLine: String?
    /// True for a few seconds after a session finishes, so the collapsed notch can show a check.
    private(set) var finishedFlash = false
    @ObservationIgnored private var flashTask: Task<Void, Never>?
    @ObservationIgnored private var queue: [Notice] = []
    @ObservationIgnored private var dismissal: Task<Void, Never>?
    @ObservationIgnored private var previewID: String?
    @ObservationIgnored private var previewMessageID: String?
    @ObservationIgnored private var previewTimestamp: String?

    /// Sessions that are waiting on the user: an approval, or any other pending request.
    private static func waitingIDs(in state: StateSnapshot) -> Set<String> {
        Set(state.pendingApprovals.map(\.threadId))
            .union(state.pendingUserInputs.map(\.threadId))
            .union(state.sessions.lazy.filter { !$0.isArchived && $0.pendingRuntimeRequest != nil }.map(\.id))
    }

    private static func runningCount(in state: StateSnapshot, excluding waiting: Set<String>) -> Int {
        state.sessions.lazy.filter { $0.status == .running && !$0.isArchived && !waiting.contains($0.id) }.count
    }

    /// What the collapsed notch's wings show. `nil` means idle: the notch is exactly the hardware notch.
    static func activity(in state: StateSnapshot, finishedRecently: Bool) -> NotchActivity? {
        let waiting = waitingIDs(in: state)
        if !waiting.isEmpty { return .attention }
        let running = runningCount(in: state, excluding: waiting)
        if running > 0 { return .running(running) }
        return finishedRecently ? .done : nil
    }

    static func panelStatus(in state: StateSnapshot) -> PanelStatus {
        switch state.connection {
        case .connected: break
        case .engineStarting, .engineRestarting: return PanelStatus(text: "Connecting…", tone: .offline)
        case .failed, .engineFailed: return PanelStatus(text: "Offline", tone: .failed)
        case .disconnected: return PanelStatus(text: "Offline", tone: .offline)
        }
        let waiting = waitingIDs(in: state)
        let running = runningCount(in: state, excluding: waiting)
        switch (waiting.count, running) {
        case (0, 0): return PanelStatus(text: "Idle", tone: .idle)
        case (0, let running): return PanelStatus(text: "\(running) running", tone: .running)
        case (let waiting, 0): return PanelStatus(text: "\(waiting) waiting", tone: .waiting)
        case (let waiting, let running): return PanelStatus(text: "\(waiting) waiting · \(running) running", tone: .waiting)
        }
    }

    static func relevantSession(in state: StateSnapshot) -> SessionSummary? {
        relevantSessions(in: state).first
    }

    static func relevantSessions(in state: StateSnapshot) -> [SessionSummary] {
        let approvals = Set(state.pendingApprovals.map(\.threadId)).union(state.pendingUserInputs.map(\.threadId))
        func priority(_ session: SessionSummary) -> Int {
            if approvals.contains(session.id) || session.pendingRuntimeRequest?.isApproval == true ||
                session.pendingRuntimeRequest?.isUserInput == true { return 3 }
            if session.status == .running { return 2 }
            return 0
        }
        return Array(state.sessions.filter { !$0.isSettled && !$0.isArchived }.sorted {
            (priority($0), $0.updatedAt ?? $0.lastActivity ?? .distantPast, $0.id) >
            (priority($1), $1.updatedAt ?? $1.lastActivity ?? .distantPast, $1.id)
        }.prefix(4))
    }

    func receive(_ event: AppEvent, previous: StateSnapshot, current: StateSnapshot) {
        switch event {
        case .conversationSnapshot(let id, let entries) where id == previewID:
            previewMessageID = nil
            previewTimestamp = nil
            previewLine = nil
            if let entry = entries.last(where: Self.isMessage) { updatePreview(entry) }
            return
        case .conversationEntry(let id, let entry) where id == previewID:
            if Self.isMessage(entry) { updatePreview(entry) }
            return
        case .approvalRequested(let request):
            guard !previous.pendingApprovals.contains(where: { $0.id == request.id }) else { return }
            let session = current.sessions.first { $0.id == request.threadId }
            enqueue(.init(kind: .approval, sessionID: request.threadId, title: request.sessionName,
                          provider: session?.providerInstanceId), current: current)
        case .userInputRequested(let request):
            guard !previous.pendingUserInputs.contains(where: { $0.id == request.id }) else { return }
            let session = current.sessions.first { $0.id == request.threadId }
            enqueue(.init(kind: .input, sessionID: request.threadId, title: request.sessionName,
                          provider: session?.providerInstanceId), current: current)
        case .sessionUpdated(let session):
            guard let old = previous.sessions.first(where: { $0.id == session.id }), old.status != session.status else { return }
            if session.status == .failed || session.status == .completed {
                enqueue(sessionNotice(session), current: current)
            }
        case .sessionCompleted(let id):
            guard previous.sessions.contains(where: { $0.id == id && $0.status == .running }),
                  let session = current.sessions.first(where: { $0.id == id && $0.status == .completed }) else { return }
            enqueue(sessionNotice(session), current: current)
        case .connectionChanged(let connection) where connection != previous.connection:
            switch connection {
            case .failed(let message), .engineFailed(let message):
                enqueue(.init(kind: .failure, sessionID: nil, title: Product.displayText(message), provider: nil), current: current)
            default: break
            }
        case .demoReset:
            clearNotices()
        default: break
        }
    }

    func setPreviewSession(_ id: String?) {
        guard id != previewID else { return }
        previewID = id
        previewMessageID = nil
        previewTimestamp = nil
        previewLine = nil
    }

    func clearNotices() {
        flashTask?.cancel()
        flashTask = nil
        finishedFlash = false
        dismissal?.cancel()
        dismissal = nil
        queue.removeAll()
        notice = nil
    }

    private nonisolated static func isMessage(_ entry: ConversationEntry) -> Bool {
        entry.kind == .assistant || entry.kind == .user
    }

    private func updatePreview(_ entry: ConversationEntry) {
        if entry.id != previewMessageID, let timestamp = previewTimestamp, entry.timestamp < timestamp { return }
        previewMessageID = entry.id
        previewTimestamp = entry.timestamp
        let line = entry.text.split(whereSeparator: \.isNewline).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let next = line.map { Product.displayText(String($0.prefix(240))) }
        if next != previewLine { previewLine = next }
    }

    private func sessionNotice(_ session: SessionSummary) -> Notice {
        .init(kind: session.status == .failed ? .failure : .completion,
              sessionID: session.id, title: session.title, provider: session.providerInstanceId)
    }

    private func enqueue(_ next: Notice, current: StateSnapshot) {
        // The workspace already exposes status and approvals. Avoid replaying stale banners after dismissal.
        guard !current.workspaceOpen, current.voiceCommand == nil, current.voiceMode == nil else { return }
        if next.kind == .completion { flashFinished() }
        if notice == nil {
            show(next)
        } else if notice?.sessionID == next.sessionID, notice?.kind == next.kind {
            notice?.count += 1
        } else if let last = queue.indices.last, queue[last].kind == next.kind {
            let count = queue[last].count + 1
            queue[last] = next
            queue[last].count = count
        } else if queue.count < 3 {
            queue.append(next)
        } else {
            let count = queue[2].count + 1
            queue[2] = next
            queue[2].count = count
        }
    }

    private func flashFinished() {
        flashTask?.cancel()
        finishedFlash = true
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, !Task.isCancelled else { return }
            finishedFlash = false
            flashTask = nil
        }
    }

    private func show(_ next: Notice) {
        notice = next
        dismissal = Task { [weak self] in
            // A finished task stays long enough to read its title and click through.
            try? await Task.sleep(for: .seconds(next.kind == .completion ? 5 : 2.5))
            guard let self, !Task.isCancelled else { return }
            if queue.isEmpty {
                notice = nil
                dismissal = nil
            } else {
                show(queue.removeFirst())
            }
        }
    }
}

enum NotchAppearance: String, CaseIterable {
    static let defaultsKey = "notchAppearance"
    case black = "Black"
    case glass = "Glass"
    case tinted = "Tinted"
}

struct NotchAppearancePicker: View {
    @AppStorage(NotchAppearance.defaultsKey) private var appearance = NotchAppearance.glass

    var body: some View {
        Picker("Notch style", selection: $appearance) {
            ForEach(NotchAppearance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }
}

/// SwiftUI interpolates the silhouette; AppKit consumes that same presented path for its backdrop and hit region.
struct NotchSurface: View, Animatable {
    nonisolated var shape: NotchShape
    let frame: CGRect
    let appearance: NotchAppearance
    let tint: Color?
    /// The collapsed, idle shape. While the surface is no larger than this it draws nothing, so it never
    /// leaves a rim around the hardware notch.
    let idleSize: CGSize?
    let present: (CGPath, Bool) -> Void

    nonisolated var animatableData: NotchShape.Metrics {
        get { shape.animatableData }
        set { shape.animatableData = newValue }
    }

    var body: some View {
        let path = shape.path(in: CGRect(origin: .zero, size: frame.size))
        let hidden = idleSize.map { shape.width <= $0.width + 0.5 && shape.height <= $0.height + 0.5 } ?? false
        present(path.cgPath, appearance == .glass && !hidden)
        return path
            .fill(appearance == .glass ? .black.opacity(0.27) : .black)
            .overlay {
                if appearance == .tinted, let tint { path.fill(tint.opacity(0.23)) }
            }
            .overlay {
                path.stroke(.white.opacity(appearance == .glass ? 0.2 : 0.15), lineWidth: 1)
            }
            .opacity(hidden ? 0 : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
