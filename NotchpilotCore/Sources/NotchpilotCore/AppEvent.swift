import Foundation

public enum AppEvent: Sendable, Equatable {
    case connectionChanged(AgentConnection)
    case sessionsResynced([SessionSummary])
    case sessionUpdated(SessionSummary)
    case sessionRemoved(sessionId: String)
    case projectsUpdated([ThreadProject])
    case conversationSnapshot(sessionID: String, entries: [ConversationEntry])
    case conversationEntry(sessionID: String, entry: ConversationEntry)
    case conversationUnavailable(sessionID: String)
    case selectPanelTab(PanelTab)
    case openThread(String)
    case collapsePanel
    case sessionCompleted(sessionId: String)
    case approvalRequested(ApprovalRequest)
    case approvalResolved(requestId: String, decision: ApprovalDecision)
    case approvalWithdrawn(requestId: String)
    case approvalResponseFailed(String)
    case userInputRequested(UserInputRequest)
    case userInputResolved(requestId: String)
    case userInputWithdrawn(requestId: String)
    case userInputResponseFailed(String)
    case sessionSettleChanged(sessionId: String, resolved: Bool)
    case settingsChanged
    case sessionSettleFinished(sessionId: String, succeeded: Bool)
    case toggleShowResolved

    case voiceCommand(UUID, VoiceCommandEvent)
    case voiceActivated
    case dictationStarted
    case voiceDeactivated
    case setSessionsPanel(Bool)
    case hoverChanged(Bool)
    case idleTimeout
    case demoReset
}
