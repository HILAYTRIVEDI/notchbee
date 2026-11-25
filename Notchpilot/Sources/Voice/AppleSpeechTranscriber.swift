import AVFoundation
import NotchpilotCore
import Speech

@MainActor
final class AppleSpeechTranscriber: NotchpilotCore.SpeechTranscriber {
    private var locale: Locale?
    private var vocabulary: [String] = []

    func prepare(vocabulary: [SpeechCustomWord], progress: @escaping SpeechProgress) async throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            let granted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
            guard granted else { throw VoiceAudioError.speechPermission }
        } else {
            guard status == .authorized else { throw VoiceAudioError.speechPermission }
        }
        try Task.checkCancellation()
        guard Speech.SpeechTranscriber.isAvailable else { throw VoiceAudioError.unsupportedSpeech }
        self.vocabulary = vocabulary.map(\.term)
        if locale != nil { return }

        let preferred = await Speech.SpeechTranscriber.supportedLocale(equivalentTo: .current)
        let english = preferred == nil
            ? await Speech.SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US"))
            : nil
        guard let locale = preferred ?? english else { throw VoiceAudioError.unsupportedSpeech }
        let transcriber = Speech.SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            progress("Installing Apple Speech model…", nil)
            try await request.downloadAndInstall()
        }
        self.locale = locale
    }

    func transcribe(_ audio: SpeechAudio, partial: @escaping SpeechPartial) async throws -> String {
        guard let locale else { throw VoiceAudioError.unsupportedSpeech }
        let transcriber = Speech.SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber], considering: .speechPCM
        ) else { throw VoiceAudioError.unsupportedSpeech }
        let converter = try PCMConverter(from: .speechPCM, to: format)
        let context = AnalysisContext()
        context.contextualStrings = [.general: vocabulary]
        try await analyzer.setContext(context)
        let input = AsyncStream<AnalyzerInput>.makeStream()
        let results = Task {
            var confirmed = ""
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                let combined = [confirmed, text].filter { !$0.isEmpty }.joined(separator: " ")
                if result.isFinal { confirmed = combined }
                partial(combined)
            }
            return confirmed
        }

        return try await withTaskCancellationHandler {
            do {
                try await analyzer.start(inputSequence: input.stream)
                var hasAudio = false
                for await samples in audio where !samples.isEmpty {
                    try Task.checkCancellation()
                    let pcm = try converter.convert(.speechBuffer(samples))
                    if pcm.frameLength > 0 {
                        input.continuation.yield(AnalyzerInput(buffer: pcm))
                        hasAudio = true
                    }
                }
                input.continuation.finish()
                try Task.checkCancellation()
                if hasAudio {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                    return try await results.value
                }
                results.cancel()
                await analyzer.cancelAndFinishNow()
                return ""
            } catch {
                input.continuation.finish()
                results.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            results.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}
