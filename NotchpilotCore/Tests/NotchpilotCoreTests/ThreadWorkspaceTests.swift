import Foundation
import Observation
import Testing
@testable import NotchpilotCore

struct ThreadWorkspaceTests {
    @MainActor
    @Test func streamingUpdatesKeepPanelStateAndConversationOrder() {
        let model = AppState()
        model.apply(.openThread("scratch"))
        model.apply(.conversationSnapshot(sessionID: "scratch", entries: []))
        withObservationTracking {
            _ = model.panelSnapshot
        } onChange: {
            Issue.record("A conversation entry invalidated panel state")
        }
        let later = ConversationEntry(id: "later", kind: .assistant, text: "Hello", timestamp: "02")
        let earlier = ConversationEntry(id: "earlier", kind: .activity, text: "Started", timestamp: "01")
        model.apply(.conversationEntry(sessionID: "scratch", entry: later))
        model.apply(.conversationEntry(sessionID: "scratch", entry: earlier))
        #expect(model.snapshot.conversation?.entries == [earlier, later])

        let moved = ConversationEntry(id: earlier.id, kind: .activity, text: "Finished", timestamp: "03")
        model.apply(.conversationEntry(sessionID: "scratch", entry: moved))
        #expect(model.snapshot.conversation?.entries == [later, moved])
    }

    @Test func selectedThreadKeepsItsTimelineAndUpsertsStreamingEntries() {
        let partial = ConversationEntry(id: "message:1", kind: .assistant, text: "Hel",
                                        timestamp: "2026-01-01T10:00:01Z", streaming: true)
        let prompt = ConversationEntry(id: "message:0", kind: .user, text: "Say hello",
                                       timestamp: "2026-01-01T10:00:00Z")
        let complete = ConversationEntry(id: partial.id, kind: .assistant, text: "Hello", timestamp: partial.timestamp)
        let approval = ApprovalRequest(id: "request", threadId: "scratch", sessionName: "Scratch",
                                       toolName: "Shell", command: "echo hello")
        let state = [
            .openThread("scratch"),
            .conversationSnapshot(sessionID: "scratch", entries: [partial, prompt]),
            .conversationEntry(sessionID: "other", entry: prompt),
            .conversationEntry(sessionID: "scratch", entry: complete),
            .approvalRequested(approval),
            .hoverChanged(false)
        ].reduce(StateSnapshot()) { reduce(state: $0, event: $1) }
        #expect(state.panelTab == .thread)
        #expect(state.sizeState == .large)
        #expect(state.conversation?.entries == [prompt, complete])
        #expect(state.pendingApprovals == [approval])

        let removed = reduce(state: state, event: .sessionRemoved(sessionId: "scratch"))
        #expect(removed.panelTab == .sessions)
        #expect(removed.conversation == nil)
        #expect(removed.pendingApprovals.isEmpty)
        let collapsed = reduce(state: state, event: .collapsePanel)
        #expect(collapsed.sizeState == .compact)
        #expect(collapsed.openThreadID == nil)
        #expect(reduce(state: collapsed, event: .hoverChanged(true)).sizeState == .medium)
    }

    @Test func decodesProviderCatalogDefaultsAndExcludesDisabledInstances() throws {
        let config = Data(#"""
        {"_tag":"Exit","requestId":"1","exit":{"_tag":"Success","value":{"providers":[
          {"instanceId":"custom-codex","driver":"codex","displayName":"Work Codex","installed":true,"enabled":true,"status":"ready","supportsTextGeneration":false,
           "supportedRuntimeModes":["approval-required","full-access","future-mode"],
           "models":[{"slug":"alternate","name":"Alternate"},{"name":"Missing slug"},{"slug":"default","name":"Default","isDefault":true}]},
          {"instanceId":"legacy"},
          {"instanceId":"open","driver":"opencode","installed":true,"enabled":true,"status":"ready",
           "supportedRuntimeModes":[],"models":[{"slug":"open/model","name":"Open Model"}]},
          {"instanceId":"disabled","driver":"codex","enabled":false,"installed":true,"status":"ready",
           "models":[{"slug":"default","name":"Default"}]},
          {"instanceId":"hidden","driver":"codex","enabled":true,"installed":true,"status":"warning","availability":"unavailable",
           "models":[{"slug":"hidden","name":"Hidden"}]}
        ],"settings":{"defaultRuntimeMode":"full-access",
            "defaultModelSelection":{"instanceId":"custom-codex","model":"alternate","options":[{"id":"fast","value":true}]},
            "projectSettingsOverrides":{"scratch":{"defaultRuntimeMode":"approval-required",
              "defaultModelSelection":{"instanceId":"custom-codex","model":"default","options":{"effort":"medium"}}}}
        }}}}
        """#.utf8)
        guard case .exit(_, let exit) = try JSONDecoder().decode(T3Client.Frame.self, from: config) else {
            Issue.record("Expected a config result")
            return
        }
        let configValue = try #require(exit.value)
        let catalog = configValue.providerCatalog(project: nil)
        #expect(configValue.providers?.skipped == 1)
        #expect(configValue.providers?.elements.first?.models.skipped == 1)
        #expect(catalog.providers.map(\.id) == ["custom-codex", "open"])
        #expect(catalog.providers.first?.models.map(\.id) == ["default", "alternate"])
        #expect(catalog.providers.first?.runtimeModes == [.approvalRequired, .fullAccess])
        #expect(catalog.providers.last?.runtimeModes == ThreadRuntimeMode.allCases)
        #expect(catalog.defaultSelection?.model == "alternate")
        #expect(catalog.defaultSelection?.options?.first?.value == .toggle(true))
        #expect(catalog.defaultRuntimeMode == .fullAccess)

        let project = try JSONDecoder().decode(T3Client.Project.self,
            from: Data(#"{"id":"scratch","title":"Scratch","workspaceRoot":"/tmp/scratch"}"#.utf8))
        let projectCatalog = configValue.providerCatalog(project: project)
        #expect(projectCatalog.defaultSelection?.model == "default")
        #expect(projectCatalog.defaultSelection?.options?.first?.value == .choice("medium"))
        #expect(projectCatalog.defaultRuntimeMode == .approvalRequired)
    }

    @MainActor
    @Test func registersScratchOnceAndReusesTheProjectByWorkspacePath() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let folder = temporaryDirectory.appending(path: "Notchpilot Scratch")
        let scratch = T3Client.ScratchProject(folder: folder)
        var registrations: [T3Client.ScratchProject.Registration] = []
        var projects: [T3Client.Project] = []

        @MainActor
        func resolve() async throws -> String {
            try await scratch.resolve(projects: { projects }) { command in
                registrations.append(command)
                await Task.yield()
            }
        }

        let first = Task { try await resolve() }
        let second = Task { try await resolve() }
        let (firstID, secondID) = try await (first.value, second.value)
        let command = try #require(registrations.first)
        #expect(firstID == command.projectId)
        #expect(secondID == firstID)
        #expect(try await resolve() == firstID)
        #expect(registrations.count == 1)
        #expect(command.type == "project.create")
        #expect(command.workspaceRoot == folder.resolvingSymlinksInPath().path)
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        #expect(attributes[.posixPermissions] as? Int == 0o700)

        let existing = try JSONSerialization.data(withJSONObject: [
            "id": firstID, "title": "Renamed scratch", "workspaceRoot": command.workspaceRoot + "/."
        ])
        projects = [try JSONDecoder().decode(T3Client.Project.self, from: existing)]
        let freshResolver = T3Client.ScratchProject(folder: folder)
        let reused = try await freshResolver.resolve(projects: { projects }) { _ in
            Issue.record("An existing workspace was registered again")
        }
        #expect(reused == firstID)
    }

    @Test func decodesAStreamingMessageUpdate() throws {
        let data = Data(#"""
        {"kind":"event","sequence":12,"event":{"type":"message.updated","payload":{
          "id":"scratch-message","role":"assistant","text":"Growing response","streaming":true,"createdAt":"2026-01-01T10:00:00Z"
        }}}
        """#.utf8)
        guard case .detailEvent(.message(let message)) = try JSONDecoder().decode(T3Client.StreamItem.self, from: data) else {
            Issue.record("Expected a streaming message")
            return
        }
        #expect(message.entry.kind == .assistant)
        #expect(message.entry.streaming)
        #expect(message.entry.text == "Growing response")
    }

    @Test func sessionListLeavesOutSubagentAndSideChatThreads() throws {
        func shell(_ id: String, lineage: String) -> String {
            #"{"id":"\#(id)","title":"\#(id)","projectId":"p","providerInstanceId":"claude","updatedAt":"2026-01-01T10:00:00Z","status":"idle","lineage":\#(lineage)}"#
        }
        let data = Data(#"""
        {"kind":"snapshot","snapshot":{"snapshotSequence":1,"projects":[],"threads":[
          \#(shell("main", lineage: #"{"parentThreadId":null,"relationshipToParent":null,"rootThreadId":"main"}"#)),
          \#(shell("fork", lineage: #"{"parentThreadId":"main","relationshipToParent":"fork","rootThreadId":"main"}"#)),
          \#(shell("child", lineage: #"{"parentThreadId":"main","relationshipToParent":"subagent","rootThreadId":"main"}"#)),
          \#(shell("side", lineage: #"{"parentThreadId":"main","relationshipToParent":null,"rootThreadId":"main","sideChat":true}"#))
        ]}}
        """#.utf8)
        let item = try JSONDecoder().decode(T3Client.StreamItem.self, from: data)
        var projection = T3Client.Projection()
        var state = StateSnapshot()
        for event in projection.apply(item) { state = reduce(state: state, event: event) }
        #expect(Set(state.sessions.map(\.id)) == ["main", "fork"])
    }

    @Test func activeRemovalKeepsAnArchivedThreadOpenAndClearsADeletedThread() throws {
        let fixture = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "fixtures/setup-and-list.jsonl")
        let captures = try String(contentsOf: fixture, encoding: .utf8).split(whereSeparator: \.isNewline)
            .map { try JSONDecoder().decode(T3Client.Capture.self, from: Data($0.utf8)) }
        let shell = try #require(captures.lazy.compactMap { capture -> T3Client.ShellSnapshot? in
            guard case .chunk(_, let items) = capture.frame,
                  case .shellSnapshot(let snapshot, _) = items.first else { return nil }
            return snapshot
        }.first)
        let thread = try #require(shell.threads.first)
        let id = thread.thread.id
        let moveSequence = shell.snapshotSequence + 1
        var projection = T3Client.Projection()
        var state = StateSnapshot()
        func apply(_ events: [AppEvent]) {
            for event in events { state = reduce(state: state, event: event) }
        }

        apply(projection.apply(.shellSnapshot(shell, enrichment: false)))
        apply([.openThread(id)])
        apply(projection.apply(.threadRemoved(id, archived: false, sequence: moveSequence)))
        #expect(projection.needsArchiveRefresh)
        #expect(state.openThreadID == id)

        apply(projection.applyArchive(.init(snapshotSequence: shell.snapshotSequence, projects: [],
                                            threads: [], archivedThreads: nil)))
        #expect(projection.needsArchiveRefresh)
        #expect(state.openThreadID == id)

        apply(projection.applyArchive(.init(snapshotSequence: moveSequence, projects: [],
                                            threads: [thread], archivedThreads: nil)))
        #expect(!projection.needsArchiveRefresh)
        #expect(state.openThreadID == id)
        #expect(state.sessions.first(where: { $0.id == id })?.isArchived == true)

        apply(projection.apply(.threadRemoved(id, archived: false, sequence: moveSequence + 1)))
        apply(projection.applyArchive(.init(snapshotSequence: moveSequence + 1, projects: [],
                                            threads: [], archivedThreads: nil)))
        #expect(state.openThreadID == nil)
        #expect(!state.sessions.contains { $0.id == id })
    }

    @Test(arguments: ["approval", "cancel"])
    func projectsMessagesAndToolUpdatesFromRecordedThreadStream(name: String) throws {
        let fixture = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "fixtures/\(name).jsonl")
        let lines = try String(contentsOf: fixture, encoding: .utf8).split(whereSeparator: \.isNewline)
        let captures = try lines.map { try JSONDecoder().decode(T3Client.Capture.self, from: Data($0.utf8)) }
        var projection = T3Client.Projection()
        var threadID: String?
        var conversation = StateSnapshot()
        var streamedIDs = Set<String>()
        for capture in captures {
            guard case .chunk(_, let items) = capture.frame else { continue }
            for item in items {
                if case .detailSnapshot(let snapshot) = item {
                    threadID = snapshot.thread.id
                    conversation = reduce(state: conversation, event: .openThread(snapshot.thread.id))
                }
                for event in projection.apply(item, detailThreadID: threadID) {
                    if case .conversationEntry(_, let entry) = event, entry.kind == .assistant, entry.streaming {
                        streamedIDs.insert(entry.id)
                    }
                    conversation = reduce(state: conversation, event: event)
                }
            }
        }
        let entries = try #require(conversation.conversation).entries
        #expect(entries.contains { $0.kind == .user && !$0.text.isEmpty })
        #expect(entries.contains { $0.kind == .assistant && !$0.text.isEmpty && !$0.streaming })
        if name == "approval" {
            #expect(entries.contains { $0.kind == .tool && $0.text.contains("echo hi") })
        } else {
            #expect(streamedIDs.count == 1)
            #expect(entries.filter { streamedIDs.contains($0.id) }.count == 1)
            #expect(entries.filter { streamedIDs.contains($0.id) }.allSatisfy { !$0.streaming })
        }
        #expect(Set(entries.map(\.id)).count == entries.count)
    }
}
