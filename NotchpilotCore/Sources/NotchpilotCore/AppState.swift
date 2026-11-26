import Foundation
import Observation

public enum NotchUIState: String, CaseIterable, Sendable {
    case idle = "Idle"
    case running = "Running"
    case needsApproval = "Needs Approval"
    case needsInput = "Needs Input"
    case done = "Done"
    case error = "Error"
    case disconnected = "Disconnected"
    case voice = "Voice"
    case dictating = "Dictating"
    case sessionsPanel = "Sessions Panel"
}

public enum NotchSizeState: Sendable {
    case compact
    case medium
    case large
}

public enum ApprovalDecision: Sendable, Equatable {
    case accepted
    case declined
}

public enum AgentConnection: Sendable, Equatable {
    case disconnected
    /// Built-in engine lifecycle, before the client connects.
    case engineStarting
    case engineRestarting
    case engineFailed(String)
    case failed(String)
    case connected
}

public struct ApprovalRequest: Identifiable, Sendable, Equatable {
    public let id: String
    public let threadId: String
    public let sessionName: String
    public let toolName: String
    public let command: String
    public let context: String?
    public let canApprove: Bool

    public init(
        id: String, threadId: String, sessionName: String, toolName: String, command: String,
        context: String? = nil, canApprove: Bool = true
    ) {
        self.id = id
        self.threadId = threadId
        self.sessionName = sessionName
        self.toolName = toolName
        self.command = command
        self.context = context
        self.canApprove = canApprove
    }
}

public struct SessionDiff: Sendable, Equatable {
    public let files: Int
    public let additions: Int
    public let deletions: Int
}

public struct SessionSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public var title: String
    public let providerInstanceId: String
    /// The model the thread's next turn uses.
    public var modelSelection: ThreadModelSelection?
    public var status: Status
    public var projectID: String?
    public var project: String?
    public var repository: String?
    public var branch: String?
    /// The folder the thread works in: its worktree when it has one, otherwise the project root.
    public var workspacePath: String?
    public var diff: SessionDiff?
    public var error: String?
    public var latestTurnEndedAt: Date?
    public func hasRecentFailure(at now: Date = .now) -> Bool {
        guard status == .failed, let ended = latestTurnEndedAt else { return false }
        return now.timeIntervalSince(ended) < 86_400
    }
    public var lastActivity: Date?
    public var updatedAt: Date?
    public var isArchived = false
    public var pendingRuntimeRequest: PendingRuntimeRequest?
    /// Server-side settle state. Settled threads are "Done" in the UI.
    public var isSettled = false
    public var displayStatus: String {
        if isSettled { return "Done" }
        switch status {
        case .running: return "Running"
        case .idle, .completed: return "Idle"
        case .interrupted, .failed: return "Stopped"
        }
    }

    public struct PendingRuntimeRequest: Sendable, Equatable {
        public let id: String
        public let kind: String?
        public let isApproval: Bool
        public let isUserInput: Bool

        public init(id: String, kind: String?, isApproval: Bool, isUserInput: Bool = false) {
            self.id = id
            self.kind = kind
            self.isApproval = isApproval
            self.isUserInput = isUserInput
        }
    }

    public enum Status: String, Sendable {
        case idle = "Idle"
        case running = "Running"
        case completed = "Done"
        case interrupted = "Stopped"
        case failed = "Error"
    }

    public init(id: String, title: String, providerInstanceId: String, status: Status) {
        self.id = id
        self.title = title
        self.providerInstanceId = providerInstanceId
        self.status = status
    }
}

public struct StateSnapshot: Sendable, Equatable {
    public enum VoiceMode: Sendable {
        case listening
        case dictating
    }

    public internal(set) var sessions: [SessionSummary] = []
    public internal(set) var projects: [ThreadProject] = []
    public internal(set) var openThreadID: String?
    public internal(set) var conversation: ThreadConversation?
    public internal(set) var conversationUnavailable = false
    public internal(set) var panelTab: PanelTab = .sessions
    public internal(set) var workspaceOpen = false
    public internal(set) var hoverSuppressed = false
    public internal(set) var pendingApprovals: [ApprovalRequest] = []
    public internal(set) var lastDecision: ApprovalDecision?
    public internal(set) var approvalError: String?
    public internal(set) var pendingUserInputs: [UserInputRequest] = []
    public internal(set) var userInputError: String?
    public internal(set) var voiceCommand: VoiceCommandState?
    public internal(set) var voiceMode: VoiceMode?
    public internal(set) var showsSessions = false
    public internal(set) var isHovering = false
    public internal(set) var completedSessionID: String?
    public internal(set) var failedSessionID: String?
    public internal(set) var connection: AgentConnection = .connected
    fileprivate var previousResolution: [String: Bool] = [:]
    public internal(set) var settingsRevision = 0
    /// Whether the sessions panel shows settled (resolved) sessions.
    public internal(set) var showResolved: Bool = false

    public init() {}

    public var uiState: NotchUIState {
        if voiceCommand != nil { return .voice }
        if workspaceOpen || (showsSessions && isHovering) { return .sessionsPanel }
        switch connection {
        case .failed, .engineFailed: return .error
        case .disconnected, .engineStarting, .engineRestarting: return .disconnected
        case .connected: break
        }
        if !pendingApprovals.isEmpty { return .needsApproval }
        if !pendingUserInputs.isEmpty { return .needsInput }
        switch voiceMode {
        case .listening: return .voice
        case .dictating: return .dictating
        case nil: break
        }
        if failedSessionID != nil { return .error }
        if sessions.contains(where: { $0.status == .running }) { return .running }
        return completedSessionID == nil ? .idle : .done
    }

    public var sizeState: NotchSizeState {
        if hoverSuppressed && !workspaceOpen && voiceCommand == nil { return .compact }
        switch uiState {
        case .sessionsPanel: return .large
        case .needsApproval: return pendingApprovals.count > 1 || approvalError != nil ? .large : .medium
        case .needsInput: return .large
        case .voice, .dictating: return .medium
        case .idle, .running, .done, .error, .disconnected: return isHovering ? .medium : .compact
        }
    }
}

@MainActor
@Observable
public final class AppState {
    /// Panel state is observed independently from the streaming conversation.
    public private(set) var panelSnapshot = StateSnapshot()
    public private(set) var conversation: ThreadConversation?

    public var snapshot: StateSnapshot {
        var state = panelSnapshot
        state.conversation = conversation
        return state
    }

    public init() {}

    public func apply(_ event: AppEvent) {
        if case .conversationEntry(let id, let entry) = event {
            guard id == panelSnapshot.openThreadID, conversation != nil,
                  conversation?.entry(withID: entry.id) != entry else { return }
            conversation?.upsert(entry)
            return
        }
        var next = reduce(state: snapshot, event: event)
        if conversation != next.conversation { conversation = next.conversation }
        next.conversation = nil
        if panelSnapshot != next { panelSnapshot = next }
    }
}

public func reduce(state: StateSnapshot, event: AppEvent) -> StateSnapshot {
    var next = state
    switch event {
    case .connectionChanged(let connection):
        next.connection = connection
        if connection != .connected {
            next.pendingApprovals.removeAll()
            next.pendingUserInputs.removeAll()
            next.userInputError = nil
            next.completedSessionID = nil
            next.failedSessionID = nil
            next.lastDecision = nil
            next.approvalError = nil
        }
    case .sessionsResynced(let sessions):
        next.previousResolution.removeAll()
        next.sessions = sessions
        next.pendingApprovals.removeAll()
        next.pendingUserInputs.removeAll()
        next.userInputError = nil
        next.completedSessionID = nil
        next.failedSessionID = nil
        next.lastDecision = nil
        next.approvalError = nil
    case .projectsUpdated(let projects):
        next.projects = projects
    case .conversationSnapshot(let id, let entries):
        guard id == next.openThreadID else { return state }
        next.conversationUnavailable = false
        next.conversation = ThreadConversation(entries)
    case .conversationEntry(let id, let entry):
        guard id == next.openThreadID, next.conversation != nil else { return state }
        next.conversation?.upsert(entry)
    case .conversationUnavailable(let id):
        guard id == next.openThreadID else { return state }
        next.conversationUnavailable = true
    case .selectPanelTab(let tab):
        guard tab != .thread || next.openThreadID != nil else { return state }
        next.panelTab = tab
        next.workspaceOpen = true
        next.hoverSuppressed = false
    case .openThread(let id):
        if next.openThreadID != id {
            next.conversation = nil
            next.conversationUnavailable = false
        }
        next.openThreadID = id
        next.panelTab = .thread
        next.workspaceOpen = true
        next.hoverSuppressed = false
    case .collapsePanel:
        next.workspaceOpen = false
        next.showsSessions = false
        next.panelTab = .sessions
        next.openThreadID = nil
        next.conversation = nil
        next.conversationUnavailable = false
        next.hoverSuppressed = true
    case .sessionUpdated(let session):
        next.previousResolution[session.id] = nil
        let previousStatus = next.sessions.first(where: { $0.id == session.id })?.status
        if let index = next.sessions.firstIndex(where: { $0.id == session.id }) {
            next.sessions[index] = session
        } else {
            next.sessions.append(session)
        }
        guard session.status != previousStatus else { return next }
        switch session.status {
        case .running:
            next.completedSessionID = nil
            next.lastDecision = nil
            if next.failedSessionID == session.id { next.failedSessionID = nil }
        case .completed where previousStatus != nil:
            if !next.sessions.contains(where: { $0.status == .running }) {
                next.completedSessionID = session.id
            }
        case .failed where previousStatus != nil:
            next.failedSessionID = session.id
        default:
            break
        }
    case .sessionRemoved(let sessionId):
        next.previousResolution[sessionId] = nil
        next.sessions.removeAll { $0.id == sessionId }
        if next.openThreadID == sessionId {
            next.openThreadID = nil
            next.conversation = nil
            next.conversationUnavailable = false
            if next.panelTab == .thread { next.panelTab = .sessions }
        }
        next.pendingApprovals.removeAll { $0.threadId == sessionId }
        next.pendingUserInputs.removeAll { $0.threadId == sessionId }
        if next.pendingUserInputs.isEmpty { next.userInputError = nil }
        if next.completedSessionID == sessionId { next.completedSessionID = nil }
        if next.failedSessionID == sessionId { next.failedSessionID = nil }
        if next.pendingApprovals.isEmpty { next.approvalError = nil }
    case .sessionCompleted(let sessionId):
        guard let index = next.sessions.firstIndex(where: { $0.id == sessionId && $0.status == .running })
        else { return state }
        next.sessions[index].status = .completed
        next.pendingApprovals.removeAll { $0.threadId == sessionId }
        if next.pendingApprovals.isEmpty { next.approvalError = nil }
        next.completedSessionID = sessionId
    case .approvalRequested(let request):
        if let index = next.pendingApprovals.firstIndex(where: { $0.id == request.id }) {
            next.pendingApprovals[index] = request
        } else {
            next.pendingApprovals.append(request)
            next.showsSessions = false
            next.lastDecision = nil
            next.approvalError = nil
        }
    case .approvalResolved(let requestId, let decision):
        guard next.pendingApprovals.contains(where: { $0.id == requestId }) else { return state }
        next.pendingApprovals.removeAll { $0.id == requestId }
        next.lastDecision = decision
        next.approvalError = nil
    case .approvalWithdrawn(let requestId):
        next.pendingApprovals.removeAll { $0.id == requestId }
        if next.pendingApprovals.isEmpty { next.approvalError = nil }
    case .approvalResponseFailed(let message):
        if !next.pendingApprovals.isEmpty { next.approvalError = message }
    case .userInputRequested(let request):
        if let index = next.pendingUserInputs.firstIndex(where: { $0.id == request.id }) {
            next.pendingUserInputs[index] = request
        } else {
            next.pendingUserInputs.append(request)
            next.showsSessions = false
            next.userInputError = nil
        }
    case .userInputResolved(let requestId), .userInputWithdrawn(let requestId):
        next.pendingUserInputs.removeAll { $0.id == requestId }
        if next.pendingUserInputs.isEmpty { next.userInputError = nil }
    case .userInputResponseFailed(let message):
        if !next.pendingUserInputs.isEmpty { next.userInputError = message }
    case .voiceCommand(let id, let event):
        next.voiceCommand = reduceVoice(next.voiceCommand, id: id, event: event)
    case .voiceActivated:
        next.voiceMode = .listening
    case .dictationStarted:
        next.voiceMode = .dictating
    case .voiceDeactivated:
        next.voiceMode = nil
    case .setSessionsPanel(let isShowing):
        next.showsSessions = isShowing
    case .hoverChanged(let isHovering):
        next.isHovering = isHovering
        if isHovering && !state.isHovering { next.hoverSuppressed = false }
        if !isHovering { next.showsSessions = false }
    case .idleTimeout:
        next.completedSessionID = nil
        next.failedSessionID = nil
    case .sessionSettleChanged(let sessionId, let state):
        if let idx = next.sessions.firstIndex(where: { $0.id == sessionId }) {
            next.previousResolution[sessionId] = next.sessions[idx].isSettled
            next.sessions[idx].isSettled = state
        }
    case .sessionSettleFinished(let id, let succeeded):
        if let previous = next.previousResolution.removeValue(forKey: id), !succeeded,
           let index = next.sessions.firstIndex(where: { $0.id == id }) {
            next.sessions[index].isSettled = previous
        }
    case .settingsChanged:
        next.settingsRevision += 1
    case .toggleShowResolved:
        next.showResolved.toggle()
    case .demoReset:
        next = StateSnapshot(isHovering: state.isHovering)
        next.voiceCommand = state.voiceCommand
    }
    return next
}

// A package-internal initializer keeps reducer fixtures concise.
extension StateSnapshot {
    init(
        sessions: [SessionSummary] = [], pendingApprovals: [ApprovalRequest] = [],
        lastDecision: ApprovalDecision? = nil, isHovering: Bool = false, completedSessionID: String? = nil
    ) {
        self.sessions = sessions
        self.pendingApprovals = pendingApprovals
        self.lastDecision = lastDecision
        self.isHovering = isHovering
        self.completedSessionID = completedSessionID
    }
}
