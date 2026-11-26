import AppKit
import KeyboardShortcuts
import NotchpilotCore
import SwiftUI

extension KeyboardShortcuts.Name {
    static let pushToTalk = Self("pushToTalk", initial: .init(.v, modifiers: [.control, .option, .command]))
}

@MainActor
@Observable
final class ComposerDictation {
    enum Phase { case preparing, recording, finishing, failed }

    struct Status {
        let owner: UUID
        var phase: Phase
        var message: String
        var progress: Double?
    }

    fileprivate(set) var status: Status?
    var isActive: Bool { status.map { $0.phase != .failed } ?? false }
}

@MainActor
final class VoiceController: NSObject, NSWindowDelegate {
    private let state: AppState
    private let microphone: any SpeechAudioSource
    private let recognition: SpeechRecognition
    var backend: (any AgentBackend)?
    let dictation = ComposerDictation()
    private(set) lazy var anywhere = AnywhereDictationController(state: state, voice: self)
    var canStartAnywhereRecording: Bool {
        recognitionTask == nil && !dictation.isActive && state.panelSnapshot.voiceCommand == nil
    }
    var dictationActivityChanged: () -> Void = {}

    private var keyHeld = false
    private var recognitionTask: Task<Void, Never>?
    private var noticeTimer: Task<Void, Never>?
    private var recordingLimit: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var editor: NSWindow?
    private var finishDictation: (() -> Void)?

    init(state: AppState, microphone: any SpeechAudioSource, recognition: SpeechRecognition) {
        self.state = state
        self.microphone = microphone
        self.recognition = recognition
    }

    func registerShortcut(showNotch: @escaping () -> Void) {
        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
            guard let self else { return }
            showNotch()
            press()
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in self?.release() }
        anywhere.registerShortcut(showNotch: showNotch)
    }

    func cancel() {
        anywhere.cancel()
        cancelDictation()
        guard let command = state.panelSnapshot.voiceCommand else { return }
        if case .sending = command.phase { return }
        reset()
    }

    func reset() {
        anywhere.cancel()
        cancelDictation()
        keyHeld = false
        microphone.stop()
        recognitionTask?.cancel()
        noticeTimer?.cancel()
        recordingLimit?.cancel()
        sendTask?.cancel()
        dismissEditor()
        if let id = state.panelSnapshot.voiceCommand?.id { apply(.clear, id: id) }
    }

    func submit() {
        guard let id = state.panelSnapshot.voiceCommand?.id else { return }
        send(.submit, id: id)
    }

    func edit() {
        guard let command = state.panelSnapshot.voiceCommand,
              case .reviewing(let draft) = command.phase else { return }
        apply(.edit, id: command.id)
        noticeTimer?.cancel()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 235),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Edit Voice Command"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: VoiceEditor(
            draft: draft,
            onCancel: { [weak self] in self?.cancel() },
            onSend: { [weak self] text in self?.send(.submitEdit(text), id: command.id) }
        ))
        editor = window
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === editor else { return }
        editor = nil
        cancel()
    }

    private func dismissEditor() {
        let window = editor
        editor = nil
        window?.close()
    }

    func press() {
        guard !keyHeld, !dictation.isActive, !anywhere.isShowing else { return }
        if case .preparing = state.panelSnapshot.voiceCommand?.phase {
            if recognitionTask?.isCancelled == false { keyHeld = true }
            return
        }
        guard recognitionTask == nil else { return }
        switch state.panelSnapshot.voiceCommand?.phase {
        case .reviewing, .editing, .sending: return
        default: break
        }
        noticeTimer?.cancel()
        keyHeld = true
        let id = UUID()
        apply(.start, id: id)
        recognitionTask = Task { [weak self] in
            await self?.recognize(id: id)
        }
    }

    func release() {
        guard keyHeld else { return }
        keyHeld = false
        guard let command = state.panelSnapshot.voiceCommand, case .listening = command.phase else { return }
        recordingLimit?.cancel()
        microphone.stop()
        apply(.keyReleased, id: command.id)
    }

    private func recognize(id: UUID) async {
        defer { recognitionTask = nil }
        do {
            let progress: SpeechProgress = { [weak self] text, value in
                self?.apply(.preparationProgress(text, value), id: id)
            }
            let transcript = try await capture(progress: progress, shouldRecord: { keyHeld }, started: {
                apply(.recordingStarted, id: id)
                limitRecording { [weak self] in
                    guard let self else { return }
                    microphone.stop()
                    recognitionTask?.cancel()
                    notice("Recording reached one minute. Release and try a shorter command.", id: id)
                }
            }, partial: { [weak self] text in
                guard let self else { return }
                let target = try? VoiceRouting.resolve(text, sessions: state.panelSnapshot.sessions).target
                apply(.partial(text, target), id: id)
            })
            guard let transcript else {
                notice("Speech is ready. Hold the shortcut while speaking.", id: id)
                return
            }
            guard !keyHeld, case .finishing = state.panelSnapshot.voiceCommand?.phase else {
                notice("Recording ended early. Check your microphone and try again.", id: id)
                return
            }
            let draft = try VoiceRouting.resolve(transcript, sessions: state.panelSnapshot.sessions)
            apply(.review(draft), id: id)
        } catch {
            guard !Task.isCancelled else { return }
            notice(error.localizedDescription, id: id)
        }
    }

    func startDictation(
        owner: UUID, begin: () -> Void, partial: @escaping SpeechPartial, finish: @escaping () -> Void
    ) {
        guard !dictation.isActive, !anywhere.isShowing else { return }
        guard recognitionTask == nil, state.panelSnapshot.voiceCommand == nil else {
            let message = state.panelSnapshot.voiceCommand == nil
                ? "Speech is still stopping. Try again in a moment."
                : "Wait for the voice command to finish."
            dictation.status = .init(owner: owner, phase: .failed, message: message)
            return
        }
        begin()
        finishDictation = finish
        dictation.status = .init(owner: owner, phase: .preparing, message: "Preparing speech…")
        dictationActivityChanged()
        recognitionTask = Task { [weak self] in
            await self?.recognizeDictation(owner: owner, partial: partial)
        }
    }

    func stopDictation() {
        guard let status = dictation.status else { return }
        switch status.phase {
        case .preparing: cancelDictation()
        case .recording:
            microphone.stop()
            recordingLimit?.cancel()
            dictation.status = .init(owner: status.owner, phase: .finishing, message: "Finishing transcription…")
        case .finishing, .failed: break
        }
    }

    func cancelDictation(owner: UUID? = nil) {
        guard let status = dictation.status, owner == nil || owner == status.owner else { return }
        if dictation.isActive {
            microphone.stop()
            recordingLimit?.cancel()
            recognitionTask?.cancel()
        }
        completeDictation()
    }

    private func recognizeDictation(owner: UUID, partial: @escaping SpeechPartial) async {
        defer { recognitionTask = nil }
        let progress: SpeechProgress = { [weak self] message, progress in
            guard let self, dictation.isActive, dictation.status?.owner == owner else { return }
            dictation.status?.message = message
            dictation.status?.progress = progress
        }
        do {
            let transcript = try await capture(progress: progress, shouldRecord: { true }, started: {
                dictation.status = .init(owner: owner, phase: .recording, message: "Listening…")
                limitRecording { [weak self] in self?.stopDictation() }
            }, partial: { [weak self] text in
                guard let self, dictation.isActive, dictation.status?.owner == owner else { return }
                partial(text)
            })
            if let transcript, !transcript.isEmpty { partial(transcript) }
            completeDictation()
        } catch {
            guard !Task.isCancelled else { return }
            completeDictation(error: .init(owner: owner, phase: .failed, message: error.localizedDescription))
        }
    }

    private func completeDictation(error: ComposerDictation.Status? = nil) {
        finishDictation?()
        finishDictation = nil
        dictation.status = error
        dictationActivityChanged()
    }

    func startAnywhereRecording(
        progress: @escaping SpeechProgress, validate: @escaping () throws -> Void,
        started: @escaping () -> Void, partial: @escaping SpeechPartial,
        limit: @escaping () -> Void, finished: @escaping (Result<String, Error>) -> Void
    ) {
        recognitionTask = Task { [weak self] in
            guard let self else { return }
            defer { recognitionTask = nil }
            do {
                let transcript = try await capture(
                    progress: progress, shouldRecord: { try validate(); return true },
                    started: { started(); limitRecording(limit) }, partial: partial
                )
                try Task.checkCancellation()
                finished(.success(transcript ?? ""))
            } catch {
                guard !Task.isCancelled else { return }
                finished(.failure(error))
            }
        }
    }

    func stopAnywhereRecording() {
        recordingLimit?.cancel()
        microphone.stop()
    }

    func cancelAnywhereRecording() {
        stopAnywhereRecording()
        recognitionTask?.cancel()
    }

    private func capture(
        progress: @escaping SpeechProgress, shouldRecord: () throws -> Bool, started: () -> Void,
        partial: @escaping SpeechPartial
    ) async throws -> String? {
        try Task.checkCancellation()
        try await microphone.requestPermission()
        try Task.checkCancellation()
        let vocabulary = await Self.loadVocabulary()
        try Task.checkCancellation()
        try await recognition.prepare(vocabulary: vocabulary, progress: progress)
        try Task.checkCancellation()
        guard try shouldRecord() else { return nil }

        let audio = try microphone.start()
        defer {
            recordingLimit?.cancel()
            microphone.stop()
        }
        started()
        let transcript = try await recognition.transcribe(audio, vocabulary: vocabulary, progress: progress, partial: partial)
        try Task.checkCancellation()
        return transcript
    }

    private func limitRecording(_ stop: @escaping () -> Void) {
        recordingLimit = Task {
            try? await Task.sleep(for: .seconds(60))
            if !Task.isCancelled { stop() }
        }
    }

    private func send(_ event: VoiceCommandEvent, id: UUID) {
        guard let command = state.panelSnapshot.voiceCommand, command.id == id else { return }
        if case .sending = command.phase { return }
        apply(event, id: id)
        guard case .sending(let draft) = state.panelSnapshot.voiceCommand?.phase else { return }
        dismissEditor()

        guard let backend, state.panelSnapshot.connection == .connected else {
            notice("Connect to the server to send the voice command.", id: id)
            return
        }
        if case .session(let sessionID, _) = draft.target,
           !state.panelSnapshot.sessions.contains(where: { $0.id == sessionID && !$0.isArchived }) {
            notice("The target session is no longer available.", id: id)
            return
        }

        sendTask = Task { [weak self] in
            do {
                switch draft.target {
                case .session(let sessionID, _):
                    try await backend.sendPrompt(sessionId: sessionID, text: draft.text)
                case .newThread, .quickSession:
                    let baseSessionID: String?
                    if case .newThread(let id, _) = draft.target { baseSessionID = id } else { baseSessionID = nil }
                    let title = draft.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    try await backend.startSession(
                        title: String(title.prefix(70)), inProjectOf: baseSessionID, prompt: draft.text
                    )
                }
                guard !Task.isCancelled else { return }
                self?.apply(.clear, id: id)
            } catch {
                guard !Task.isCancelled else { return }
                self?.notice(error.localizedDescription, id: id)
            }
        }
    }

    private func notice(_ message: String, id: UUID) {
        guard state.panelSnapshot.voiceCommand?.id == id else { return }
        apply(.notice(message), id: id)
        noticeTimer?.cancel()
        noticeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.apply(.clear, id: id)
        }
    }

    private func apply(_ event: VoiceCommandEvent, id: UUID) {
        state.apply(.voiceCommand(id, event))
    }

    @concurrent
    static func loadVocabulary() async -> SpeechVocabulary {
        let custom = (UserDefaults.standard.string(forKey: "dictationWords") ?? "").split(whereSeparator: \.isNewline)
            .map { SpeechCustomWord(term: String($0), aliases: []) }
        return SpeechVocabulary(words: custom)
    }
}

private struct VoiceEditor: View {
    let draft: VoiceDraft
    let onCancel: () -> Void
    let onSend: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(draft.target.label, systemImage: "arrow.turn.up.right")
                .lineLimit(1)
            TextEditor(text: $text)
                .font(.body)
                .focused($focused)
                .padding(4)
                .border(.quaternary)
                .accessibilityLabel("Voice command")
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Send") { onSend(text) }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .onAppear {
            text = draft.text
            focused = true
        }
    }
}
