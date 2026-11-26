import Foundation

/// Source control and editor operations for the folder a thread works in: its worktree when it has one,
/// otherwise the project root.
@MainActor
public protocol WorkspaceBackend: AnyObject {
    func workspaceStatus(cwd: String) async throws -> WorkspaceStatus
    func workspaceBranches(cwd: String, query: String) async throws -> WorkspaceBranchPage
    /// Switches to a local branch, or creates a tracking branch for a remote one.
    func switchBranch(cwd: String, name: String) async throws
    /// Creates a branch from the current one and switches to it.
    func createBranch(cwd: String, name: String) async throws -> String
    func pullBranch(cwd: String) async throws -> WorkspacePullOutcome
    /// Streams progress for commit, push and pull-request steps. The stream throws when a step fails.
    func runGitAction(_ request: GitActionRequest) -> AsyncThrowingStream<GitActionEvent, Error>
    func pullRequestDetail(of pullRequest: WorkspacePullRequest, projectID: String) async throws -> WorkspacePullRequestDetail
    func mergePullRequest(_ detail: WorkspacePullRequestDetail, projectID: String, method: PullRequestMergeMethod) async throws
    /// Looks a pull request up again by number to confirm its current state.
    func resolvePullRequest(cwd: String, reference: String) async throws -> WorkspacePullRequest
    func availableEditors() async throws -> [WorkspaceEditor]
    func openInEditor(cwd: String, editor: WorkspaceEditor) async throws
}

public enum WorkspaceError: LocalizedError, Equatable {
    case unavailable
    case actionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Source control is unavailable on this connection."
        case .actionFailed(let message): message
        }
    }
}

public struct WorkspacePullRequest: Sendable, Equatable {
    public enum State: String, Sendable { case open, closed, merged }

    public let number: Int
    public let title: String
    public let url: String
    public let state: State
    public let isDraft: Bool
    public let baseBranch: String?
    public let headBranch: String?

    public init(number: Int, title: String, url: String, state: State, isDraft: Bool = false,
                baseBranch: String? = nil, headBranch: String? = nil) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.baseBranch = baseBranch
        self.headBranch = headBranch
    }

    /// `owner/name`, taken from a GitHub-style `…/pull/N` or GitLab-style `…/-/merge_requests/N` link.
    public var repository: String? {
        guard let components = URLComponents(string: url) else { return nil }
        var parts = components.path.split(separator: "/").map(String.init)
        if let index = parts.lastIndex(of: "pull") ?? parts.lastIndex(of: "merge_requests") {
            parts = Array(parts[..<index])
            if parts.last == "-" { parts.removeLast() }
        } else {
            return nil
        }
        return parts.count >= 2 ? parts.joined(separator: "/") : nil
    }
}

public struct WorkspaceStatus: Sendable, Equatable {
    public struct BranchChanges: Sendable, Equatable {
        public let baseRef: String?
        public let insertions: Int
        public let deletions: Int

        public init(baseRef: String?, insertions: Int, deletions: Int) {
            self.baseRef = baseRef
            self.insertions = insertions
            self.deletions = deletions
        }
    }

    public var isRepository: Bool
    public var branch: String?
    public var isDefaultBranch: Bool
    public var hasRemote: Bool
    public var hasUpstream: Bool
    public var ahead: Int
    public var behind: Int
    public var hasUncommittedChanges: Bool
    public var changedFiles: Int
    public var insertions: Int
    public var deletions: Int
    public var branchChanges: BranchChanges?
    public var pullRequest: WorkspacePullRequest?

    public init(isRepository: Bool = true, branch: String? = nil, isDefaultBranch: Bool = false, hasRemote: Bool = true,
                hasUpstream: Bool = false, ahead: Int = 0, behind: Int = 0, hasUncommittedChanges: Bool = false,
                changedFiles: Int = 0, insertions: Int = 0, deletions: Int = 0,
                branchChanges: BranchChanges? = nil, pullRequest: WorkspacePullRequest? = nil) {
        self.isRepository = isRepository
        self.branch = branch
        self.isDefaultBranch = isDefaultBranch
        self.hasRemote = hasRemote
        self.hasUpstream = hasUpstream
        self.ahead = ahead
        self.behind = behind
        self.hasUncommittedChanges = hasUncommittedChanges
        self.changedFiles = changedFiles
        self.insertions = insertions
        self.deletions = deletions
        self.branchChanges = branchChanges
        self.pullRequest = pullRequest
    }

    /// The branch's changes against what it tracks: the upstream when it has one, else the default branch.
    public var comparison: (label: String, insertions: Int, deletions: Int)? {
        if let changes = branchChanges, changes.insertions + changes.deletions > 0 {
            return (changes.baseRef.map { "vs \($0)" } ?? "vs base", changes.insertions, changes.deletions)
        }
        if insertions + deletions > 0 {
            return ("uncommitted", insertions, deletions)
        }
        return nil
    }
}

public struct WorkspaceBranch: Identifiable, Sendable, Equatable {
    public let name: String
    public let isRemote: Bool
    public let remoteName: String?
    public let isCurrent: Bool
    public let isDefault: Bool
    /// Set when another worktree already has this branch checked out.
    public let worktreePath: String?

    public var id: String { (isRemote ? "remote:" : "local:") + name }

    /// A remote branch without its `origin/` prefix.
    public var shortName: String {
        guard isRemote, let remoteName, name.hasPrefix(remoteName + "/") else { return name }
        return String(name.dropFirst(remoteName.count + 1))
    }

    public init(name: String, isRemote: Bool = false, remoteName: String? = nil, isCurrent: Bool = false,
                isDefault: Bool = false, worktreePath: String? = nil) {
        self.name = name
        self.isRemote = isRemote
        self.remoteName = remoteName
        self.isCurrent = isCurrent
        self.isDefault = isDefault
        self.worktreePath = worktreePath
    }
}

public struct WorkspaceBranchPage: Sendable, Equatable {
    public let branches: [WorkspaceBranch]
    public let total: Int

    public init(branches: [WorkspaceBranch], total: Int) {
        self.branches = branches
        self.total = total
    }
}

public enum PullRequestMergeMethod: String, CaseIterable, Sendable {
    case merge, squash, rebase

    public var label: String {
        switch self {
        case .merge: "Merge commit"
        case .squash: "Squash and merge"
        case .rebase: "Rebase and merge"
        }
    }
}

public struct WorkspacePullRequestDetail: Sendable, Equatable {
    public enum Mergeability: String, Sendable { case mergeable, conflicting, unknown }

    public struct Checks: Sendable, Equatable {
        public var passing = 0
        public var failing = 0
        public var pending = 0
        public var total: Int { passing + failing + pending }

        public init(passing: Int = 0, failing: Int = 0, pending: Int = 0) {
            self.passing = passing
            self.failing = failing
            self.pending = pending
        }

        public var summary: String? {
            guard total > 0 else { return nil }
            if failing > 0 { return "\(failing) failing" }
            if pending > 0 { return "\(pending) pending" }
            return "\(passing) passing"
        }
    }

    public let pullRequest: WorkspacePullRequest
    public let repository: String
    public let mergeability: Mergeability
    public let checks: Checks
    public let mergeMethods: [PullRequestMergeMethod]

    public init(pullRequest: WorkspacePullRequest, repository: String, mergeability: Mergeability = .unknown,
                checks: Checks = .init(), mergeMethods: [PullRequestMergeMethod] = PullRequestMergeMethod.allCases) {
        self.pullRequest = pullRequest
        self.repository = repository
        self.mergeability = mergeability
        self.checks = checks
        self.mergeMethods = mergeMethods
    }
}

public struct WorkspacePullOutcome: Sendable, Equatable {
    public let upToDate: Bool
    public let branch: String

    public init(upToDate: Bool, branch: String) {
        self.upToDate = upToDate
        self.branch = branch
    }
}

public enum GitActionKind: String, CaseIterable, Sendable {
    case commit
    case commitAndPush = "commit_push"
    case push
    case createPullRequest = "create_pr"
    case commitPushAndCreatePullRequest = "commit_push_pr"
}

public struct GitActionRequest: Sendable, Equatable {
    public let id: String
    public let cwd: String
    public let kind: GitActionKind
    /// Empty lets the engine write the message.
    public let commitMessage: String?
    public let threadID: String?
    public let projectID: String?

    public init(id: String = UUID().uuidString.lowercased(), cwd: String, kind: GitActionKind,
                commitMessage: String? = nil, threadID: String? = nil, projectID: String? = nil) {
        self.id = id
        self.cwd = cwd
        self.kind = kind
        let trimmed = commitMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.commitMessage = trimmed?.isEmpty == false ? trimmed : nil
        self.threadID = threadID
        self.projectID = projectID
    }
}

public struct GitActionOutcome: Sendable, Equatable {
    public let title: String
    public let detail: String?
    public let committed: Bool
    public let pushed: Bool
    public let pullRequestURL: String?

    public init(title: String, detail: String? = nil, committed: Bool = false, pushed: Bool = false,
                pullRequestURL: String? = nil) {
        self.title = title
        self.detail = detail
        self.committed = committed
        self.pushed = pushed
        self.pullRequestURL = pullRequestURL
    }
}

public enum GitActionEvent: Sendable, Equatable {
    /// A step began, such as "Committing…".
    case phase(String)
    /// Output from a commit or push hook.
    case output(String)
    case finished(GitActionOutcome)
}

public struct WorkspaceEditor: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// The engine's editor ids and labels (packages/contracts/src/editor.ts), in its order of preference.
    public static let known: [WorkspaceEditor] = [
        ("cursor", "Cursor"), ("trae", "Trae"), ("kiro", "Kiro"), ("vscode", "VS Code"),
        ("vscode-insiders", "VS Code Insiders"), ("vscodium", "VSCodium"), ("zed", "Zed"),
        ("antigravity", "Antigravity"), ("idea", "IntelliJ IDEA"), ("aqua", "Aqua"), ("clion", "CLion"),
        ("datagrip", "DataGrip"), ("dataspell", "DataSpell"), ("goland", "GoLand"), ("phpstorm", "PhpStorm"),
        ("pycharm", "PyCharm"), ("rider", "Rider"), ("rubymine", "RubyMine"), ("rustrover", "RustRover"),
        ("webstorm", "WebStorm")
    ].map { WorkspaceEditor(id: $0.0, name: $0.1) }

    public static let vscode = WorkspaceEditor(id: "vscode", name: "VS Code")

    /// Keeps the engine's editors it reports as installed, ignoring the file manager and unknown ids.
    public static func detected(from ids: [String]) -> [WorkspaceEditor] {
        let installed = Set(ids)
        return known.filter { installed.contains($0.id) }
    }

    /// The remembered editor when it is still installed, otherwise VS Code, otherwise the first installed one.
    public static func preferred(remembered: String?, among editors: [WorkspaceEditor]) -> WorkspaceEditor? {
        if let remembered, let match = editors.first(where: { $0.id == remembered }) { return match }
        return editors.first { $0.id == vscode.id } ?? editors.first
    }
}

/// How the branch menu treats a switch right now.
public enum BranchSwitchPolicy: Equatable, Sendable {
    case allowed
    /// The working tree has changes; git carries them over or refuses, so the user confirms first.
    case confirmUncommitted
    case blocked(String)

    public static func evaluate(agentRunning: Bool, hasUncommittedChanges: Bool, target: WorkspaceBranch) -> Self {
        if agentRunning { return .blocked("The agent is running in this thread. Stop it before switching branches.") }
        if target.isCurrent { return .blocked("Already on \(target.shortName).") }
        if let path = target.worktreePath, !target.isRemote {
            return .blocked("\(target.name) is checked out in another worktree (\(path)).")
        }
        return hasUncommittedChanges ? .confirmUncommitted : .allowed
    }
}

/// Branch names the engine would pass to git. Mirrors git's own refusals closely enough to catch typos early.
public enum BranchNameValidation {
    public static func problem(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Enter a branch name." }
        if name.hasPrefix("-") { return "A branch name can’t start with a dash." }
        if name.hasPrefix("/") || name.hasSuffix("/") || name.hasSuffix(".") || name.hasSuffix(".lock") {
            return "That isn’t a valid branch name."
        }
        if name.contains("..") || name.contains("//") || name.contains("@{") || name == "@" {
            return "That isn’t a valid branch name."
        }
        if name.contains(where: { " ~^:?*[\\".contains($0) || $0.isNewline || $0.asciiValue.map { $0 < 32 || $0 == 127 } == true }) {
            return "A branch name can’t contain spaces or ~ ^ : ? * [ \\."
        }
        if name.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
            return "A branch name segment can’t start with a dot."
        }
        return nil
    }
}
