import Foundation
import NotchpilotCore

/// An in-memory repository so the workspace menu works offline in Fake mode. It never touches a real folder.
struct FakeRepository {
    static let path = "/Users/demo/notchbee-demo"

    var branch = "feature/workspace-menu"
    var localBranches = ["main", "feature/workspace-menu", "fix/timeline-scroll"]
    var remoteBranches = ["origin/main", "origin/feature/workspace-menu", "origin/release/1.0"]
    var changedFiles = 3
    var insertions = 42
    var deletions = 7
    var ahead = 1
    var behind = 0
    var hasUpstream = true
    var pullRequest: WorkspacePullRequest? = WorkspacePullRequest(
        number: 12, title: "Add the workspace menu to the thread view",
        url: "https://github.com/demo/notchbee-demo/pull/12", state: .open,
        baseBranch: "main", headBranch: "feature/workspace-menu"
    )
    var editors = ["vscode", "cursor", "zed"]
}

extension FakeBackend: WorkspaceBackend {
    private func pause(_ milliseconds: Int = 450) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }

    func workspaceStatus(cwd: String) async throws -> WorkspaceStatus {
        try await pause(150)
        let repo = repository
        let onDefault = repo.branch == "main"
        let committed = repo.ahead > 0 ? 118 : 0
        return WorkspaceStatus(
            branch: repo.branch, isDefaultBranch: onDefault, hasUpstream: repo.hasUpstream, ahead: repo.ahead,
            behind: repo.behind, hasUncommittedChanges: repo.changedFiles > 0, changedFiles: repo.changedFiles,
            insertions: repo.insertions, deletions: repo.deletions,
            branchChanges: onDefault ? nil : .init(baseRef: "origin/\(repo.branch)", insertions: committed + repo.insertions,
                                                   deletions: committed / 8 + repo.deletions),
            pullRequest: onDefault ? nil : repo.pullRequest
        )
    }

    func workspaceBranches(cwd: String, query: String) async throws -> WorkspaceBranchPage {
        try await pause(150)
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let local = repository.localBranches.map {
            WorkspaceBranch(name: $0, isCurrent: $0 == repository.branch, isDefault: $0 == "main")
        }
        let remote = repository.remoteBranches.map {
            WorkspaceBranch(name: $0, isRemote: true, remoteName: "origin", isDefault: $0 == "origin/main")
        }
        let all = (local + remote).filter { needle.isEmpty || $0.name.lowercased().contains(needle) }
        return .init(branches: all, total: all.count)
    }

    func switchBranch(cwd: String, name: String) async throws {
        try await pause()
        let short = name.hasPrefix("origin/") ? String(name.dropFirst(7)) : name
        guard repository.localBranches.contains(short) || repository.remoteBranches.contains(name) else {
            throw WorkspaceError.actionFailed("Branch \(name) was not found.")
        }
        if !repository.localBranches.contains(short) { repository.localBranches.append(short) }
        repository.branch = short
        repository.pullRequest = short == "feature/workspace-menu" ? WorkspacePullRequest(
            number: 12, title: "Add the workspace menu to the thread view",
            url: "https://github.com/demo/notchbee-demo/pull/12", state: .open,
            baseBranch: "main", headBranch: short) : nil
    }

    func createBranch(cwd: String, name: String) async throws -> String {
        try await pause()
        guard !repository.localBranches.contains(name) else {
            throw WorkspaceError.actionFailed("A branch named \(name) already exists.")
        }
        repository.localBranches.append(name)
        repository.branch = name
        repository.ahead = 0
        repository.hasUpstream = false
        repository.pullRequest = nil
        return name
    }

    func pullBranch(cwd: String) async throws -> WorkspacePullOutcome {
        try await pause(700)
        let upToDate = repository.behind == 0
        repository.behind = 0
        return .init(upToDate: upToDate, branch: repository.branch)
    }

    func runGitAction(_ request: GitActionRequest) -> AsyncThrowingStream<GitActionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor [self] in
                do {
                    var committed = false
                    var pushed = false
                    var pullRequestURL: String?
                    let kind = request.kind
                    if kind == .commit || kind == .commitAndPush || kind == .commitPushAndCreatePullRequest {
                        continuation.yield(.phase("Committing…"))
                        try await pause(600)
                        committed = repository.changedFiles > 0
                        repository.changedFiles = 0
                        repository.insertions = 0
                        repository.deletions = 0
                        if committed { repository.ahead += 1 }
                    }
                    if kind != .commit && kind != .createPullRequest {
                        continuation.yield(.phase("Pushing…"))
                        continuation.yield(.output("Fake hook: checks passed"))
                        try await pause(800)
                        pushed = repository.ahead > 0 || !repository.hasUpstream
                        repository.ahead = 0
                        repository.hasUpstream = true
                    }
                    if kind == .createPullRequest || kind == .commitPushAndCreatePullRequest {
                        continuation.yield(.phase("Creating pull request…"))
                        try await pause(700)
                        let pr = repository.pullRequest ?? WorkspacePullRequest(
                            number: 13, title: request.commitMessage ?? "Update \(repository.branch)",
                            url: "https://github.com/demo/notchbee-demo/pull/13", state: .open,
                            baseBranch: "main", headBranch: repository.branch)
                        repository.pullRequest = pr
                        pullRequestURL = pr.url
                    }
                    let title = pullRequestURL != nil ? "Pull request ready" : pushed ? "Pushed to origin/\(repository.branch)"
                        : committed ? "Committed" : "Nothing to do"
                    continuation.yield(.finished(.init(title: title, committed: committed, pushed: pushed,
                                                       pullRequestURL: pullRequestURL)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func pullRequestDetail(of pullRequest: WorkspacePullRequest, projectID: String) async throws -> WorkspacePullRequestDetail {
        try await pause(200)
        let current = repository.pullRequest ?? pullRequest
        return .init(pullRequest: current, repository: "demo/notchbee-demo", mergeability: .mergeable,
                     checks: .init(passing: 4, failing: 0, pending: 1), mergeMethods: [.squash, .merge])
    }

    func mergePullRequest(_ detail: WorkspacePullRequestDetail, projectID: String, method: PullRequestMergeMethod) async throws {
        try await pause(900)
        let merged = detail.pullRequest
        repository.pullRequest = WorkspacePullRequest(
            number: merged.number, title: merged.title, url: merged.url, state: .merged,
            baseBranch: merged.baseBranch, headBranch: merged.headBranch)
    }

    func resolvePullRequest(cwd: String, reference: String) async throws -> WorkspacePullRequest {
        try await pause(150)
        guard let pr = repository.pullRequest else { throw WorkspaceError.actionFailed("Pull request not found.") }
        return pr
    }

    func availableEditors() async throws -> [WorkspaceEditor] {
        WorkspaceEditor.detected(from: repository.editors)
    }

    func openInEditor(cwd: String, editor: WorkspaceEditor) async throws {
        try await pause(250)
    }
}
