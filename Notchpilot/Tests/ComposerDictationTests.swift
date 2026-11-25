import AppKit
import NotchpilotCore
import Testing
@testable import Notchpilot

@MainActor
struct ComposerDictationTests {
    @Test func replacesPartialsAtCaretAndCommitsAnUndoableDraft() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let editor = PanelTextView(frame: .zero)
        editor.allowsUndo = true
        editor.string = "Hi 👋 there"
        window.contentView = editor
        #expect(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 5, length: 0))

        editor.beginDictation()
        editor.previewDictation("good")
        #expect(editor.string == "Hi 👋 good there")
        editor.previewDictation("good morning")
        #expect(editor.string == "Hi 👋 good morning there")
        editor.finishDictation()
        #expect(editor.string == "Hi 👋 good morning there")
        #expect(editor.isEditable)
        let undoManager = try #require(editor.undoManager)
        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(editor.string == "Hi 👋 there")
    }

    @Test func usesTheEndOfAnUnfocusedDraft() {
        let editor = PanelTextView(frame: .zero)
        editor.string = "First prompt:"
        editor.beginDictation()
        editor.previewDictation("partial")
        editor.previewDictation("")
        #expect(editor.string == "First prompt:")
        editor.previewDictation("final")
        editor.finishDictation()
        #expect(editor.string == "First prompt: final")
    }

    @Test func stopsCaptureAndKeepsFinalTextInTheEditor() async {
        let state = AppState()
        let microphone = TestMicrophone()
        let transcriber = TestTranscriber()
        let voice = VoiceController(state: state, microphone: microphone,
                                    recognition: SpeechRecognition(primary: transcriber, fallback: transcriber))
        let editor = PanelTextView(frame: .zero)
        editor.string = "Existing"

        await confirmation { finished in
            await withCheckedContinuation { continuation in
                voice.startDictation(owner: UUID(), begin: editor.beginDictation, partial: { text in
                    editor.previewDictation(text)
                    if text == "par" {
                        #expect(editor.string == "Existing par")
                        #expect(voice.dictation.status?.phase == .recording)
                        voice.stopDictation()
                        #expect(voice.dictation.status?.phase == .finishing)
                    }
                }, finish: {
                    editor.finishDictation()
                    finished()
                    continuation.resume()
                })
            }
        }
        #expect(editor.string == "Existing final")
        #expect(!microphone.isRecording)
        #expect(!voice.dictation.isActive)
        #expect(state.snapshot.voiceCommand == nil)
    }

    @Test func pushToTalkKeepsTheDraftUntilSend() async throws {
        let state = AppState()
        let backend = FakeBackend()
        let id = try await backend.startSession(title: "Test", providerInstanceId: "test", model: "test")
        state.apply(.sessionUpdated(SessionSummary(id: id, title: "Test", providerInstanceId: "test", status: .idle)))
        state.apply(.connectionChanged(.connected))
        let microphone = TestMicrophone()
        let transcriber = TestTranscriber()
        let voice = VoiceController(state: state, microphone: microphone,
                                    recognition: SpeechRecognition(primary: transcriber, fallback: transcriber))
        voice.backend = backend
        defer { voice.reset() }

        voice.press()
        try await waitFor { microphone.isRecording }
        voice.release()
        try await waitFor {
            if case .reviewing = state.panelSnapshot.voiceCommand?.phase { return true }
            return false
        }

        let draft = VoiceDraft(target: .session(id: id, title: "Test"), text: "final")
        try await Task.sleep(for: .milliseconds(2_200))
        #expect(state.panelSnapshot.voiceCommand?.phase == .reviewing(draft))
        voice.submit()
        #expect(state.panelSnapshot.voiceCommand?.phase == .sending(draft))
        try await waitFor { state.panelSnapshot.voiceCommand == nil }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    @Test func showsMicrophoneDenialAndPreservesDraft() async {
        let microphone = TestMicrophone()
        microphone.permissionDenied = true
        let transcriber = TestTranscriber()
        let voice = VoiceController(state: AppState(), microphone: microphone,
                                    recognition: SpeechRecognition(primary: transcriber, fallback: transcriber))
        let editor = PanelTextView(frame: .zero)
        editor.string = "Existing"
        await withCheckedContinuation { continuation in
            voice.startDictation(owner: UUID(), begin: editor.beginDictation, partial: { editor.previewDictation($0) }) {
                editor.finishDictation()
                continuation.resume()
            }
        }
        #expect(editor.string == "Existing")
        #expect(!microphone.isRecording)
        #expect(voice.dictation.status?.phase == .failed)
        #expect(voice.dictation.status?.message.contains("Privacy & Security") == true)
    }
}

@MainActor
private final class TestMicrophone: SpeechAudioSource {
    var permissionDenied = false
    private var continuation: SpeechAudio.Continuation?
    var isRecording: Bool { continuation != nil }

    func requestPermission() async throws {
        if permissionDenied { throw VoiceAudioError.microphonePermission }
    }

    func start() throws -> SpeechAudio {
        let audio = SpeechAudio.makeStream()
        continuation = audio.continuation
        return audio.stream
    }

    func stop() {
        continuation?.finish()
        continuation = nil
    }
}

@MainActor
private final class TestTranscriber: SpeechTranscriber {
    func prepare(vocabulary: [SpeechCustomWord], progress: @escaping SpeechProgress) async throws {
        progress("Downloading model…", 0.5)
    }

    func transcribe(_ audio: SpeechAudio, partial: @escaping SpeechPartial) async throws -> String {
        partial("par")
        for await _ in audio {}
        return "final"
    }
}
