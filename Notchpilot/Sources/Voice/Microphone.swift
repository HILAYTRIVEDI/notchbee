import AVFoundation
import NotchpilotCore

enum VoiceAudioError: LocalizedError {
    case microphonePermission, speechPermission, microphoneUnavailable, unsupportedSpeech, audioConversion

    var errorDescription: String? {
        switch self {
        case .microphonePermission: "Allow \(Product.name) to use the microphone in System Settings → Privacy & Security."
        case .speechPermission: "Allow \(Product.name) to use Speech Recognition in System Settings → Privacy & Security."
        case .microphoneUnavailable: "No microphone is available. Check the Sound input settings."
        case .unsupportedSpeech: "On-device Apple Speech is unavailable for this Mac or language."
        case .audioConversion: "\(Product.name) could not read the recorded audio."
        }
    }
}

@MainActor
final class Microphone: SpeechAudioSource {
    private let engine = AVAudioEngine()
    private var continuation: SpeechAudio.Continuation?

    func requestPermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
        default:
            break
        }
        throw VoiceAudioError.microphonePermission
    }

    func start() throws -> SpeechAudio {
        stop()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceAudioError.microphoneUnavailable }
        let converter = try PCMConverter(from: format, to: .speechPCM)
        let (stream, output) = SpeechAudio.makeStream()
        continuation = output
        // Core Audio invokes this tap serially. The converter belongs to this tap alone.
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in
            guard let converted = try? converter.convert(buffer),
                  let channel = converted.floatChannelData?[0], converted.frameLength > 0 else { return }
            output.yield(Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))))
        }
        do {
            engine.prepare()
            try engine.start()
            return stream
        } catch {
            stop()
            throw VoiceAudioError.microphoneUnavailable
        }
    }

    func stop() {
        guard let continuation else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        continuation.finish()
        self.continuation = nil
    }
}

extension AVAudioFormat {
    static var speechPCM: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    }
}

extension AVAudioPCMBuffer {
    static func speechBuffer(_ samples: [Float]) throws -> AVAudioPCMBuffer {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: .speechPCM, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw VoiceAudioError.audioConversion }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { source in
            if let address = source.baseAddress { channel.update(from: address, count: source.count) }
        }
        return buffer
    }
}

/// Each instance is confined to one audio tap or one serial transcription loop.
final class PCMConverter: @unchecked Sendable {
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    init(from input: AVAudioFormat, to output: AVAudioFormat) throws {
        outputFormat = output
        if input == output {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: input, to: output) else {
                throw VoiceAudioError.audioConversion
            }
            self.converter = converter
        }
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let converter else { return input }
        let capacity = (Double(input.frameLength) * outputFormat.sampleRate / input.format.sampleRate).rounded(.up)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(capacity) + 64)
        else { throw VoiceAudioError.audioConversion }
        let feed = ConverterInput(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            inputStatus.pointee = feed.buffer == nil ? .noDataNow : .haveData
            defer { feed.buffer = nil }
            return feed.buffer
        }
        guard status != .error else { throw error.map { $0 as Error } ?? VoiceAudioError.audioConversion }
        return output
    }

    // AVAudioConverter invokes its input block synchronously.
    private final class ConverterInput: @unchecked Sendable {
        var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }
}
