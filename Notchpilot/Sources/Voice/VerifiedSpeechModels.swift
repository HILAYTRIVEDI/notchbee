import CryptoKit
import Foundation
import OSLog

/// Downloads only the files used by the local loaders, from immutable Hugging Face revisions.
struct VerifiedSpeechModels: Sendable {
    let name: String
    let revision: String
    let files: [String: String]

    private static let logger = Logger(subsystem: "com.hilaytrivedi.Notchbee", category: "SpeechModels")

    func isInstalled(in root: URL) -> Bool {
        (try? installedDirectory(in: root).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func installedDirectory(in root: URL) -> URL {
        root.appending(path: name, directoryHint: .isDirectory)
    }

    @concurrent
    func prepare(
        in root: URL, downloadIfMissing: Bool, progress: @Sendable (String, Double?) async -> Void
    ) async throws -> URL? {
        let fm = FileManager.default
        try Self.privateDirectory(root)
        let directory = installedDirectory(in: root)
        await progress("Checking \(name) files…", nil)
        if try matchesManifest(at: directory) { return directory }
        guard downloadIfMissing else { return nil }

        if (try? fm.attributesOfItem(atPath: directory.path)) != nil {
            try fm.removeItem(at: directory)
        }
        let staging = root.appending(path: ".download-\(UUID())", directoryHint: .isDirectory)
        try Self.privateDirectory(staging)
        defer { try? fm.removeItem(at: staging) }

        let session = URLSession(configuration: .ephemeral, delegate: HTTPSOnly(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let base = URL(string: "https://huggingface.co/FluidInference/")!
            .appending(path: "\(name)/resolve/\(revision)/", directoryHint: .isDirectory)
        for (index, path) in files.keys.sorted().enumerated() {
            try Task.checkCancellation()
            await progress("Downloading \(name)…", Double(index) / Double(files.count))
            let (download, response) = try await session.download(from: base.appending(path: path))
            defer { try? fm.removeItem(at: download) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.url?.scheme == "https" else { throw ModelError.download(name) }
            guard try Self.sha256(download) == files[path] else { throw ModelError.integrity(path) }
            let destination = staging.appending(path: path)
            try Self.privateDirectory(destination.deletingLastPathComponent())
            try fm.moveItem(at: download, to: destination)
        }
        try Task.checkCancellation()
        // The staging tree contains only files that passed verification.
        try fm.moveItem(at: staging, to: directory)
        Self.logger.info("Installed verified speech model \(name, privacy: .public)")
        return directory
    }

    private func matchesManifest(at directory: URL) throws -> Bool {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        guard let root = try? directory.resourceValues(forKeys: keys),
              root.isSymbolicLink == false, root.isDirectory == true else { return false }
        try Self.privateDirectory(directory)
        var enumerationError: Error?
        guard let entries = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.producesRelativePathURLs],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else { return false }
        var verified = Set<String>()
        for case let entry as URL in entries {
            try Task.checkCancellation()
            let values = try entry.resourceValues(forKeys: keys)
            guard values.isSymbolicLink == false else { return false }
            let path = entry.relativePath
            if values.isDirectory == true {
                guard files.keys.contains(where: { $0.hasPrefix(path + "/") }) else { return false }
                try Self.privateDirectory(entry)
            } else {
                guard values.isRegularFile == true, let expected = files[path],
                      try Self.sha256(entry) == expected else { return false }
                verified.insert(path)
            }
        }
        if let enumerationError { throw enumerationError }
        return verified.count == files.count
    }

    private static func privateDirectory(_ directory: URL) throws {
        let fm = FileManager.default
        let permissions: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: permissions)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink == false else {
            throw ModelError.integrity(directory.lastPathComponent)
        }
        try fm.setAttributes(permissions, ofItemAtPath: directory.path)
    }

    private static func sha256(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private final class HTTPSOnly: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
        ) async -> URLRequest? {
            request.url?.scheme == "https" ? request : nil
        }
    }

    private enum ModelError: LocalizedError {
        case download(String)
        case integrity(String)

        var errorDescription: String? {
            switch self {
            case .download(let model): "Could not download \(model)."
            case .integrity(let file): "Speech model integrity check failed for \(file)."
            }
        }
    }
}

extension VerifiedSpeechModels {
    static let parakeet = Self(
        name: "parakeet-unified-en-0.6b-coreml",
        revision: "d32e972dd4315f1dc3f6be28fb2aab0ab3e80358",
        files: [
            "parakeet_unified_decoder.mlmodelc/analytics/coremldata.bin":
                "9ae70f6559989f88b856b326e59315798f9f0d08207a19fcc2dd3287a30088a5",
            "parakeet_unified_decoder.mlmodelc/coremldata.bin":
                "ce99c4488840fc463d59f8d4d6d2a9e8ceae8138ead51e3c265dde4d2ba4a0e9",
            "parakeet_unified_decoder.mlmodelc/model.mil":
                "6e60965b89c93943aa2be2d991c2461108145851fde05e1d048223a32d4cb20d",
            "parakeet_unified_decoder.mlmodelc/weights/weight.bin":
                "96f990461a5986d5e7309ad1a0f36084fbf0f4b28aec35948f8b8d0dcbf8599e",
            "parakeet_unified_encoder_streaming_70_13_13_int8.mlmodelc/analytics/coremldata.bin":
                "ffbbab2cbdc941dd88fc41c41d3f7ac61cc31475a17a1cb06ed7f3b0b25c611b",
            "parakeet_unified_encoder_streaming_70_13_13_int8.mlmodelc/coremldata.bin":
                "e1ffdae252dcc276ff2964ee2259a63d9c519b8413302609300d692f6a79b824",
            "parakeet_unified_encoder_streaming_70_13_13_int8.mlmodelc/model.mil":
                "64a4bdf20760025c8df072872b9aa71fdbce938f469c976fda690354424cc93c",
            "parakeet_unified_encoder_streaming_70_13_13_int8.mlmodelc/weights/weight.bin":
                "259e5818cf4acee1155409a048ec408eecd8cfc27ade04ba18bca243398cc9b6",
            "parakeet_unified_joint_decision_single_step.mlmodelc/analytics/coremldata.bin":
                "163877ad14af97ec4107cd854fd1c6d336ee5d40ad25a657cc764fb763f452f5",
            "parakeet_unified_joint_decision_single_step.mlmodelc/coremldata.bin":
                "68a081570a48b52ec9379e153bd56748a5408a50be16767601563f231eaeff03",
            "parakeet_unified_joint_decision_single_step.mlmodelc/model.mil":
                "03c21096090bcd0b71c896c5ae0eb815db31a91c6676f572a7868eee4299abe3",
            "parakeet_unified_joint_decision_single_step.mlmodelc/weights/weight.bin":
                "06831afa6d1beb0c0b10350ebf7886bc37638e951d14e738d7e06fbd2a05012f",
            "vocab.json":
                "e1a7bff4f5df133c0f4ad47b8e43c96f6bf1865d99126a4c4725ef51d0108bec",
        ]
    )
    static let vocabulary = Self(
        name: "parakeet-ctc-110m-coreml",
        revision: "accdafd8cf8a2ff1cabe3c11e54416b405d409aa",
        files: [
            "AudioEncoder.mlmodelc/analytics/coremldata.bin":
                "8906c823e9bb3bf6b16d9f0308f98cd70573526333ad85dd767dc3f9ae6b25fa",
            "AudioEncoder.mlmodelc/coremldata.bin":
                "a88b002b58193b4c31211754cdfdf220a85f9651dc61caf336ab84400cbc191a",
            "AudioEncoder.mlmodelc/metadata.json":
                "4f288bfe5cbe867ef1e592cdae33578b2fe59ada69182fc12209879558f985c2",
            "AudioEncoder.mlmodelc/model.mil":
                "2f84ef93a69115e55f3b5d8ce695b3c937de1833d4d229620634fae967cd587e",
            "AudioEncoder.mlmodelc/weights/weight.bin":
                "af0734b4a5d7465ad9e8bb170f0c53c5e6b91ebb75a9bdf88d3f59ae4ad6aebd",
            "MelSpectrogram.mlmodelc/analytics/coremldata.bin":
                "22f2a8cba1de25c984050566b534a1d8caf22a82f9fe6c1c6f3149a0dd7e8ae3",
            "MelSpectrogram.mlmodelc/coremldata.bin":
                "3a32ec67c76aa0aa2faef518413c311493e89aeb7fa11289fa4b8653ab8a160c",
            "MelSpectrogram.mlmodelc/metadata.json":
                "5e11d21a65c02bcfc37db43e941978e5d60d59e0efeadfda08e41f33b4f835d3",
            "MelSpectrogram.mlmodelc/model.mil":
                "0a7cb5693b39667295218bac5c7c09053f6bcd4b32699a83d06ac35d14ac6b79",
            "MelSpectrogram.mlmodelc/weights/weight.bin":
                "0a89c055bfde9022029d3cc59a23e949385e063974460d8eaec3a7614c3eaaa8",
            "tokenizer.json":
                "9f7c517c0bf644b1b690ab037bab4d4c53aecd38e047e7154d011013ab9160db",
            "vocab.json":
                "319d386eead79aadc80df9c3ecc8340d1a727efb7c02a8847eb940380dd61e1f",
        ]
    )
}
