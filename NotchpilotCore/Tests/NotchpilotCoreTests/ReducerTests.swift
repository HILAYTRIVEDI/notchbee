import Testing
@testable import NotchpilotCore

struct ReducerTests {
    private let session = SessionSummary(id: "a", title: "Frontend", providerInstanceId: "Claude", status: .running)
    private let request = ApprovalRequest(
        id: "req-a", threadId: "a", sessionName: "Frontend", toolName: "Shell", command: "npm run build"
    )

    @Test func idleAndRunningExpandOnlyWhileHovered() {
        let idle = StateSnapshot()
        #expect(idle.uiState == .idle)
        #expect(idle.sizeState == .compact)

        let hovered = reduce(state: idle, event: .hoverChanged(true))
        #expect(hovered.sizeState == .medium)
        let running = reduce(state: hovered, event: .sessionUpdated(session))
        #expect(running.uiState == .running)
        #expect(running.sizeState == .medium)
        #expect(reduce(state: running, event: .hoverChanged(false)).sizeState == .compact)
        #expect(idle == StateSnapshot())
    }

    @Test func newApprovalsTakePrecedenceAndDuplicatesStayInOrder() {
        let second = ApprovalRequest(
            id: "req-b", threadId: "b", sessionName: "API", toolName: "Shell", command: "cargo test"
        )
        let third = ApprovalRequest(
            id: "req-c", threadId: "c", sessionName: "Database", toolName: "Shell", command: "psql -f migrate.sql"
        )
        var state = [
            .sessionUpdated(session), .setSessionsPanel(true), .approvalRequested(request)
        ].reduce(StateSnapshot()) { reduce(state: $0, event: $1) }
        #expect(state.uiState == .needsApproval)
        #expect(state.sizeState == .medium)

        state = [.approvalRequested(second), .approvalRequested(third), .approvalRequested(request)]
            .reduce(state) { reduce(state: $0, event: $1) }
        #expect(state.pendingApprovals.map(\.id) == [request.id, second.id, third.id])
        #expect(state.sizeState == .large)

        state = reduce(state: state, event: .approvalResolved(requestId: second.id, decision: .declined))
        #expect(state.pendingApprovals == [request, third])
        #expect(state.lastDecision == .declined)
        #expect(reduce(state: state, event: .approvalResolved(requestId: second.id, decision: .accepted)) == state)

        state = reduce(state: state, event: .approvalResolved(requestId: request.id, decision: .accepted))
        #expect(state.sizeState == .medium)
        state = reduce(state: state, event: .approvalResolved(requestId: third.id, decision: .accepted))
        #expect(state.lastDecision == .accepted)
        #expect(state.uiState == .running)
    }

    @Test func completionClearsOnlyThatSessionsApprovalAndWaitsForOtherRuns() {
        let second = SessionSummary(id: "b", title: "API", providerInstanceId: "Codex", status: .running)
        var state = [
            .sessionUpdated(session), .sessionUpdated(second), .approvalRequested(request)
        ].reduce(StateSnapshot()) { reduce(state: $0, event: $1) }
        #expect(reduce(state: state, event: .sessionCompleted(sessionId: "missing")) == state)

        state = reduce(state: state, event: .sessionCompleted(sessionId: session.id))
        #expect(state.pendingApprovals.isEmpty)
        #expect(state.uiState == .running)
        state = reduce(state: state, event: .sessionCompleted(sessionId: second.id))
        #expect(state.sessions.allSatisfy { $0.status == .completed })
        #expect(state.uiState == .done)
        #expect(state.sizeState == .compact)
        #expect(reduce(state: state, event: .hoverChanged(true)).sizeState == .medium)
        #expect(reduce(state: state, event: .idleTimeout).uiState == .idle)
    }

    @Test(arguments: [SessionSummary.Status.idle, .completed])
    func completingANonRunningSessionChangesNothing(status: SessionSummary.Status) {
        var inactive = session
        inactive.status = status
        let state = StateSnapshot(sessions: [inactive], pendingApprovals: [request])
        #expect(reduce(state: state, event: .sessionCompleted(sessionId: inactive.id)) == state)
    }

    @Test func completedSessionUpdateReportsDoneWhenTheLastRunFinishes() {
        var completed = session
        completed.status = .completed
        var other = SessionSummary(id: "b", title: "API", providerInstanceId: "Codex", status: .running)
        let state = StateSnapshot(sessions: [session, other])

        let stillRunning = reduce(state: state, event: .sessionUpdated(completed))
        #expect(stillRunning.uiState == .running)
        #expect(stillRunning.completedSessionID == nil)

        other.status = .completed
        let done = reduce(state: stillRunning, event: .sessionUpdated(other))
        #expect(done.uiState == .done)
        #expect(done.completedSessionID == other.id)

        var idle = session
        idle.status = .idle
        let fastRun = reduce(state: StateSnapshot(sessions: [idle]), event: .sessionUpdated(completed))
        #expect(fastRun.uiState == .done)
        #expect(reduce(state: fastRun, event: .idleTimeout).completedSessionID == nil)
    }

    @Test func runningSessionUpdateClearsCompletionAndLastDecision() {
        var completed = session
        completed.status = .completed
        let state = StateSnapshot(sessions: [completed], lastDecision: .accepted, completedSessionID: completed.id)

        let running = reduce(state: state, event: .sessionUpdated(session))
        #expect(running.uiState == .running)
        #expect(running.completedSessionID == nil)
        #expect(running.lastDecision == nil)
    }

    @Test func sessionsAndVoiceReturnToUnderlyingAgentState() {
        var state = reduce(state: StateSnapshot(), event: .sessionUpdated(session))
        state = reduce(state: state, event: .voiceActivated)
        #expect(state.uiState == .voice)
        #expect(state.sizeState == .medium)
        state = reduce(state: state, event: .dictationStarted)
        #expect(state.uiState == .dictating)
        state = reduce(state: state, event: .setSessionsPanel(true))
        #expect(state.uiState == .dictating)
        state = reduce(state: state, event: .hoverChanged(true))
        #expect(state.uiState == .sessionsPanel)
        #expect(state.sizeState == .large)
        state = reduce(state: state, event: .hoverChanged(false))
        #expect(!state.showsSessions)
        #expect(state.uiState == .dictating)
        state = reduce(state: state, event: .voiceDeactivated)
        #expect(state.uiState == .running)
    }

    @Test func demoResetClearsRuntimeStateAndPreservesHover() {
        let state = [
            .hoverChanged(true), .sessionUpdated(session), .dictationStarted, .approvalRequested(request)
        ].reduce(StateSnapshot()) { reduce(state: $0, event: $1) }
        #expect(reduce(state: state, event: .demoReset) == StateSnapshot(isHovering: true))
    }

    @Test func errorDotCountsOnlyAFreshFailureOfTheLatestTurn() {
        var session = SessionSummary(id: "a", title: "A", providerInstanceId: "codex", status: .failed)
        #expect(!session.hasRecentFailure())
        session.latestTurnEndedAt = .now.addingTimeInterval(-60)
        #expect(session.hasRecentFailure())
        session.latestTurnEndedAt = .now.addingTimeInterval(-90_000)
        #expect(!session.hasRecentFailure())
        session.latestTurnEndedAt = .now
        session.status = .completed
        #expect(!session.hasRecentFailure())
    }
}
