import Foundation
import Testing
@testable import NotchpilotCore

struct T3FixtureTests {
    @Test func encodesTheRecordedLaunchAndDecodesItsSuccessAndFailures() throws {
        struct LaunchCapture: Decodable {
            struct Frame: Decodable { let payload: T3Client.LaunchThread }
            let frame: Frame
        }

        let captures = try fixture("thread-launch")
        let first = try #require(try fixtureLines("thread-launch").first)
        let recorded = try JSONDecoder().decode(LaunchCapture.self, from: Data(first.utf8)).frame.payload
        let ids = ThreadLaunch.IDs()
        let launch = T3Client.LaunchThread(.init(projectID: recorded.projectId, modelSelection: recorded.modelSelection,
                                                 runtimeMode: .approvalRequired, prompt: recorded.initialMessage.text,
                                                 ids: ids), projectID: recorded.projectId)
        #expect(Set([ids.command, ids.thread, ids.message]).count == 3)
        let record = try #require(try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
        let frame = try #require(record["frame"] as? [String: Any])
        var expected = try #require(frame["payload"] as? [String: Any])
        var message = try #require(expected["initialMessage"] as? [String: Any])
        expected["commandId"] = ids.command
        expected["threadId"] = ids.thread
        message["messageId"] = ids.message
        expected["initialMessage"] = message
        let encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(launch)) as? NSDictionary)
        #expect(encoded == NSDictionary(dictionary: expected))
        #expect(launch.modelSelection.options?.first?.value == .choice("low"))

        let exits = captures.compactMap { capture -> T3Client.Exit? in
            if case .exit(_, let exit) = capture.frame { return exit }
            return nil
        }
        #expect(exits.map(\.tag) == ["Success", "Failure", "Failure"])
        #expect(exits.first?.value?.threadId == recorded.threadId)
        #expect(exits.dropFirst().map { T3Client.RPCFailure(exit: $0).localizedDescription }
            == ["Expected a non-blank string\n  at [\"title\"]", "Project not found."])
    }

    @Test func skipsWhitespaceWhenGeneratingALaunchTitle() {
        let launch = T3Client.LaunchThread(.init(
            projectID: "scratch", modelSelection: .init(instanceId: "codex", model: "gpt-6-astra"),
            runtimeMode: .approvalRequired, prompt: "\n  \n  First prompt\nFollow-up"
        ), projectID: "scratch")
        #expect(launch.title == "First prompt")
        #expect(launch.initialMessage.text.hasPrefix("\n  \n"))
    }

    @Test(arguments: ["setup-and-list", "normal", "approval", "denial", "cancel", "stale-approval-error"])
    func decodeAndReplayFixture(_ name: String) throws {
        let captures = try fixture(name)
        #expect(!captures.isEmpty)

        var replay = Replay()
        if name == "stale-approval-error" {
            // Seed the pending second request with the same thread and ID as the stale response.
            for capture in try fixture("denial") {
                replay.apply(capture)
                if capture.frameContainsPendingApproval { break }
            }
            #expect(replay.state.uiState == .needsApproval)
        }
        for capture in captures { replay.apply(capture) }

        switch name {
        case "setup-and-list":
            #expect(replay.state.sessions.count == 2)
            #expect(replay.state.uiState == .idle)
            #expect(replay.state.sessions.allSatisfy { $0.project == "Example workspace" })
        case "normal":
            #expect(replay.states.contains { $0.uiState == .running })
            #expect(replay.state.uiState == .done)
            #expect(replay.state.sessions.first?.diff?.files == 0)
        case "approval", "denial":
            #expect(replay.states.contains { $0.uiState == .running })
            #expect(replay.states.contains { $0.uiState == .needsApproval })
            #expect(replay.states.contains { $0.pendingApprovals.first?.command == (name == "approval" ? "echo hi" : "echo demo-denied") })
            #expect(replay.state.lastDecision == (name == "approval" ? .accepted : .declined))
            #expect(replay.state.pendingApprovals.isEmpty)
            #expect(replay.state.uiState == .done)
        case "cancel":
            #expect(replay.states.contains { $0.uiState == .running })
            #expect(replay.state.sessions.first?.status == .interrupted)
            #expect(replay.state.uiState == .idle)
        case "stale-approval-error":
            #expect(replay.staleResponses == 1)
            #expect(replay.state.pendingApprovals.isEmpty)
            #expect(replay.state.lastDecision == nil)
            #expect(replay.state.uiState == .running)
        default:
            Issue.record("Unexpected fixture")
        }
    }

    @Test func approvalShowsTheCorrelatedToolInputAboveTheProviderExplanation() throws {
        let captures = try fixture("approval") {
            $0.replacingOccurrences(of: #""prompt":"echo hi""#, with: #""prompt":"Just checking a file""#)
        }
        var replay = Replay()
        for capture in captures { replay.apply(capture) }
        let request = try #require(replay.states.lazy.flatMap(\.pendingApprovals).first { $0.context != nil })
        #expect(request.canApprove)
        #expect(request.toolName == "Shell")
        #expect(request.command == "echo hi")
        #expect(request.context == "Just checking a file")
    }

    @Test func reconnectResyncClearsCachedApprovalsAndDoesNotAnnounceHistoricalCompletions() {
        let running = SessionSummary(id: "test", title: "Task", providerInstanceId: "any provider", status: .running)
        let approval = ApprovalRequest(id: "request", threadId: running.id, sessionName: running.title,
                                       toolName: "Shell", command: "echo hi")
        var failed = running
        failed.status = .failed
        var completed = running
        completed.status = .completed
        let states = [
            .sessionUpdated(running), .sessionUpdated(failed), .approvalRequested(approval),
            .connectionChanged(.disconnected), .sessionsResynced([completed]), .connectionChanged(.connected)
        ].reduce(into: [StateSnapshot()]) { states, event in
            states.append(reduce(state: states[states.count - 1], event: event))
        }
        #expect(states.map(\.uiState) == [.idle, .running, .error, .needsApproval, .disconnected, .disconnected, .idle])
        #expect(states.last?.pendingApprovals.isEmpty == true)
        #expect(states.last?.sessions == [completed])
    }

    @Test func repositoryEnrichmentAndCheckoutBranchKeepTheShellListIntact() throws {
        let captures = try fixture("setup-and-list")
        let snapshot = try #require(captures.compactMap { capture -> T3Client.ShellSnapshot? in
            guard case .chunk(_, let items) = capture.frame,
                  case .shellSnapshot(let snapshot, _) = items.first else { return nil }
            return snapshot
        }.first)
        var projection = T3Client.Projection()
        var state = StateSnapshot()
        func apply(_ events: [AppEvent]) {
            for event in events { state = reduce(state: state, event: event) }
        }

        apply(projection.apply(.shellSnapshot(snapshot, enrichment: false)))
        let project = try #require(snapshot.projects.first)
        let enrichment = T3Client.ShellSnapshot(snapshotSequence: snapshot.snapshotSequence,
                                               projects: [project], threads: [], archivedThreads: [])
        apply(projection.apply(.shellSnapshot(enrichment, enrichment: true)))
        #expect(state.sessions.count == 2)

        let branchFrame = Data(#"{"_tag":"Chunk","requestId":"2","values":[{"refName":"main"}]}"#.utf8)
        guard case .chunk(_, let items) = try JSONDecoder().decode(T3Client.Frame.self, from: branchFrame),
              case .branch(let name) = items.first else {
            Issue.record("Expected a checkout branch update")
            return
        }
        apply(projection.updateBranch(name, at: project.workspaceRoot))
        #expect(state.sessions.allSatisfy { $0.branch == "main" })
    }

    private func fixtureLines(_ name: String, transform: (String) -> String = { $0 }) throws -> [Substring] {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let content = try String(contentsOf: root.appending(path: "fixtures/\(name).jsonl"), encoding: .utf8)
        return transform(content).split(whereSeparator: \.isNewline)
    }

    private func fixture(_ name: String, transform: (String) -> String = { $0 }) throws -> [T3Client.Capture] {
        let decoder = JSONDecoder()
        return try fixtureLines(name, transform: transform).map {
            try decoder.decode(T3Client.Capture.self, from: Data($0.utf8))
        }
    }

    private struct Replay {
        private struct RequestKey: Hashable {
            let connection: String
            let id: String
        }

        private var requests: [RequestKey: (String, T3Client.CapturedPayload)] = [:]
        private var projection = T3Client.Projection()
        var states = [StateSnapshot()]
        var staleResponses = 0
        var state: StateSnapshot { states[states.count - 1] }

        mutating func apply(_ capture: T3Client.Capture) {
            var events: [AppEvent] = []
            switch capture.frame {
            case .request(let id, let method, let payload):
                requests[RequestKey(connection: capture.connection, id: id)] = (method, payload)
            case .chunk(let id, let items):
                let request = requests[RequestKey(connection: capture.connection, id: id)]
                for item in items { events += projection.apply(item, detailThreadID: request?.1.threadId) }
            case .exit(let id, let exit):
                let request = requests.removeValue(forKey: RequestKey(connection: capture.connection, id: id))
                if request?.0 == "orchestration.getArchivedShellSnapshot", let archive = exit.value?.shell {
                    events = projection.applyArchive(archive)
                } else if let thread = request?.1.threadId, let approval = request?.1.requestId,
                          T3Client.RPCFailure(exit: exit).isStaleApproval(approval) {
                    staleResponses += 1
                    events = projection.withdrawApproval(approval, threadID: thread)
                }
            case .control:
                break
            }
            for event in events { states.append(reduce(state: state, event: event)) }
        }
    }
}

private extension T3Client.Capture {
    var frameContainsPendingApproval: Bool {
        guard case .chunk(_, let items) = frame else { return false }
        return items.contains {
            if case .detailEvent(.request(let request)) = $0 { return request.canRespond }
            return false
        }
    }
}
