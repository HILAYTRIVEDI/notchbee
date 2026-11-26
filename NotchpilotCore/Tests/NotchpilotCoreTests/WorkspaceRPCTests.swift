import Foundation
import Testing
@testable import NotchpilotCore

/// Request payloads and result shapes follow engine/packages/contracts/src (rpc.ts, git.ts, editor.ts, pullRequest.ts).
struct WorkspaceRPCTests {
    private func json(_ value: some Encodable) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? NSDictionary)
    }

    private func result(_ value: String) throws -> T3Client.ResultValue? {
        let frame = #"{"_tag":"Exit","requestId":"1","exit":{"_tag":"Success","value":\#(value)}}"#
        guard case .exit(_, let exit) = try T3Client.decodeFrame(Data(frame.utf8)) else {
            Issue.record("Expected an exit frame")
            return nil
        }
        return exit.value
    }

    // MARK: Requests

    @Test func encodesTheStatusAndPullRequests() throws {
        #expect(try json(T3Client.VcsCwd(cwd: "/w/app")) == ["cwd": "/w/app"])
        let frame = try json(T3Client.Request(id: "9", method: "vcs.refreshStatus", payload: T3Client.VcsCwd(cwd: "/w/app")))
        #expect(frame == ["_tag": "Request", "tag": "vcs.refreshStatus", "id": "9",
                          "payload": ["cwd": "/w/app"], "headers": [] as [Any]])
    }

    @Test func encodesTheBranchList() throws {
        let payload = T3Client.ListRefsPayload(cwd: "/w/app", query: "feat", limit: 100)
        #expect(try json(payload) == ["cwd": "/w/app", "query": "feat", "limit": 100, "includeMatchingRemoteRefs": true])
        // An empty search leaves `query` out; the schema rejects an empty string.
        let all = try json(T3Client.ListRefsPayload(cwd: "/w/app", query: nil, limit: 100))
        #expect(all["query"] == nil)
    }

    @Test func encodesSwitchAndCreateBranch() throws {
        #expect(try json(T3Client.RefPayload(cwd: "/w/app", refName: "main", switchRef: nil))
            == ["cwd": "/w/app", "refName": "main"])
        #expect(try json(T3Client.RefPayload(cwd: "/w/app", refName: "feature/x", switchRef: true))
            == ["cwd": "/w/app", "refName": "feature/x", "switchRef": true])
    }

    @Test func encodesTheStackedActions() throws {
        let request = GitActionRequest(id: "a1", cwd: "/w/app", kind: .commitPushAndCreatePullRequest,
                                       commitMessage: "  Fix it \n", threadID: "t1", projectID: "p1")
        #expect(try json(T3Client.StackedActionPayload(request)) == [
            "actionId": "a1", "cwd": "/w/app", "action": "commit_push_pr", "commitMessage": "Fix it",
            "threadId": "t1", "projectId": "p1"
        ])
        // A blank message lets the engine write one.
        let generated = GitActionRequest(id: "a2", cwd: "/w/app", kind: .commit, commitMessage: " \n")
        #expect(try json(T3Client.StackedActionPayload(generated)) == ["actionId": "a2", "cwd": "/w/app", "action": "commit"])
        #expect(GitActionKind.allCases.map(\.rawValue).sorted()
            == ["commit", "commit_push", "commit_push_pr", "create_pr", "push"])
    }

    @Test func encodesOpenInEditorAndResolve() throws {
        #expect(try json(T3Client.OpenEditorPayload(cwd: "/w/app", editor: "vscode")) == ["cwd": "/w/app", "editor": "vscode"])
        #expect(try json(T3Client.ResolvePullRequestPayload(cwd: "/w/app", reference: "12"))
            == ["cwd": "/w/app", "reference": "12"])
    }

    @Test func encodesTheMerge() throws {
        let ref = T3Client.PullRequestRefPayload(projectId: "p1", repository: "acme/app", number: 12)
        #expect(try json(ref) == ["projectId": "p1", "repository": "acme/app", "number": 12])
        let merge = T3Client.PullRequestActionPayload(projectId: "p1", repository: "acme/app", number: 12,
                                                      action: "merge", mergeMethod: PullRequestMergeMethod.squash.rawValue)
        #expect(try json(merge) == ["projectId": "p1", "repository": "acme/app", "number": 12,
                                    "action": "merge", "mergeMethod": "squash"])
    }

    // MARK: Results

    @Test func decodesTheStatus() throws {
        let value = try result("""
        {"isRepo":true,"hasPrimaryRemote":true,"isDefaultRef":false,"refName":"feature/menu",
         "hasWorkingTreeChanges":true,
         "workingTree":{"rootPath":"/w/app","files":[{"path":"a.swift","insertions":4,"deletions":1},
                                                   {"path":"b.swift","insertions":2,"deletions":0}],
                        "insertions":6,"deletions":1},
         "branchChanges":{"baseRef":"origin/main","insertions":120,"deletions":14},
         "hasUpstream":true,"aheadCount":2,"behindCount":1,"aheadOfDefaultCount":3,
         "pr":{"number":12,"title":"Add workspace menu","url":"https://github.com/acme/app/pull/12",
               "baseRef":"main","headRef":"feature/menu","state":"open","isDraft":false}}
        """)
        let status = try T3Client.workspaceStatus(from: value)
        #expect(status.branch == "feature/menu")
        #expect(status.hasUncommittedChanges && status.changedFiles == 2)
        #expect((status.insertions, status.deletions) == (6, 1))
        #expect((status.ahead, status.behind) == (2, 1))
        #expect(status.pullRequest?.number == 12)
        #expect(status.pullRequest?.repository == "acme/app")
        let comparison = try #require(status.comparison)
        #expect((comparison.label, comparison.insertions, comparison.deletions) == ("vs origin/main", 120, 14))
    }

    @Test func decodesAStatusWithoutAPullRequestOrBranchChanges() throws {
        let value = try result("""
        {"isRepo":true,"hasPrimaryRemote":false,"isDefaultRef":true,"refName":"main","hasWorkingTreeChanges":false,
         "workingTree":{"files":[],"insertions":0,"deletions":0},"hasUpstream":false,"aheadCount":0,"behindCount":0,"pr":null}
        """)
        let status = try T3Client.workspaceStatus(from: value)
        #expect(status.pullRequest == nil && status.comparison == nil && !status.hasRemote)
    }

    @Test func decodesTheBranchList() throws {
        let value = try result("""
        {"isRepo":true,"hasPrimaryRemote":true,"nextCursor":null,"totalCount":3,"refs":[
          {"name":"main","current":true,"isDefault":true,"worktreePath":"/w/app"},
          {"name":"feature/menu","current":false,"isDefault":false,"worktreePath":null},
          {"name":"origin/feature/other","isRemote":true,"remoteName":"origin","upstreamRef":"refs/remotes/origin/feature/other",
           "current":false,"isDefault":false,"worktreePath":null}]}
        """)
        let page = try T3Client.workspaceBranches(from: value)
        #expect(page.total == 3)
        #expect(page.branches.map(\.name) == ["main", "feature/menu", "origin/feature/other"])
        #expect(page.branches[0].isCurrent && page.branches[0].isDefault)
        #expect(page.branches[2].isRemote && page.branches[2].shortName == "feature/other")
        #expect(Set(page.branches.map(\.id)).count == 3)
    }

    /// Captured from the real engine against a throwaway repository (paths shortened).
    @Test func decodesResultsCapturedFromTheEngine() throws {
        let status = try T3Client.workspaceStatus(from: try result("""
        {"hasUpstream":true,"aheadCount":0,"isRepo":true,"refName":"main","branchChanges":{"baseRef":"origin/main","insertions":0,"deletions":0},
         "aheadOfDefaultCount":0,"behindCount":0,"hasWorkingTreeChanges":false,
         "workingTree":{"insertions":0,"rootPath":"/tmp/project","files":[],"deletions":0},"isDefaultRef":true,"hasPrimaryRemote":true,"pr":null}
        """))
        #expect(status.branch == "main" && status.isDefaultBranch && status.hasUpstream && status.comparison == nil)
        let page = try T3Client.workspaceBranches(from: try result("""
        {"isRepo":true,"isAtRepositoryRoot":true,"refs":[
          {"worktreePath":"/tmp/project","name":"main","current":true,"isDefault":true,"isRemote":false,"upstreamRef":"refs/remotes/origin/main"},
          {"current":false,"isRemote":true,"worktreePath":null,"remoteName":"origin","name":"origin/main","isDefault":true},
          {"worktreePath":null,"remoteName":"origin","isRemote":true,"current":false,"name":"origin/remote-only","isDefault":false}],
         "totalCount":3,"nextCursor":null,"hasPrimaryRemote":true}
        """))
        #expect(page.branches.map(\.name) == ["main", "origin/main", "origin/remote-only"])
        #expect(page.branches.first?.isCurrent == true && page.branches.last?.shortName == "remote-only")
    }

    @Test func decodesCreateSwitchAndPullResults() throws {
        #expect(try T3Client.createdBranch(from: try result(#"{"refName":"feature/new"}"#)) == "feature/new")
        let pulled = try T3Client.pullOutcome(from: try result(#"{"status":"pulled","refName":"main","upstreamRef":"origin/main"}"#))
        #expect(pulled == WorkspacePullOutcome(upToDate: false, branch: "main"))
        let current = try T3Client.pullOutcome(
            from: try result(#"{"status":"skipped_up_to_date","refName":"main","upstreamRef":null}"#))
        #expect(current.upToDate)
    }

    @Test func decodesThePullRequestDetailAndSummarisesItsChecks() throws {
        let value = try result("""
        {"provider":"github","number":12,"title":"Add workspace menu","url":"https://github.com/acme/app/pull/12",
         "repository":"acme/app","state":"open","isDraft":false,"mergeability":"mergeable",
         "baseBranch":"main","headBranch":"feature/menu",
         "mergeCapabilities":{"merge":false,"squash":true,"rebase":true},
         "checks":[{"name":"build","status":"success","description":null,"url":null},
                   {"name":"lint","status":"failure","description":null,"url":null},
                   {"name":"e2e","status":"pending","description":null,"url":null},
                   {"name":"docs","status":"skipped","description":null,"url":null},
                   {"name":"unlisted","status":"pending","description":null,"url":null,"placeholder":true}]}
        """)
        let detail = try T3Client.pullRequestDetail(from: value)
        #expect(detail.repository == "acme/app" && detail.pullRequest.number == 12)
        #expect(detail.mergeability == .mergeable)
        #expect(detail.checks == .init(passing: 1, failing: 1, pending: 1))
        #expect(detail.checks.summary == "1 failing")
        #expect(detail.mergeMethods == [.squash, .rebase])
    }

    @Test func decodesAResolvedPullRequest() throws {
        let value = try result("""
        {"pullRequest":{"number":12,"title":"Add workspace menu","url":"https://github.com/acme/app/pull/12",
                        "baseBranch":"main","headBranch":"feature/menu","state":"merged"}}
        """)
        let pullRequest = try T3Client.resolvedPullRequest(from: value)
        #expect(pullRequest.state == .merged && pullRequest.number == 12)
    }

    @Test func derivesTheRepositoryFromGitHubAndGitLabLinks() {
        func repository(_ url: String) -> String? {
            WorkspacePullRequest(number: 1, title: "t", url: url, state: .open).repository
        }
        #expect(repository("https://github.com/acme/app/pull/12") == "acme/app")
        #expect(repository("https://gitlab.com/group/sub/app/-/merge_requests/3") == "group/sub/app")
        #expect(repository("https://example.com/not-a-pr") == nil)
    }

    @Test func readsTheEditorsTheEngineReports() throws {
        #expect(try result(#"{"availableEditors":["cursor","vscode","file-manager"],"providers":[]}"#)?.availableEditors
            == ["cursor", "vscode", "file-manager"])
        let editors = WorkspaceEditor.detected(from: ["zed", "file-manager", "vscode", "mystery"])
        #expect(editors.map(\.id) == ["vscode", "zed"])
        #expect(WorkspaceEditor.preferred(remembered: nil, among: editors)?.id == "vscode")
        #expect(WorkspaceEditor.preferred(remembered: "zed", among: editors)?.id == "zed")
        #expect(WorkspaceEditor.preferred(remembered: "cursor", among: editors)?.id == "vscode")
        let withoutCode = WorkspaceEditor.detected(from: ["zed"])
        #expect(WorkspaceEditor.preferred(remembered: nil, among: withoutCode)?.id == "zed")
        #expect(WorkspaceEditor.preferred(remembered: nil, among: []) == nil)
    }

    // MARK: Streamed progress

    @Test func decodesStackedActionProgressChunks() throws {
        let chunk = """
        {"_tag":"Chunk","requestId":"4","values":[
          {"actionId":"a1","cwd":"/w/app","action":"commit_push","kind":"action_started","phases":["commit","push"]},
          {"actionId":"a1","cwd":"/w/app","action":"commit_push","kind":"phase_started","phase":"commit","label":"Committing..."},
          {"actionId":"a1","cwd":"/w/app","action":"commit_push","kind":"hook_output","hookName":null,"stream":"stderr","text":"lint ok"},
          {"actionId":"a1","cwd":"/w/app","action":"commit_push","kind":"action_finished","result":{
            "action":"commit_push","branch":{"status":"skipped_not_requested"},
            "commit":{"status":"created","commitSha":"abc123","subject":"Add menu"},
            "push":{"status":"pushed","branch":"feature/menu","upstreamBranch":"origin/feature/menu","setUpstream":true},
            "pr":{"status":"skipped_not_requested"},
            "toast":{"title":"Pushed abc123 to origin/feature/menu","cta":{"kind":"none"}}}}]}
        """
        guard case .chunk(let id, let items) = try T3Client.decodeFrame(Data(chunk.utf8)) else {
            Issue.record("Expected a chunk")
            return
        }
        #expect(id == "4")
        let events = items.compactMap { item -> T3Client.GitProgress.Interpretation? in
            if case .gitProgress(let progress) = item { return progress.event }
            return nil
        }
        #expect(events == [
            .event(.phase("Committing...")),
            .event(.output("lint ok")),
            .event(.finished(GitActionOutcome(title: "Pushed abc123 to origin/feature/menu", committed: true, pushed: true)))
        ])
    }

    @Test func decodesAFailedStackedAction() throws {
        let chunk = #"""
        {"_tag":"Chunk","requestId":"4","values":[{"actionId":"a1","cwd":"/w/app","action":"push","kind":"action_failed","phase":"push","message":"Push rejected"}]}
        """#
        guard case .chunk(_, let items) = try T3Client.decodeFrame(Data(chunk.utf8)),
              case .gitProgress(let progress) = items.first else {
            Issue.record("Expected a progress chunk")
            return
        }
        #expect(progress.event == .failure("Push rejected"))
    }

    @Test func showsTheEnginesGitErrorDetail() throws {
        let frame = #"""
        {"_tag":"Exit","requestId":"2","exit":{"_tag":"Failure","cause":[{"_tag":"Fail","error":{"_tag":"GitCommandError","operation":"GitVcsDriver.switchRef.checkout","cwd":"/w/app","detail":"Your local changes would be overwritten by checkout.","cause":{"message":"stderr with a credential"}}}]}}
        """#
        guard case .exit(_, let exit) = try T3Client.decodeFrame(Data(frame.utf8)) else {
            Issue.record("Expected an exit frame")
            return
        }
        #expect(T3Client.RPCFailure(exit: exit).localizedDescription == "Your local changes would be overwritten by checkout.")
    }

    // MARK: Scopes

    @Test func requestsOnlyTheScopesTheWorkspaceMenuNeeds() {
        let scopes = T3Client.requestedScopes
        // Reads and shell.openInEditor ride on orchestration:read/operate; branch, commit, push, pull and merge need this one.
        #expect(scopes.contains("source-control:write"))
        #expect(Set(scopes) == ["orchestration:read", "orchestration:operate", "settings:write", "providers:manage",
                                "diagnostics:read", "source-control:write"])
        for broader in ["environment:maintain", "filesystem:write", "terminal:operate", "access:write"] {
            #expect(!scopes.contains(broader))
        }
    }

    // MARK: Policy

    @Test func blocksSwitchesWhileTheAgentRunsAndConfirmsWhenDirty() {
        let other = WorkspaceBranch(name: "feature/x")
        let remote = WorkspaceBranch(name: "origin/feature/y", isRemote: true, remoteName: "origin")
        let elsewhere = WorkspaceBranch(name: "wip", worktreePath: "/w/other")
        let current = WorkspaceBranch(name: "main", isCurrent: true)
        func policy(_ branch: WorkspaceBranch, running: Bool = false, dirty: Bool = false) -> BranchSwitchPolicy {
            .evaluate(agentRunning: running, hasUncommittedChanges: dirty, target: branch)
        }
        #expect(policy(other) == .allowed)
        #expect(policy(remote) == .allowed)
        #expect(policy(other, dirty: true) == .confirmUncommitted)
        if case .blocked = policy(other, running: true, dirty: true) {} else { Issue.record("running must block") }
        if case .blocked = policy(elsewhere) {} else { Issue.record("another worktree must block") }
        if case .blocked = policy(current) {} else { Issue.record("the current branch must block") }
    }

    @Test(arguments: ["", "  ", "-x", "a b", "a..b", "a~1", "x/", "x.lock", "a//b", "a@{b", "/x", "a\\b", "a/.b"])
    func rejectsInvalidBranchNames(_ name: String) {
        #expect(BranchNameValidation.problem(name) != nil)
    }

    @Test(arguments: ["feature/menu", "fix-123", "release_1.2", "user/hilay/notes"])
    func acceptsValidBranchNames(_ name: String) {
        #expect(BranchNameValidation.problem(name) == nil)
    }
}
