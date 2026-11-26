import Foundation

// Source control and editor calls. Method names, payloads and results follow
// engine/packages/contracts/src (rpc.ts, git.ts, pullRequest.ts, editor.ts).

extension T3Client {
    /// Everything the notch calls, and no more. `source-control:write` covers branch switches, commits, pushes,
    /// pulls and pull-request actions; the git, pull request and editor reads and `shell.openInEditor` need
    /// nothing beyond the orchestration scopes.
    nonisolated static let requestedScopes = [
        "orchestration:read", "orchestration:operate", "settings:write", "providers:manage",
        "diagnostics:read", "source-control:write"
    ]

    /// One progress event of `git.runStackedAction`.
    struct GitProgress: Decodable {
        enum Interpretation: Equatable {
            case event(GitActionEvent)
            case failure(String)
        }

        struct Result: Decodable {
            struct Commit: Decodable { let status: String?; let subject: String? }
            struct Push: Decodable { let status: String? }
            struct PullRequest: Decodable { let status: String?; let url: String? }
            struct Toast: Decodable { let title: String; let description: String? }
            let commit: Commit?
            let push: Push?
            let pr: PullRequest?
            let toast: Toast?
        }

        let kind: String
        let phase: String?
        let label: String?
        let text: String?
        let message: String?
        let result: Result?

        var event: Interpretation? {
            switch kind {
            case "phase_started":
                return label.map { .event(.phase(Product.displayText($0))) }
            case "hook_output":
                return text.map { .event(.output(Product.displayText($0))) }
            case "action_failed":
                return .failure(Product.displayText(message ?? "The action failed."))
            case "action_finished":
                guard let result else { return .event(.finished(.init(title: "Done"))) }
                let committed = result.commit?.status == "created"
                let pushed = result.push?.status == "pushed"
                let title = result.toast?.title ?? (committed ? "Committed" : pushed ? "Pushed" : "Nothing to do")
                return .event(.finished(.init(
                    title: Product.displayText(title), detail: result.toast?.description.map(Product.displayText),
                    committed: committed, pushed: pushed, pullRequestURL: result.pr?.url
                )))
            default:
                return nil
            }
        }
    }

    // MARK: Payloads

    struct VcsCwd: Encodable, Sendable { let cwd: String }

    struct ListRefsPayload: Encodable, Sendable {
        let cwd: String
        let query: String?
        let limit: Int
        let includeMatchingRemoteRefs = true
    }

    struct RefPayload: Encodable, Sendable {
        let cwd: String
        let refName: String
        let switchRef: Bool?
    }

    struct OpenEditorPayload: Encodable, Sendable {
        let cwd: String
        let editor: String
    }

    struct ResolvePullRequestPayload: Encodable, Sendable {
        let cwd: String
        let reference: String
    }

    struct PullRequestRefPayload: Encodable, Sendable {
        let projectId: String
        let repository: String
        let number: Int
    }

    struct PullRequestActionPayload: Encodable, Sendable {
        let projectId: String
        let repository: String
        let number: Int
        let action: String
        let mergeMethod: String
    }

    struct StackedActionPayload: Encodable, Sendable {
        let actionId: String
        let cwd: String
        let action: String
        let commitMessage: String?
        let threadId: String?
        let projectId: String?

        init(_ request: GitActionRequest) {
            actionId = request.id
            cwd = request.cwd
            action = request.kind.rawValue
            commitMessage = request.commitMessage
            threadId = request.threadID
            projectId = request.projectID
        }
    }

    // MARK: Results

    struct StatusWire: Decodable {
        struct WorkingTree: Decodable {
            struct File: Decodable { let path: String }
            let files: [File]?
            let insertions: Int?
            let deletions: Int?
        }
        struct BranchChanges: Decodable {
            let baseRef: String?
            let insertions: Int?
            let deletions: Int?
        }
        struct PullRequest: Decodable {
            let number: Int
            let title: String
            let url: String
            let baseRef: String?
            let headRef: String?
            let state: String
            let isDraft: Bool?
        }

        let isRepo: Bool
        let hasPrimaryRemote: Bool?
        let isDefaultRef: Bool?
        let refName: String?
        let hasWorkingTreeChanges: Bool?
        let workingTree: WorkingTree?
        let branchChanges: BranchChanges?
        let hasUpstream: Bool?
        let aheadCount: Int?
        let behindCount: Int?
        let pr: PullRequest?
    }

    struct RefsWire: Decodable {
        struct Ref: Decodable {
            let name: String
            let isRemote: Bool?
            let remoteName: String?
            let current: Bool?
            let isDefault: Bool?
            let worktreePath: String?
        }
        let refs: [Ref]
        let totalCount: Int?
    }

    struct PullRequestDetailWire: Decodable {
        struct Check: Decodable {
            let status: String
            let placeholder: Bool?
        }
        struct Capabilities: Decodable {
            let merge: Bool?
            let squash: Bool?
            let rebase: Bool?
        }
        let repository: String
        let number: Int
        let title: String
        let url: String
        let state: String
        let isDraft: Bool?
        let mergeability: String?
        let baseBranch: String?
        let headBranch: String?
        let checks: [Check]?
        let mergeCapabilities: Capabilities?
    }

    struct ResolvedPullRequestWire: Decodable {
        struct PullRequest: Decodable {
            let number: Int
            let title: String
            let url: String
            let baseBranch: String?
            let headBranch: String?
            let state: String
        }
        let pullRequest: PullRequest
    }

    struct PullWire: Decodable {
        let status: String
        let refName: String
    }

    nonisolated static func workspaceStatus(from result: ResultValue?) throws -> WorkspaceStatus {
        guard let wire = result?.wire?.decoded(StatusWire.self) else { throw ClientError.protocolMismatch }
        let tree = wire.workingTree
        return WorkspaceStatus(
            isRepository: wire.isRepo, branch: wire.refName, isDefaultBranch: wire.isDefaultRef ?? false,
            hasRemote: wire.hasPrimaryRemote ?? false, hasUpstream: wire.hasUpstream ?? false,
            ahead: wire.aheadCount ?? 0, behind: wire.behindCount ?? 0,
            hasUncommittedChanges: wire.hasWorkingTreeChanges ?? false,
            changedFiles: tree?.files?.count ?? 0, insertions: tree?.insertions ?? 0, deletions: tree?.deletions ?? 0,
            branchChanges: wire.branchChanges.map {
                .init(baseRef: $0.baseRef, insertions: $0.insertions ?? 0, deletions: $0.deletions ?? 0)
            },
            pullRequest: wire.pr.map {
                WorkspacePullRequest(number: $0.number, title: Product.displayText($0.title), url: $0.url,
                                     state: .init(rawValue: $0.state) ?? .open, isDraft: $0.isDraft ?? false,
                                     baseBranch: $0.baseRef, headBranch: $0.headRef)
            }
        )
    }

    nonisolated static func workspaceBranches(from result: ResultValue?) throws -> WorkspaceBranchPage {
        guard let wire = result?.wire?.decoded(RefsWire.self) else { throw ClientError.protocolMismatch }
        let branches = wire.refs.map {
            WorkspaceBranch(name: $0.name, isRemote: $0.isRemote ?? false, remoteName: $0.remoteName,
                            isCurrent: $0.current ?? false, isDefault: $0.isDefault ?? false,
                            worktreePath: $0.worktreePath)
        }
        return .init(branches: branches, total: wire.totalCount ?? branches.count)
    }

    nonisolated static func pullRequestDetail(from result: ResultValue?) throws -> WorkspacePullRequestDetail {
        guard let wire = result?.wire?.decoded(PullRequestDetailWire.self) else { throw ClientError.protocolMismatch }
        var checks = WorkspacePullRequestDetail.Checks()
        for check in wire.checks ?? [] where check.placeholder != true {
            switch check.status {
            case "success": checks.passing += 1
            case "failure", "cancelled", "action-required": checks.failing += 1
            case "pending": checks.pending += 1
            default: break
            }
        }
        let capabilities = wire.mergeCapabilities
        let methods = PullRequestMergeMethod.allCases.filter {
            switch $0 {
            case .merge: capabilities?.merge ?? true
            case .squash: capabilities?.squash ?? true
            case .rebase: capabilities?.rebase ?? true
            }
        }
        let pullRequest = WorkspacePullRequest(
            number: wire.number, title: Product.displayText(wire.title), url: wire.url,
            state: .init(rawValue: wire.state) ?? .open, isDraft: wire.isDraft ?? false,
            baseBranch: wire.baseBranch, headBranch: wire.headBranch
        )
        return .init(pullRequest: pullRequest, repository: wire.repository,
                     mergeability: wire.mergeability.flatMap(WorkspacePullRequestDetail.Mergeability.init(rawValue:)) ?? .unknown,
                     checks: checks, mergeMethods: methods)
    }

    nonisolated static func resolvedPullRequest(from result: ResultValue?) throws -> WorkspacePullRequest {
        guard let wire = result?.wire?.decoded(ResolvedPullRequestWire.self)?.pullRequest else {
            throw ClientError.protocolMismatch
        }
        return WorkspacePullRequest(number: wire.number, title: Product.displayText(wire.title), url: wire.url,
                                    state: .init(rawValue: wire.state) ?? .open,
                                    baseBranch: wire.baseBranch, headBranch: wire.headBranch)
    }

    nonisolated static func pullOutcome(from result: ResultValue?) throws -> WorkspacePullOutcome {
        guard let wire = result?.wire?.decoded(PullWire.self) else { throw ClientError.protocolMismatch }
        return .init(upToDate: wire.status == "skipped_up_to_date", branch: wire.refName)
    }

    nonisolated static func createdBranch(from result: ResultValue?) throws -> String {
        guard case .object(let fields)? = result?.wire, case .string(let name)? = fields["refName"] else {
            throw ClientError.protocolMismatch
        }
        return name
    }
}

extension T3Client: WorkspaceBackend {
    public func workspaceStatus(cwd: String) async throws -> WorkspaceStatus {
        try Self.workspaceStatus(from: try await requireConnection().call(
            "vcs.refreshStatus", VcsCwd(cwd: cwd), timeout: .seconds(30)))
    }

    public func workspaceBranches(cwd: String, query: String) async throws -> WorkspaceBranchPage {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return try Self.workspaceBranches(from: try await requireConnection().call(
            "vcs.listRefs", ListRefsPayload(cwd: cwd, query: trimmed.isEmpty ? nil : String(trimmed.prefix(256)), limit: 100)))
    }

    public func switchBranch(cwd: String, name: String) async throws {
        try await requireConnection().call("vcs.switchRef", RefPayload(cwd: cwd, refName: name, switchRef: nil),
                                           timeout: .seconds(45))
    }

    public func createBranch(cwd: String, name: String) async throws -> String {
        try Self.createdBranch(from: try await requireConnection().call(
            "vcs.createRef", RefPayload(cwd: cwd, refName: name, switchRef: true), timeout: .seconds(45)))
    }

    public func pullBranch(cwd: String) async throws -> WorkspacePullOutcome {
        try Self.pullOutcome(from: try await requireConnection().call(
            "vcs.pull", VcsCwd(cwd: cwd), timeout: .seconds(120)))
    }

    public func runGitAction(_ request: GitActionRequest) -> AsyncThrowingStream<GitActionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let connection = try self.requireConnection()
                    guard connection.actionRuns[request.id] == nil else { throw WorkspaceError.unavailable }
                    connection.actionRuns[request.id] = continuation
                    try await connection.subscribe(.action(request.id), method: "git.runStackedAction",
                                                   payload: StackedActionPayload(request))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { @MainActor in
                    guard let connection = self.connection, connection.actionRuns.removeValue(forKey: request.id) != nil
                    else { return }
                    // The caller stopped listening. The engine finishes the action on its own.
                    try? await connection.interrupt(.action(request.id))
                }
            }
        }
    }

    public func pullRequestDetail(of pullRequest: WorkspacePullRequest,
                                  projectID: String) async throws -> WorkspacePullRequestDetail {
        guard let repository = pullRequest.repository else { throw WorkspaceError.unavailable }
        return try Self.pullRequestDetail(from: try await requireConnection().call(
            "pullRequests.detail", PullRequestRefPayload(projectId: projectID, repository: repository,
                                                         number: pullRequest.number),
            timeout: .seconds(30)))
    }

    public func mergePullRequest(_ detail: WorkspacePullRequestDetail, projectID: String,
                                 method: PullRequestMergeMethod) async throws {
        try await requireConnection().call(
            "pullRequests.runAction",
            PullRequestActionPayload(projectId: projectID, repository: detail.repository,
                                     number: detail.pullRequest.number, action: "merge", mergeMethod: method.rawValue),
            timeout: .seconds(60))
    }

    public func resolvePullRequest(cwd: String, reference: String) async throws -> WorkspacePullRequest {
        try Self.resolvedPullRequest(from: try await requireConnection().call(
            "git.resolvePullRequest", ResolvePullRequestPayload(cwd: cwd, reference: reference), timeout: .seconds(30)))
    }

    public func availableEditors() async throws -> [WorkspaceEditor] {
        let result = try await requireConnection().call("server.getConfig", Empty())
        return WorkspaceEditor.detected(from: result?.availableEditors ?? [])
    }

    public func openInEditor(cwd: String, editor: WorkspaceEditor) async throws {
        try await requireConnection().call("shell.openInEditor", OpenEditorPayload(cwd: cwd, editor: editor.id))
    }
}
