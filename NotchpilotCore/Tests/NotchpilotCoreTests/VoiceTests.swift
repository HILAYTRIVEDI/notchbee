import Foundation
import Testing
@testable import NotchpilotCore

struct VoiceTests {
    private func session(
        _ id: String, title: String, project: String? = nil, activity: TimeInterval = 0, archived: Bool = false
    ) -> SessionSummary {
        var session = SessionSummary(id: id, title: title, providerInstanceId: "Codex", status: .idle)
        session.project = project
        session.lastActivity = Date(timeIntervalSince1970: activity)
        session.isArchived = archived
        return session
    }

    @Test func defaultAndNewThreadUseTheLastActiveSession() throws {
        let sessions = [
            session("old", title: "Build Dashboard", activity: 1),
            session("archived", title: "Archived", activity: 30, archived: true),
            session("last", title: "Schema Changes", project: "Deploy Tool", activity: 12)
        ]
        #expect(try VoiceRouting.resolve("Run the tests.", sessions: sessions) ==
            VoiceDraft(target: .session(id: "last", title: "Schema Changes"), text: "Run the tests."))
        #expect(try VoiceRouting.resolve("New thread, inspect .github.", sessions: sessions) ==
            VoiceDraft(target: .newThread(baseSessionID: "last", project: "Deploy Tool"), text: "inspect .github."))
        #expect(try VoiceRouting.resolve("New thread .github settings", sessions: sessions).text == ".github settings")
        #expect(try VoiceRouting.resolve("New threading change", sessions: sessions).text == "New threading change")
    }

    @Test func fuzzyTitlesAndProjectsConsumeOnlyTheSpokenName() throws {
        let sessions = [
            session("old", title: "Build Dashboard", project: "Notchpilot", activity: 1),
            session("last", title: "Verify Voice", project: "Notchpilot", activity: 12),
            session("api", title: "API Server", activity: 20)
        ]
        #expect(try VoiceRouting.resolve("tell build dashbord, run the checks", sessions: sessions) ==
            VoiceDraft(target: .session(id: "old", title: "Build Dashboard"), text: "run the checks"))
        #expect(try VoiceRouting.resolve("tell notch pilot: fix the hotkey", sessions: sessions) ==
            VoiceDraft(target: .session(id: "last", title: "Verify Voice"), text: "fix the hotkey"))
        #expect(try VoiceRouting.resolve("tell api server run tests", sessions: sessions) ==
            VoiceDraft(target: .session(id: "api", title: "API Server"), text: "run tests"))
    }

    @Test func routingErrorsNeverSelectAnUnintendedDefault() {
        let sessions = [session("first", title: "Audio"), session("second", title: "Audio")]
        #expect(throws: VoiceRouting.Failure.noSessions) {
            try VoiceRouting.resolve("Run tests", sessions: [])
        }
        #expect(throws: VoiceRouting.Failure.noSpeech) {
            try VoiceRouting.resolve("  ", sessions: sessions)
        }
        #expect(throws: VoiceRouting.Failure.ambiguousTarget) {
            try VoiceRouting.resolve("tell audio run tests", sessions: sessions)
        }
        #expect(throws: VoiceRouting.Failure.unknownTarget) {
            try VoiceRouting.resolve("tell imaginary run tests", sessions: sessions)
        }
        #expect(throws: VoiceRouting.Failure.noPrompt) {
            try VoiceRouting.resolve("tell audio.", sessions: Array(sessions.prefix(1)))
        }
    }

    @Test(arguments: [true, false])
    func newThreadFallsBackToQuickSession(hasSession: Bool) throws {
        let sessions = hasSession ? [session("first", title: "Audio")] : []
        #expect(try VoiceRouting.resolve("new thread run tests", sessions: sessions) ==
            VoiceDraft(target: .quickSession, text: "run tests"))
    }

    @Test func vocabularyReplacesAliasesAndCanonicalizesWholeTerms() {
        let vocabulary = SpeechVocabulary(words: [
            .init(term: "pnpm", aliases: ["pea en pea em"]),
            .init(term: "T3", aliases: ["tee three"]),
            .init(term: "T3 Code", aliases: ["tee three code"]),
            .init(term: "C++", aliases: ["see plus plus"]),
        ])
        #expect(vocabulary.apply(to: "tell tee   three code, use PnPM with see plus plus") ==
            "tell T3 Code, use pnpm with C++")
        #expect(vocabulary.apply(to: "T3s and superpnpm and x_tee three") == "T3s and superpnpm and x_tee three")
        #expect(vocabulary.apply(to: "tee three and pea en pea em.") == "T3 and pnpm.")
        #expect(SpeechVocabulary(words: []).apply(to: "unchanged") == "unchanged")
    }

    @Test func reviewWaitsForExplicitSend() {
        let id = UUID()
        let draft = VoiceDraft(target: .session(id: "one", title: "Test"), text: "Run tests")
        func step(_ state: StateSnapshot, _ event: VoiceCommandEvent, id eventID: UUID? = nil) -> StateSnapshot {
            reduce(state: state, event: .voiceCommand(eventID ?? id, event))
        }
        let preparing = step(StateSnapshot(), .start)
        let listening = step(preparing, .recordingStarted)
        let partial = step(listening, .partial("Run", draft.target))
        let finishing = step(partial, .keyReleased)
        let reviewing = step(finishing, .review(draft))
        #expect(preparing.uiState == .voice)
        #expect(partial.voiceCommand?.phase == .listening(text: "Run", target: draft.target))
        #expect(finishing.voiceCommand?.phase == .finishing(text: "Run", target: draft.target))
        #expect(reviewing.voiceCommand?.phase == .reviewing(draft))
        #expect(step(partial, .submit) == partial)
        #expect(step(finishing, .submit) == finishing)
        #expect(step(reviewing, .keyReleased) == reviewing)
        #expect(step(reviewing, .start, id: UUID()) == reviewing)
        #expect(reduce(state: reviewing, event: .idleTimeout).voiceCommand == reviewing.voiceCommand)
        #expect(step(reviewing, .submit, id: UUID()) == reviewing)
        #expect(step(reviewing, .submit).voiceCommand?.phase == .sending(draft))

        let cancelled = step(reviewing, .cancel)
        #expect(cancelled.uiState == .idle)
        #expect(step(cancelled, .submit).voiceCommand == nil)

        let editing = step(reviewing, .edit)
        #expect(editing.voiceCommand?.phase == .editing(draft))
        #expect(step(editing, .submit) == editing)
        #expect(step(editing, .submitEdit(" \n ")) == editing)
        let edited = VoiceDraft(target: draft.target, text: "Run the unit tests")
        #expect(step(editing, .submitEdit("  Run the unit tests\n")).voiceCommand?.phase == .sending(edited))
        #expect(step(editing, .cancel).voiceCommand == nil)
    }
}

@MainActor
struct SpeechRecognitionTests {
    @Test(arguments: [false, true])
    func fallbackReceivesTheWholeRecordingAndVocabulary(failDuringPrepare: Bool) async throws {
        let primary = FakeTranscriber(failDuringPrepare: failDuringPrepare, failDuringTranscription: !failDuringPrepare)
        let fallback = FakeTranscriber()
        let microphone = FakeMicrophone()
        let recognition = SpeechRecognition(primary: primary, fallback: fallback)
        let vocabulary = SpeechVocabulary(words: [.init(term: "pnpm", aliases: ["pea en pea em"])])
        var updates: [String] = []

        try await microphone.requestPermission()
        let audio = try microphone.start()
        try await recognition.prepare(vocabulary: vocabulary) { _, _ in }
        microphone.record([1, 2, 3])
        microphone.record([4, 5])
        microphone.stop()
        let final = try await recognition.transcribe(audio, vocabulary: vocabulary, progress: { _, _ in }) {
            updates.append($0)
        }

        #expect(final == "use pnpm")
        #expect(updates.last == "use pnpm")
        #expect(fallback.samples == [1, 2, 3, 4, 5])
        #expect(primary.samples == (failDuringPrepare ? [] : [1, 2, 3]))
        #expect(fallback.vocabulary == vocabulary.words)
    }
}

@MainActor
private final class FakeMicrophone: SpeechAudioSource {
    private let audio = SpeechAudio.makeStream()

    func requestPermission() async throws {}
    func start() throws -> SpeechAudio { audio.stream }
    func record(_ samples: [Float]) { audio.continuation.yield(samples) }
    func stop() { audio.continuation.finish() }
}

@MainActor
private final class FakeTranscriber: SpeechTranscriber {
    enum Failure: Error { case unavailable }
    let failDuringPrepare: Bool
    let failDuringTranscription: Bool
    var vocabulary: [SpeechCustomWord] = []
    var samples: [Float] = []

    init(failDuringPrepare: Bool = false, failDuringTranscription: Bool = false) {
        self.failDuringPrepare = failDuringPrepare
        self.failDuringTranscription = failDuringTranscription
    }

    func prepare(vocabulary: [SpeechCustomWord], progress: @escaping SpeechProgress) async throws {
        if failDuringPrepare { throw Failure.unavailable }
        self.vocabulary = vocabulary
    }

    func transcribe(_ audio: SpeechAudio, partial: @escaping SpeechPartial) async throws -> String {
        for await chunk in audio {
            samples += chunk
            if failDuringTranscription { throw Failure.unavailable }
            partial("use pea en pea em")
        }
        return "use pea en pea em"
    }
}
