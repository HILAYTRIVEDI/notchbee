import Foundation

public enum VoiceCommandPhase: Sendable, Equatable {
    case preparing(message: String, progress: Double?)
    case listening(text: String, target: VoiceTarget?)
    case finishing(text: String, target: VoiceTarget?)
    case reviewing(VoiceDraft)
    case editing(VoiceDraft)
    case sending(VoiceDraft)
    case notice(String)

    public var canCancelWithGlobalEscape: Bool {
        switch self {
        case .preparing, .listening, .finishing, .reviewing: true
        case .editing, .sending, .notice: false
        }
    }
}

public struct VoiceCommandState: Sendable, Equatable {
    public let id: UUID
    public internal(set) var phase: VoiceCommandPhase
}

public enum VoiceCommandEvent: Sendable, Equatable {
    case start
    case preparationProgress(String, Double?)
    case recordingStarted
    case partial(String, VoiceTarget?)
    case keyReleased
    case review(VoiceDraft)
    case edit
    case submit
    case submitEdit(String)
    case cancel
    case notice(String)
    case clear
}

func reduceVoice(
    _ state: VoiceCommandState?, id: UUID, event: VoiceCommandEvent
) -> VoiceCommandState? {
    if event == .start {
        switch state?.phase {
        case .reviewing, .editing, .sending: return state
        default: break
        }
        return VoiceCommandState(id: id, phase: .preparing(message: "Preparing speech recognition…", progress: nil))
    }
    guard var command = state, command.id == id else { return state }
    switch (command.phase, event) {
    case (.preparing, .preparationProgress(let message, let progress)):
        command.phase = .preparing(message: message, progress: progress)
    case (.preparing, .recordingStarted):
        command.phase = .listening(text: "", target: nil)
    case (.listening, .partial(let text, let target)):
        command.phase = .listening(text: text, target: target)
    case (.finishing, .partial(let text, let target)):
        command.phase = .finishing(text: text, target: target)
    case (.listening(let text, let target), .keyReleased):
        command.phase = .finishing(text: text, target: target)
    case (.finishing, .review(let draft)):
        command.phase = .reviewing(draft)
    case (.reviewing(let draft), .edit):
        command.phase = .editing(draft)
    case (.reviewing(let draft), .submit):
        command.phase = .sending(draft)
    case (.editing(var draft), .submitEdit(let text)):
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return command }
        draft.text = text
        command.phase = .sending(draft)
    case (.sending, .cancel):
        return command
    case (_, .cancel), (_, .clear):
        return nil
    case (_, .notice(let message)):
        command.phase = .notice(message)
    default:
        break
    }
    return command
}
