import NotchpilotCore
import Foundation

@MainActor
final class FakeBackend: AgentBackend {
    enum BackendError: LocalizedError {
        case unknownSession, emptyPrompt, wrongThread

        var errorDescription: String? {
            switch self {
            case .unknownSession: "The session could not be found."
            case .emptyPrompt: "Enter a prompt first."
            case .wrongThread: "The request belongs to another session."
            }
        }
    }

    private let feed = FakeEventFeed()
    private var events = AsyncStream<AppEvent>.makeStream()
    private var eventsFinished = false
    private var sessions: [String: SessionSummary] = [:]
    private var visibleDetails: Set<String> = []
    private var conversations: [String: [ConversationEntry]] = [:]
    private var pendingApprovals: [String: ApprovalRequest] = [:]
    var repository = FakeRepository()
    private var pendingInputs: [String: UserInputRequest] = [:]

    func eventStream() -> AsyncStream<AppEvent> {
        if eventsFinished {
            events = AsyncStream<AppEvent>.makeStream()
            eventsFinished = false
        }
        return events.stream
    }

    func startSession(title: String, providerInstanceId: String, model: String) async throws -> String {
        let session = SessionSummary(
            id: UUID().uuidString, title: title, providerInstanceId: providerInstanceId, status: .idle
        )
        emit(.sessionUpdated(session))
        return session.id
    }

    func startSession(title: String, inProjectOf sessionId: String?, prompt: String) async throws {
        let base = sessionId.flatMap { sessions[$0] }
        var session = SessionSummary(
            id: UUID().uuidString, title: title, providerInstanceId: base?.providerInstanceId ?? "demo", status: .idle
        )
        session.project = base?.project ?? "\(Product.name) Scratch"
        session.projectID = base?.projectID
        emit(.sessionUpdated(session))
        try await sendPrompt(sessionId: session.id, text: prompt)
    }

    func sendPrompt(sessionId: String, text: String) async throws {
        guard var session = sessions[sessionId] else { throw BackendError.unknownSession }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BackendError.emptyPrompt
        }
        append(text, kind: .user, to: sessionId)
        session.lastActivity = .now
        session.status = .running
        emit(.sessionUpdated(session))
        emit(.approvalRequested(ApprovalRequest(
            id: UUID().uuidString, threadId: sessionId, sessionName: session.title,
            toolName: "Shell", command: "echo 'Simulated agent task'"
        )))
    }

    func setSessionDetailsVisible(_ visible: Bool, sessionId: String) {
        if visible {
            visibleDetails.insert(sessionId)
            emit(.conversationSnapshot(sessionID: sessionId, entries: conversations[sessionId, default: []]))
        } else {
            visibleDetails.remove(sessionId)
        }
    }

    func providerCatalog(projectID: String?) async throws -> ThreadProviderCatalog {
        .init(providers: [.init(id: "demo", name: "Demo",
                               models: [.init(id: "demo", name: "Demo Model"), .init(id: "demo-fast", name: "Demo Fast")],
                               runtimeModes: [.approvalRequired],
                               commands: [.init(kind: .command, name: "review", detail: "Review the current changes"),
                                          .init(kind: .skill, name: "explain", detail: "Explain the selected code")])],
              defaultSelection: .init(instanceId: "demo", model: "demo"))
    }

    func launchThread(_ request: ThreadLaunch) async throws -> String {
        let id = request.ids.thread
        guard sessions[id] == nil else { return id }
        var session = SessionSummary(id: id, title: String(request.prompt.prefix(80)), providerInstanceId: "Demo", status: .idle)
        session.project = "\(Product.name) Demo"
        emit(.sessionUpdated(session))
        try await sendPrompt(sessionId: id, text: request.prompt)
        return id
    }

    func mutateThread(sessionID: String, mutation: ThreadMutation) async throws {
        guard var session = sessions[sessionID] else { throw BackendError.unknownSession }
        switch mutation {
        case .resolve(let resolved): session.isSettled = resolved
        case .stop:
            for request in pendingApprovals.values.filter({ $0.threadId == sessionID }) {
                emit(.approvalWithdrawn(requestId: request.id))
            }
            session.status = .interrupted
        case .rename(let title):
            session.title = title
        case .setModel(let selection): session.modelSelection = selection
        case .archive: session.isArchived = true
        case .unarchive: session.isArchived = false
        case .delete:
            emit(.sessionRemoved(sessionId: sessionID))
            return
        }
        emit(.sessionUpdated(session))
    }

    private func append(_ text: String, kind: ConversationEntry.Kind, to sessionID: String) {
        let entry = ConversationEntry(id: UUID().uuidString, kind: kind, text: text,
                                      timestamp: Date.now.formatted(.iso8601.time(includingFractionalSeconds: true)))
        conversations[sessionID, default: []].append(entry)
        if visibleDetails.contains(sessionID) { emit(.conversationEntry(sessionID: sessionID, entry: entry)) }
    }

    func approve(requestId: String, threadId: String) async throws {
        try resolve(requestId: requestId, threadId: threadId, decision: .accepted)
    }

    func deny(requestId: String, threadId: String) async throws {
        try resolve(requestId: requestId, threadId: threadId, decision: .declined)
    }

    func answerUserInput(requestId: String, threadId: String, answers: [String: UserInputAnswer]) async throws {
        guard let request = pendingInputs[requestId] else { return }
        guard request.threadId == threadId else { throw BackendError.wrongThread }
        emit(.userInputResolved(requestId: requestId))
        let summary = request.questions.compactMap { question in
            answers[question.id].map { answer -> String in
                switch answer {
                case .single(let value): value
                case .multiple(let values): values.joined(separator: ", ")
                }
            }
        }.joined(separator: " · ")
        append("Answered: \(summary)", kind: .user, to: threadId)
        append("Thanks, continuing with that.", kind: .assistant, to: threadId)
    }

    func dismissUserInput(requestId: String, threadId: String) async throws {
        guard let request = pendingInputs[requestId] else { return }
        guard request.threadId == threadId else { throw BackendError.wrongThread }
        emit(.userInputWithdrawn(requestId: requestId))
    }

    func startEventFeed() {
        emit(.demoReset)
        let session = Self.demoSessions[0]
        let request = Self.demoApprovals[0]
        feed.start(script: [
            (.seconds(1), .sessionUpdated(session)),
            (.seconds(2), .approvalRequested(request)),
            (.seconds(6), .approvalResolved(requestId: request.id, decision: .accepted)),
            (.seconds(1), .sessionCompleted(sessionId: session.id)),
            (.seconds(6), .voiceActivated),
            (.seconds(2), .dictationStarted),
            (.seconds(2), .voiceDeactivated),
            (.seconds(1), .setSessionsPanel(true)),
            (.seconds(3), .setSessionsPanel(false))
        ]) { [weak self] event in
            self?.emit(event)
        }
    }

    func stopEventFeed() {
        feed.stop()
        events.continuation.finish()
        eventsFinished = true
    }

    func showDemo(_ state: NotchUIState) {
        feed.stop()
        emit(.demoReset)
        let session = Self.demoSessions[0]
        switch state {
        case .idle: break
        case .running:
            Self.demoSessions.forEach { emit(.sessionUpdated($0)) }
        case .needsApproval:
            Self.demoSessions.forEach { emit(.sessionUpdated($0)) }
            emit(.approvalRequested(Self.demoApprovals[0]))
        case .needsInput:
            showUserInputDemo()
        case .done:
            emit(.sessionUpdated(session))
            emit(.sessionCompleted(sessionId: session.id))
        case .error:
            emit(.sessionUpdated(session))
            var failed = session
            failed.status = .failed
            failed.error = "The demo task failed."
            emit(.sessionUpdated(failed))
        case .disconnected:
            emit(.connectionChanged(.disconnected))
        case .voice:
            emit(.voiceActivated)
        case .dictating:
            emit(.dictationStarted)
        case .sessionsPanel:
            Self.demoSessions.forEach { emit(.sessionUpdated($0)) }
            emit(.setSessionsPanel(true))
        }
    }

    #if DEBUG
    /// Opens the Sessions tab with the demo sessions, held open like a clicked workspace.
    func showSessionsWorkspace() {
        feed.stop()
        emit(.demoReset)
        for (session, line) in zip(Self.demoSessions, [
            "Checking the responsive layout and build output.",
            "Validating the migration against the demo database.",
            "Running the API smoke tests."
        ]) {
            emit(.sessionUpdated(session))
            append(line, kind: .assistant, to: session.id)
        }
        emit(.selectPanelTab(.sessions))
    }

    /// A rich, offline thread used to review the timeline renderer. Never talks to a real engine.
    func showRichDemo() {
        feed.stop()
        emit(.demoReset)
        Self.demoSessions.forEach { emit(.sessionUpdated($0)) }
        let id = Self.demoSessions[0].id
        let base = Date.now.addingTimeInterval(-600)
        func at(_ seconds: Double) -> String {
            base.addingTimeInterval(seconds).formatted(.iso8601.time(includingFractionalSeconds: true))
        }
        func tool(_ key: String, _ seconds: Double, _ detail: ConversationDetail, status: String = "completed") -> ConversationEntry {
            var detail = detail
            detail.endTimestamp = at(seconds + 3)
            return .init(id: "activity:" + key, kind: .tool, text: detail.title, timestamp: at(seconds), status: status, detail: detail)
        }
        let answer = """
        ## Resolve in one click

        The resolve flow now needs **one** click: hover a row and press the check, or hit `⌘⇧D` inside a thread.

        ```swift
        func resolve(_ session: SessionSummary) {
            guard connected else { return }
            state.apply(.sessionSettleChanged(sessionId: session.id, resolved: true)) // optimistic
            Task { try await backend.mutateThread(sessionID: session.id, mutation: .resolve(true)) }
        }
        ```

        | Surface | Before | Now |
        |:--|:-:|--:|
        | Session row | Open the workspace, find the **active session**, then open its menu. | Hover the row and choose `Resolve` to finish in one click. |
        | Thread header | Open the menu and confirm the change. | The **checkmark** stays within reach while you read a long reply. |
        | Keyboard | none | ⌘⇧D |

        - Undo lives in a toast for six seconds
        - Nothing is confirmed twice
        - [x] Hover check
        - [ ] Swipe to resolve

        > Resolved threads leave **Active** but stay searchable.
        """
        conversations[id] = [
            .init(id: "message:u1", kind: .user, text: "Make resolving a session a single click and show me the diff.", timestamp: at(0)),
            .init(id: "activity:r1", kind: .reasoning, text: "**Planning the change**\nThe row needs a hover affordance, the header a button, and a toast for undo.", timestamp: at(2), status: "completed"),
            tool("c1", 5, .init(tool: .command, title: "rg -n \"resolveButton\" Notchpilot/Sources", output: "Panel/NotchView.swift:353: private func resolveButton(_ session: SessionSummary)\nPanel/NotchView.swift:391: resolveButton(session)", exitCode: 0)),
            tool("r1", 9, .init(tool: .read, title: "Notchpilot/Sources/Panel/NotchView.swift")),
            tool("s1", 12, .init(tool: .search, title: "SessionRowView")),
            tool("e1", 20, .init(tool: .fileChange, title: "NotchView.swift", additions: 42, deletions: 11,
                                  diff: "@@ -353,3 +353,9 @@\n-    private func resolveButton(_ session: SessionSummary) -> some View {\n+    private func threadResolveButton(_ session: SessionSummary) -> some View {\n+        Button { resolver.resolve(session) } label: { Text(\"Resolve\") }\n     }",
                                  files: [.init(path: "Notchpilot/Sources/Panel/NotchView.swift")])),
            tool("c2", 34, .init(tool: .command, title: "swift test", output: "Test run with 84 tests passed", exitCode: 0)),
            .init(id: "plan1", kind: .plan, text: "### Plan\n1. Add the hover check to session rows\n2. Add a header Resolve button\n3. Wire ⌘⇧D and the Undo toast", timestamp: at(40)),
            .init(id: "todo1", kind: .todo, text: "", timestamp: at(41), detail: .init(steps: [
                .init(text: "Hover check on rows", status: "completed"), .init(text: "Header Resolve button", status: "completed"),
                .init(text: "Undo toast", status: "running"), .init(text: "Keyboard shortcut", status: "pending")])),
            .init(id: "message:a1", kind: .assistant, text: answer, timestamp: at(60)),
            .init(id: "error1", kind: .error, text: "Rate limit reached for gpt-5. Retrying in 20s.", timestamp: at(70)),
            .init(id: "message:u2", kind: .user, text: "Looks right. Ship it.", timestamp: at(80))
        ]
        emit(.openThread(id))
        emit(.conversationSnapshot(sessionID: id, entries: conversations[id] ?? []))
        if ProcessInfo.processInfo.arguments.contains("--demo-stream") { streamDemoReply(to: id) }
    }

    /// Streams a long Markdown reply word by word, like a fast provider, for profiling the timeline.
    private func streamDemoReply(to id: String) {
        let paragraph = "The renderer folds **tool calls** into a single `Worked for` row, highlights code, and keeps tables aligned. "
        let code = "```swift\nfunc tick() {\n    state.apply(.sessionSettleChanged(sessionId: id, resolved: true))\n}\n```\n\n"
        let table = "| Surface | Before | Now |\n|:--|:-:|--:|\n| Row | 3 clicks | 1 click |\n| Header | menu | 1 click |\n\n"
        let source = (0..<14).map { "### Step \($0)\n\n" + paragraph + paragraph + "\n\n" + ($0 % 3 == 0 ? code : "") + ($0 % 4 == 0 ? table : "") }.joined()
        let words = source.split(separator: " ", omittingEmptySubsequences: false)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            var text = ""
            for (index, word) in words.enumerated() {
                guard let self, !Task.isCancelled else { return }
                text += (index == 0 ? "" : " ") + word
                self.emit(.conversationEntry(sessionID: id, entry: .init(
                    id: "message:stream", kind: .assistant, text: text,
                    timestamp: Date.now.addingTimeInterval(1).formatted(.iso8601.time(includingFractionalSeconds: true)),
                    streaming: index < words.count - 1)))
                try? await Task.sleep(for: .milliseconds(12))
            }
        }
    }
    #endif

    /// An agent asking two questions: a single choice and a multi-select with a free-text "Other".
    func showUserInputDemo(openingThread: Bool = false) {
        feed.stop()
        emit(.demoReset)
        Self.demoSessions.forEach { emit(.sessionUpdated($0)) }
        emit(.userInputRequested(Self.demoUserInput))
        if openingThread { emit(.openThread(Self.demoSessions[0].id)) }
    }

    func showMultipleApprovals() {
        feed.stop()
        emit(.demoReset)
        Self.demoSessions.forEach { emit(.sessionUpdated($0)) }
        Self.demoApprovals.forEach { emit(.approvalRequested($0)) }
    }

    private func resolve(requestId: String, threadId: String, decision: ApprovalDecision) throws {
        guard let request = pendingApprovals[requestId] else { return }
        guard request.threadId == threadId else { throw BackendError.wrongThread }
        emit(.approvalResolved(requestId: requestId, decision: decision))
        append(decision == .accepted ? "The demo command completed." : "The demo command was denied.",
               kind: .assistant, to: threadId)
        if !pendingApprovals.values.contains(where: { $0.threadId == threadId }) {
            emit(.sessionCompleted(sessionId: threadId))
        }
    }

    private func emit(_ event: AppEvent) {
        switch event {
        case .sessionUpdated(let session):
            sessions[session.id] = session
        case .sessionCompleted(let sessionId):
            guard sessions[sessionId]?.status == .running else { return }
            sessions[sessionId]?.status = .completed
            pendingApprovals = pendingApprovals.filter { $0.value.threadId != sessionId }
        case .approvalRequested(let request):
            pendingApprovals[request.id] = request
        case .approvalResolved(let requestId, _):
            guard pendingApprovals.removeValue(forKey: requestId) != nil else { return }
        case .approvalWithdrawn(let requestId):
            pendingApprovals.removeValue(forKey: requestId)
        case .userInputRequested(let request):
            pendingInputs[request.id] = request
        case .userInputResolved(let requestId), .userInputWithdrawn(let requestId):
            pendingInputs.removeValue(forKey: requestId)
        case .sessionRemoved(let sessionId):
            sessions.removeValue(forKey: sessionId)
            conversations.removeValue(forKey: sessionId)
            pendingApprovals = pendingApprovals.filter { $0.value.threadId != sessionId }
            pendingInputs = pendingInputs.filter { $0.value.threadId != sessionId }
        case .demoReset:
            sessions.removeAll()
            conversations.removeAll()
            visibleDetails.removeAll()
            pendingApprovals.removeAll()
            pendingInputs.removeAll()
        default:
            break
        }
        events.continuation.yield(event)
        if event == .demoReset {
            events.continuation.yield(.projectsUpdated([.init(id: "demo", name: "\(Product.name) Demo")]))
        }
    }

    private static let demoSessions = [
        SessionSummary(id: "frontend", title: "Frontend build", providerInstanceId: "Claude", status: .running),
        SessionSummary(id: "api", title: "API server", providerInstanceId: "Codex", status: .running),
        SessionSummary(id: "database", title: "Database migration", providerInstanceId: "Claude", status: .running),
        SessionSummary(id: "docs", title: "Understand Notch Version Zero PDF", providerInstanceId: "Codex", status: .idle)
    ].map { session in
        var session = session
        session.project = "\(Product.name) Demo"
        session.projectID = "demo"
        session.workspacePath = FakeRepository.path
        if session.id == "docs" { session.updatedAt = Date.now.addingTimeInterval(-7_200) }
        return session
    }

    private static var demoUserInput: UserInputRequest {
        let session = demoSessions[0]
        return UserInputRequest(id: UUID().uuidString, threadId: session.id, sessionName: session.title, questions: [
            UserInputQuestion(
                id: "database", header: "Database", question: "Which database should the migration target?",
                options: [
                    .init(label: "Postgres", description: "Matches production and supports the JSON columns."),
                    .init(label: "SQLite", description: "Zero setup, fine for local development only."),
                    .init(label: "MySQL", description: "Only if the hosting plan requires it.")
                ]),
            UserInputQuestion(
                id: "checks", header: "Checks", question: "Which checks should run before merging?",
                options: [
                    .init(label: "Unit tests", description: "Fast, runs on every change."),
                    .init(label: "Type check", description: "Catches contract drift early.")
                ], multiSelect: true, allowCustomAnswer: true, required: false)
        ])
    }

    private static var demoApprovals: [ApprovalRequest] {
        zip(demoSessions.prefix(3), ["npm run build", "cargo test", "psql -f migrate.sql"]).map { session, command in
            ApprovalRequest(
                id: UUID().uuidString, threadId: session.id,
                sessionName: session.title, toolName: "Shell", command: command
            )
        }
    }
}
