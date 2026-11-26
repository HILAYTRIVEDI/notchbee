import Foundation

@MainActor
public protocol AgentBackend: AnyObject {
    func startSession(title: String, providerInstanceId: String, model: String) async throws -> String
    func startSession(title: String, inProjectOf sessionId: String?, prompt: String) async throws
    func sendPrompt(sessionId: String, text: String) async throws
    func cleanTranscript(_ transcript: String, options: SpeechCleanupOptions) async throws -> String
    func runDictationPrompt(_ prompt: String, target: DictationAgentTarget) async throws -> String
    func approve(requestId: String, threadId: String) async throws
    func deny(requestId: String, threadId: String) async throws
    func answerUserInput(requestId: String, threadId: String, answers: [String: UserInputAnswer]) async throws
    func dismissUserInput(requestId: String, threadId: String) async throws
    func launchThread(_ request: ThreadLaunch) async throws -> String
    func providerCatalog(projectID: String?) async throws -> ThreadProviderCatalog
    func mutateThread(sessionID: String, mutation: ThreadMutation) async throws
    func eventStream() -> AsyncStream<AppEvent>
    func setSessionDetailsVisible(_ visible: Bool, sessionId: String)
}

public extension AgentBackend {
    func setSessionDetailsVisible(_ visible: Bool, sessionId: String) {}
}

public enum DictationAgentTarget: Sendable {
    case existing(threadID: String)
    case new(inProjectOf: String)
    case newInProject(String)
}

enum DictationBackendError: LocalizedError {
    case unavailable, noReply, runFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: "Dictation is unavailable on this connection."
        case .noReply: "The run finished without a text reply."
        case .runFailed: "The run ended before producing a reply."
        }
    }
}

public extension AgentBackend {
    func answerUserInput(requestId: String, threadId: String, answers: [String: UserInputAnswer]) async throws {
        throw DictationBackendError.unavailable
    }
    func dismissUserInput(requestId: String, threadId: String) async throws {
        throw DictationBackendError.unavailable
    }
    func cleanTranscript(_ transcript: String, options: SpeechCleanupOptions) async throws -> String {
        throw DictationBackendError.unavailable
    }
    func runDictationPrompt(_ prompt: String, target: DictationAgentTarget) async throws -> String {
        throw DictationBackendError.unavailable
    }
}
