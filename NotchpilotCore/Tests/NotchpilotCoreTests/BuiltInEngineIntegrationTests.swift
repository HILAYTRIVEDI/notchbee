import Darwin
import Foundation
import Testing
@testable import NotchpilotCore

/// Runs the real engine binary in a scratch directory with a fake Codex. Opt in with
/// `NOTCHBEE_ENGINE_BINARY=/path/to/notchbee-engine NOTCHBEE_BUN=$(which bun) swift test --filter BuiltInEngineIntegrationTests`.
/// It never touches `~/.t3` or the app's real engine data.
@MainActor
struct BuiltInEngineIntegrationTests {
    nonisolated private static let binary = ProcessInfo.processInfo.environment["NOTCHBEE_ENGINE_BINARY"]

    @Test(.enabled(if: binary != nil), .timeLimit(.minutes(5)))
    func scratchThreadStreamsStopsAndResolves() async throws {
        let scratch = URL(filePath: try #require(realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) }))
            .appending(path: "notchbee-engine-it-\(UUID().uuidString)")
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: scratch) }
        let home = scratch.appending(path: "home")
        let project = scratch.appending(path: "project")
        let tools = scratch.appending(path: "bin")
        let codexHome = scratch.appending(path: "codex")
        for directory in [home, project, tools, codexHome, scratch.appending(path: "tmp")] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let git = Process()
        git.executableURL = URL(filePath: "/usr/bin/git")
        git.arguments = ["init", "-q", project.path]
        git.environment = ["HOME": home.path]
        try git.run()
        git.waitUntilExit()

        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = repository.appending(path: "engine/tests/codex-fixture.ts")
        let bun = ProcessInfo.processInfo.environment["NOTCHBEE_BUN"] ?? "/opt/homebrew/bin/bun"
        let codex = tools.appending(path: "codex")
        try "#!/bin/sh\nexec '\(bun)' '\(fixture.path)' \"$@\"\n".write(to: codex, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)

        let locations = EngineLocations(support: scratch.appending(path: "support"), logs: scratch.appending(path: "logs"))
        let userdata = locations.dataDirectory.appending(path: "userdata")
        try fileManager.createDirectory(at: userdata, withIntermediateDirectories: true)
        var providers: [String: Any] = [:]
        for id in ["claudeAgent", "cursor", "grok", "opencode", "antigravity", "fx", "kiro", "muse", "pi"] {
            providers[id] = ["driver": id, "enabled": false]
        }
        providers["codex"] = ["driver": "codex", "config": ["setupMode": "existing", "binaryPath": codex.path, "homePath": codexHome.path]]
        try JSONSerialization.data(withJSONObject: ["enableProviderUpdateChecks": false, "providerInstances": providers])
            .write(to: userdata.appending(path: "settings.json"))

        let log = EngineLog(directory: locations.logs)
        let launcher = EngineProcessLauncher(
            executable: URL(filePath: try #require(Self.binary)), locations: locations, log: log,
            environment: ["HOME": home.path, "TMPDIR": scratch.appending(path: "tmp").path, "CODEX_HOME": codexHome.path,
                          "SHELL": "/bin/sh", "PATH": "\(tools.path):/usr/bin:/bin:/usr/sbin:/sbin"]
        )
        let supervisor = EngineSupervisor(launcher: launcher, probe: EngineReadinessProbe(runtimeRecord: locations.runtimeRecord))
        var endpoint: BundledEngineEndpoint?
        supervisor.onReady = { endpoint = $0 }
        supervisor.start()
        try await eventually("engine readiness", seconds: 150) { endpoint != nil }
        let enginePID = try #require(endpoint?.pid)

        let client = T3Client(bundledEngine: try #require(endpoint), preferredProject: { nil })
        let state = AppState()
        var texts: [String] = []
        let events = client.eventStream()
        let pump = Task { @MainActor in
            for await event in events {
                state.apply(event)
                switch event {
                case .conversationSnapshot(_, let entries): texts += entries.map(\.text)
                case .conversationEntry(_, let entry): texts.append(entry.text)
                default: break
                }
            }
        }
        client.start()
        try await eventually("client connection", seconds: 30) { state.panelSnapshot.connection == .connected }

        // The shell snapshot can land just after the connected event.
        var added = false
        for _ in 0..<200 where !added {
            do { try await client.addProject(folder: project); added = true } catch { try await Task.sleep(for: .milliseconds(50)) }
        }
        try #require(added, "Timed out adding the scratch project")
        try await eventually("project", seconds: 15) { !state.panelSnapshot.projects.isEmpty }
        let projectID = try #require(state.panelSnapshot.projects.first?.id)
        let threadID = try await client.launchThread(ThreadLaunch(
            projectID: projectID, modelSelection: ThreadModelSelection(instanceId: "codex", model: "gpt-6-luna"),
            runtimeMode: .approvalRequired, prompt: "Reply with a short message.", title: "Scratch"
        ))
        client.setSessionDetailsVisible(true, sessionId: threadID)
        try await eventually("streamed reply", seconds: 30) { texts.contains { $0.contains("Isolated smoke stream.") } }

        try await client.mutateThread(sessionID: threadID, mutation: .stop)
        try await eventually("stopped turn", seconds: 30) {
            state.panelSnapshot.sessions.first { $0.id == threadID }?.status == .interrupted
        }

        // Mid-conversation model switch: the engine records it and the session summary follows.
        #expect(state.panelSnapshot.sessions.first { $0.id == threadID }?.modelSelection?.model == "gpt-6-luna")
        // The fixture's model list is empty, so pick a fixed second slug rather than reading the catalog.
        let target = "gpt-6-luna-mini"
        try await client.mutateThread(sessionID: threadID,
                                      mutation: .setModel(ThreadModelSelection(instanceId: "codex", model: target)))
        try await eventually("switched model", seconds: 30) {
            state.panelSnapshot.sessions.first { $0.id == threadID }?.modelSelection?.model == target
        }

        try await client.mutateThread(sessionID: threadID, mutation: .resolve(true))
        try await eventually("resolved thread", seconds: 30) {
            state.panelSnapshot.sessions.first { $0.id == threadID }?.isSettled == true
        }

        client.stop()
        pump.cancel()
        await supervisor.stop()
        #expect(kill(enginePID, 0) == -1 && errno == ESRCH)
        let logText = (try? String(contentsOf: log.currentFile, encoding: .utf8)) ?? ""
        #expect(!logText.isEmpty)
    }

    private func eventually(_ name: String, seconds: Double, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        try #require(condition(), "Timed out waiting for \(name)")
    }
}
