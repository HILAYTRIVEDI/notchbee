import Foundation
import Testing
@testable import NotchpilotCore

private final class FakeEngine: EngineProcess, @unchecked Sendable {
    let pid: Int32
    private let lock = NSLock()
    private var exit: EngineExit?
    private var waiters: [CheckedContinuation<EngineExit, Never>] = []
    private(set) var terminated = false

    init(pid: Int32) { self.pid = pid }

    var isRunning: Bool { lock.withLock { exit == nil } }
    func terminate() { terminated = true; finish(EngineExit(code: 130)) }
    func forceKill() { finish(EngineExit(code: 137, signaled: true)) }

    func finish(_ value: EngineExit) {
        let pending: [CheckedContinuation<EngineExit, Never>] = lock.withLock {
            guard exit == nil else { return [] }
            exit = value
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume(returning: value) }
    }

    func waitForExit() async -> EngineExit {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let exit {
                lock.unlock()
                continuation.resume(returning: exit)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

private final class FakeLauncher: EngineLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var secrets: [String] = []
    private(set) var engines: [FakeEngine] = []

    func launch(secret: String) throws -> any EngineProcess {
        lock.withLock {
            secrets.append(secret)
            let engine = FakeEngine(pid: Int32(1000 + engines.count))
            engines.append(engine)
            return engine
        }
    }

    var latest: FakeEngine? { lock.withLock { engines.last } }
    var count: Int { lock.withLock { engines.count } }
}

private struct FakeProbe: EngineReadinessProbing {
    func probe(pid: Int32, secret: String) async -> BundledEngineEndpoint? {
        let record = Data(#"{"origin":"http://127.0.0.1:5000","pid":\#(pid),"port":5000}"#.utf8)
        return BundledEngineEndpoint(runtimeRecord: record, childPID: pid, bootstrapToken: secret)
    }
}

@MainActor
private func wait(for condition: @MainActor () -> Bool) async throws {
    for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
    try #require(condition())
}

@MainActor
struct EngineSupervisorTests {
    @Test func backoffDoublesAndCaps() {
        let backoff = EngineBackoff()
        #expect([1, 2, 3, 4, 5, 6, 7].map(backoff.delay(afterFailures:)) == [1, 2, 4, 8, 16, 30, 30])
        #expect(backoff.delay(afterFailures: 0) == 0)
    }

    @Test func restartsAfterACrashWithAFreshSecret() async throws {
        let launcher = FakeLauncher()
        let supervisor = EngineSupervisor(launcher: launcher, probe: FakeProbe(), sleep: { _ in })
        var statuses: [EngineStatus] = []
        var ready = 0
        var lost = 0
        supervisor.onStatus = { statuses.append($0) }
        supervisor.onReady = { _ in ready += 1 }
        supervisor.onLost = { lost += 1 }
        supervisor.start()
        try await wait { ready == 1 }
        launcher.latest?.finish(EngineExit(code: 1))
        try await wait { ready == 2 }
        #expect(lost == 1)
        #expect(Set(launcher.secrets).count == 2)
        #expect(launcher.secrets.allSatisfy { $0.count == 64 })
        #expect(statuses == [.starting, .running, .restarting(attempt: 1), .running])
        await supervisor.stop()
        #expect(supervisor.status == .stopped)
        #expect(launcher.latest?.terminated == true)
    }

    @Test(arguments: [(Int32(77), "policy"), (Int32(78), "data folder")])
    func fatalExitsAreNotRetried(code: Int32, fragment: String) async throws {
        let launcher = FakeLauncher()
        let supervisor = EngineSupervisor(launcher: launcher, probe: FakeProbe(), sleep: { _ in })
        supervisor.start()
        try await wait { launcher.latest != nil }
        launcher.latest?.finish(EngineExit(code: code))
        try await wait { if case .failed = supervisor.status { true } else { false } }
        guard case .failed(let message) = supervisor.status else { return }
        #expect(message.contains(fragment))
        #expect(launcher.count == 1)
    }

    @Test func givesUpAfterRepeatedCrashesAndRetryStartsAgain() async throws {
        let launcher = FakeLauncher()
        let supervisor = EngineSupervisor(
            launcher: launcher, probe: FakeProbe(), backoff: EngineBackoff(maxFailures: 2), sleep: { _ in }
        )
        supervisor.start()
        for index in 1...3 {
            try await wait { launcher.count == index }
            launcher.latest?.finish(EngineExit(code: 1))
        }
        try await wait { if case .failed = supervisor.status { true } else { false } }
        #expect(launcher.count == 3)
        supervisor.retry()
        try await wait { launcher.count == 4 }
        await supervisor.stop()
    }

    @Test func stopImmediatelyTerminatesTheChild() async throws {
        let launcher = FakeLauncher()
        let supervisor = EngineSupervisor(launcher: launcher, probe: FakeProbe(), sleep: { _ in })
        var ready = false
        supervisor.onReady = { _ in ready = true }
        supervisor.start()
        try await wait { ready }
        supervisor.stopImmediately()
        #expect(launcher.latest?.isRunning == false)
        #expect(supervisor.status == .stopped)
    }

    @Test func bootstrapSecretTravelsOnlyThroughStandardInput() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "engine-launch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appending(path: "notchbee-engine")
        let capture = directory.appending(path: "capture.txt")
        try """
        #!/bin/sh
        { echo "ARGS: $*"; env | grep -c SECRETVALUE; env | grep -c ENGINE_FILTER_TEST; echo "DO_NOT_TRACK: $DO_NOT_TRACK"; read line; echo "STDIN: $line"; } > "\(capture.path)"
        sleep 30
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let locations = EngineLocations(support: directory.appending(path: "support"), logs: directory.appending(path: "logs"))
        let launcher = EngineProcessLauncher(
            executable: script, locations: locations, log: EngineLog(directory: locations.logs),
            environment: [
                "T3CODE_TELEMETRY_ENABLED": "ENGINE_FILTER_TEST",
                "NOTCHBEE_ENGINE_PORT": "ENGINE_FILTER_TEST",
                "OTEL_EXPORTER_OTLP_ENDPOINT": "ENGINE_FILTER_TEST",
            ]
        )
        let process = try launcher.launch(secret: "SECRETVALUE" + String(repeating: "a", count: 40))
        defer { process.forceKill() }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: capture.path) || ((try? String(contentsOf: capture))?.contains("STDIN") != true) {
            try await Task.sleep(for: .milliseconds(25))
        }
        let text = try String(contentsOf: capture, encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(!lines[0].contains("SECRETVALUE"))
        #expect(lines[0].contains("--bootstrap-fd 0") && lines[0].contains("--port 0"))
        #expect(lines[1] == "0")
        #expect(lines[2] == "0")
        #expect(lines[3] == "DO_NOT_TRACK: 1")
        #expect(lines[4].contains("SECRETVALUE") && lines[4].contains("desktopBootstrapToken"))
        #expect(!(try String(contentsOf: locations.logs.appending(path: "engine.log"), encoding: .utf8)).contains("SECRETVALUE"))
    }

    @Test func pidFileReapsOnlyTheEngineExecutable() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "engine-pid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func spawn(named name: String) throws -> Process {
            let copy = directory.appending(path: name)
            try FileManager.default.copyItem(at: URL(filePath: "/bin/sleep"), to: copy)
            let process = Process()
            process.executableURL = copy
            process.arguments = ["60"]
            try process.run()
            return process
        }
        let engine = try spawn(named: "notchbee-engine")
        let other = try spawn(named: "other-tool")
        defer { engine.terminate(); other.terminate() }
        let pidFile = EnginePidFile(url: directory.appending(path: "engine.pid"))

        pidFile.write(pid: other.processIdentifier)
        #expect(!pidFile.reapStaleEngine(grace: 0.2))
        #expect(other.isRunning)

        pidFile.write(pid: engine.processIdentifier)
        #expect(pidFile.reapStaleEngine(grace: 2))
        engine.waitUntilExit()
        #expect(!engine.isRunning)
        #expect(!FileManager.default.fileExists(atPath: pidFile.url.path))
    }

    @Test func logRotatesAndRedactsSecrets() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "engine-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = EngineLog(directory: directory, maxBytes: 100, keep: 2)
        log.redact("topsecret")
        for _ in 0..<12 { log.append(Data("line with topsecret value 0123456789\n".utf8)) }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(names == ["engine.1.log", "engine.2.log", "engine.log"])
        for name in names {
            let text = try String(contentsOf: directory.appending(path: name), encoding: .utf8)
            #expect(!text.contains("topsecret") && text.contains("[redacted]"))
        }
    }

    @Test func bundledEndpointRequiresMatchingPidAndStrongSecret() {
        let record = Data(#"{"origin":"http://127.0.0.1:5000","pid":42,"port":5000}"#.utf8)
        let secret = String(repeating: "a", count: 64)
        #expect(BundledEngineEndpoint(runtimeRecord: record, childPID: 42, bootstrapToken: secret) != nil)
        #expect(BundledEngineEndpoint(runtimeRecord: record, childPID: 43, bootstrapToken: secret) == nil)
        #expect(BundledEngineEndpoint(runtimeRecord: record, childPID: 42, bootstrapToken: "short") == nil)
        let remote = Data(#"{"origin":"http://example.com:5000","pid":42,"port":5000}"#.utf8)
        #expect(BundledEngineEndpoint(runtimeRecord: remote, childPID: 42, bootstrapToken: secret) == nil)
    }
}
