import Foundation
import OSLog

/// T3 Code v0.1.9, orchestration protocol 2. This file owns the wire format,
/// authentication, subscriptions and the translation to Notchpilot events.
@MainActor
public final class T3Client: AgentBackend {
    private var events = AsyncStream<AppEvent>.makeStream()
    private var eventsFinished = false
    private let credentials: Credentials
    private let preferredProject: @MainActor () -> String?
    private let replayOrigin: URL?
    private let bundledEngine: BundledEngineEndpoint?
    private static let logger = Logger(subsystem: "com.hilaytrivedi.Notchbee", category: "Engine connection")
    private var lifecycle: Task<Void, Never>?
    var connection: Connection?
    private var projection = Projection()
    private var updatingProviders: Set<String> = []
    private var visibleDetails: Set<String> = []

    public init(bundledEngine: BundledEngineEndpoint, preferredProject: @escaping @MainActor () -> String?) {
        self.bundledEngine = bundledEngine
        self.preferredProject = preferredProject
        credentials = Credentials(engine: bundledEngine)
        replayOrigin = nil
    }

    #if DEBUG
    /// A separate loopback endpoint for the fixture server. It never receives a live credential.
    public init(replayOrigin: URL) {
        self.replayOrigin = replayOrigin
        credentials = Credentials(engine: nil)
        bundledEngine = nil
        preferredProject = { nil }
    }
    #endif

    public func eventStream() -> AsyncStream<AppEvent> {
        prepareEventStream()
        return events.stream
    }

    private func prepareEventStream() {
        guard eventsFinished else { return }
        events = AsyncStream<AppEvent>.makeStream()
        eventsFinished = false
    }

    public func start() {
        guard lifecycle == nil else { return }
        prepareEventStream()
        emit(.connectionChanged(.disconnected))
        lifecycle = Task { await run() }
    }

    public func retryConnection() {
        guard connection == nil else { return }
        lifecycle?.cancel()
        lifecycle = nil
        start()
    }

    public func stop() {
        lifecycle?.cancel()
        lifecycle = nil
        connection?.close()
        connection = nil
        projection = Projection()
        visibleDetails.removeAll()
        emit(.connectionChanged(.disconnected))
        events.continuation.finish()
        eventsFinished = true
    }

    public func setSessionDetailsVisible(_ visible: Bool, sessionId: String) {
        if visible {
            visibleDetails.insert(sessionId)
            if let detail = projection.details[sessionId] {
                emit(.conversationSnapshot(sessionID: sessionId, entries: detail.conversation.entries))
            }
            connection?.unavailableDetails.remove(sessionId)
            if let path = projection.branchPath(sessionId) { connection?.unavailableBranches.remove(path) }
        } else {
            visibleDetails.remove(sessionId)
        }
        // The receive loop also reconciles after every chunk. This pass handles an idle socket.
        guard let connection else { return }
        Task {
            do {
                try await reconcileDetails(connection)
            } catch {
                connection.close()
            }
        }
    }

    public func startSession(title: String, providerInstanceId: String, model: String) async throws -> String {
        let connection = try requireConnection()
        let projects = projection.projects.values.filter { $0.archivedAt == nil }
        guard let projectID = preferredProject() ?? (projects.count == 1 ? projects.first?.id : nil),
              projects.contains(where: { $0.id == projectID }) else { throw ClientError.projectRequired }
        let threadID = UUID().uuidString
        try await connection.call("orchestration.dispatchCommand", CreateThread(
            threadId: threadID, projectId: projectID, title: title,
            modelSelection: .init(instanceId: providerInstanceId, model: model)
        ))
        return threadID
    }

    public func startSession(title: String, inProjectOf sessionId: String?, prompt: String) async throws {
        if let base = sessionId.flatMap({ projection.activeThread($0) }),
           let project = projection.projects[base.projectId], project.archivedAt == nil {
            guard let model = base.modelSelection else { throw ClientError.modelRequired }
            _ = try await launchThread(.init(projectID: project.id, modelSelection: model,
                                             runtimeMode: .approvalRequired, prompt: prompt, title: title))
        } else {
            let projectID = preferredProject().flatMap { id in
                projection.projects[id].flatMap { $0.archivedAt == nil ? id : nil }
            }
            let catalog = try await providerCatalog(projectID: projectID)
            guard let model = supervisedModel(in: catalog) else { throw ClientError.noSupervisedModel }
            _ = try await launchThread(.init(projectID: projectID, modelSelection: model,
                                             runtimeMode: .approvalRequired, prompt: prompt, title: title))
        }
    }

    public func sendPrompt(sessionId: String, text: String) async throws {
        try await requireConnection().call("orchestration.dispatchCommand", DispatchMessage(threadId: sessionId, text: text))
    }

    public func cleanTranscript(_ transcript: String, options: SpeechCleanupOptions) async throws -> String {
        let connection = try requireConnection()
        return try await connection.clean(.init(transcript: transcript, options: options))
    }

    public func runDictationPrompt(_ prompt: String, target: DictationAgentTarget) async throws -> String {
        let connection = try requireConnection()
        let ids = ThreadLaunch.IDs()
        let messageID = ids.message
        let threadID: String
        let launch: ThreadLaunch?
        switch target {
        case .existing(let id):
            guard projection.activeThread(id) != nil else { throw DictationBackendError.unavailable }
            threadID = id
            launch = nil
        case .new(let baseID):
            guard let base = projection.activeThread(baseID),
                  let project = projection.projects[base.projectId], project.archivedAt == nil,
                  let model = base.modelSelection else {
                throw DictationBackendError.unavailable
            }
            threadID = ids.thread
            launch = .init(
                projectID: project.id, modelSelection: model,
                runtimeMode: .approvalRequired, prompt: prompt, ids: ids
            )
        case .newInProject(let projectID):
            let catalog = try await providerCatalog(projectID: projectID)
            guard let model = supervisedModel(in: catalog) else { throw DictationBackendError.unavailable }
            threadID = ids.thread
            launch = .init(
                projectID: projectID, modelSelection: model,
                runtimeMode: .approvalRequired, prompt: prompt, ids: ids
            )
        }

        guard connection === self.connection, connection.dictationReplies[threadID] == nil else {
            throw DictationBackendError.unavailable
        }
        let reply = DictationReply(messageID: messageID)
        connection.dictationReplies[threadID] = reply
        connection.unavailableDetails.remove(threadID)
        defer {
            connection.dictationReplies.removeValue(forKey: threadID)
            reply.finish()
            Task {
                do { try await reconcileDetails(connection) }
                catch { connection.close() }
            }
        }
        try await reconcileDetails(connection)
        if let launch {
            _ = try await launchThread(launch, on: connection)
        } else {
            try await connection.call("orchestration.dispatchCommand", DispatchMessage(
                threadId: threadID, text: prompt, messageId: messageID
            ))
        }
        for try await text in reply.results.stream {
            try Task.checkCancellation()
            return text
        }
        try Task.checkCancellation()
        throw DictationBackendError.noReply
    }

    private func supervisedModel(in catalog: ThreadProviderCatalog) -> ThreadModelSelection? {
        let supervised = catalog.providers.filter { $0.runtimeModes.contains(.approvalRequired) }
        if supervised.contains(where: { $0.id == catalog.defaultSelection?.instanceId }) {
            return catalog.defaultSelection
        }
        return supervised.first.flatMap { provider in
            provider.models.first.map { ThreadModelSelection(instanceId: provider.id, model: $0.id) }
        }
    }

    public func launchThread(_ request: ThreadLaunch) async throws -> String {
        try await launchThread(request, on: requireConnection())
    }

    private func launchThread(_ request: ThreadLaunch, on connection: Connection) async throws -> String {
        let projectID: String
        if let selected = request.projectID {
            projectID = selected
        } else {
            guard replayOrigin == nil else { throw ClientError.projectRequired }
            projectID = try await connection.scratch.resolve(
                projects: { Array(self.projection.projects.values) },
                register: { command in
                    let result = try await connection.call("projects.mutate", command)
                    guard result?.project?.id == command.projectId else { throw ClientError.protocolMismatch }
                }
            )
        }
        let result = try await connection.call("orchestration.launchThread", LaunchThread(request, projectID: projectID))
        guard let id = result?.threadId, id == request.ids.thread else { throw ClientError.protocolMismatch }
        return id
    }

    public func providerCatalog(projectID: String?) async throws -> ThreadProviderCatalog {
        let project = projectID.flatMap { projection.projects[$0] }
        let result = try await requireConnection().call("server.getConfig", Empty())
        guard let result, let providers = result.providers else { throw ClientError.invalidProviderCatalog }
        let skippedModels = providers.elements.reduce(0) { $0 + $1.models.skipped }
        if providers.skipped > 0 || skippedModels > 0 {
            Self.logger.warning("Skipped \(providers.skipped) malformed providers and \(skippedModels) malformed models")
        }
        guard !providers.elements.isEmpty || providers.skipped == 0 else { throw ClientError.invalidProviderCatalog }
        return result.providerCatalog(project: project)
    }

    public func mutateThread(sessionID: String, mutation: ThreadMutation) async throws {
        try await requireConnection().call("orchestration.dispatchCommand", Self.threadCommand(sessionID: sessionID, mutation: mutation))
    }

    nonisolated static func threadCommand(sessionID: String, mutation: ThreadMutation) -> ThreadCommand {
        switch mutation {
        case .stop: .init(type: "thread.stop", threadId: sessionID, stopDelegatedTasks: false)
        case .resolve(let resolved): .init(type: resolved ? "thread.settle" : "thread.unsettle", threadId: sessionID, reason: resolved ? nil : "user")
        case .rename(let title): .init(type: "thread.metadata.update", threadId: sessionID, title: title)
        case .setModel(let selection): .init(type: "thread.model-selection.set", threadId: sessionID, modelSelection: selection)
        case .archive: .init(type: "thread.archive", threadId: sessionID)
        case .unarchive: .init(type: "thread.unarchive", threadId: sessionID)
        case .delete: .init(type: "thread.delete", threadId: sessionID)
        }
    }

    public func approve(requestId: String, threadId: String) async throws {
        try await respond(requestId: requestId, threadId: threadId, decision: "accept")
    }

    public func deny(requestId: String, threadId: String) async throws {
        try await respond(requestId: requestId, threadId: threadId, decision: "decline")
    }

    public func answerUserInput(requestId: String, threadId: String, answers: [String: UserInputAnswer]) async throws {
        try await sendUserInput(requestId: requestId, threadId: threadId, command: AnswerUserInput(
            threadId: threadId, requestId: requestId, answers: answers), commandType: "runtime-request.respond")
    }

    public func dismissUserInput(requestId: String, threadId: String) async throws {
        try await sendUserInput(requestId: requestId, threadId: threadId, command: DismissUserInput(
            threadId: threadId, requestId: requestId), commandType: "thread.user-input.dismiss")
    }

    private func sendUserInput(
        requestId: String, threadId: String, command: some Encodable & Sendable, commandType: String
    ) async throws {
        let connection = try requireConnection()
        guard projection.details[threadId]?.advertisedInputs[requestId] != nil else { return }
        do {
            try await connection.call("orchestration.dispatchCommand", command)
        } catch let failure as RPCFailure where failure.isStaleRequest(requestId, commandType: commandType) {
            projection.withdrawUserInput(requestId, threadID: threadId).forEach(emit)
        }
    }

    private func respond(requestId: String, threadId: String, decision: String) async throws {
        let connection = try requireConnection()
        guard let request = projection.details[threadId]?.advertised[requestId],
              decision != "accept" || request.canApprove else { return }
        do {
            try await connection.call("orchestration.dispatchCommand", Respond(
                threadId: threadId, requestId: requestId, decision: decision
            ))
        } catch let failure as RPCFailure where failure.isStaleApproval(requestId) {
            projection.withdrawApproval(requestId, threadID: threadId).forEach(emit)
        }
    }

    func requireConnection() throws -> Connection {
        guard let connection, projection.hasShell else { throw ClientError.disconnected }
        return connection
    }

    private func emit(_ event: AppEvent) {
        events.continuation.yield(event)
    }

    private func run() async {
        var delay = 0.5
        while !Task.isCancelled {
            var status: AgentConnection = .disconnected
            do {
                try await connect()
            } catch let error as ClientError where error == .protocolMismatch {
                guard !Task.isCancelled else { return }
                connection?.close()
                connection = nil
                projection = Projection()
                lifecycle = nil
                emit(.connectionChanged(.failed(Product.displayText(error.localizedDescription))))
                return
            } catch let error as EngineListenerError {
                status = .failed(error.localizedDescription)
            } catch ClientError.discovery {
                status = .failed(ClientError.discovery.localizedDescription)
            } catch {
                // Foundation transport errors can contain the ticket URL. Keep them out of logs and UI.
            }
            guard !Task.isCancelled else { return }
            if projection.hasShell { delay = 0.5 }
            connection?.close()
            connection = nil
            projection = Projection()
            emit(.connectionChanged(status))
            do {
                try await Task.sleep(for: .seconds(delay * Double.random(in: 0.8...1.2)))
            } catch {
                return
            }
            delay = min(delay * 2, 30)
        }
    }

    private func connect() async throws {
        guard let origin = bundledEngine?.origin ?? replayOrigin,
              T3LoopbackEndpoint(origin: origin) != nil else { throw ClientError.discovery }
        let verify: () async throws -> Void = { [bundledEngine] in
            try await bundledEngine?.verify()
        }
        try await verify()
        let session = URLSession(configuration: Self.sessionConfiguration(), delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let data = try await Self.http(session, URLRequest(url: origin.appending(path: ".well-known/t3/environment")))
        guard let descriptor = try? JSONDecoder().decode(Descriptor.self, from: data),
              descriptor.orchestrationProtocolVersion == 2 else { throw ClientError.protocolMismatch }
        let ticket = try await websocketTicket(
            session, origin: origin, verify: verify
        )
        try await verify()
        var url = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        url.scheme = origin.scheme == "https" ? "wss" : "ws"
        url.path = "/ws"
        url.queryItems = [
            .init(name: "orchestrationProtocol", value: "2"),
            .init(name: "wsTicket", value: ticket)
        ]
        guard let socketURL = url.url else { throw ClientError.protocolMismatch }
        try Task.checkCancellation()
        let connection = Connection(socket: session.webSocketTask(with: socketURL)) { [weak self] payload in
            guard let self else { throw ClientError.disconnected }
            return try await self.postProcess(
                payload, session: session, origin: origin, verify: verify
            )
        }
        self.connection = connection
        projection = Projection()
        defer { connection.close() }
        connection.socket.resume()
        try await connection.subscribe(.shell, method: "orchestration.subscribeShell", payload: Empty())
        try await connection.subscribe(.archive, method: "orchestration.getArchivedShellSnapshot", payload: Empty())

        let heartbeat = Task {
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(8))
                    guard connection.lastFrame.duration(to: .now) < .seconds(25),
                          self.projection.hasShell || connection.started.duration(to: .now) < .seconds(25) else {
                        connection.close()
                        return
                    }
                    try await connection.send(Control(tag: "Ping"))
                }
            } catch {
                if !Task.isCancelled { connection.close() }
            }
        }
        defer { heartbeat.cancel() }

        while !Task.isCancelled {
            let frame = try await connection.receive()
            try Task.checkCancellation()
            switch frame {
            case .chunk(let id, let items):
                if case .action(let actionID) = connection.streams[id] {
                    for case .gitProgress(let progress) in items {
                        guard let run = connection.actionRuns[actionID] else { continue }
                        switch progress.event {
                        case .event(let event): run.yield(event)
                        case .failure(let message):
                            connection.actionRuns.removeValue(forKey: actionID)
                            run.finish(throwing: WorkspaceError.actionFailed(message))
                        case nil: break
                        }
                    }
                } else if let stream = connection.streams[id] {
                    let reply = stream.threadID.flatMap { connection.dictationReplies[$0] }
                    for item in items {
                        reply?.apply(item)
                        if case .branch(let path) = stream, case .branch(let name) = item {
                            projection.updateBranch(name, at: path).forEach(emit)
                        } else {
                            let updates = projection.apply(item, detailThreadID: stream.threadID)
                            switch item {
                            case .projectUpdated(let project): connection.scratch.observe(project.id)
                            case .projectRemoved(let id): connection.scratch.observe(id)
                            default: break
                            }
                            updates.forEach(emit)
                        }
                    }
                    reply?.resolve()
                }
                try await connection.send(Control(tag: "Ack", requestId: id))
                if connection === self.connection {
                    if projection.needsArchiveRefresh {
                        try await connection.subscribe(.archive, method: "orchestration.getArchivedShellSnapshot", payload: Empty())
                    }
                    try await reconcileDetails(connection)
                }
            case .exit(let id, let exit):
                if let stream = connection.streams.removeValue(forKey: id) {
                    switch stream {
                    case .shell: throw ClientError.disconnected
                    case .archive:
                        if let archive = exit.value?.shell {
                            projection.applyArchive(archive).forEach(emit)
                            if projection.needsArchiveRefresh {
                                try await connection.subscribe(.archive, method: "orchestration.getArchivedShellSnapshot", payload: Empty())
                            }
                            try await reconcileDetails(connection)
                        } else if projection.needsArchiveRefresh {
                            throw ClientError.disconnected
                        }
                    case .detail(let threadID):
                        connection.dictationReplies[threadID]?.finish(throwing: ClientError.disconnected)
                        let isVisible = visibleDetails.contains(threadID) && projection.threadIDs.contains(threadID)
                        if !isVisible && projection.needsApprovalDetails(threadID) { throw ClientError.disconnected }
                        projection.dropDetail(threadID).forEach(emit)
                        connection.unavailableDetails.insert(threadID)
                        if isVisible { emit(.conversationUnavailable(sessionID: threadID)) }
                    case .branch(let path):
                        connection.unavailableBranches.insert(path)
                    case .action(let actionID):
                        let run = connection.actionRuns.removeValue(forKey: actionID)
                        if exit.tag == "Success" { run?.finish() } else { run?.finish(throwing: RPCFailure(exit: exit)) }
                    }
                } else {
                    connection.resolve(id, exit: exit)
                }
            case .control("Ping", _):
                try await connection.send(Control(tag: "Pong"))
            case .control("Defect", _):
                throw ClientError.protocolMismatch
            default:
                break
            }
        }
    }

    private func reconcileDetails(_ connection: Connection) async throws {
        guard connection === self.connection else { return }
        connection.needsDetailPass = true
        guard !connection.reconcilingDetails else { return }
        connection.reconcilingDetails = true
        defer { connection.reconcilingDetails = false }
        while connection.needsDetailPass, connection === self.connection {
            connection.needsDetailPass = false
            let consumers = visibleDetails.union(connection.dictationReplies.keys)
            let wanted = projection.approvalThreads.union(consumers.intersection(projection.threadIDs))
            let subscribed = Set(connection.streams.values.compactMap(\.threadID))
            for threadID in subscribed.subtracting(wanted) {
                guard connection === self.connection, !projection.needsApprovalDetails(threadID),
                      !visibleDetails.contains(threadID) || !projection.threadIDs.contains(threadID),
                      connection.dictationReplies[threadID] == nil || !projection.threadIDs.contains(threadID)
                else { continue }
                connection.dictationReplies[threadID]?.finish(throwing: ClientError.disconnected)
                projection.dropDetail(threadID).forEach(emit)
                try await connection.interrupt(.detail(threadID))
            }
            for threadID in wanted.subtracting(subscribed).subtracting(connection.unavailableDetails).sorted() {
                guard connection === self.connection,
                      projection.needsApprovalDetails(threadID) ||
                        ((visibleDetails.contains(threadID) || connection.dictationReplies[threadID] != nil) &&
                            projection.threadIDs.contains(threadID)) else { continue }
                try await connection.subscribe(.detail(threadID), method: "orchestration.subscribeThread",
                                               payload: ThreadDetail(threadId: threadID))
            }

            let paths = Set(visibleDetails.compactMap { projection.branchPath($0) })
            let watchedPaths = Set(connection.streams.values.compactMap(\.branchPath))
            for path in watchedPaths.subtracting(paths) {
                try await connection.interrupt(.branch(path))
            }
            for path in paths.subtracting(watchedPaths).subtracting(connection.unavailableBranches) {
                guard connection === self.connection else { return }
                try await connection.subscribe(.branch(path), method: "subscribeVcsBranch", payload: BranchStatus(cwd: path))
            }
        }
    }

    private func postProcess(
        _ payload: T3SpeechCleanupRequest, session: URLSession, origin: URL,
        verify: () async throws -> Void
    ) async throws -> String {
        var token = try await credentials.token()
        for attempt in 0...1 {
            try await verify()
            try Task.checkCancellation()
            let request = try payload.urlRequest(origin: origin, token: token)
            do {
                let data = try await Self.http(session, request)
                return try JSONDecoder().decode(T3SpeechCleanupRequest.Response.self, from: data).text
            } catch ClientError.http(let status) where attempt == 0 && status == 401 {
                token = try await credentials.token(rejectedToken: token)
            }
        }
        throw ClientError.authentication
    }

    private func websocketTicket(
        _ session: URLSession, origin: URL, verify: () async throws -> Void
    ) async throws -> String {
        var request = URLRequest(url: origin.appending(path: "api/auth/websocket-ticket/rpc"))
        request.httpMethod = "POST"
        var token = try await credentials.token()
        for attempt in 0...1 {
            try Task.checkCancellation()
            try await verify()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            do {
                return try JSONDecoder().decode(Ticket.self, from: await Self.http(session, request)).ticket
            } catch ClientError.http(let status) where attempt == 0 && (status == 401 || status == 403) {
                token = try await credentials.token(rejectedToken: token)
            }
        }
        throw ClientError.authentication
    }

    private static func sessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
                                            "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        config.timeoutIntervalForRequest = 10
        return config
    }

    private static func http(_ session: URLSession, _ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ClientError.disconnected }
        guard (200..<300).contains(response.statusCode) else { throw ClientError.http(response.statusCode) }
        return data
    }
}

extension T3Client {
    nonisolated static let maximumMessageBytes = 4 * 1024 * 1024
    nonisolated static let maximumChunkItems = 1_024

    nonisolated static func decodeFrame(_ data: Data) throws -> Frame {
        guard data.count <= maximumMessageBytes else { throw ClientError.messageTooLarge }
        return try JSONDecoder().decode(Frame.self, from: data)
    }

    enum ClientError: LocalizedError, Equatable {
        case discovery, authentication, protocolMismatch, disconnected, projectRequired, modelRequired, timedOut
        case invalidProviderCatalog, noSupervisedModel
        case messageTooLarge
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .discovery: "The local server address is unavailable."
            case .authentication: "Could not authenticate with the local server."
            case .protocolMismatch: "The server’s WebSocket protocol is incompatible."
            case .invalidProviderCatalog: "The server returned an invalid provider catalog."
            case .disconnected: "The server is disconnected."
            case .projectRequired: "Choose a project before starting a session."
            case .modelRequired: "The last active session’s model is unavailable."
            case .noSupervisedModel: "No model is available in approval-required mode."
            case .timedOut: "The server did not respond in time."
            case .messageTooLarge: "The server sent an oversized WebSocket message."
            case .http: "The server rejected the request."
            }
        }
    }

    private struct Descriptor: Decodable {
        let orchestrationProtocolVersion: Int
    }
    private struct Ticket: Decodable { let ticket: String }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
        ) async -> URLRequest? { nil }
    }

    private actor Credentials {
        private struct Bearer: Sendable {
            let token: String
            let expiry: ContinuousClock.Instant
        }

        private let engine: BundledEngineEndpoint?
        private var bearer: Bearer?
        private var exchange: Task<Bearer, Error>?

        init(engine: BundledEngineEndpoint?) {
            self.engine = engine
        }

        func token(rejectedToken: String? = nil) async throws -> String {
            if let engine { return try await engineToken(engine, rejectedToken: rejectedToken) }
            return "fixture-replay"
        }

        private func engineToken(_ engine: BundledEngineEndpoint, rejectedToken: String?) async throws -> String {
            if let exchange { return try await exchange.value.token }
            if let bearer, bearer.expiry > .now, bearer.token != rejectedToken { return bearer.token }

            // Exchange revokes the previous desktop session. Coalesce simultaneous refreshes.
            let task = Task { try await Self.exchangeToken(engine) }
            exchange = task
            defer { exchange = nil }
            let result = try await task.value
            bearer = result
            return result.token
        }

        private static func exchangeToken(_ engine: BundledEngineEndpoint) async throws -> Bearer {
            struct Response: Decodable {
                let access_token: String
                let expires_in: Int
            }
            let configuration = await T3Client.sessionConfiguration()
            let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: engine.origin.appending(path: "oauth/token"))
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var form = URLComponents()
            form.queryItems = [
                .init(name: "grant_type", value: "urn:ietf:params:oauth:grant-type:token-exchange"),
                .init(name: "subject_token", value: engine.bootstrapToken),
                .init(name: "subject_token_type", value: "urn:t3:params:oauth:token-type:environment-bootstrap"),
                .init(name: "requested_token_type", value: "urn:ietf:params:oauth:token-type:access_token"),
                .init(name: "scope", value: T3Client.requestedScopes.joined(separator: " ")),
                .init(name: "client_label", value: Product.name)
            ]
            request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
            try await engine.verify()
            let data = try await T3Client.http(session, request)
            let response = try JSONDecoder().decode(Response.self, from: data)
            guard !response.access_token.isEmpty, response.expires_in > 0 else { throw ClientError.authentication }
            return Bearer(token: response.access_token, expiry: .now.advanced(by: .seconds(max(0, response.expires_in - 15))))
        }

    }
}

extension T3Client {
    @MainActor
    final class DictationReply {
        let results = AsyncThrowingStream<String, Error>.makeStream()
        private let messageID: String
        private var run: Run?
        private var messages: [String: Message] = [:]

        init(messageID: String) {
            self.messageID = messageID
        }

        func apply(_ item: StreamItem) {
            switch item {
            case .detailSnapshot(let projection):
                run = projection.runs.last { $0.userMessageId == messageID }
                messages.removeAll()
                projection.messages?.forEach(record)
            case .detailEvent(.run(let updated)) where updated.userMessageId == messageID:
                guard updated.ordinal >= (run?.ordinal ?? 0) else { return }
                if updated.id != run?.id { messages.removeAll() }
                run = updated
            case .detailEvent(.message(let message)):
                record(message)
            default: break
            }
        }

        private func record(_ message: Message) {
            guard let runID = run?.id, message.runId == runID, message.role == "assistant" else { return }
            messages[message.id] = message
        }

        func resolve() {
            switch run?.status {
            case "completed":
                let text = messages.values
                    .filter { !$0.streaming && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
                    .map(\.text).joined(separator: "\n\n")
                if text.isEmpty {
                    finish(throwing: DictationBackendError.noReply)
                } else {
                    results.continuation.yield(text)
                    finish()
                }
            case "failed", "interrupted", "cancelled", "rolled_back":
                finish(throwing: DictationBackendError.runFailed)
            default: break
            }
        }

        func finish(throwing error: Error? = nil) {
            results.continuation.finish(throwing: error)
        }
    }

    @MainActor
    final class Connection {
        let socket: URLSessionWebSocketTask
        let clean: (T3SpeechCleanupRequest) async throws -> String
        var dictationReplies: [String: DictationReply] = [:]
        var actionRuns: [String: AsyncThrowingStream<GitActionEvent, Error>.Continuation] = [:]
        let started = ContinuousClock.now
        var lastFrame = ContinuousClock.now
        var streams: [String: Subscription] = [:]
        var unavailableDetails: Set<String> = []
        var unavailableBranches: Set<String> = []
        var needsDetailPass = false
        var reconcilingDetails = false
        let scratch = ScratchProject()

        private var nextID = 0
        private var calls: [String: CheckedContinuation<ResultValue?, Error>] = [:]
        private var closed = false

        init(socket: URLSessionWebSocketTask, clean: @escaping (T3SpeechCleanupRequest) async throws -> String) {
            self.socket = socket
            self.clean = clean
            socket.maximumMessageSize = T3Client.maximumMessageBytes
        }

        func close() {
            guard !closed else { return }
            closed = true
            socket.cancel(with: .goingAway, reason: nil)
            streams.removeAll()
            for reply in dictationReplies.values { reply.finish(throwing: ClientError.disconnected) }
            dictationReplies.removeAll()
            for run in actionRuns.values { run.finish(throwing: ClientError.disconnected) }
            actionRuns.removeAll()
            for call in calls.values { call.resume(throwing: ClientError.disconnected) }
            calls.removeAll()
        }

        func receive() async throws -> Frame {
            let data: Data
            do {
                switch try await socket.receive() {
                case .data(let message): data = message
                case .string(let message): data = Data(message.utf8)
                @unknown default: throw ClientError.protocolMismatch
                }
            } catch {
                throw ClientError.disconnected
            }
            lastFrame = .now
            return try await Self.decodeFrame(data)
        }

        @concurrent
        private static func decodeFrame(_ data: Data) async throws -> sending Frame {
            return try T3Client.decodeFrame(data)
        }

        func send(_ message: some Encodable) async throws {
            guard !closed else { throw ClientError.disconnected }
            let data = try JSONEncoder().encode(message)
            do {
                try await socket.send(.string(String(decoding: data, as: UTF8.self)))
            } catch {
                throw ClientError.disconnected
            }
        }

        func subscribe(_ stream: Subscription, method: String, payload: some Encodable) async throws {
            guard !streams.values.contains(stream) else { return }
            let id = requestID()
            streams[id] = stream
            try await send(Request(id: id, method: method, payload: payload))
        }

        func interrupt(_ stream: Subscription) async throws {
            guard let id = streams.first(where: { $0.value == stream })?.key else { return }
            streams.removeValue(forKey: id)
            try await send(Control(tag: "Interrupt", requestId: id))
        }

        @discardableResult
        func call(_ method: String, _ payload: some Encodable & Sendable,
                  timeout limit: Duration = .seconds(15)) async throws -> ResultValue? {
            guard !closed else { throw ClientError.disconnected }
            try Task.checkCancellation()
            let id = requestID()
            var timeout: Task<Void, Never>?
            defer { timeout?.cancel() }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    calls[id] = continuation
                    timeout = Task {
                        do {
                            try await Task.sleep(for: limit)
                            calls.removeValue(forKey: id)?.resume(throwing: ClientError.timedOut)
                        } catch {}
                    }
                    Task {
                        do {
                            try await send(Request(id: id, method: method, payload: payload))
                        } catch {
                            calls.removeValue(forKey: id)?.resume(throwing: error)
                        }
                    }
                }
            } onCancel: {
                Task { @MainActor in
                    self.calls.removeValue(forKey: id)?.resume(throwing: CancellationError())
                }
            }
        }

        func resolve(_ id: String, exit: Exit) {
            guard let call = calls.removeValue(forKey: id) else { return }
            if exit.tag == "Success" {
                call.resume(returning: exit.value)
            } else {
                call.resume(throwing: RPCFailure(exit: exit))
            }
        }

        private func requestID() -> String {
            nextID += 1
            return String(nextID)
        }
    }

    enum Subscription: Equatable {
        case shell, archive, detail(String), branch(String), action(String)

        var branchPath: String? {
            if case .branch(let path) = self { return path }
            return nil
        }

        var threadID: String? {
            if case .detail(let id) = self { return id }
            return nil
        }
    }

    struct RPCFailure: LocalizedError {
        let exit: Exit

        var errorDescription: String? {
            let detail = exit.cause?.lazy.compactMap { $0.error?.detail ?? $0.defect?.detail }.first
            return detail.map { Product.displayText(String($0.prefix(500))) } ?? "The request could not be completed."
        }

        func isStaleApproval(_ id: String) -> Bool { isStaleRequest(id, commandType: "runtime-request.respond") }

        func isStaleRequest(_ id: String, commandType: String) -> Bool {
            let prefix = "Runtime request \(id)"
            let staleMessages = ["is resolved.", "is cancelled.", "is expired.", "was not found."]
            return exit.cause?.contains { cause in
                guard cause.error?.tag == "OrchestrationV2DispatchCommandError",
                      cause.error?.commandType == commandType,
                      let message = cause.error?.message else { return false }
                return staleMessages.contains(where: { message == "\(prefix) \($0)" })
            } == true
        }
    }

    struct Capture: Decodable {
        let connection: String
        let direction: String
        let frame: Frame
    }

    enum Frame: Decodable {
        case request(id: String, method: String, payload: CapturedPayload)
        case chunk(id: String, items: [StreamItem])
        case exit(id: String, exit: Exit)
        case control(String, requestID: String?)

        private enum CodingKeys: String, CodingKey {
            case kind = "_tag"
            case id, tag, payload, requestId, values, exit
        }

        init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try keys.decode(String.self, forKey: .kind)
            switch kind {
            case "Request":
                self = try .request(id: keys.decode(String.self, forKey: .id),
                                    method: keys.decode(String.self, forKey: .tag),
                                    payload: keys.decode(CapturedPayload.self, forKey: .payload))
            case "Chunk":
                var values = try keys.nestedUnkeyedContainer(forKey: .values)
                guard (values.count ?? 0) <= T3Client.maximumChunkItems else { throw ClientError.messageTooLarge }
                var items: [StreamItem] = []
                while !values.isAtEnd {
                    guard items.count < T3Client.maximumChunkItems else { throw ClientError.messageTooLarge }
                    items.append(try values.decode(StreamItem.self))
                }
                self = try .chunk(id: keys.decode(String.self, forKey: .requestId), items: items)
            case "Exit":
                self = try .exit(id: keys.decode(String.self, forKey: .requestId),
                                 exit: keys.decode(Exit.self, forKey: .exit))
            default:
                self = try .control(kind, requestID: keys.decodeIfPresent(String.self, forKey: .requestId))
            }
        }
    }

    struct CapturedPayload: Decodable {
        let type: String?
        let threadId: String?
        let requestId: String?
        let decision: String?
    }

    struct Exit: Decodable {
        let tag: String
        let value: ResultValue?
        let cause: [Cause]?

        enum CodingKeys: String, CodingKey {
            case tag = "_tag"
            case value, cause
        }
    }

    struct LossyArray<Element: Decodable & Sendable>: Decodable, Sendable {
        let elements: [Element]
        let skipped: Int

        init(from decoder: Decoder) throws {
            var entries = try decoder.unkeyedContainer()
            var elements: [Element] = []
            var skipped = 0
            while !entries.isAtEnd {
                let entry = try entries.superDecoder()
                if let decoded = try? Element(from: entry) {
                    elements.append(decoded)
                } else {
                    skipped += 1
                }
            }
            self.elements = elements
            self.skipped = skipped
        }
    }

    struct ResultValue: Decodable {
        let shell: ShellSnapshot?
        let threadId: String?
        let providers: LossyArray<Provider>?
        let providerSDKs: [ProviderSDK]
        let settings: LaunchSettings?
        let rawSettings: [String: WireValue]?
        let project: Project?
        let usageSummary: UsageSummary?
        let availableEditors: [String]?
        /// The raw result of a source control call, kept only for results that carry one of `wireKeys`.
        let wire: WireValue?

        static let wireKeys: Set<CodingKeys> = [.isRepo, .refs, .pullRequest, .refName, .upstreamRef, .mergeCapabilities]

        enum CodingKeys: String, CodingKey {
            case threads, threadId, providers, settings, workspaceRoot, buckets, availableEditors
            case isRepo, refs, pullRequest, refName, upstreamRef, mergeCapabilities
            case providerSdks
        }

        init(from decoder: Decoder) throws {
            let keys = try? decoder.container(keyedBy: CodingKeys.self)
            shell = try keys?.contains(.threads) == true ? ShellSnapshot(from: decoder) : nil
            threadId = try keys?.decodeIfPresent(String.self, forKey: .threadId)
            providers = try? keys?.decodeIfPresent(LossyArray<Provider>.self, forKey: .providers)
            providerSDKs = (try? keys?.decodeIfPresent([ProviderSDK].self, forKey: .providerSdks)) ?? []
            settings = try keys?.decodeIfPresent(LaunchSettings.self, forKey: .settings)
            rawSettings = try? keys?.decodeIfPresent([String: WireValue].self, forKey: .settings)
            usageSummary = keys?.contains(.buckets) == true ? try? UsageSummary(from: decoder) : nil
            project = keys?.contains(.workspaceRoot) == true ? try? Project(from: decoder) : nil
            availableEditors = try? keys?.decodeIfPresent([String].self, forKey: .availableEditors)
            wire = keys.map { Self.wireKeys.contains(where: $0.contains) } == true ? try? WireValue(from: decoder) : nil
        }

        func providerCatalog(project: Project?) -> ThreadProviderCatalog {
            let overrides = project.flatMap { settings?.projectSettingsOverrides?[$0.id] }
            let pendingSDKs = Set(providerSDKs.filter { !$0.installed }.map(\.driver))
            let candidates = (providers?.elements ?? []).compactMap { provider -> ThreadProvider? in
                guard !pendingSDKs.contains(provider.driver) else { return nil }
                let enabled = overrides?.providerInstances?[provider.instanceId]?.enabled
                    ?? settings?.enabled(instanceID: provider.instanceId)
                return provider.availableProvider(enabled: enabled, cwd: project?.workspaceRoot)
            }
            let preferred = overrides?.hasModelOverride == true
                ? overrides?.defaultModelSelection
                : project?.defaultModelSelection ?? settings?.defaultModelSelection
            let selection = [preferred, settings?.fallbackModelSelection].compactMap { $0 }.first { selection in
                candidates.contains { provider in
                    provider.id == selection.instanceId && provider.models.contains { $0.id == selection.model }
                }
            } ?? candidates.first.flatMap { provider in
                provider.models.first.map { ThreadModelSelection(instanceId: provider.id, model: $0.id) }
            }
            let runtime = (overrides?.defaultRuntimeMode ?? settings?.defaultRuntimeMode)
                .flatMap(ThreadRuntimeMode.init(rawValue:)) ?? .fullAccess
            return .init(providers: candidates, defaultSelection: selection, defaultRuntimeMode: runtime)
        }
    }

    struct LaunchSettings: Decodable {
        struct ProviderOverride: Decodable { let enabled: Bool? }
        let rawInstances: [String: [String: WireValue]]?
        enum CodingKeys: String, CodingKey {
            case rawInstances = "providerInstances"
            case defaultModelSelection, fallbackModelSelection, defaultRuntimeMode, projectSettingsOverrides
        }
        func enabled(instanceID: String) -> Bool? {
            guard case .bool(let enabled) = rawInstances?[instanceID]?["enabled"] else { return nil }
            return enabled
        }

        struct ProjectOverrides: Decodable {
            let hasModelOverride: Bool
            let defaultModelSelection: ThreadModelSelection?
            let defaultRuntimeMode: String?
            let providerInstances: [String: ProviderOverride]?

            enum CodingKeys: String, CodingKey { case defaultModelSelection, defaultRuntimeMode, providerInstances }

            init(from decoder: Decoder) throws {
                let fields = try decoder.container(keyedBy: CodingKeys.self)
                hasModelOverride = fields.contains(.defaultModelSelection)
                defaultModelSelection = try fields.decodeIfPresent(ThreadModelSelection.self, forKey: .defaultModelSelection)
                defaultRuntimeMode = try fields.decodeIfPresent(String.self, forKey: .defaultRuntimeMode)
                providerInstances = try fields.decodeIfPresent([String: ProviderOverride].self, forKey: .providerInstances)
            }
        }

        let defaultModelSelection: ThreadModelSelection?
        let fallbackModelSelection: ThreadModelSelection?
        let defaultRuntimeMode: String?
        let projectSettingsOverrides: [String: ProjectOverrides]?
    }

    struct Cause: Decodable {
        let error: DispatchFailure?
        let defect: FailureDetail?
    }

    struct DispatchFailure: Decodable {
        let tag: String?
        let commandType: String?
        let message: String?
        let cause: FailureDetail?
        let reasonDetail: String?

        enum CodingKeys: String, CodingKey {
            case tag = "_tag"
            case commandType, message, cause
            case reasonDetail = "detail"
        }

        /// Git and source control errors carry a curated `detail`; their `cause` can echo raw command output.
        var detail: String? { reasonDetail ?? cause?.detail ?? message }
    }

    struct FailureDetail: Decodable {
        let detail: String?

        enum CodingKeys: String, CodingKey { case message, cause }

        init(from decoder: Decoder) throws {
            if let fields = try? decoder.container(keyedBy: CodingKeys.self) {
                let cause = try? fields.decodeIfPresent(Self.self, forKey: .cause)
                detail = cause?.detail ?? (try? fields.decodeIfPresent(String.self, forKey: .message))
            } else {
                detail = try? decoder.singleValueContainer().decode(String.self)
            }
        }
    }

    private struct Control: Encodable {
        let tag: String
        var requestId: String?

        enum CodingKeys: String, CodingKey {
            case tag = "_tag"
            case requestId
        }
    }

    struct Request<Payload: Encodable>: Encodable {
        let id: String
        let method: String
        let payload: Payload
        var kind = "Request"
        var headers: [[String]] = []

        enum CodingKeys: String, CodingKey {
            case kind = "_tag"
            case method = "tag"
            case id, payload, headers
        }
    }

    struct Empty: Encodable {}
    private struct BranchStatus: Encodable { let cwd: String }
    private struct ThreadDetail: Encodable {
        let threadId: String
    }

    private struct CreateThread: Encodable, Sendable {
        let threadId: String
        let projectId: String
        let title: String
        let modelSelection: ThreadModelSelection
        var type = "thread.create"
        var commandId = UUID().uuidString
        var createdBy = "user"
        var creationSource = "web"
        var runtimeMode = "approval-required"
        var interactionMode = "default"
        var branch = Null()
        var worktreePath = Null()
    }

    struct LaunchThread: Codable, Sendable {
        struct Workspace: Codable, Sendable { var type = "root" }
        struct Message: Codable, Sendable {
            let messageId: String
            let text: String
            var attachments: [String] = []
        }

        let commandId: String
        let threadId: String
        let projectId: String
        let title: String
        let modelSelection: ThreadModelSelection
        let runtimeMode: String
        var interactionMode = "default"
        var creationSource = "web"
        var workspaceStrategy = Workspace()
        var generateTitle = true
        let initialMessage: Message

        init(_ request: ThreadLaunch, projectID: String) {
            commandId = request.ids.command
            threadId = request.ids.thread
            projectId = projectID
            let seed = (request.title ?? request.prompt).trimmingCharacters(in: .whitespacesAndNewlines)
            title = String(seed.split(whereSeparator: \.isNewline).first?.prefix(80) ?? "New thread")
            modelSelection = request.modelSelection
            runtimeMode = request.runtimeMode.rawValue
            initialMessage = .init(messageId: request.ids.message, text: request.prompt)
        }
    }

    struct ThreadCommand: Encodable, Sendable {
        let type: String
        let threadId: String
        var title: String?
        var stopDelegatedTasks: Bool?
        var reason: String?
        var modelSelection: ThreadModelSelection?
        var commandId = UUID().uuidString
    }

    private struct Null: Encodable, Sendable {
        func encode(to encoder: Encoder) throws {
            var value = encoder.singleValueContainer()
            try value.encodeNil()
        }
    }

    private struct DispatchMessage: Encodable, Sendable {
        struct Mode: Encodable, Sendable { var type = "queue_after_active" }
        let threadId: String
        let text: String
        var type = "message.dispatch"
        var commandId = UUID().uuidString
        var messageId = UUID().uuidString
        var createdBy = "user"
        var creationSource = "web"
        var attachments: [String] = []
        var dispatchMode = Mode()
    }

    private struct Respond: Encodable, Sendable {
        let threadId: String
        let requestId: String
        let decision: String
        var type = "runtime-request.respond"
        var commandId = UUID().uuidString
    }

    struct AnswerUserInput: Encodable, Sendable {
        let threadId: String
        let requestId: String
        let answers: [String: UserInputAnswer]
        var type = "runtime-request.respond"
        var commandId = UUID().uuidString
    }

    struct DismissUserInput: Encodable, Sendable {
        let threadId: String
        let requestId: String
        var type = "thread.user-input.dismiss"
        var commandId = UUID().uuidString
    }
}

extension T3Client {
    enum StreamItem: Decodable {
        case shellSnapshot(ShellSnapshot, enrichment: Bool)
        case projectUpdated(Project)
        case projectRemoved(String)
        case threadUpdated(ThreadShell, archived: Bool, sequence: Int)
        case threadRemoved(String, archived: Bool, sequence: Int)
        case detailSnapshot(ThreadProjection)
        case detailEvent(DomainEvent)
        case branch(String?)
        case gitProgress(GitProgress)
        case ignored

        private enum CodingKeys: String, CodingKey {
            case kind, snapshot, projection, event, project, projectId, thread, threadId
            case location, sequence, resolvedRepositoryIdentityRoots, refName
        }

        init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: CodingKeys.self)
            switch try keys.decodeIfPresent(String.self, forKey: .kind) {
            case "snapshot" where keys.contains(.projection):
                self = try .detailSnapshot(keys.decode(ThreadProjection.self, forKey: .projection))
            case "snapshot":
                self = try .shellSnapshot(keys.decode(ShellSnapshot.self, forKey: .snapshot),
                                          enrichment: keys.contains(.resolvedRepositoryIdentityRoots))
            case "project.updated":
                self = try .projectUpdated(keys.decode(Project.self, forKey: .project))
            case "project.removed":
                self = try .projectRemoved(keys.decode(String.self, forKey: .projectId))
            case "thread.updated":
                self = try .threadUpdated(keys.decode(ThreadShell.self, forKey: .thread),
                                          archived: keys.decode(String.self, forKey: .location) == "archive",
                                          sequence: keys.decode(Int.self, forKey: .sequence))
            case "thread.removed":
                self = try .threadRemoved(keys.decode(String.self, forKey: .threadId),
                                          archived: keys.decode(String.self, forKey: .location) == "archive",
                                          sequence: keys.decode(Int.self, forKey: .sequence))
            case "event":
                self = try .detailEvent(keys.decode(DomainEvent.self, forKey: .event))
            case "action_started", "phase_started", "hook_started", "hook_output", "hook_finished",
                 "action_finished", "action_failed":
                self = try .gitProgress(GitProgress(from: decoder))
            case nil where keys.contains(.refName):
                self = try .branch(keys.decodeIfPresent(String.self, forKey: .refName))
            default:
                self = .ignored
            }
        }
    }

    struct ShellSnapshot: Decodable {
        let snapshotSequence: Int
        let projects: [Project]
        let threads: [ThreadShell]
        let archivedThreads: [ThreadShell]?

        enum CodingKeys: String, CodingKey {
            case snapshotSequence, projects, threads, archivedThreads
        }
    }

    struct Project: Decodable {
        struct Repository: Decodable {
            let displayName: String?
            let name: String?
        }
        let id: String
        let title: String
        let workspaceRoot: String
        let repositoryIdentity: Repository?
        let archivedAt: String?
        let defaultModelSelection: ThreadModelSelection?

        var repositoryName: String {
            repositoryIdentity?.displayName ?? repositoryIdentity?.name ?? URL(filePath: workspaceRoot).lastPathComponent
        }
    }

    struct Provider: Decodable, Sendable {
        struct Model: Decodable, Sendable {
            let slug: String
            let name: String
            let isDefault: Bool?
            let isCustom: Bool?
            struct Capabilities: Decodable { let optionDescriptors: LossyArray<ProviderOption>? }
            let capabilities: Capabilities?
        }

        let instanceId: String
        let driver: String
        let displayName: String?
        let status: String
        let enabled: Bool
        struct Auth: Decodable { let status: String; let type: String?; let label: String?; let email: String? }
        struct Setup: Decodable { let canInstall: Bool?; let documentationUrl: String? }
        struct Advisory: Decodable {
            let status: String?; let latestVersion: String?; let canUpdate: Bool?
        }
        struct UpdateState: Decodable { let status: String?; let message: String? }
        struct RuntimePaths: Decodable { let homePath: String?; let shadowHomePath: String? }
        let setup: Setup?
        let auth: Auth?
        let accentColor: String?
        let version: String?
        let checkedAt: String?
        let message: String?
        let versionAdvisory: Advisory?
        let updateState: UpdateState?
        let runtimePaths: RuntimePaths?
        let usageLimits: ProviderUsageLimits?
        let availability: String?
        let installed: Bool
        let supportedRuntimeModes: [String]?
        let models: LossyArray<Model>
        let slashCommands: LossyArray<SlashCommand>?
        let skills: LossyArray<Skill>?
        let workspaceSnapshots: LossyArray<WorkspaceSnapshot>?

        struct SlashCommand: Decodable, Sendable {
            struct Input: Decodable, Sendable { let hint: String }
            let name: String
            let description: String?
            let input: Input?
        }

        struct Skill: Decodable, Sendable {
            let name: String
            let description: String?
            let shortDescription: String?
            let enabled: Bool
            let userInvocable: Bool?
        }

        struct WorkspaceSnapshot: Decodable, Sendable {
            let cwd: String
            let slashCommands: LossyArray<SlashCommand>
            let skills: LossyArray<Skill>
        }

        /// A scanned snapshot of the project folder replaces the machine-wide lists, as in the T3 web composer.
        func composerCommands(cwd: String?) -> [ComposerCommand] {
            let snapshot = cwd.flatMap { cwd in workspaceSnapshots?.elements.first { $0.cwd == cwd } }
            let commands = snapshot?.slashCommands.elements ?? slashCommands?.elements ?? []
            let skills = snapshot?.skills.elements ?? skills?.elements ?? []
            return ComposerCommand.menu(
                slashCommands: commands.map { .init(name: $0.name, description: $0.description, inputHint: $0.input?.hint) },
                skills: skills.map { .init(name: $0.name, description: $0.description, shortDescription: $0.shortDescription,
                                           enabled: $0.enabled, userInvocable: $0.userInvocable) })
        }

        func availableProvider(enabled override: Bool?, cwd: String? = nil) -> ThreadProvider? {
            let models = models.elements
            guard override ?? enabled, installed, availability != "unavailable",
                  status != "disabled", status != "error",
                  let defaultModel = models.first(where: { $0.isDefault == true && $0.isCustom != true })
                    ?? models.first(where: { $0.isCustom != true }) ?? models.first
            else { return nil }
            let supported = supportedRuntimeModes ?? []
            let modes = ThreadRuntimeMode.allCases.filter { supported.isEmpty || supported.contains($0.rawValue) }
            guard !modes.isEmpty else { return nil }
            let ordered = [defaultModel] + models.filter { $0.slug != defaultModel.slug }
            return ThreadProvider(
                id: instanceId, name: Product.displayText(displayName ?? driver),
                models: ordered.map { .init(id: $0.slug, name: Product.displayText($0.name)) },
                runtimeModes: modes, usage: usageLimits, commands: composerCommands(cwd: cwd)
            )
        }
    }

    struct Thread: Decodable {
        let id: String
        let title: String
        let projectId: String
        let providerInstanceId: String
        let branch: String?
        let worktreePath: String?
        let updatedAt: String
        var settledOverride: String?
        let latestUserAuthoredMessageAt: String?
        let latestUserMessageAt: String?
        let modelSelection: ThreadModelSelection?
        let lineage: Lineage?

        struct Lineage: Decodable {
            let relationshipToParent: String?
            let sideChat: Bool?
        }

        /// Subagents and side chats live inside their parent's view, never in session lists.
        var isListed: Bool {
            lineage?.relationshipToParent != "subagent" && lineage?.sideChat != true
        }

        var lastActivity: Date? {
            (latestUserAuthoredMessageAt ?? latestUserMessageAt).flatMap(Self.date) ?? updateDate
        }

        var updateDate: Date? { Self.date(updatedAt) }

        fileprivate static func date(_ timestamp: String) -> Date? {
            (try? Date(timestamp, strategy: .iso8601)) ??
                (try? Date(timestamp, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
    }

    struct ThreadShell: Decodable {
        struct PendingRequest: Decodable {
            let id: String
            let kind: String?

            var isApproval: Bool { kind.map(RuntimeRequest.isApprovalKind) ?? true }
            var isUserInput: Bool { kind == RuntimeRequest.userInputKind }
        }
        var thread: Thread
        let status: String
        let latestRunCompletedAt: String?
        let activityRunStatus: String?
        let lastError: String?
        let pendingRuntimeRequest: PendingRequest?

        enum CodingKeys: String, CodingKey {
            case status, latestRunCompletedAt, activityRunStatus, lastError, pendingRuntimeRequest
        }

        init(from decoder: Decoder) throws {
            thread = try Thread(from: decoder)
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            status = try fields.decode(String.self, forKey: .status)
            latestRunCompletedAt = try fields.decodeIfPresent(String.self, forKey: .latestRunCompletedAt)
            activityRunStatus = try fields.decodeIfPresent(String.self, forKey: .activityRunStatus)
            lastError = try fields.decodeIfPresent(String.self, forKey: .lastError)
            pendingRuntimeRequest = try fields.decodeIfPresent(PendingRequest.self, forKey: .pendingRuntimeRequest)
        }
    }

    struct ThreadProjection: Decodable {
        let thread: Thread
        let runs: [Run]
        let runtimeRequests: [RuntimeRequest]
        let turnItems: [TurnItem]
        let checkpoints: [Checkpoint]
        let messages: [Message]?
    }

    enum DomainEvent: Decodable {
        case thread(Thread)
        case run(Run)
        case request(RuntimeRequest)
        case item(TurnItem)
        case message(Message)
        case checkpoint(Checkpoint)
        case ignored

        enum CodingKeys: String, CodingKey { case type, payload }

        init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: CodingKeys.self)
            let type = try keys.decode(String.self, forKey: .type)
            switch type {
            case "run.created", "run.updated":
                self = try .run(keys.decode(Run.self, forKey: .payload))
            case "runtime-request.updated":
                self = try .request(keys.decode(RuntimeRequest.self, forKey: .payload))
            case "message.updated":
                self = try .message(keys.decode(Message.self, forKey: .payload))
            case "turn-item.updated":
                self = try .item(keys.decode(TurnItem.self, forKey: .payload))
            case "checkpoint.captured":
                self = try .checkpoint(keys.decode(Checkpoint.self, forKey: .payload))
            case "thread.settled", "thread.unsettled", "thread.metadata-updated", "thread.provider-switched":
                self = try .thread(keys.decode(Thread.self, forKey: .payload))
            default:
                self = .ignored
            }
        }
    }

    struct Run: Decodable {
        let ordinal: Int
        let status: String
        let id: String?
        let userMessageId: String?
    }

    struct ProviderItemRef: Decodable, Hashable {
        let driver: String
        let nativeId: String
        let strength: String
    }

    struct ApprovalToolKey: Hashable {
        let turn: String
        let ref: ProviderItemRef
    }

    struct RuntimeRequest: Decodable {
        struct Capability: Decodable { let type: String }
        let id: String
        let kind: String
        let status: String
        let createdAt: String
        let responseCapability: Capability
        let providerTurnId: String?
        let nativeRequestRef: ProviderItemRef?

        var toolKey: ApprovalToolKey? {
            guard let providerTurnId, let nativeRequestRef, nativeRequestRef.strength == "strong" else { return nil }
            return .init(turn: providerTurnId, ref: nativeRequestRef)
        }

        var requiresToolPayload: Bool { ["command", "file-read", "file-change"].contains(kind) }
        let decision: String?

        var isApproval: Bool {
            Self.isApprovalKind(kind)
        }

        static func isApprovalKind(_ kind: String) -> Bool {
            ["command", "file-read", "file-change", "permission", "mcp-elicitation"].contains(kind)
        }

        var canRespond: Bool { isApproval && status == "pending" && responseCapability.type == "live" }

        static let userInputKind = "user_input"
        var isUserInput: Bool { kind == Self.userInputKind }
        /// Only a live request has a provider session waiting for the answer. Message-mode questions
        /// are answered by replying in the thread.
        var canAnswer: Bool { isUserInput && status == "pending" && responseCapability.type == "live" }

        var approvalDecision: ApprovalDecision? {
            switch decision {
            case "accept", "acceptForSession", "acceptAlways": .accepted
            case "decline": .declined
            default: nil
            }
        }

        var tool: String {
            switch kind {
            case "command": "Shell"
            case "file-read": "File read"
            case "file-change": "File change"
            case "mcp-elicitation": "MCP"
            default: "Permission"
            }
        }
    }

    struct Message: Decodable {
        let id: String
        let role: String
        let text: String
        let runId: String?
        let streaming: Bool
        let createdAt: String

        var entry: ConversationEntry {
            let kind: ConversationEntry.Kind = switch role {
            case "user": .user
            case "assistant": .assistant
            default: .system
            }
            return .init(id: "message:" + id, kind: kind, text: text, timestamp: createdAt, streaming: streaming)
        }
    }

    struct TurnItem: Decodable {
        struct Question: Decodable, Sendable {
            struct Option: Decodable, Sendable {
                let label: String
                let description: String?
                let value: String?
            }
            let id: String
            let header: String?
            let question: String
            let options: [Option]?
            let multiSelect: Bool?
            let allowCustomAnswer: Bool?
            let initialAnswer: String?
            let required: Bool?

            /// Prose is rebranded for display. Ids and answer values go back to the provider verbatim.
            var model: UserInputQuestion {
                UserInputQuestion(
                    id: id, header: Product.displayText(header ?? "Question"), question: Product.displayText(question),
                    options: (options ?? []).map {
                        UserInputOption(label: Product.displayText($0.label),
                                        description: Product.displayText($0.description ?? ""), value: $0.value ?? $0.label)
                    },
                    multiSelect: multiSelect == true, allowCustomAnswer: allowCustomAnswer == true,
                    initialAnswer: initialAnswer, required: required != false)
            }
        }

        struct FileChange: Decodable {
            let path: String
            let oldPath: String?
            let operation: String?
        }

        struct PlanStep: Decodable {
            let text: String
            let status: String
        }

        private struct Failure: Decodable { let message: String }

        private enum ToolInputKeys: String, CodingKey {
            case command, path, filePath, pattern, query, url, description, prompt
            case file_path
        }

        struct ToolPayload {
            let kind: String?
            var command: String? = nil
            var filePaths: String? = nil

            func text(for requestKind: String) -> String? {
                switch requestKind {
                case "command": command
                case "file-read", "file-change": filePaths
                default: nil
                }
            }
        }

        let providerTurnId: String?
        let nativeItemRef: ProviderItemRef?
        let toolPayload: ToolPayload?

        var toolKey: ApprovalToolKey? {
            guard let providerTurnId, let nativeItemRef, nativeItemRef.strength == "strong" else { return nil }
            return .init(turn: providerTurnId, ref: nativeItemRef)
        }

        let type: String
        let title: String?
        let requestId: String?
        let prompt: String?
        let reason: String?
        let appName: String?
        let id: String?
        let status: String?
        let startedAt: String?
        let updatedAt: String?
        let completedAt: String?
        let input: String?
        let fileName: String?
        let toolName: String?
        let message: String?
        let messageId: String?
        let text: String?
        let streaming: Bool?
        let output: String?
        let exitCode: Int?
        let outputIndicatesFailure: Bool?
        let additions: Int?
        let deletions: Int?
        let diffStr: String?
        let changes: [FileChange]
        let steps: [PlanStep]
        let markdown: String?
        let failureMessage: String?
        let patterns: [String]
        let summary: String?
        let requestKind: String?
        let questions: [Question]
        /// Best human label for a dynamic tool's JSON input.
        let dynamicLabel: String?

        enum CodingKeys: String, CodingKey {
            case type, title, requestId, prompt, reason, appName, id, status, startedAt, updatedAt, completedAt
            case input, fileName, toolName, message, messageId, text, streaming
            case changes, providerTurnId, nativeItemRef
            case output, exitCode, outputIndicatesFailure, additions, deletions, diffStr
            case steps, explanation, markdown, failure, pattern, patterns, summary, requestKind, questions
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            type = try fields.decode(String.self, forKey: .type)
            title = try fields.decodeIfPresent(String.self, forKey: .title)
            requestId = try fields.decodeIfPresent(String.self, forKey: .requestId)
            prompt = try fields.decodeIfPresent(String.self, forKey: .prompt)
            reason = try fields.decodeIfPresent(String.self, forKey: .reason)
            appName = try fields.decodeIfPresent(String.self, forKey: .appName)
            id = try fields.decodeIfPresent(String.self, forKey: .id)
            status = try fields.decodeIfPresent(String.self, forKey: .status)
            startedAt = try fields.decodeIfPresent(String.self, forKey: .startedAt)
            updatedAt = try fields.decodeIfPresent(String.self, forKey: .updatedAt)
            completedAt = try fields.decodeIfPresent(String.self, forKey: .completedAt)
            // Dynamic tools carry arbitrary JSON input; command executions use a string.
            input = type == "command_execution" ? try fields.decodeIfPresent(String.self, forKey: .input) : nil
            fileName = try fields.decodeIfPresent(String.self, forKey: .fileName)
            toolName = try fields.decodeIfPresent(String.self, forKey: .toolName)
            message = try fields.decodeIfPresent(String.self, forKey: .message)
            messageId = try fields.decodeIfPresent(String.self, forKey: .messageId)
            text = try fields.decodeIfPresent(String.self, forKey: .text)
            streaming = try fields.decodeIfPresent(Bool.self, forKey: .streaming)
            providerTurnId = try fields.decodeIfPresent(String.self, forKey: .providerTurnId)
            nativeItemRef = try fields.decodeIfPresent(ProviderItemRef.self, forKey: .nativeItemRef)
            output = type == "command_execution" ? try? fields.decodeIfPresent(String.self, forKey: .output) : nil
            exitCode = try? fields.decodeIfPresent(Int.self, forKey: .exitCode)
            outputIndicatesFailure = try? fields.decodeIfPresent(Bool.self, forKey: .outputIndicatesFailure)
            additions = try? fields.decodeIfPresent(Int.self, forKey: .additions)
            deletions = try? fields.decodeIfPresent(Int.self, forKey: .deletions)
            diffStr = try? fields.decodeIfPresent(String.self, forKey: .diffStr)
            changes = (try? fields.decodeIfPresent([FileChange].self, forKey: .changes)) ?? []
            steps = (try? fields.decodeIfPresent([PlanStep].self, forKey: .steps)) ?? []
            markdown = try? fields.decodeIfPresent(String.self, forKey: .markdown)
            failureMessage = (try? fields.decodeIfPresent(Failure.self, forKey: .failure))?.message
            let single = try? fields.decodeIfPresent(String.self, forKey: .pattern)
            patterns = (try? fields.decodeIfPresent([String].self, forKey: .patterns)) ?? single.map { [$0] } ?? []
            summary = try? fields.decodeIfPresent(String.self, forKey: .summary)
            requestKind = try? fields.decodeIfPresent(String.self, forKey: .requestKind)
            questions = type == "user_input_request"
                ? (try? fields.decodeIfPresent(LossyArray<Question>.self, forKey: .questions))?.elements ?? [] : []
            switch type {
            case "command_execution":
                toolPayload = .init(kind: "Shell", command: input)
                dynamicLabel = nil
            case "file_change":
                let paths = changes.map { change in
                    change.oldPath.map { "\($0) → \(change.path)" } ?? change.path
                }
                toolPayload = .init(kind: "File change", filePaths: paths.isEmpty ? fileName : paths.joined(separator: "\n"))
                dynamicLabel = nil
            case "dynamic_tool":
                let payload = try? fields.nestedContainer(keyedBy: ToolInputKeys.self, forKey: .input)
                let command = try? payload?.decodeIfPresent(String.self, forKey: .command)
                let path = [ToolInputKeys.file_path, .filePath, .path].lazy.compactMap { key in
                    try? payload?.decodeIfPresent(String.self, forKey: key)
                }.first
                toolPayload = .init(kind: toolName, command: command, filePaths: path)
                let others = [ToolInputKeys.pattern, .query, .url, .description, .prompt].lazy.compactMap { key in
                    try? payload?.decodeIfPresent(String.self, forKey: key)
                }.first
                dynamicLabel = command ?? path ?? others
            default:
                toolPayload = nil
                dynamicLabel = nil
            }
        }

        private var failed: Bool {
            status == "failed" || outputIndicatesFailure == true || (exitCode ?? 0) != 0
        }

        var entry: ConversationEntry? {
            guard let id, let timestamp = startedAt ?? updatedAt else { return nil }
            func make(_ kind: ConversationEntry.Kind, text: String, detail: ConversationDetail? = nil) -> ConversationEntry {
                var detail = detail
                detail?.endTimestamp = completedAt ?? updatedAt
                return .init(id: "activity:" + id, kind: kind, text: text, timestamp: timestamp, status: status,
                             streaming: streaming == true || status == "running", detail: detail)
            }
            switch type {
            case "assistant_message", "user_message":
                guard let messageId, let text else { return nil }
                return .init(id: "message:" + messageId, kind: type == "assistant_message" ? .assistant : .user,
                             text: text, timestamp: timestamp, streaming: streaming == true)
            case "reasoning":
                guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return make(.reasoning, text: text)
            case "command_execution":
                let command = input ?? title ?? "Command"
                return make(.tool, text: command, detail: .init(
                    tool: .command, title: command, output: output, exitCode: exitCode, failed: failed))
            case "file_change":
                let name = fileName ?? changes.first?.path ?? title ?? "File change"
                return make(.tool, text: name, detail: .init(
                    tool: .fileChange, title: name, additions: additions, deletions: deletions, diff: diffStr,
                    files: changes.map { .init(path: $0.path, oldPath: $0.oldPath, operation: $0.operation) },
                    failed: status == "failed"))
            case "file_search", "web_search":
                let query = patterns.joined(separator: ", ")
                let label = query.isEmpty ? (title ?? "Search") : query
                return make(.tool, text: label, detail: .init(
                    tool: type == "web_search" ? .web : .search, title: label, failed: status == "failed"))
            case "dynamic_tool":
                let name = toolName ?? title ?? "Tool"
                let label = dynamicLabel ?? Product.displayText(title ?? name)
                return make(.tool, text: label, detail: .init(
                    tool: ToolClassifier.classify(name), title: label, toolName: Product.displayText(name), failed: status == "failed"))
            case "proposed_plan":
                guard let markdown else { return nil }
                return make(.plan, text: markdown)
            case "todo_list":
                return make(.todo, text: text ?? "", detail: .init(
                    steps: steps.map { .init(text: $0.text, status: $0.status) }))
            case "error":
                return make(.error, text: Product.displayText(failureMessage ?? message ?? title ?? "Something went wrong"))
            case "system_notice", "run_interrupt_result", "run_interrupt_request":
                guard let message else { return nil }
                return make(.notice, text: Product.displayText(message))
            case "compaction":
                return make(.notice, text: Product.displayText(summary ?? "Context compacted"))
            case "approval_request":
                guard status != "waiting" else { return nil }
                let subject = prompt ?? reason ?? appName ?? title ?? "Request"
                return make(.approval, text: Product.displayText(subject), detail: .init(
                    title: requestKind ?? "", failed: status == "failed" || status == "cancelled"))
            case "checkpoint", "notification", "user_input_request", "fork", "handoff", "thread_created", "subagent",
                 "secret_request", "link_request":
                return nil
            default:
                let summary = input ?? fileName ?? Product.displayText(toolName ?? message ?? title ?? type.replacingOccurrences(of: "_", with: " ").capitalized)
                return make(.tool, text: String(summary.prefix(500)), detail: .init(title: String(summary.prefix(500))))
            }
        }
    }

    struct Checkpoint: Decodable {
        struct File: Decodable {
            let additions: Int
            let deletions: Int
        }
        struct Totals: Decodable {
            let count: Int
            let additions: Int
            let deletions: Int
        }
        let id: String
        let status: String
        let appRunOrdinal: Int?
        let capturedAt: String
        let files: [File]
        let filesTotal: Totals?

        var diff: SessionDiff {
            if let totals = filesTotal {
                return SessionDiff(files: totals.count, additions: totals.additions, deletions: totals.deletions)
            }
            return SessionDiff(files: files.count, additions: files.reduce(0) { $0 + $1.additions },
                               deletions: files.reduce(0) { $0 + $1.deletions })
        }
    }
}

extension T3Client {
    struct Projection {
        private(set) var hasShell = false
        private(set) var projects: [String: Project] = [:]
        private var active: [String: ThreadShell] = [:]
        private var archive: [String: ThreadShell] = [:]
        private var archiveSequence: Int?
        private var archiveChanges: [String: Int] = [:]
        private var activeRemovals: [String: Int] = [:]
        var needsArchiveRefresh: Bool { !activeRemovals.isEmpty }
        private var branches: [String: String] = [:]
        private(set) var details: [String: Detail] = [:]

        var threadIDs: Set<String> { Set(active.keys).union(archive.keys) }

        var approvalThreads: Set<String> {
            Set(threadIDs.filter(needsApprovalDetails))
        }

        func needsApprovalDetails(_ id: String) -> Bool {
            if let detail = details[id], !detail.advertised.isEmpty || !detail.advertisedInputs.isEmpty { return true }
            guard let request = shell(id)?.pendingRuntimeRequest else { return false }
            // A question's text lives only in the thread detail, so a pending one needs its subscription too.
            return request.isApproval || request.isUserInput
        }

        func branchPath(_ id: String) -> String? {
            guard let thread = shell(id)?.thread, thread.branch == nil else { return nil }
            return thread.worktreePath ?? projects[thread.projectId]?.workspaceRoot
        }

        mutating func updateBranch(_ name: String?, at path: String) -> [AppEvent] {
            guard branches[path] != name else { return [] }
            branches[path] = name
            return threadIDs.filter { branchPath($0) == path }.sorted().flatMap(sessionEvent)
        }

        mutating func apply(_ item: StreamItem, detailThreadID: String? = nil) -> [AppEvent] {
            switch item {
            case .shellSnapshot(let snapshot, let enrichment):
                if enrichment {
                    for project in snapshot.projects { projects[project.id] = project }
                    return [projectsEvent] + snapshot.projects.flatMap { refreshProject($0.id) }
                }
                hasShell = true
                projects = Dictionary(snapshot.projects.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                active = Dictionary(snapshot.threads.map { ($0.thread.id, $0) }, uniquingKeysWith: { _, last in last })
                for thread in snapshot.archivedThreads ?? [] { archive[thread.thread.id] = thread }
                let sortedIDs = threadIDs.sorted {
                    (shell($0)?.thread.updatedAt ?? "", $0) > (shell($1)?.thread.updatedAt ?? "", $1)
                }
                return [projectsEvent, .sessionsResynced(sortedIDs.compactMap(summary)), .connectionChanged(.connected)]
            case .projectUpdated(let project):
                projects[project.id] = project
                return [projectsEvent] + refreshProject(project.id)
            case .projectRemoved(let id):
                projects.removeValue(forKey: id)
                return [projectsEvent] + refreshProject(id)
            case .threadUpdated(let thread, let archived, let sequence):
                let id = thread.thread.id
                if archived {
                    guard noteArchiveChange(id, sequence: sequence) else { return [] }
                    archive[id] = thread
                } else {
                    activeRemovals.removeValue(forKey: id)
                    active[id] = thread
                    if noteArchiveChange(id, sequence: sequence) { archive.removeValue(forKey: id) }
                }
                return sessionEvent(id)
            case .threadRemoved(let id, let archived, let sequence):
                if archived {
                    guard noteArchiveChange(id, sequence: sequence) else { return [] }
                    archive.removeValue(forKey: id)
                } else {
                    // v0.1.9 emits an active removal for both moving to Archive and deleting.
                    activeRemovals[id] = sequence
                    return []
                }
                if shell(id) != nil { return sessionEvent(id) }
                details.removeValue(forKey: id)
                return [.sessionRemoved(sessionId: id)]
            case .detailSnapshot(let snapshot):
                let id = snapshot.thread.id
                guard detailThreadID == nil || detailThreadID == id else { return [] }
                let previous = details[id]?.advertised ?? [:]
                let previousInputs = details[id]?.advertisedInputs ?? [:]
                details[id] = Detail(snapshot)
                let removed = previous.keys.filter { details[id]?.pending[$0] == nil }
                let removedInputs = previousInputs.keys.filter { details[id]?.pendingInputs[$0] == nil }
                let entries = details[id]?.conversation.entries ?? []
                return [.conversationSnapshot(sessionID: id, entries: entries)] + sessionEvent(id)
                    + removed.map { .approvalWithdrawn(requestId: $0) }
                    + removedInputs.map { .userInputWithdrawn(requestId: $0) }
                    + refreshApprovals(id) + refreshUserInputs(id)
            case .detailEvent(let event):
                guard let id = detailThreadID, details[id] != nil else { return [] }
                switch event {
                case .request(let request):
                    if request.isUserInput {
                        if request.canAnswer {
                            details[id]?.pendingInputs[request.id] = request
                            return refreshUserInputs(id)
                        }
                        return withdrawUserInput(request.id, threadID: id, resolved: request.status == "resolved")
                    }
                    if request.canRespond {
                        details[id]?.pending[request.id] = request
                        return refreshApprovals(id)
                    }
                    return withdrawApproval(request.id, threadID: id, decision: request.approvalDecision)
                case .message(let message):
                    return updateConversation(message.entry, id: id)
                case .item(let item):
                    if item.type == "user_input_request", let requestID = item.requestId {
                        if details[id]?.pendingInputs[requestID] != nil { details[id]?.inputItems[requestID] = item }
                        return refreshUserInputs(id)
                    }
                    if item.type == "approval_request", let requestID = item.requestId {
                        if item.status == "waiting" { details[id]?.approvalItems[requestID] = item }
                        return (item.entry.map { updateConversation($0, id: id) } ?? []) + refreshApprovals(id)
                    }
                    var updates = item.entry.map { updateConversation($0, id: id) } ?? []
                    if let key = item.toolKey, let payload = item.toolPayload {
                        details[id]?.approvalTools[key] = payload
                        if details[id]?.pending.values.contains(where: { $0.toolKey == key }) == true {
                            updates += refreshApprovals(id)
                        }
                    }
                    return updates
                case .checkpoint(let checkpoint):
                    details[id]?.updateDiff(checkpoint)
                    return sessionEvent(id)
                case .run(let run):
                    // The shell is authoritative when available. Detail-only captures still
                    // carry enough information to replay run transitions.
                    guard shell(id) == nil,
                          run.ordinal >= details[id]?.latestRun?.ordinal ?? 0 else { return [] }
                    details[id]?.latestRun = run
                    return sessionEvent(id)
                case .thread(let thread):
                    guard thread.id == id else { return [] }
                    if active[id] != nil { active[id]?.thread.settledOverride = thread.settledOverride }
                    if archive[id] != nil { archive[id]?.thread.settledOverride = thread.settledOverride }
                    details[id]?.thread = thread
                    return sessionEvent(id) + refreshApprovals(id)
                case .ignored:
                    return []
                }
            case .branch, .gitProgress, .ignored:
                return []
            }
        }

        private mutating func updateConversation(_ entry: ConversationEntry, id: String) -> [AppEvent] {
            details[id]?.conversation.upsert(entry)
            return [.conversationEntry(sessionID: id, entry: entry)]
        }

        mutating func applyArchive(_ snapshot: ShellSnapshot) -> [AppEvent] {
            let sequence = snapshot.snapshotSequence
            archiveSequence = sequence
            let previousIDs = Set(archive.keys)
            let refreshed = Dictionary(snapshot.threads.map { ($0.thread.id, $0) }, uniquingKeysWith: { _, last in last })
            for id in previousIDs.union(refreshed.keys) where archiveChanges[id, default: -1] <= sequence {
                archive[id] = refreshed[id]
            }
            archiveChanges = archiveChanges.filter { $0.value > sequence }

            let settledRemovals = activeRemovals.filter { $0.value <= sequence }.keys
            for id in settledRemovals {
                activeRemovals.removeValue(forKey: id)
                active.removeValue(forKey: id)
            }
            guard hasShell else { return [] }
            let affected = previousIDs.union(archive.keys).union(settledRemovals)
            return affected.sorted().flatMap { id -> [AppEvent] in
                if shell(id) != nil { return sessionEvent(id) }
                details.removeValue(forKey: id)
                return [.sessionRemoved(sessionId: id)]
            }
        }

        mutating func withdrawApproval(
            _ requestID: String, threadID: String, decision: ApprovalDecision? = nil
        ) -> [AppEvent] {
            details[threadID]?.pending.removeValue(forKey: requestID)
            details[threadID]?.approvalItems.removeValue(forKey: requestID)
            guard details[threadID]?.advertised.removeValue(forKey: requestID) != nil else { return [] }
            if let decision { return [.approvalResolved(requestId: requestID, decision: decision)] }
            return [.approvalWithdrawn(requestId: requestID)]
        }

        mutating func withdrawUserInput(_ requestID: String, threadID: String, resolved: Bool = false) -> [AppEvent] {
            details[threadID]?.pendingInputs.removeValue(forKey: requestID)
            details[threadID]?.inputItems.removeValue(forKey: requestID)
            guard details[threadID]?.advertisedInputs.removeValue(forKey: requestID) != nil else { return [] }
            return [resolved ? .userInputResolved(requestId: requestID) : .userInputWithdrawn(requestId: requestID)]
        }

        mutating func dropDetail(_ id: String) -> [AppEvent] {
            guard let detail = details.removeValue(forKey: id) else { return [] }
            var events = detail.advertised.keys.map { AppEvent.approvalWithdrawn(requestId: $0) }
            events += detail.advertisedInputs.keys.map { AppEvent.userInputWithdrawn(requestId: $0) }
            // The panel will refresh the summary on its next detail subscription.
            if detail.latestCheckpoint != nil { events += sessionEvent(id) }
            return events
        }

        func activeThread(_ id: String) -> Thread? { active[id]?.thread }

        private func shell(_ id: String) -> ThreadShell? { active[id] ?? archive[id] }

        private mutating func noteArchiveChange(_ id: String, sequence: Int) -> Bool {
            guard sequence > archiveSequence ?? -1, sequence >= archiveChanges[id, default: -1] else { return false }
            archiveChanges[id] = sequence
            return true
        }

        private var projectsEvent: AppEvent {
            .projectsUpdated(projects.values.filter { $0.archivedAt == nil }
                .map { ThreadProject(id: $0.id, name: Product.displayText($0.title)) }
                .sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) })
        }

        private func refreshProject(_ id: String) -> [AppEvent] {
            threadIDs.filter { shell($0)?.thread.projectId == id }.sorted().flatMap(sessionEvent)
        }

        private func sessionEvent(_ id: String) -> [AppEvent] {
            summary(id).map { [.sessionUpdated($0)] } ?? []
        }

        private func summary(_ id: String) -> SessionSummary? {
            let shell = shell(id)
            let detail = details[id]
            guard let thread = shell?.thread ?? detail?.thread, thread.isListed else { return nil }
            let wireStatus = shell?.activityRunStatus ?? shell?.status ?? detail?.latestRun?.status ?? "idle"
            let status: SessionSummary.Status = switch wireStatus {
            case "preparing", "queued", "starting", "running", "waiting": .running
            case "completed": .completed
            case "interrupted", "cancelled", "rolled_back": .interrupted
            case "failed": .failed
            default: .idle
            }
            var session = SessionSummary(id: id, title: Product.displayText(thread.title),
                                         providerInstanceId: thread.providerInstanceId, status: status)
            let project = projects[thread.projectId]
            session.lastActivity = thread.lastActivity
            session.updatedAt = thread.updateDate
            session.isSettled = thread.settledOverride == "settled"
            session.projectID = thread.projectId
            session.modelSelection = thread.modelSelection
            session.isArchived = active[id] == nil && archive[id] != nil
            session.project = project.map { Product.displayText($0.title) }
            session.repository = project.map { Product.displayText($0.repositoryName) }
            session.branch = thread.branch ?? branchPath(id).flatMap { branches[$0] }
            session.workspacePath = thread.worktreePath ?? project?.workspaceRoot
            if let checkpoint = detail?.latestCheckpoint, checkpoint.status == "ready" {
                session.diff = checkpoint.diff
            }
            session.pendingRuntimeRequest = shell?.pendingRuntimeRequest.map {
                .init(id: $0.id, kind: $0.kind, isApproval: $0.isApproval, isUserInput: $0.isUserInput)
            }
            session.latestTurnEndedAt = shell?.latestRunCompletedAt.flatMap(Thread.date)
            if status == .failed { session.error = shell?.lastError.map(Product.displayText) }
            return session
        }

        /// Advertises each live question once its turn item (which carries the question text) has arrived.
        private mutating func refreshUserInputs(_ id: String) -> [AppEvent] {
            guard var detail = details[id] else { return [] }
            let title = shell(id)?.thread.title ?? detail.thread.title
            var updates: [AppEvent] = []
            for pending in detail.pendingInputs.values.sorted(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }) {
                guard let questions = detail.inputItems[pending.id]?.questions.map(\.model), !questions.isEmpty else { continue }
                let request = UserInputRequest(id: pending.id, threadId: id, sessionName: Product.displayText(title),
                                               questions: questions)
                if detail.advertisedInputs[pending.id] != request {
                    detail.advertisedInputs[pending.id] = request
                    updates.append(.userInputRequested(request))
                }
            }
            details[id] = detail
            return updates
        }

        private mutating func refreshApprovals(_ id: String) -> [AppEvent] {
            guard var detail = details[id] else { return [] }
            let title = shell(id)?.thread.title ?? detail.thread.title
            var updates: [AppEvent] = []
            for pending in detail.pending.values.sorted(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }) {
                let item = detail.approvalItems[pending.id]
                let payload = (item?.toolKey ?? pending.toolKey).flatMap { detail.approvalTools[$0] }
                let action = (pending.kind == "mcp-elicitation" ? item?.appName : payload?.text(for: pending.kind))
                    .flatMap { $0.isEmpty ? nil : $0 }
                // T3 can put a provider explanation in prompt. Only the matched tool item
                // supplies the command or paths in that case.
                let context = [item?.reason, item?.title, item?.prompt].compactMap { $0 }
                    .first { !$0.isEmpty && $0 != action }
                let request = ApprovalRequest(
                    id: pending.id, threadId: id, sessionName: Product.displayText(title),
                    toolName: Product.displayText(payload?.kind ?? pending.tool),
                    command: action ?? (pending.requiresToolPayload ? "Tool details unavailable. Review in the desktop app." : ""),
                    context: context.map(Product.displayText), canApprove: !pending.requiresToolPayload || action != nil
                )
                if detail.advertised[pending.id] != request {
                    detail.advertised[pending.id] = request
                    updates.append(.approvalRequested(request))
                }
            }
            details[id] = detail
            return updates
        }
    }

    struct Detail {
        var thread: Thread
        var latestRun: Run?
        var latestCheckpoint: Checkpoint?
        var pending: [String: RuntimeRequest]
        var approvalItems: [String: TurnItem]
        var approvalTools: [ApprovalToolKey: TurnItem.ToolPayload]
        var conversation: ThreadConversation
        var advertised: [String: ApprovalRequest] = [:]
        var pendingInputs: [String: RuntimeRequest]
        var inputItems: [String: TurnItem]
        var advertisedInputs: [String: UserInputRequest] = [:]

        init(_ snapshot: ThreadProjection) {
            thread = snapshot.thread
            conversation = ThreadConversation(snapshot.turnItems.compactMap(\.entry) + (snapshot.messages ?? []).map(\.entry))
            latestRun = snapshot.runs.max { $0.ordinal < $1.ordinal }
            let actionable = snapshot.runtimeRequests.filter(\.canRespond)
            pending = Dictionary(actionable.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            let ids = Set(pending.keys)
            approvalItems = Dictionary(snapshot.turnItems.compactMap { item in
                guard item.type == "approval_request", let id = item.requestId, ids.contains(id) else { return nil }
                return (id, item)
            }, uniquingKeysWith: { _, last in last })
            let answerable = Dictionary(snapshot.runtimeRequests.filter(\.canAnswer).map { ($0.id, $0) },
                                        uniquingKeysWith: { _, last in last })
            pendingInputs = answerable
            inputItems = Dictionary(snapshot.turnItems.compactMap { item in
                guard item.type == "user_input_request", let id = item.requestId, answerable[id] != nil else { return nil }
                return (id, item)
            }, uniquingKeysWith: { _, last in last })
            approvalTools = Dictionary(snapshot.turnItems.compactMap { item in
                guard let key = item.toolKey, let payload = item.toolPayload else { return nil }
                return (key, payload)
            }, uniquingKeysWith: { _, last in last })
            for checkpoint in snapshot.checkpoints { updateDiff(checkpoint) }
        }

        mutating func updateDiff(_ checkpoint: Checkpoint) {
            guard checkpoint.appRunOrdinal != nil else { return }
            if latestCheckpoint?.id == checkpoint.id || checkpoint.capturedAt >= latestCheckpoint?.capturedAt ?? "" {
                latestCheckpoint = checkpoint
            }
        }
    }
}

extension T3Client: SettingsBackend {
    private func settingsConfig() async throws -> ResultValue {
        guard let result = try await requireConnection().call("server.getConfig", Empty()),
              result.providers != nil, result.settings != nil else { throw ClientError.invalidProviderCatalog }
        return result
    }

    public func workspaceSettings() async throws -> WorkspaceSettings {
        try Self.workspaceSettings(from: try await settingsConfig())
    }

    public func settingsAndProviders() async throws -> (settings: ServerSettings, workspace: WorkspaceSettings) {
        let result = try await settingsConfig()
        return (ServerSettings(values: result.rawSettings ?? [:]), try Self.workspaceSettings(from: result))
    }

    nonisolated static func workspaceSettings(from result: ResultValue) throws -> WorkspaceSettings {
        guard let snapshots = result.providers else { throw ClientError.invalidProviderCatalog }
        let providers = snapshots.elements.map { p in
            var settings = ProviderSettings(id: p.instanceId, name: Product.displayText(p.displayName ?? p.driver), driver: p.driver,
                enabled: p.enabled,
                installed: p.installed, auth: p.auth?.status ?? "unknown",
                models: p.models.elements.map { .init(id: $0.slug, name: Product.displayText($0.name),
                    options: $0.capabilities?.optionDescriptors?.elements ?? []) },
                defaultModel: p.models.elements.first { $0.isDefault == true }?.slug,
                canInstall: p.setup?.canInstall == true, documentationURL: p.setup?.documentationUrl)
            let raw = result.settings?.rawInstances?[p.instanceId]
            settings.displayName = p.displayName
            settings.accentColor = p.accentColor ?? { if case .string(let c) = raw?["accentColor"] { return c } else { return nil } }()
            settings.version = p.version.map(Product.displayText)
            settings.latestVersion = p.versionAdvisory?.latestVersion.map(Product.displayText)
            settings.updateAvailable = p.versionAdvisory?.status == "behind_latest"
            settings.canUpdate = p.versionAdvisory?.canUpdate == true
            settings.updateStatus = p.updateState?.status
            settings.updateMessage = p.updateState?.message.map(Product.displayText)
            settings.authType = p.auth?.type.map(Product.displayText)
            settings.authLabel = p.auth?.label.map(Product.displayText)
            settings.authEmail = p.auth?.email
            settings.checkedAt = p.checkedAt.flatMap(TimelineFormat.date)
            settings.statusMessage = p.message.map(Product.displayText)
            settings.usage = p.usageLimits
            settings.homePath = p.runtimePaths?.homePath
            settings.shadowHomePath = p.runtimePaths?.shadowHomePath
            settings.sdk = result.providerSDKs.first { $0.driver == p.driver }
            if case .object(let config) = raw?["config"] { settings.config = config }
            return settings
        }
        return .init(providers: providers, selection: result.settings?.defaultModelSelection)
    }

    public func updateProvider(id: String, enabled: Bool, apiKey: String?) async throws {
        guard updatingProviders.insert(id).inserted else { throw SettingsChangeError.busy }
        defer { updatingProviders.remove(id) }
        let result = try await settingsConfig()
        guard let provider = result.providers?.elements.first(where: { $0.instanceId == id }) else {
            throw ClientError.invalidProviderCatalog
        }
        let mutation = try Self.providerMutation(id: id, driver: provider.driver,
            existing: result.settings?.rawInstances?[id], enabled: enabled, apiKey: apiKey)
        do {
            try await requireConnection().call("server.updateSettings", ["patch": WireValue.object([:]), "providerInstanceMutation": mutation])
            emit(.settingsChanged)
        } catch {
            if apiKey != nil { throw SettingsChangeError.secret }
            throw error
        }
    }

    nonisolated static func providerMutation(id: String, driver: String, existing: [String: WireValue]?,
                                 enabled: Bool, apiKey: String?) throws -> WireValue {
        var instance = existing ?? ["driver": .string(driver)]
        instance["enabled"] = .bool(enabled)
        var config: [String: WireValue] = [:]
        if case .object(let previous) = instance["config"] { config = previous }
        config["enabled"] = .bool(enabled)
        if let apiKey {
            guard !apiKey.isEmpty else { throw ClientError.authentication }
            if driver == "antigravity" {
                config["apiKey"] = .string(apiKey)
                config["authMethod"] = .string("gemini-api-key")
            } else if let name = ProviderSettings.secretVariable(for: driver) {
                var rows: [WireValue] = []
                if case .array(let previous) = instance["environment"] {
                    rows = previous.filter { row in
                        guard case .object(let fields) = row, case .string(let key) = fields["name"] else { return true }
                        return key != name
                    }
                }
                rows.append(.object(["name": .string(name), "sensitive": .bool(true), "value": .string(apiKey)]))
                instance["environment"] = .array(rows)
            } else { throw ClientError.invalidProviderCatalog }
        }
        instance["config"] = .object(config)
        return .object(["operation": .string("upsert"), "instanceId": .string(id), "instance": .object(instance)])
    }

    public func installProviderSDK(id: String, sdk: ProviderSDK) async throws {
        try await requireConnection().call("provider.sdk.install",
            ["instanceId": id, "driver": sdk.driver, "version": sdk.version], timeout: .seconds(110))
        emit(.settingsChanged)
    }

    public func installProvider(id: String) async throws {
        try await requireConnection().call("provider.install.start", ["instanceId": id])
    }

    public func refreshProvider(id: String) async throws {
        try await requireConnection().call("server.refreshProviders", ["instanceId": WireValue.string(id), "fresh": .bool(true), "refreshModels": .bool(true)])
    }

    public func setDefaultModel(_ selection: ThreadModelSelection) async throws {
        try await requireConnection().call("server.updateSettings", ["patch": ["defaultModelSelection": selection]])
        emit(.settingsChanged)
    }

    public func serverSettings() async throws -> ServerSettings {
        ServerSettings(values: try await settingsConfig().rawSettings ?? [:])
    }

    public func updateServerSettings(_ patch: [String: WireValue]) async throws {
        try await requireConnection().call("server.updateSettings", ["patch": WireValue.object(patch)])
        emit(.settingsChanged)
    }

    public func refreshProviders(instanceID: String?) async throws {
        var payload: [String: WireValue] = ["fresh": .bool(true), "refreshModels": .bool(true)]
        if let instanceID { payload["instanceId"] = .string(instanceID) }
        try await requireConnection().call("server.refreshProviders", payload)
    }

    public func updateProviderVersion(driver: String, instanceID: String?) async throws {
        var payload: [String: String] = ["provider": driver]
        if let instanceID { payload["instanceId"] = instanceID }
        try await requireConnection().call("server.updateProvider", payload)
    }

    public func saveProviderFields(id: String, displayName: String??, config: [String: String?]) async throws {
        guard updatingProviders.insert(id).inserted else { throw SettingsChangeError.busy }
        defer { updatingProviders.remove(id) }
        let result = try await settingsConfig()
        guard var instance = result.settings?.rawInstances?[id] else { throw ClientError.invalidProviderCatalog }
        if let displayName {
            if let name = displayName, !name.isEmpty { instance["displayName"] = .string(name) }
            else { instance.removeValue(forKey: "displayName") }
        }
        var fields: [String: WireValue] = [:]
        if case .object(let previous) = instance["config"] { fields = previous }
        for (key, value) in config {
            if let value, !value.isEmpty { fields[key] = .string(value) } else { fields.removeValue(forKey: key) }
        }
        instance["config"] = .object(fields)
        let mutation = WireValue.object(["operation": .string("upsert"), "instanceId": .string(id), "instance": .object(instance)])
        try await requireConnection().call("server.updateSettings", ["patch": WireValue.object([:]), "providerInstanceMutation": mutation])
        emit(.settingsChanged)
    }

    public func addProvider(driver: String, displayName: String) async throws -> String {
        let existing = Set(try await settingsConfig().settings?.rawInstances?.keys.map { $0 } ?? [])
        let slug = displayName.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        var id = slug.isEmpty ? driver : "\(driver)_\(slug)"
        var suffix = 2
        while existing.contains(id) { id = "\(driver)_\(slug.isEmpty ? "extra" : slug)_\(suffix)"; suffix += 1 }
        let instance: [String: WireValue] = ["driver": .string(driver), "displayName": .string(displayName), "enabled": .bool(true)]
        let mutation = WireValue.object(["operation": .string("create"), "instanceId": .string(id), "instance": .object(instance)])
        try await requireConnection().call("server.updateSettings", ["patch": WireValue.object([:]), "providerInstanceMutation": mutation])
        emit(.settingsChanged)
        return id
    }

    public func usageSummary(days: Int) async throws -> UsageSummary {
        let calendar = Calendar.current
        let until = Date()
        let since = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: until) ?? until
        let format = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
            .dateSeparator(.dash)
        let payload: [String: String] = [
            "sinceDay": since.formatted(format), "untilDay": until.formatted(format),
            "timeZone": TimeZone.current.identifier
        ]
        guard let summary = try await requireConnection().call("server.getUsageSummary", payload)?.usageSummary else {
            throw ClientError.invalidProviderCatalog
        }
        return summary
    }

    public func refreshUsageRates() async throws {
        try await requireConnection().call("server.refreshUsageRates", Empty())
    }

    @discardableResult
    public func addProject(folder: URL) async throws -> String {
        let connection = try requireConnection()
        let directory = folder.standardizedFileURL
        let canonical = directory.resolvingSymlinksInPath()
        if let existing = projection.projects.values.first(where: {
            $0.archivedAt == nil && URL(filePath: $0.workspaceRoot).resolvingSymlinksInPath().path == canonical.path
        }) {
            return existing.id
        }
        let id = UUID().uuidString
        let result = try await connection.call("projects.mutate", ["type": "project.create", "commandId": UUID().uuidString,
            "projectId": id, "title": directory.lastPathComponent, "workspaceRoot": canonical.path])
        guard let project = result?.project, project.id == id else { throw ClientError.protocolMismatch }
        guard self.connection === connection else { throw ClientError.disconnected }
        if projection.projects[id] == nil {
            projection.apply(.projectUpdated(project)).forEach(emit)
        }
        return id
    }

    public func removeProject(id: String) async throws {
        try await requireConnection().call("projects.mutate", ["type": "project.delete", "commandId": UUID().uuidString, "projectId": id])
    }
}
