import Foundation
#if os(macOS)
import Darwin
#endif

// MARK: - Status and policy

public enum EngineStatus: Sendable, Equatable {
    case stopped
    case starting
    case running
    case restarting(attempt: Int)
    case failed(String)
}

public struct EngineExit: Sendable, Equatable {
    public let code: Int32
    public let signaled: Bool

    public init(code: Int32, signaled: Bool = false) {
        self.code = code
        self.signaled = signaled
    }

    /// Exit 77 means a managed policy refused startup. Exit 78 means another process owns the data directory.
    /// Retrying cannot fix either.
    var fatalReason: String? {
        guard !signaled else { return nil }
        switch code {
        case 77: return "A managed policy refused to start the engine."
        case 78: return "Another process is using the engine’s data folder."
        default: return nil
        }
    }
}

public struct EngineBackoff: Sendable, Equatable {
    public var initial: TimeInterval
    public var maximum: TimeInterval
    /// A run at least this long resets the failure count.
    public var stableAfter: TimeInterval
    /// Consecutive unstable runs before the supervisor stops and shows "failed".
    public var maxFailures: Int

    public init(initial: TimeInterval = 1, maximum: TimeInterval = 30, stableAfter: TimeInterval = 60, maxFailures: Int = 5) {
        self.initial = initial
        self.maximum = maximum
        self.stableAfter = stableAfter
        self.maxFailures = maxFailures
    }

    public func delay(afterFailures count: Int) -> TimeInterval {
        guard count > 0 else { return 0 }
        return min(maximum, initial * pow(2, Double(min(count, 30) - 1)))
    }
}

// MARK: - Seams

public protocol EngineProcess: AnyObject, Sendable {
    var pid: Int32 { get }
    var isRunning: Bool { get }
    /// SIGTERM.
    func terminate()
    /// SIGKILL.
    func forceKill()
    func waitForExit() async -> EngineExit
}

public protocol EngineLaunching: Sendable {
    /// Starts the engine and delivers `secret` through the inherited bootstrap descriptor, never argv or environment.
    func launch(secret: String) throws -> any EngineProcess
}

public protocol EngineReadinessProbing: Sendable {
    /// One non-blocking check. Returns a verified endpoint only when `pid` owns a listening, responding engine.
    func probe(pid: Int32, secret: String) async -> BundledEngineEndpoint?
}

// MARK: - Supervisor

@MainActor
public final class EngineSupervisor {
    public var onStatus: (@MainActor (EngineStatus) -> Void)?
    public var onReady: (@MainActor (BundledEngineEndpoint) -> Void)?
    public var onLost: (@MainActor () -> Void)?
    public private(set) var status: EngineStatus = .stopped

    private let launcher: any EngineLaunching
    private let probe: any EngineReadinessProbing
    private let backoff: EngineBackoff
    private let startupTimeout: TimeInterval
    private let pidFile: EnginePidFile?
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var task: Task<Void, Never>?
    private var current: (any EngineProcess)?

    public init(
        launcher: any EngineLaunching,
        probe: any EngineReadinessProbing,
        backoff: EngineBackoff = EngineBackoff(),
        startupTimeout: TimeInterval = 120,
        pidFile: EnginePidFile? = nil,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.launcher = launcher
        self.probe = probe
        self.backoff = backoff
        self.startupTimeout = startupTimeout
        self.pidFile = pidFile
        self.sleep = sleep
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    /// Restarts after a failure or after the supervisor was stopped.
    public func retry() {
        guard task == nil else { return }
        start()
    }

    public func stop() async {
        let running = task
        task = nil
        running?.cancel()
        let process = current
        current = nil
        if let process { await Self.shutDown(process) }
        await running?.value
        pidFile?.clear(ifPid: process?.pid)
        set(.stopped)
    }

    /// Synchronous variant for application quit. Blocks for at most `grace` seconds.
    public func stopImmediately(grace: TimeInterval = 3) {
        task?.cancel()
        task = nil
        guard let process = current else { set(.stopped); return }
        current = nil
        process.terminate()
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < deadline { usleep(25_000) }
        if process.isRunning {
            process.forceKill()
            let kill = Date().addingTimeInterval(1)
            while process.isRunning, Date() < kill { usleep(10_000) }
        }
        pidFile?.clear(ifPid: process.pid)
        set(.stopped)
    }

    private func set(_ status: EngineStatus) {
        guard self.status != status else { return }
        self.status = status
        onStatus?(status)
    }

    private static func shutDown(_ process: any EngineProcess, grace: TimeInterval = 5) async {
        process.terminate()
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < deadline { try? await Task.sleep(for: .milliseconds(25)) }
        if process.isRunning { process.forceKill() }
        _ = await process.waitForExit()
    }

    private func run() async {
        pidFile?.reapStaleEngine()
        var failures = 0
        while !Task.isCancelled {
            set(failures == 0 ? .starting : .restarting(attempt: failures))
            let secret = EngineSecret.generate()
            let process: any EngineProcess
            do {
                process = try launcher.launch(secret: secret)
            } catch {
                finish(failed: "The engine could not be launched: \(error.localizedDescription)")
                return
            }
            current = process
            pidFile?.write(pid: process.pid)
            let startedAt = Date()

            let endpoint = await waitUntilReady(process, secret: secret)
            var reachedRunning = false
            if let endpoint, !Task.isCancelled {
                reachedRunning = true
                set(.running)
                onReady?(endpoint)
            } else if process.isRunning {
                await Self.shutDown(process)
            }
            let exit = await process.waitForExit()
            if reachedRunning { onLost?() }
            guard !Task.isCancelled else { return }
            current = nil
            pidFile?.clear(ifPid: process.pid)

            if let reason = exit.fatalReason {
                finish(failed: reason)
                return
            }
            failures = Date().timeIntervalSince(startedAt) >= backoff.stableAfter ? 1 : failures + 1
            if failures > backoff.maxFailures {
                finish(failed: "The engine stopped unexpectedly \(backoff.maxFailures) times in a row.")
                return
            }
            set(.restarting(attempt: failures))
            do {
                try await sleep(backoff.delay(afterFailures: failures))
            } catch {
                return
            }
        }
    }

    private func finish(failed message: String) {
        task = nil
        current = nil
        set(.failed(message))
    }

    /// Startup only: a bounded poll while the engine runs migrations and binds its port.
    private func waitUntilReady(_ process: any EngineProcess, secret: String) async -> BundledEngineEndpoint? {
        let deadline = Date().addingTimeInterval(startupTimeout)
        var interval: TimeInterval = 0.05
        while !Task.isCancelled, process.isRunning, Date() < deadline {
            if let endpoint = await probe.probe(pid: process.pid, secret: secret) { return endpoint }
            try? await sleep(interval)
            interval = min(interval * 1.5, 0.5)
        }
        return nil
    }
}

// MARK: - Secret

public enum EngineSecret {
    /// 32 random bytes as hex. Held in memory only for one engine launch.
    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Secure random bytes are unavailable")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Pidfile

/// Backstop for a force-quit app: the engine watches its launcher, and the next launch reaps a survivor.
public struct EnginePidFile: Sendable {
    public let url: URL
    public let executableName: String

    public init(url: URL, executableName: String = "notchbee-engine") {
        self.url = url
        self.executableName = executableName
    }

    func write(pid: Int32) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("\(pid)\n".utf8).write(to: url, options: .atomic)
    }

    func clear(ifPid pid: Int32?) {
        guard let pid, recordedPid == pid else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private var recordedPid: Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Terminates a leftover engine from a previous run, but only if the pid still names our executable.
    @discardableResult
    public func reapStaleEngine(grace: TimeInterval = 3) -> Bool {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let pid = recordedPid, pid > 1, pid != getpid(), isEngine(pid) else { return false }
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(grace)
        while isEngine(pid), Date() < deadline { usleep(25_000) }
        if isEngine(pid) { kill(pid, SIGKILL) }
        return true
    }

    private func isEngine(_ pid: Int32) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return URL(filePath: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)).lastPathComponent == executableName
    }
}

// MARK: - Locations

public struct EngineLocations: Sendable {
    public let support: URL
    public var dataDirectory: URL { support.appending(path: "engine") }
    public var runtimeRecord: URL { dataDirectory.appending(path: "userdata/server-runtime.json") }
    public var pidFile: URL { support.appending(path: "engine.pid") }
    public let logs: URL

    public init(support: URL, logs: URL) {
        self.support = support
        self.logs = logs
    }

    public static var standard: EngineLocations {
        let home = URL(filePath: NSHomeDirectory())
        return EngineLocations(
            support: home.appending(path: "Library/Application Support/\(Product.name)"),
            logs: home.appending(path: "Library/Logs/\(Product.name)")
        )
    }
}

extension EngineSupervisor {
    /// Wires the real process launcher, probe, log and pidfile.
    public static func standard(executable: URL, locations: EngineLocations = .standard) -> EngineSupervisor {
        let log = EngineLog(directory: locations.logs)
        return EngineSupervisor(
            launcher: EngineProcessLauncher(executable: executable, locations: locations, log: log),
            probe: EngineReadinessProbe(runtimeRecord: locations.runtimeRecord),
            pidFile: EnginePidFile(url: locations.pidFile)
        )
    }
}

// MARK: - Real process

public struct EngineProcessLauncher: EngineLaunching {
    public let executable: URL
    public let locations: EngineLocations
    public let log: EngineLog
    /// Applied over the inherited environment. Tests use it to isolate HOME and PATH.
    public let environment: [String: String]

    public init(executable: URL, locations: EngineLocations, log: EngineLog, environment: [String: String] = [:]) {
        self.executable = executable
        self.locations = locations
        self.log = log
        self.environment = environment
    }

    public func launch(secret: String) throws -> any EngineProcess {
        let files = FileManager.default
        try Self.preparePrivateDirectory(at: locations.support)
        try Self.preparePrivateDirectory(at: locations.dataDirectory)
        // A record from a crashed run must not satisfy readiness.
        try? files.removeItem(at: locations.runtimeRecord)
        log.redact(secret)
        log.note("Starting the engine")
        signal(SIGPIPE, SIG_IGN)

        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "--base-dir", locations.dataDirectory.path, "--port", "0", "--bootstrap-fd", "0",
            "--launcher-pid", String(getpid()), "--log-level", "info"
        ]
        process.currentDirectoryURL = locations.dataDirectory
        var childEnvironment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }.filter {
            !$0.key.hasPrefix("T3CODE_") && !$0.key.hasPrefix("NOTCHBEE_ENGINE_") && !$0.key.hasPrefix("OTEL_")
        }
        // Bun reads this at startup, before the engine's JavaScript entry point runs.
        childEnvironment["DO_NOT_TRACK"] = "1"
        process.environment = childEnvironment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        let exit = ExitSignal()
        let log = self.log
        process.terminationHandler = { finished in
            exit.finish(EngineExit(code: finished.terminationStatus, signaled: finished.terminationReason == .uncaughtSignal))
            log.note("The engine exited with status \(finished.terminationStatus)")
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { log.append(data) }
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        let envelope: [String: Any] = [
            "mode": "desktop", "port": 0, "host": "127.0.0.1", "noBrowser": true,
            "desktopBootstrapToken": secret, "tailscaleServeEnabled": false, "tailscaleServePort": 443
        ]
        if var data = try? JSONSerialization.data(withJSONObject: envelope) {
            data.append(0x0A)
            try? input.fileHandleForWriting.write(contentsOf: data)
        }
        try? input.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
        return FoundationEngineProcess(process: process, exit: exit)
    }

    fileprivate static func preparePrivateDirectory(at url: URL) throws {
        let files = FileManager.default
        let permissions: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try files.createDirectory(at: url, withIntermediateDirectories: true, attributes: permissions)
        let attributes = try files.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try files.setAttributes(permissions, ofItemAtPath: url.path)
    }
}

final class ExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var result: EngineExit?
    private var waiters: [CheckedContinuation<EngineExit, Never>] = []

    func finish(_ exit: EngineExit) {
        lock.lock()
        result = exit
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume(returning: exit) }
    }

    func wait() async -> EngineExit {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

final class FoundationEngineProcess: EngineProcess, @unchecked Sendable {
    private let process: Process
    private let exit: ExitSignal
    let pid: Int32

    init(process: Process, exit: ExitSignal) {
        self.process = process
        self.exit = exit
        pid = process.processIdentifier
    }

    var isRunning: Bool { process.isRunning }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    func forceKill() {
        if process.isRunning { kill(pid, SIGKILL) }
    }

    func waitForExit() async -> EngineExit { await exit.wait() }
}

public struct EngineReadinessProbe: EngineReadinessProbing {
    public let runtimeRecord: URL

    public init(runtimeRecord: URL) {
        self.runtimeRecord = runtimeRecord
    }

    public func probe(pid: Int32, secret: String) async -> BundledEngineEndpoint? {
        guard let data = try? Data(contentsOf: runtimeRecord),
              let endpoint = BundledEngineEndpoint(runtimeRecord: data, childPID: pid, bootstrapToken: secret),
              (try? await endpoint.verify()) != nil else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 2
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
                                                   "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        let session = URLSession(configuration: configuration, delegate: EngineProbeNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        guard let (_, response) = try? await session.data(from: endpoint.origin.appending(path: ".well-known/t3/environment")),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return endpoint
    }
}

// MARK: - Log

/// Size-rotated engine log. Secrets registered with `redact` never reach disk.
public final class EngineLog: @unchecked Sendable {
    public let directory: URL
    public var currentFile: URL { directory.appending(path: "engine.log") }
    private let maxBytes: Int
    private let keep: Int
    private let lock = NSLock()
    private var handle: FileHandle?
    private var size = 0
    private var secrets: [String] = []

    public init(directory: URL, maxBytes: Int = 2 << 20, keep: Int = 3) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.keep = max(1, keep)
    }

    deinit { try? handle?.close() }

    public func redact(_ secret: String) {
        lock.lock()
        secrets = [secret]
        lock.unlock()
    }

    public func note(_ message: String) {
        append(Data("[\(Product.name)] \(ISO8601DateFormatter().string(from: Date())) \(message)\n".utf8))
    }

    public func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        var data = data
        if !secrets.isEmpty {
            var text = String(decoding: data, as: UTF8.self)
            for secret in secrets where text.contains(secret) {
                text = text.replacingOccurrences(of: secret, with: "[redacted]")
            }
            data = Data(text.utf8)
        }
        guard !data.isEmpty, openIfNeeded() else { return }
        if size > 0, size + data.count > maxBytes { rotate() }
        guard openIfNeeded() else { return }
        do {
            try handle?.write(contentsOf: data)
            size += data.count
        } catch {
            try? handle?.close()
            handle = nil
        }
    }

    private func openIfNeeded() -> Bool {
        if handle != nil { return true }
        let files = FileManager.default
        do {
            try EngineProcessLauncher.preparePrivateDirectory(at: directory)
            if !files.fileExists(atPath: currentFile.path) {
                guard files.createFile(atPath: currentFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
                else { return false }
            }
            guard try files.attributesOfItem(atPath: currentFile.path)[.type] as? FileAttributeType == .typeRegular else {
                return false
            }
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: currentFile.path)
            let opened = try FileHandle(forWritingTo: currentFile)
            size = Int(try opened.seekToEnd())
            handle = opened
            return true
        } catch {
            return false
        }
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let files = FileManager.default
        func file(_ index: Int) -> URL { directory.appending(path: "engine.\(index).log") }
        try? files.removeItem(at: file(keep))
        for index in stride(from: keep - 1, through: 1, by: -1) {
            try? files.moveItem(at: file(index), to: file(index + 1))
        }
        try? files.moveItem(at: currentFile, to: file(1))
        size = 0
    }
}
