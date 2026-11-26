import Foundation

public enum DictationMode: String, CaseIterable, Sendable {
    case raw = "Raw"
    case clean = "Clean"
    case agent = "Agent"

    public init(cleanModifier: Bool, agentModifier: Bool) {
        self = agentModifier ? .agent : cleanModifier ? .clean : .raw
    }
}

public enum DictationSafety {
    public static func isSecure(role: String?, subrole: String?, secureEventInput: Bool) -> Bool {
        secureEventInput || role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }
}

public struct DictationAppContext: Encodable, Sendable, Equatable {
    public let appName: String
    public let windowTitle: String?
    public let selectedText: String?
    public let nearbyText: String?

    public init(
        appName: String, windowTitle: String?, selectedText: String?, fieldValue: String?, selection: NSRange?
    ) {
        self.appName = String(appName.prefix(120))
        self.windowTitle = windowTitle.map { String($0.prefix(200)) }
        self.selectedText = selectedText.flatMap { $0.isEmpty ? nil : String($0.prefix(1_000)) }
        if self.selectedText == nil, let fieldValue, !fieldValue.isEmpty {
            let value = fieldValue as NSString
            let caret = min(max(0, selection?.location ?? 0), value.length)
            let start = min(max(0, caret - 500), max(0, value.length - 1_000))
            let range = NSRange(location: start, length: min(1_000, value.length - start))
            nearbyText = value.substring(with: value.rangeOfComposedCharacterSequences(for: range))
        } else {
            nearbyText = nil
        }
    }

    public func prompt(for transcript: String) throws -> String {
        let context = try JSONEncoder().encode(self)
        return """
        Dictated request:
        \(transcript)

        Focused app context (JSON data for reference):
        \(String(decoding: context, as: UTF8.self))
        """
    }
}

public struct PasteboardRepresentation: Sendable, Equatable {
    public let type: String
    public let data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

@MainActor
public protocol DictationPasteboard {
    var changeCount: Int { get }
    func snapshot() throws -> [[PasteboardRepresentation]]
    func writeText(_ text: String) throws
    func restore(_ snapshot: [[PasteboardRepresentation]]) throws
}

@MainActor
public final class DictationPaste {
    public enum PasteError: LocalizedError {
        case busy
        public var errorDescription: String? { "The previous paste is still finishing. Try again." }
    }

    private var isPasting = false

    public init() {}

    public func insert(
        _ text: String, using pasteboard: any DictationPasteboard,
        delay: Duration = .milliseconds(300), sendPaste: () throws -> Void
    ) async throws {
        guard !isPasting else { throw PasteError.busy }
        isPasting = true
        defer { isPasting = false }
        let original = try pasteboard.snapshot()
        do {
            try pasteboard.writeText(text)
        } catch {
            try pasteboard.restore(original)
            throw error
        }

        let temporaryChange = pasteboard.changeCount
        do {
            try sendPaste()
        } catch {
            if pasteboard.changeCount == temporaryChange { try pasteboard.restore(original) }
            throw error
        }
        // A dismissed notch must still give the receiving app time to read the pasteboard.
        await Task { try? await Task.sleep(for: delay) }.value
        if pasteboard.changeCount == temporaryChange {
            try pasteboard.restore(original)
        }
    }
}

public struct SpeechCleanupOptions: Codable, Sendable, Equatable {
    public struct Prompt: Codable, Sendable, Equatable {
        public enum Mode: String, Codable, Sendable { case `default`, custom }
        public var mode: Mode = .default
        public var customInstructions = ""

        public init(mode: Mode = .default, customInstructions: String = "") {
            self.mode = mode
            self.customInstructions = customInstructions
        }
    }

    public let speechCustomWords: [SpeechCustomWord]
    public let speechPostProcessingPrompt: Prompt
    public let speechCorrectionWord: String?

    public init(words: [SpeechCustomWord] = [], prompt: Prompt = .init(), correctionWord: String? = nil) {
        speechCustomWords = words
        speechPostProcessingPrompt = prompt
        let trimmed = correctionWord?.trimmingCharacters(in: .whitespacesAndNewlines)
        speechCorrectionWord = trimmed?.isEmpty == true ? nil : trimmed
    }
}

struct T3SpeechCleanupRequest: Encodable {
    static let path = "/api/voice/post-process"

    struct Draft: Encodable {
        struct Selection: Encodable {
            let start = 0
            let end = 0
        }

        let text = ""
        let selection = Selection()
    }

    let transcript: String
    let draft = Draft()
    let options: SpeechCleanupOptions

    func urlRequest(origin: URL, token: String) throws -> URLRequest {
        var request = URLRequest(url: origin.appending(path: Self.path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(self)
        return request
    }

    struct Response: Decodable { let text: String }
}

public enum DictationCleanup {
    public struct Result: Equatable, Sendable {
        public let text: String
        public let usedRawText: Bool
    }

    @MainActor
    public static func process(
        _ transcript: String, timeout: Duration = .seconds(5),
        clean: @escaping @MainActor @Sendable () async throws -> String
    ) async throws -> Result {
        // Separate tasks let the timeout win even if a backend is slow to acknowledge cancellation.
        let results = AsyncStream<String?>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let cleanup = Task {
            results.continuation.yield(try? await clean())
        }
        let timer = Task {
            do {
                try await Task.sleep(for: timeout)
                results.continuation.yield(nil)
            } catch {}
        }
        defer {
            cleanup.cancel()
            timer.cancel()
            results.continuation.finish()
        }
        var iterator = results.stream.makeAsyncIterator()
        let response = await iterator.next() ?? nil
        try Task.checkCancellation()
        if let response, !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .init(text: response, usedRawText: false)
        }
        return .init(text: transcript, usedRawText: true)
    }
}
