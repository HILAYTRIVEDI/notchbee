import NotchpilotCore
import Testing
@testable import Notchpilot

@MainActor
struct FakeBackendTests {
    @Test(.timeLimit(.minutes(1)))
    func backendEmitsSessionAndApprovalLifecycleForBothDecisions() async throws {
        let backend: any AgentBackend = FakeBackend()
        var events = backend.eventStream().makeAsyncIterator()
        var state = StateSnapshot()

        let sessionID = try await backend.startSession(title: "Test session", providerInstanceId: "Codex", model: "demo")
        state = reduce(state: state, event: try #require(await events.next()))
        #expect(state.sessions.first?.id == sessionID)
        #expect(state.uiState == .idle)

        for decision in [ApprovalDecision.accepted, .declined] {
            try await backend.sendPrompt(sessionId: sessionID, text: "Run the fake task")
            state = reduce(state: state, event: try #require(await events.next()))
            #expect(state.uiState == .running)
            state = reduce(state: state, event: try #require(await events.next()))
            #expect(state.uiState == .needsApproval)
            let request = try #require(state.pendingApprovals.first)
            #expect(request.threadId == sessionID)

            switch decision {
            case .accepted: try await backend.approve(requestId: request.id, threadId: request.threadId)
            case .declined: try await backend.deny(requestId: request.id, threadId: request.threadId)
            }
            state = reduce(state: state, event: try #require(await events.next()))
            #expect(state.pendingApprovals.isEmpty)
            #expect(state.lastDecision == decision)
            state = reduce(state: state, event: try #require(await events.next()))
            #expect(state.uiState == .done)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func questionIsRequestedAnsweredAndDismissedThroughTheBackend() async throws {
        let fake = FakeBackend()
        let backend: any AgentBackend = fake
        var events = backend.eventStream().makeAsyncIterator()
        var state = StateSnapshot()

        fake.showUserInputDemo()
        while state.pendingUserInputs.isEmpty { state = reduce(state: state, event: try #require(await events.next())) }
        #expect(state.uiState == .needsInput)
        let request = try #require(state.pendingUserInputs.first)
        var draft = UserInputDraft(for: request)
        #expect(!draft.isComplete(for: request))
        draft.toggle(request.questions[0].options[0], in: request.questions[0])
        #expect(draft.isComplete(for: request))

        try await backend.answerUserInput(requestId: request.id, threadId: request.threadId, answers: draft.answers(for: request))
        state = reduce(state: state, event: try #require(await events.next()))
        #expect(state.pendingUserInputs.isEmpty)

        fake.showUserInputDemo()
        while state.pendingUserInputs.isEmpty { state = reduce(state: state, event: try #require(await events.next())) }
        let second = try #require(state.pendingUserInputs.first)
        try await backend.dismissUserInput(requestId: second.id, threadId: second.threadId)
        state = reduce(state: state, event: try #require(await events.next()))
        #expect(state.pendingUserInputs.isEmpty)
    }
}
