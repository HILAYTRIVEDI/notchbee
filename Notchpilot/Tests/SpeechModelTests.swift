import Foundation
import Testing
@testable import Notchpilot

@MainActor
struct SpeechModelTests {
    #if arch(arm64)
    @Test(.timeLimit(.minutes(1)))
    func cancelingCaptureLeavesOnePreparationForTheNextCapture() async throws {
        let (release, gate) = AsyncStream<Void>.makeStream()
        let (started, start) = AsyncStream<Void>.makeStream()
        let (joined, join) = AsyncStream<Void>.makeStream()
        let requests = PreparationRequests()
        let transcriber = ParakeetTranscriber { _, _, downloadIfMissing, progress in
            await requests.append(downloadIfMissing)
            await progress("Downloading", 0.5)
            start.finish()
            for await _ in release {}
            throw TestError.offline
        }

        let first = Task { try await transcriber.prepare(vocabulary: []) { _, _ in } }
        for await _ in started {}
        first.cancel()
        do {
            try await first.value
            Issue.record("Canceled capture finished successfully")
        } catch {
            #expect(error is CancellationError)
        }

        let second = Task {
            try await transcriber.prepare(vocabulary: []) { message, progress in
                #expect(message == "Downloading")
                #expect(progress == 0.5)
                join.finish()
            }
        }
        for await _ in joined {}
        #expect(await requests.downloads == [true])
        gate.finish()
        do {
            try await second.value
            Issue.record("Missing model was reported as loaded")
        } catch {
            #expect(error as? TestError == .offline)
        }
    }
    #endif

    @Test func cacheOnlyChecksThePinnedFilesWithoutDownloadingOrRemovingThem() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let model = VerifiedSpeechModels(name: "tiny-model", revision: "test", files: [
            "encoder.mlmodelc/weights.bin": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        ])
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appending(path: "tiny-model/encoder.mlmodelc")
        let weights = bundle.appending(path: "weights.bin")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: weights)
        #expect(model.isInstalled(in: directory))
        let cached = try await model.prepare(in: directory, downloadIfMissing: false) { _, _ in }
        #expect(cached?.lastPathComponent == "tiny-model")

        try Data("xyz".utf8).write(to: weights)
        let corrupt = try await model.prepare(in: directory, downloadIfMissing: false) { _, _ in }
        #expect(corrupt == nil)
        #expect(try Data(contentsOf: weights) == Data("xyz".utf8))

        let validBytes = directory.appending(path: "outside-bundle.bin")
        try Data("abc".utf8).write(to: validBytes)
        try FileManager.default.removeItem(at: weights)
        try FileManager.default.createSymbolicLink(at: weights, withDestinationURL: validBytes)
        let symlink = try await model.prepare(in: directory, downloadIfMissing: false) { _, _ in }
        #expect(symlink == nil)
    }

    private enum TestError: Error { case offline }

    private actor PreparationRequests {
        private(set) var downloads: [Bool] = []
        func append(_ value: Bool) { downloads.append(value) }
    }
}
