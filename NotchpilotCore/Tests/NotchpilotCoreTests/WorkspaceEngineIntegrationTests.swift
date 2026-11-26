import Darwin
import Foundation
import Testing
@testable import NotchpilotCore

/// Drives the workspace menu's calls against the real engine, on a throwaway repository with a local bare
/// "remote" inside a scratch directory. A stub `code` records how the engine launched it. Opt in with
/// `NOTCHBEE_ENGINE_BINARY=/path/to/notchbee-engine swift test --filter WorkspaceEngineIntegrationTests`.
/// It never touches `~/.t3`, the app's engine data or any real repository.
@MainActor
struct WorkspaceEngineIntegrationTests {
    nonisolated private static let binary = ProcessInfo.processInfo.environment["NOTCHBEE_ENGINE_BINARY"]

    @Test(.enabled(if: binary != nil), .timeLimit(.minutes(5)))
    func branchEditorCommitPushPullAgainstAThrowawayRepository() async throws {
        let scratch = URL(filePath: try #require(realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) }))
            .appending(path: "notchbee-workspace-it-\(UUID().uuidString)")
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: scratch) }
        let home = scratch.appending(path: "home")
        let project = scratch.appending(path: "project")
        let remote = scratch.appending(path: "remote.git")
        let other = scratch.appending(path: "other")
        let tools = scratch.appending(path: "bin")
        for directory in [home, project, tools, scratch.appending(path: "tmp"), scratch.appending(path: "codex")] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "[user]\n\tname = Throwaway\n\temail = throwaway@example.invalid\n[init]\n\tdefaultBranch = main\n"
            .write(to: home.appending(path: ".gitconfig"), atomically: true, encoding: .utf8)
        let git = Git(env: Self.gitEnvironment(home: home))
        try fileManager.createDirectory(at: remote, withIntermediateDirectories: true)
        try git(remote, "init", "-q", "--bare", "-b", "main")
        try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
        try git(project, "init", "-q", "-b", "main")
        try "one\ntwo\n".write(to: project.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        try git(project, "add", "-A")
        try git(project, "commit", "-q", "-m", "Initial commit")
        try git(project, "remote", "add", "origin", remote.path)
        try git(project, "push", "-q", "-u", "origin", "main")
        try git(scratch, "clone", "-q", remote.path, other.path)
        try git(other, "checkout", "-q", "-b", "remote-only")
        try "remote\n".write(to: other.appending(path: "remote.txt"), atomically: true, encoding: .utf8)
        try git(other, "add", "-A")
        try git(other, "commit", "-q", "-m", "Remote only")
        try git(other, "push", "-q", "origin", "remote-only")
        try git(project, "fetch", "-q", "origin")

        let editorLog = scratch.appending(path: "editor-args.txt")
        let code = tools.appending(path: "code")
        try "#!/bin/sh\necho \"$@\" >> '\(editorLog.path)'\n".write(to: code, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: code.path)

        let locations = EngineLocations(support: scratch.appending(path: "support"), logs: scratch.appending(path: "logs"))
        let userdata = locations.dataDirectory.appending(path: "userdata")
        try fileManager.createDirectory(at: userdata, withIntermediateDirectories: true)
        var providers: [String: Any] = [:]
        for id in ["claudeAgent", "cursor", "grok", "opencode", "antigravity", "fx", "kiro", "muse", "pi", "codex"] {
            providers[id] = ["driver": id, "enabled": false]
        }
        try JSONSerialization.data(withJSONObject: ["enableProviderUpdateChecks": false, "providerInstances": providers])
            .write(to: userdata.appending(path: "settings.json"))

        let log = EngineLog(directory: locations.logs)
        let launcher = EngineProcessLauncher(
            executable: URL(filePath: try #require(Self.binary)), locations: locations, log: log,
            environment: ["HOME": home.path, "TMPDIR": scratch.appending(path: "tmp").path, "SHELL": "/bin/sh",
                          "PATH": "\(tools.path):/usr/bin:/bin:/usr/sbin:/sbin", "GIT_CONFIG_NOSYSTEM": "1"]
        )
        let supervisor = EngineSupervisor(launcher: launcher, probe: EngineReadinessProbe(runtimeRecord: locations.runtimeRecord))
        var endpoint: BundledEngineEndpoint?
        supervisor.onReady = { endpoint = $0 }
        supervisor.start()
        try await eventually("engine readiness", seconds: 150) { endpoint != nil }

        let client = T3Client(bundledEngine: try #require(endpoint), preferredProject: { nil })
        let state = AppState()
        let events = client.eventStream()
        let pump = Task { @MainActor in for await event in events { state.apply(event) } }
        client.start()
        try await eventually("client connection", seconds: 30) { state.panelSnapshot.connection == .connected }

        let cwd = project.path
        let report = Report()
        func note(_ line: String) { report.add(line) }
        func run(_ kind: GitActionKind, message: String? = nil) async throws -> [GitActionEvent] {
            try await Self.collect(client.runGitAction(.init(cwd: cwd, kind: kind, commitMessage: message)))
        }

        // The status call needs the connection's shell snapshot first.
        var status: WorkspaceStatus?
        for _ in 0..<100 where status == nil {
            status = try? await client.workspaceStatus(cwd: cwd)
            if status == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        let first = try #require(status, "vcs.refreshStatus never succeeded")
        note("status on main: branch=\(first.branch ?? "nil") repo=\(first.isRepository) upstream=\(first.hasUpstream) ahead=\(first.ahead) behind=\(first.behind) dirty=\(first.hasUncommittedChanges) pr=\(String(describing: first.pullRequest))")
        #expect(first.isRepository && first.branch == "main" && !first.hasUncommittedChanges)

        if ProcessInfo.processInfo.environment["NOTCHBEE_PRINT_WIRE"] != nil, let connection = client.connection {
            let status = try await connection.call("vcs.refreshStatus", T3Client.VcsCwd(cwd: cwd))
            let refs = try await connection.call("vcs.listRefs", T3Client.ListRefsPayload(cwd: cwd, query: nil, limit: 100))
            for (method, result) in [("vcs.refreshStatus", status), ("vcs.listRefs", refs)] {
                print("WIRE \(method) \(String(decoding: try JSONEncoder().encode(result?.wire), as: UTF8.self))")
            }
        }

        // Editors and "Open in VS Code".
        let editors = try await client.availableEditors()
        note("available editors: \(editors.map(\.id))")
        #expect(editors.contains(.vscode))
        try await client.openInEditor(cwd: cwd, editor: .vscode)
        for _ in 0..<40 where !fileManager.fileExists(atPath: editorLog.path) { try await Task.sleep(for: .milliseconds(50)) }
        let launched = (try? String(contentsOf: editorLog, encoding: .utf8)) ?? ""
        note("stub editor was launched with: \(launched.trimmingCharacters(in: .whitespacesAndNewlines))")
        #expect(launched.contains(cwd))

        // Branch list: local and remote.
        let page = try await client.workspaceBranches(cwd: cwd, query: "")
        note("branches: \(page.branches.map { ($0.isRemote ? "remote:" : "local:") + $0.name + ($0.isCurrent ? "*" : "") })")
        #expect(page.branches.contains { $0.name == "main" && $0.isCurrent })
        #expect(page.branches.contains { $0.isRemote && $0.shortName == "remote-only" })
        let searched = try await client.workspaceBranches(cwd: cwd, query: "remote")
        note("search 'remote': \(searched.branches.map(\.name))")
        #expect(!searched.branches.isEmpty && searched.branches.allSatisfy { $0.name.contains("remote") })

        // Uncommitted changes carry over to a new branch.
        try "one\ntwo\nthree\nfour\n".write(to: project.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        let created = try await client.createBranch(cwd: cwd, name: "feature/live")
        note("created branch: \(created)")
        let dirty = try await client.workspaceStatus(cwd: cwd)
        note("status on feature/live: branch=\(dirty.branch ?? "nil") dirty=\(dirty.hasUncommittedChanges) files=\(dirty.changedFiles) +\(dirty.insertions) -\(dirty.deletions) upstream=\(dirty.hasUpstream) comparison=\(String(describing: dirty.comparison))")
        #expect(dirty.branch == "feature/live" && dirty.hasUncommittedChanges && dirty.insertions == 2)

        // Commit with a message, then push. Pushing sets the upstream.
        let committed = try await run(.commit, message: "Add two lines")
        note("commit events: \(committed)")
        let afterCommit = try await client.workspaceStatus(cwd: cwd)
        note("after commit: dirty=\(afterCommit.hasUncommittedChanges) ahead=\(afterCommit.ahead) upstream=\(afterCommit.hasUpstream)")
        #expect(!afterCommit.hasUncommittedChanges)
        let pushed = try await run(.push)
        note("push events: \(pushed)")
        let afterPush = try await client.workspaceStatus(cwd: cwd)
        note("after push: ahead=\(afterPush.ahead) upstream=\(afterPush.hasUpstream) remote branch=\(try git(remote, "branch", "--list").replacingOccurrences(of: "\n", with: " "))")
        #expect(afterPush.hasUpstream && afterPush.ahead == 0)
        #expect(try git(remote, "branch", "--list").contains("feature/live"))

        // Commit with an empty message: the engine either writes one or reports why it cannot.
        try "one\ntwo\nthree\nfour\nfive\n".write(to: project.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        do { note("commit with an empty message: ok \(try await run(.commit, message: nil))") }
        catch { note("commit with an empty message: failed — \(error.localizedDescription)") }

        // Switching: a clean remote branch creates a tracking branch; a conflicting dirty tree is refused.
        try "dirty\n".write(to: project.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        do { try await client.switchBranch(cwd: cwd, name: "main"); note("switch to main with uncommitted changes: ok") }
        catch { note("switch to main with uncommitted changes: failed — \(error.localizedDescription)") }
        let afterDirtySwitch = try await client.workspaceStatus(cwd: cwd)
        note("branch after the dirty switch attempt: \(afterDirtySwitch.branch ?? "nil")")
        try git(project, "checkout", "-q", "--", "notes.txt")
        try await client.switchBranch(cwd: cwd, name: "origin/remote-only")
        let tracking = try await client.workspaceStatus(cwd: cwd)
        note("after switching to origin/remote-only: branch=\(tracking.branch ?? "nil") upstream=\(tracking.hasUpstream)")
        #expect(tracking.branch == "remote-only")
        try await client.switchBranch(cwd: cwd, name: "main")

        // Pull: the remote moved on from the other clone.
        try git(other, "checkout", "-q", "main")
        try "from remote\n".write(to: other.appending(path: "pulled.txt"), atomically: true, encoding: .utf8)
        try git(other, "add", "-A")
        try git(other, "commit", "-q", "-m", "Move main")
        try git(other, "push", "-q", "origin", "main")
        let pulled = try await client.pullBranch(cwd: cwd)
        note("pull: \(pulled)")
        #expect(!pulled.upToDate && fileManager.fileExists(atPath: project.appending(path: "pulled.txt").path))
        let again = try await client.pullBranch(cwd: cwd)
        note("pull again: \(again)")
        #expect(again.upToDate)

        // No hosting provider is configured on a local remote, so pull request calls can only fail cleanly.
        do { note("resolve pull request 1: ok \(try await client.resolvePullRequest(cwd: cwd, reference: "1"))") }
        catch { note("resolve pull request 1: failed — \(error.localizedDescription)") }
        do { note("create pull request: ok \(try await run(.createPullRequest))") }
        catch { note("create pull request: failed — \(error.localizedDescription)") }

        if let path = ProcessInfo.processInfo.environment["NOTCHBEE_LIVE_REPORT"] {
            try? report.lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        client.stop()
        pump.cancel()
        await supervisor.stop()
    }

    private final class Report {
        private(set) var lines: [String] = []
        func add(_ line: String) { lines.append(line); print("LIVE-SMOKE \(line)") }
    }

    private struct Git {
        let env: [String: String]

        @discardableResult
        func callAsFunction(_ directory: URL, _ arguments: String...) throws -> String {
            try WorkspaceEngineIntegrationTests.git(directory, arguments, env: env)
        }
    }

    private static func gitEnvironment(home: URL) -> [String: String] {
        ["HOME": home.path, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1"]
    }

    @discardableResult
    nonisolated private static func git(_ directory: URL, _ arguments: [String], env: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.environment = env
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static func collect(_ stream: AsyncThrowingStream<GitActionEvent, Error>) async throws -> [GitActionEvent] {
        var events: [GitActionEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    private func eventually(_ name: String, seconds: Double, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        try #require(condition(), "Timed out waiting for \(name)")
    }
}
