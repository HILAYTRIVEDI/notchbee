import Foundation
import Testing
@testable import NotchpilotCore

struct AnywhereDictationTests {
    @Test(arguments: [
        (false, false, DictationMode.raw), (true, false, .clean), (false, true, .agent)
    ])
    func selectsMode(clean: Bool, agent: Bool, expected: DictationMode) {
        #expect(DictationMode(cleanModifier: clean, agentModifier: agent) == expected)
    }

    @Test func detectsSecureRoleSubroleAndKeyboardEntry() {
        #expect(DictationSafety.isSecure(role: "AXSecureTextField", subrole: nil, secureEventInput: false))
        #expect(DictationSafety.isSecure(role: "AXTextField", subrole: "AXSecureTextField", secureEventInput: false))
        #expect(DictationSafety.isSecure(role: nil, subrole: nil, secureEventInput: true))
        #expect(!DictationSafety.isSecure(role: "AXTextField", subrole: nil, secureEventInput: false))
    }

    @Test func limitsContextAndPrefersTheSelection() {
        let title = String(repeating: "T", count: 900)
        let field = String(repeating: "a", count: 1_200) + "✈️" + String(repeating: "b", count: 1_200)
        let selection = NSRange(location: 1_201, length: 0)
        let selected = DictationAppContext(
            appName: title, windowTitle: title, selectedText: title + title,
            fieldValue: field, selection: selection
        )
        #expect(selected.appName.count == 120)
        #expect(selected.windowTitle?.count == 200)
        #expect(selected.selectedText?.count == 1_000)
        #expect(selected.nearbyText == nil)
        let nearby = DictationAppContext(
            appName: "Notes", windowTitle: nil, selectedText: "", fieldValue: field, selection: selection
        )
        #expect(nearby.nearbyText?.contains("✈️") == true)
        #expect(nearby.nearbyText?.utf16.count == 1_000)
    }

    @Test @MainActor func restoresEveryItemAndTypeAfterPaste() async throws {
        let pasteboard = FakePasteboard()
        let saved = pasteboard.items
        try await DictationPaste().insert("dictated", using: pasteboard, delay: .zero) {
            #expect(pasteboard.items == [[.init(type: "public.utf8-plain-text", data: Data("dictated".utf8))]])
        }
        #expect(pasteboard.items == saved)
    }

    @Test @MainActor func preservesNewClipboardContentsDuringPaste() async throws {
        let pasteboard = FakePasteboard()
        let concurrentCopy = [[PasteboardRepresentation(type: "public.utf8-plain-text", data: Data("copy".utf8))]]
        try await DictationPaste().insert("dictated", using: pasteboard, delay: .zero) {
            pasteboard.replace(with: concurrentCopy)
        }
        #expect(pasteboard.items == concurrentCopy)
    }

    @Test @MainActor func restoresClipboardWhenPasteEventThrows() async {
        let pasteboard = FakePasteboard()
        let saved = pasteboard.items
        await #expect(throws: TestError.self) {
            try await DictationPaste().insert("dictated", using: pasteboard, delay: .zero) {
                throw TestError.failed
            }
        }
        #expect(pasteboard.items == saved)
    }

    @Test @MainActor func cleanupFallsBackOnFailureOrEmptyText() async throws {
        let failed = try await DictationCleanup.process("raw words") { throw TestError.failed }
        let empty = try await DictationCleanup.process("raw words") { " " }
        #expect(failed == .init(text: "raw words", usedRawText: true))
        #expect(empty == failed)
        let cleaned = try await DictationCleanup.process("raw words") { "Cleaned." }
        #expect(cleaned == .init(text: "Cleaned.", usedRawText: false))
    }

    @Test @MainActor func cleanupReturnsOnTimeoutBeforeUncooperativeBackendFinishes() async throws {
        let delayed = AsyncStream<Void>.makeStream()
        defer { delayed.continuation.finish() }
        let result = try await DictationCleanup.process("raw words", timeout: .milliseconds(20)) {
            await Task { for await _ in delayed.stream {} }.value
            return "Too late"
        }
        #expect(result == .init(text: "raw words", usedRawText: true))
    }

    @Test func encodesTheT3TextCleanupRequest() throws {
        let payload = T3SpeechCleanupRequest(transcript: "test transcript", options: .init(
            words: [.init(term: "Notchbee", aliases: ["notch bee"])],
            prompt: .init(mode: .custom, customInstructions: "Use short sentences."),
            correctionWord: "scratch that"))
        let origin = try #require(URL(string: "http://127.0.0.1:3773"))
        let request = try payload.urlRequest(origin: origin, token: "test-credential")
        #expect(request.url?.absoluteString == "http://127.0.0.1:3773/api/voice/post-process")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-credential")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["transcript"] as? String == "test transcript")
        let draft = try #require(body["draft"] as? [String: Any])
        #expect(draft["text"] as? String == "")
        #expect(draft["selection"] as? [String: Int] == ["start": 0, "end": 0])
        let options = try #require(body["options"] as? [String: Any])
        #expect(options["speechCorrectionWord"] as? String == "scratch that")
        #expect(options["speechPostProcessingPrompt"] as? [String: String] == [
            "mode": "custom", "customInstructions": "Use short sentences."
        ])
        #expect(options["speechRemoveFillerWords"] == nil)
        let words = try #require(options["speechCustomWords"] as? [[String: Any]])
        #expect(words.first?["term"] as? String == "Notchbee")
        #expect(words.first?["aliases"] as? [String] == ["notch bee"])
    }

    @Test @MainActor func agentResultBelongsToTheDispatchedMessageAndRun() async throws {
        let reply = T3Client.DictationReply(messageID: "dictated")
        reply.apply(.detailEvent(.run(.init(ordinal: 4, status: "running", id: "target", userMessageId: "dictated"))))
        reply.apply(.detailEvent(.message(.init(
            id: "other-message", role: "assistant", text: "Unrelated", runId: "unrelated",
            streaming: false, createdAt: "02"
        ))))
        reply.apply(.detailEvent(.run(.init(ordinal: 5, status: "completed", id: "unrelated", userMessageId: "other"))))
        reply.resolve()
        reply.apply(.detailEvent(.message(.init(
            id: "reply", role: "assistant", text: "Par", runId: "target", streaming: true, createdAt: "01"
        ))))
        reply.apply(.detailEvent(.message(.init(
            id: "reply", role: "assistant", text: "Final answer", runId: "target", streaming: false, createdAt: "01"
        ))))
        reply.apply(.detailEvent(.run(.init(ordinal: 4, status: "completed", id: "target", userMessageId: "dictated"))))
        reply.resolve()
        var iterator = reply.results.stream.makeAsyncIterator()
        #expect(try await iterator.next() == "Final answer")
        #expect(try await iterator.next() == nil)
    }

    private enum TestError: Error { case failed }

    @MainActor
    private final class FakePasteboard: DictationPasteboard {
        private(set) var changeCount = 0
        private(set) var items: [[PasteboardRepresentation]] = [
            [
                .init(type: "public.utf8-plain-text", data: Data("original".utf8)),
                .init(type: "public.rtf", data: Data("{rtf}".utf8))
            ],
            [.init(type: "public.png", data: Data([1, 2, 3]))]
        ]

        func snapshot() -> [[PasteboardRepresentation]] { items }

        func writeText(_ text: String) {
            replace(with: [[.init(type: "public.utf8-plain-text", data: Data(text.utf8))]])
        }

        func restore(_ snapshot: [[PasteboardRepresentation]]) {
            replace(with: snapshot)
        }

        func replace(with items: [[PasteboardRepresentation]]) {
            self.items = items
            changeCount += 1
        }
    }
}
