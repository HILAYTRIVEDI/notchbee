import Foundation

/// Audio supplied to either engine is mono Float32 PCM at 16 kHz.
public typealias SpeechAudio = AsyncStream<[Float]>
public typealias SpeechProgress = @MainActor @Sendable (String, Double?) -> Void
public typealias SpeechPartial = @MainActor @Sendable (String) -> Void

@MainActor
public protocol SpeechAudioSource: AnyObject {
    func requestPermission() async throws
    func start() throws -> SpeechAudio
    func stop()
}

@MainActor
public protocol SpeechTranscriber: AnyObject {
    func prepare(vocabulary: [SpeechCustomWord], progress: @escaping SpeechProgress) async throws
    func transcribe(_ audio: SpeechAudio, partial: @escaping SpeechPartial) async throws -> String
}

@MainActor
public final class SpeechRecognition {
    private let primary: any SpeechTranscriber
    private let fallback: any SpeechTranscriber
    private var usingFallback = false

    public init(primary: any SpeechTranscriber, fallback: any SpeechTranscriber) {
        self.primary = primary
        self.fallback = fallback
    }

    public func prepare(vocabulary: SpeechVocabulary, progress: @escaping SpeechProgress) async throws {
        usingFallback = false
        do {
            try await primary.prepare(vocabulary: vocabulary.words, progress: progress)
        } catch {
            try Task.checkCancellation()
            try await prepareFallback(vocabulary: vocabulary, progress: progress)
        }
    }

    public func transcribe(
        _ audio: SpeechAudio, vocabulary: SpeechVocabulary,
        progress: @escaping SpeechProgress, partial: @escaping SpeechPartial
    ) async throws -> String {
        let corrected: SpeechPartial = { partial(vocabulary.apply(to: $0)) }
        if usingFallback {
            return vocabulary.apply(to: try await fallback.transcribe(audio, partial: corrected))
        }

        let replay = Replay()
        let input = replay.stream()
        let pump = Task {
            for await chunk in audio {
                guard !Task.isCancelled else { break }
                replay.append(chunk)
            }
            replay.finish()
        }
        defer {
            pump.cancel()
            replay.finish()
        }

        let text: String
        do {
            text = try await primary.transcribe(input, partial: corrected)
        } catch {
            try Task.checkCancellation()
            corrected("")
            try await prepareFallback(vocabulary: vocabulary, progress: progress)
            text = try await fallback.transcribe(replay.stream(), partial: corrected)
        }
        return vocabulary.apply(to: text)
    }

    private func prepareFallback(vocabulary: SpeechVocabulary, progress: @escaping SpeechProgress) async throws {
        progress("Preparing Apple Speech…", nil)
        try await fallback.prepare(vocabulary: vocabulary.words, progress: progress)
        usingFallback = true
    }

    /// A voice command holds at most one minute of audio. Replay lets a fallback
    /// engine recover the same command whether the mic is still open or has stopped.
    @MainActor
    private final class Replay {
        private var chunks: [[Float]] = []
        private var continuation: SpeechAudio.Continuation?
        private var ended = false

        func stream() -> SpeechAudio {
            continuation?.finish()
            let input = SpeechAudio.makeStream()
            for chunk in chunks { input.continuation.yield(chunk) }
            if ended {
                input.continuation.finish()
            } else {
                continuation = input.continuation
            }
            return input.stream
        }

        func append(_ chunk: [Float]) {
            chunks.append(chunk)
            continuation?.yield(chunk)
        }

        func finish() {
            ended = true
            continuation?.finish()
            continuation = nil
        }
    }
}
