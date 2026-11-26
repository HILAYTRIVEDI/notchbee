import AppKit
import KeyboardShortcuts
import NotchpilotCore
import Observation

@MainActor
@Observable
final class AnywhereDictationController {
    enum Phase: Equatable {
        case preparing, recording, finishing, cleaning, review, sending, result, notice
    }

    struct Status {
        let id = UUID()
        let mode: DictationMode
        var phase: Phase
        var message = ""
        var text = ""
        var progress: Double?
        var offersAccessibility = false
    }

    private(set) var status: Status?
    private(set) var destination: SessionSummary?
    private(set) var newThread = false
    var context: DictationAppContext? { target?.context }
    var isShowing: Bool { status != nil }
    var isConnected: Bool { state.panelSnapshot.connection == .connected }

    private let state: AppState
    private unowned let voice: VoiceController
    private let paste = DictationPaste()
    private var target: FocusedDictationTarget?
    private var heldShortcut: KeyboardShortcuts.Name?
    private var operation: Task<Void, Never>?
    private var focusWatch: Task<Void, Never>?
    private var noticeTimer: Task<Void, Never>?
    private var promptedForAccessibility = false

    init(state: AppState, voice: VoiceController) {
        self.state = state
        self.voice = voice
    }

    func registerShortcut(showNotch: @escaping () -> Void) {
        DictationSettings.updateShortcuts(KeyboardShortcuts.getShortcut(for: .anywhereDictation))
        let names: [KeyboardShortcuts.Name] = [.anywhereDictation, .cleanDictation, .agentDictation]
        for name in names {
            KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
                guard let keys = KeyboardShortcuts.getShortcut(for: name)?.modifiers else { return }
                let mode = DictationMode(cleanModifier: keys.contains(.shift), agentModifier: keys.contains(.option))
                self?.press(name, mode: mode, showNotch: showNotch)
            }
            KeyboardShortcuts.onKeyUp(for: name) { [weak self] in self?.release(name) }
        }
    }

    private func press(_ shortcut: KeyboardShortcuts.Name, mode: DictationMode, showNotch: () -> Void) {
        guard heldShortcut == nil, status == nil || status?.phase == .notice,
              voice.canStartAnywhereRecording else { return }
        heldShortcut = shortcut
        showNotch()
        noticeTimer?.cancel()
        status = .init(mode: mode, phase: .preparing, message: "Preparing speech…")
        voice.dictationActivityChanged()
        guard let id = status?.id else { return }
        do {
            target = try FocusedDictationTarget.capture(includeContext: mode == .agent)
        } catch {
            fail(error)
            return
        }
        voice.startAnywhereRecording(
            progress: { [weak self] message, progress in
                guard let self, status?.id == id, status?.phase == .preparing else { return }
                status?.message = message
                status?.progress = progress
            },
            validate: { [weak self] in try self?.target?.validate() },
            started: { [weak self] in
                guard let self, status?.id == id else { return }
                status?.phase = .recording
                status?.message = "Listening…"
                status?.progress = nil
                watchFocus(id: id)
            },
            partial: { [weak self] text in
                guard let self, status?.id == id else { return }
                status?.text = text
            },
            limit: { [weak self] in self?.discard("Recording reached one minute. Try a shorter dictation.") },
            finished: { [weak self] result in self?.finishRecording(result, id: id) }
        )
    }

    private func release(_ shortcut: KeyboardShortcuts.Name) {
        guard heldShortcut == shortcut else { return }
        heldShortcut = nil
        switch status?.phase {
        case .preparing: discard("Speech was preparing. Hold the shortcut until dictation starts.")
        case .recording:
            status?.phase = .finishing
            status?.message = "Finishing transcription…"
            voice.stopAnywhereRecording()
        default: break
        }
    }

    func cancel() {
        if status?.phase == .preparing || status?.phase == .recording || status?.phase == .finishing {
            voice.cancelAnywhereRecording()
        }
        heldShortcut = nil
        operation?.cancel()
        focusWatch?.cancel()
        noticeTimer?.cancel()
        target = nil
        destination = nil
        newThread = false
        if status != nil {
            status = nil
            voice.dictationActivityChanged()
        }
    }

    private func watchFocus(id: UUID) {
        focusWatch = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard let self, status?.id == id else { return }
                do { try target?.validate() }
                catch {
                    voice.cancelAnywhereRecording()
                    fail(error)
                    return
                }
            }
        }
    }

    private func finishRecording(_ result: Result<String, Error>, id: UUID) {
        guard status?.id == id, let status else { return }
        focusWatch?.cancel()
        guard status.phase == .finishing else {
            if case .failure(let error) = result { fail(error) }
            else { discard("Recording ended early. Check your microphone and try again.") }
            return
        }
        do {
            try target?.validate()
            let text = try result.get()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                discard("No speech detected.")
                return
            }
            self.status?.text = text
            switch status.mode {
            case .raw: insert(text, id: id)
            case .clean:
                if UserDefaults.standard.object(forKey: "dictationCleanup") as? Bool ?? true { clean(text, id: id) }
                else { insert(text, id: id) }
            case .agent: review()
            }
        } catch {
            fail(error)
        }
    }

    private func clean(_ text: String, id: UUID) {
        guard isConnected, let backend = voice.backend else {
            insert(text, id: id)
            return
        }
        status?.phase = .cleaning
        status?.message = "Cleaning transcript…"
        operation = Task { [weak self] in
            do {
                let options = SpeechCleanupOptions(words: await VoiceController.loadVocabulary().words)
                try Task.checkCancellation()
                guard let self, let target, status?.id == id else { return }
                try target.validate()
                let result = try await DictationCleanup.process(text) {
                    return try await backend.cleanTranscript(text, options: options)
                }
                guard status?.id == id else { return }
                if result.usedRawText {
                    insert(result.text, id: id, usedRawText: true)
                } else {
                    status?.phase = .result
                    status?.message = "Review the cleaned transcript before inserting."
                    status?.text = result.text
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, status?.id == id else { return }
                fail(error)
            }
        }
    }

    private func review() {
        destination = VoiceRouting.activeSessionsByRecency(state.panelSnapshot.sessions).first
        newThread = destination == nil
        status?.phase = .review
        status?.message = ""
    }

    var newThreadProject: ThreadProject? { state.panelSnapshot.projects.first }
    var canSend: Bool { isConnected && (destination != nil || newThreadProject != nil) }

    func chooseNewThread(_ enabled: Bool) {
        newThread = enabled || destination == nil
        status?.message = ""
    }

    func send() {
        guard let status, status.phase == .review, let context, canSend, let backend = voice.backend else { return }
        let agentTarget: DictationAgentTarget
        if let destination {
            guard state.panelSnapshot.sessions.contains(where: { $0.id == destination.id && !$0.isArchived }) else {
                self.status?.message = "The selected thread is unavailable."
                return
            }
            agentTarget = newThread ? .new(inProjectOf: destination.id) : .existing(threadID: destination.id)
        } else if let project = newThreadProject {
            agentTarget = .newInProject(project.id)
        } else {
            return
        }

        do {
            try target?.validate()
            let prompt = try context.prompt(for: status.text)
            self.status?.phase = .sending
            self.status?.message = "Waiting for the agent…"
            self.status?.text = ""
            operation = Task { [weak self] in
                do {
                    let reply = try await backend.runDictationPrompt(prompt, target: agentTarget)
                    guard let self, !Task.isCancelled, self.status?.id == status.id else { return }
                    self.status?.phase = .result
                    self.status?.message = ""
                    self.status?.text = reply
                } catch {
                    guard let self, !Task.isCancelled, self.status?.id == status.id else { return }
                    discard((error as? LocalizedError)?.errorDescription ?? "Couldn't complete the agent request.")
                }
            }
        } catch {
            fail(error)
        }
    }

    func insertResult() {
        guard let status, status.phase == .result else { return }
        insert(status.text, id: status.id, canRetry: true)
    }

    private func insert(_ text: String, id: UUID, usedRawText: Bool = false, canRetry: Bool = false) {
        status?.phase = .finishing
        status?.message = "Inserting text…"
        operation = Task { [weak self] in
            guard let self, let target, !Task.isCancelled, status?.id == id else { return }
            do {
                try await target.insert(text, paste: paste)
                guard !Task.isCancelled, status?.id == id else { return }
                if usedRawText { discard("Transcript cleanup didn't respond in time or failed. Inserted the raw transcript.") }
                else { cancel() }
            } catch DictationTargetError.changed where canRetry {
                guard status?.id == id else { return }
                status?.phase = .result
                status?.message = DictationTargetError.changed.localizedDescription
            } catch {
                guard !Task.isCancelled, status?.id == id else { return }
                fail(error)
            }
        }
    }

    private func discard(_ message: String, offersAccessibility: Bool = false) {
        focusWatch?.cancel()
        target = nil
        destination = nil
        guard let mode = status?.mode else { return }
        status = .init(mode: mode, phase: .notice, message: message, offersAccessibility: offersAccessibility)
        noticeTimer?.cancel()
        noticeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(7))
            if !Task.isCancelled { self?.cancel() }
        }
    }

    private func fail(_ error: Error) {
        let needsAccess = (error as? DictationTargetError) == .permission
        discard(error.localizedDescription, offersAccessibility: needsAccess)
        if needsAccess && !promptedForAccessibility {
            promptedForAccessibility = true
            FocusedDictationTarget.requestAccessibility()
        }
    }
}
