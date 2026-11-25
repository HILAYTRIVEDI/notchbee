import Darwin
import Foundation

extension T3Client {
    @MainActor
    final class ScratchProject {
        struct Registration: Encodable, Sendable {
            let type = "project.create"
            let commandId = UUID().uuidString.lowercased()
            let projectId = UUID().uuidString.lowercased()
            let title = "\(Product.name) Scratch"
            let workspaceRoot: String
        }

        enum Failure: LocalizedError {
            case invalidFolder, archivedProject

            var errorDescription: String? {
                switch self {
                case .invalidFolder: "\(Product.name) Scratch must be a folder in your home directory."
                case .archivedProject: "The \(Product.name) Scratch project is archived."
                }
            }
        }

        private let folder: URL
        private var registration: Task<String, Error>?
        private var awaitingShellID: String?

        init(folder: URL = URL(filePath: NSHomeDirectory()).appending(path: "\(Product.name) Scratch")) {
            self.folder = folder.standardizedFileURL
        }

        func observe(_ projectID: String) {
            if awaitingShellID == projectID { awaitingShellID = nil }
        }

        func resolve(
            projects: @escaping () -> [Project],
            register: @escaping (Registration) async throws -> Void
        ) async throws -> String {
            try Task.checkCancellation()
            try ensureFolder()
            let workspace = folder.resolvingSymlinksInPath().path
            func matchingProject() -> Project? {
                projects().first {
                    URL(filePath: $0.workspaceRoot).standardizedFileURL.resolvingSymlinksInPath().path == workspace
                }
            }
            if let existing = matchingProject() {
                observe(existing.id)
                guard existing.archivedAt == nil else { throw Failure.archivedProject }
                return existing.id
            }
            if let awaitingShellID { return awaitingShellID }
            if let registration { return try await registration.value }

            let command = Registration(workspaceRoot: workspace)
            let task = Task {
                defer { registration = nil }
                do {
                    try await register(command)
                } catch {
                    if let existing = matchingProject(), existing.archivedAt == nil { return existing.id }
                    throw error
                }
                if matchingProject() == nil { awaitingShellID = command.projectId }
                return command.projectId
            }
            registration = task
            return try await task.value
        }

        private func ensureFolder() throws {
            if mkdir(folder.path, 0o700) == 0 { return }
            let failure = errno
            guard failure == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
            var info = stat()
            guard lstat(folder.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR else { throw Failure.invalidFolder }
        }
    }
}
