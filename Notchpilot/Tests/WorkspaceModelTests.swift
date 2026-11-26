import Foundation
import NotchpilotCore
import Testing
@testable import Notchpilot

@MainActor
struct WorkspaceModelTests {
    private func model(running: Bool = false) async throws -> (WorkspaceModel, FakeBackend) {
        let backend = FakeBackend()
        let defaults = try #require(UserDefaults(suiteName: "WorkspaceModelTests.\(UUID().uuidString)"))
        let model = WorkspaceModel(defaults: defaults)
        model.backend = { backend }
        model.bind(threadID: "t1", projectID: "demo", path: FakeRepository.path, agentRunning: running, connected: true)
        try await waitUntil { model.status != nil }
        return (model, backend)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition())
    }

    @Test(.timeLimit(.minutes(1)))
    func loadsTheBranchChangesAndPullRequest() async throws {
        let (model, _) = try await model()
        #expect(model.status?.branch == "feature/workspace-menu")
        #expect(model.status?.pullRequest?.number == 12)
        let comparison = try #require(model.status?.comparison)
        #expect(comparison.insertions > 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func refusesToSwitchWhileTheAgentRuns() async throws {
        let (model, backend) = try await model(running: true)
        model.requestSwitch(to: WorkspaceBranch(name: "main"))
        #expect(model.confirmation == nil && !model.isBusy)
        #expect(model.notice?.isError == true)
        #expect(backend.repository.branch == "feature/workspace-menu")
    }

    @Test(.timeLimit(.minutes(1)))
    func switchingWithUncommittedChangesWaitsForConfirmation() async throws {
        let (model, backend) = try await model()
        #expect(model.status?.hasUncommittedChanges == true)
        let main = WorkspaceBranch(name: "main")
        model.requestSwitch(to: main)
        #expect(model.confirmation == .switchBranch(main))
        #expect(backend.repository.branch == "feature/workspace-menu")
        model.confirm()
        await model.settled()
        #expect(backend.repository.branch == "main")
        try await waitUntil { model.status?.branch == "main" }
        #expect(model.notice == .init(text: "Switched to main.", isError: false))
    }

    @Test(.timeLimit(.minutes(1)))
    func switchingACleanTreeNeedsNoConfirmation() async throws {
        let (model, backend) = try await model()
        backend.repository.changedFiles = 0
        model.refresh()
        try await waitUntil { model.status?.hasUncommittedChanges == false }
        model.requestSwitch(to: WorkspaceBranch(name: "main"))
        #expect(model.confirmation == nil)
        await model.settled()
        #expect(backend.repository.branch == "main")
    }

    @Test(.timeLimit(.minutes(1)))
    func createsAndSwitchesToANewBranchAndRejectsBadNames() async throws {
        let (model, backend) = try await model()
        model.branchQuery = "bad name"
        model.createBranch()
        #expect(model.notice?.isError == true && backend.repository.branch == "feature/workspace-menu")
        model.branchQuery = "feature/second"
        model.createBranch()
        await model.settled()
        #expect(backend.repository.branch == "feature/second")
        try await waitUntil { model.status?.pullRequest == nil }
    }

    @Test(.timeLimit(.minutes(1)))
    func pushAndMergeNeedConfirmationButCommitDoesNot() async throws {
        let (model, backend) = try await model()
        model.request(.push)
        #expect(model.confirmation == .action(.push) && backend.repository.ahead == 1)
        model.cancelConfirmation()
        #expect(backend.repository.ahead == 1)
        model.request(.commit)
        #expect(model.confirmation == nil)
        await model.settled()
        #expect(backend.repository.changedFiles == 0)
        try await waitUntil { model.status?.hasUncommittedChanges == false }
        #expect(model.notice?.isError == false)

        model.request(.push)
        model.confirm()
        await model.settled()
        #expect(backend.repository.ahead == 0)

        model.requestMerge()
        try await waitUntil { model.confirmation == .merge }
        #expect(backend.repository.pullRequest?.state == .open)
        model.confirm()
        await model.settled()
        #expect(backend.repository.pullRequest?.state == .merged)
        #expect(model.notice?.text == "Merged #12.")
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingTheMergeLeavesThePullRequestOpen() async throws {
        let (model, backend) = try await model()
        model.requestMerge()
        try await waitUntil { model.confirmation == .merge }
        model.cancelConfirmation()
        #expect(backend.repository.pullRequest?.state == .open)
    }

    @Test(.timeLimit(.minutes(1)))
    func rememberedEditorWinsAndVSCodeIsTheDefault() async throws {
        let (model, _) = try await model()
        model.toggleOpen()
        try await waitUntil { !model.editors.isEmpty }
        #expect(model.selectedEditor?.id == "vscode")
        let zed = try #require(model.editors.first { $0.id == "zed" })
        model.chooseEditor(zed)
        #expect(model.selectedEditor == zed)
    }

    @Test(.timeLimit(.minutes(1)))
    func aNewThreadStartsFromAnEmptyMenu() async throws {
        let (model, _) = try await model()
        model.toggleOpen()
        model.bind(threadID: "t2", projectID: "demo", path: "/elsewhere", agentRunning: false, connected: true)
        #expect(!model.isOpen)
        #expect(model.confirmation == nil && model.notice == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func gitActionStreamEndsWithAnOutcome() async throws {
        let backend = FakeBackend()
        var phases: [String] = []
        var outcome: GitActionOutcome?
        for try await event in backend.runGitAction(.init(cwd: FakeRepository.path, kind: .commitAndPush)) {
            switch event {
            case .phase(let phase): phases.append(phase)
            case .output: break
            case .finished(let result): outcome = result
            }
        }
        #expect(phases == ["Committing…", "Pushing…"])
        #expect(outcome?.committed == true && outcome?.pushed == true)
    }
}
