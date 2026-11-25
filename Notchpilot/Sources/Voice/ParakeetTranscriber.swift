import AVFoundation
import CoreML
import FluidAudio
import NotchpilotCore
import OSLog

@MainActor
final class ParakeetTranscriber: SpeechTranscriber {
    private struct Progress {
        let message: String
        let fraction: Double?
    }

    private static let logger = Logger(subsystem: "com.hilaytrivedi.Notchbee", category: "SpeechModels")
    private var manager: StreamingUnifiedAsrManager?
    private var configuredVocabulary: [SpeechCustomWord]?
    private var preparing = false
    private var progress: Progress?
    private var listeners: [UUID: AsyncThrowingStream<Progress, Error>.Continuation] = [:]
    private var ctc: (models: CtcModels, tokenizer: CtcTokenizer)?
    static let defaultModelsDirectory = URL.applicationSupportDirectory
        .appending(path: "Notchbee/Models", directoryHint: .isDirectory)
    private let modelsDirectory: URL
    private let prepareFiles: @Sendable (VerifiedSpeechModels, URL, Bool, SpeechProgress) async throws -> URL?

    init(
        modelsDirectory: URL = defaultModelsDirectory,
        prepareFiles: @escaping @Sendable (VerifiedSpeechModels, URL, Bool, SpeechProgress) async throws -> URL? = {
            model, directory, downloadIfMissing, progress in
            try await model.prepare(in: directory, downloadIfMissing: downloadIfMissing, progress: progress)
        }
    ) {
        self.modelsDirectory = modelsDirectory
        self.prepareFiles = prepareFiles
    }

    func warmIfInstalled(vocabulary: [SpeechCustomWord]) {
        #if arch(arm64)
        guard manager == nil, !preparing, VerifiedSpeechModels.parakeet.isInstalled(in: modelsDirectory) else {
            return
        }
        let words = VerifiedSpeechModels.vocabulary.isInstalled(in: modelsDirectory) ? vocabulary : []
        startPreparation(vocabulary: words, downloadIfMissing: false)
        #endif
    }

    func prepare(vocabulary: [SpeechCustomWord], progress: @escaping SpeechProgress) async throws {
        #if arch(arm64)
        while configuredVocabulary != vocabulary {
            try Task.checkCancellation()
            if !preparing {
                startPreparation(vocabulary: vocabulary, downloadIfMissing: true)
            }
            try await waitForPreparation(progress: progress)
        }
        #else
        throw VoiceAudioError.unsupportedSpeech
        #endif
    }

    private func waitForPreparation(progress: @escaping SpeechProgress) async throws {
        let id = UUID()
        let (updates, listener) = AsyncThrowingStream<Progress, Error>.makeStream()
        listeners[id] = listener
        if let current = self.progress { listener.yield(current) }
        defer { listeners[id] = nil }
        for try await update in updates {
            progress(update.message, update.fraction)
        }
        try Task.checkCancellation()
    }

    private func startPreparation(vocabulary: [SpeechCustomWord], downloadIfMissing: Bool) {
        preparing = true
        // Preparation belongs to the shared engine. Canceling a capture only unsubscribes
        // that caller, so a subsequent capture can join the same download or load.
        Task(priority: .utility) {
            do {
                try await load(vocabulary: vocabulary, downloadIfMissing: downloadIfMissing)
                finishPreparation()
            } catch {
                Self.logger.error("Parakeet preparation failed: \(error.localizedDescription, privacy: .public)")
                finishPreparation(error: error)
            }
        }
    }

    private func finishPreparation(error: Error? = nil) {
        preparing = false
        progress = nil
        for listener in listeners.values { listener.finish(throwing: error) }
        listeners.removeAll()
    }

    private func load(vocabulary: [SpeechCustomWord], downloadIfMissing: Bool) async throws {
        let notify: SpeechProgress = { message, fraction in
            let update = Progress(message: message, fraction: fraction)
            self.progress = update
            for listener in self.listeners.values { listener.yield(update) }
        }
        let manager: StreamingUnifiedAsrManager
        if let existing = self.manager, configuredVocabulary == [] {
            // A warm base model can take its first boost list without reloading.
            manager = existing
        } else {
            guard let directory = try await prepareFiles(.parakeet, modelsDirectory, downloadIfMissing, notify) else {
                return
            }
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            // Rebuild when replacing or removing an existing boost list so removed terms never linger.
            manager = StreamingUnifiedAsrManager(configuration: config)
            notify("Preparing Parakeet…", nil)
            try await manager.loadModels(from: directory)
        }
        var configured = vocabulary
        if !vocabulary.isEmpty {
            do {
                if ctc == nil, let directory = try await prepareFiles(
                    .vocabulary, modelsDirectory, downloadIfMissing, notify
                ) {
                    notify("Preparing vocabulary model…", nil)
                    ctc = try await (CtcModels.loadDirect(from: directory, variant: .ctc110m),
                                     CtcTokenizer.load(from: directory))
                }
                if let ctc {
                    try await configureBoosting(vocabulary, manager: manager, ctc: ctc)
                } else {
                    configured = []
                }
            } catch {
                // Aliases and canonical spellings still apply when the optional CTC model is unavailable.
                Self.logger.error("Vocabulary model preparation failed: \(error.localizedDescription, privacy: .public)")
                if !downloadIfMissing { configured = [] }
            }
        }
        self.manager = manager
        configuredVocabulary = configured
    }

    func transcribe(_ audio: SpeechAudio, partial: @escaping SpeechPartial) async throws -> String {
        guard let manager else { throw VoiceAudioError.unsupportedSpeech }
        try await manager.reset()
        var previous = ""
        var heardAudio = false
        for await samples in audio where !samples.isEmpty {
            try Task.checkCancellation()
            heardAudio = true
            try await manager.appendAudio(.speechBuffer(samples))
            try await manager.processBufferedAudio()
            let text = await manager.getPartialTranscript()
            if text != previous {
                partial(text)
                previous = text
            }
        }
        try Task.checkCancellation()
        guard heardAudio else { return "" }
        return try await manager.finish()
    }

    private func configureBoosting(
        _ words: [SpeechCustomWord], manager: StreamingUnifiedAsrManager, ctc: (models: CtcModels, tokenizer: CtcTokenizer)
    ) async throws {
        let terms: [CustomVocabularyTerm] = words.compactMap { word in
            let tokens = ctc.tokenizer.encode(word.term)
            guard !tokens.isEmpty else { return nil }
            return CustomVocabularyTerm(text: word.term, aliases: word.aliases, ctcTokenIds: tokens)
        }
        guard !terms.isEmpty else { return }
        try await manager.configureVocabularyBoosting(
            vocabulary: CustomVocabularyContext(terms: terms), ctcModels: ctc.models
        )
    }
}
