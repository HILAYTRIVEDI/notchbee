import AppKit
import NotchpilotCore
import Observation

/// State and actions behind the thread's workspace menu: branch, editor, changes, commit and pull request.
/// One operation runs at a time. Remote and destructive ones wait for `confirm()`.
@MainActor @Observable
final class WorkspaceModel {
    enum Confirmation: Equatable {
        case switchBranch(WorkspaceBranch)
        case action(GitActionKind)
        case pull
        case merge

        var prompt: String {
            switch self {
            case .switchBranch(let branch): "This folder has uncommitted changes. Switch to \(branch.shortName) anyway?"
            case .action(.push): "Push the current branch to its remote?"
            case .action(.commitAndPush): "Commit all changes and push them to the remote?"
            case .action(.createPullRequest): "Create a pull request for this branch?"
            case .action(.commitPushAndCreatePullRequest): "Commit all changes, push them and create a pull request?"
            case .action(.commit): "Commit all changes?"
            case .pull: "This folder has uncommitted changes. Pull from the remote anyway?"
            case .merge: "Merge this pull request?"
            }
        }

        var button: String {
            switch self {
            case .switchBranch: "Switch"
            case .action(.push): "Push"
            case .action(.commitAndPush): "Commit & push"
            case .action(.createPullRequest), .action(.commitPushAndCreatePullRequest): "Create PR"
            case .action(.commit): "Commit"
            case .pull: "Pull"
            case .merge: "Merge"
            }
        }
    }

    struct Notice: Equatable {
        let text: String
        let isError: Bool
    }

    static let editorDefaultsKey = "workspaceEditor"

    @ObservationIgnored var backend: () -> (any WorkspaceBackend)? = { nil }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var wasRunning = false
    @ObservationIgnored private var wasConnected = false

    private(set) var threadID: String?
    private(set) var projectID: String?
    private(set) var path: String?
    private(set) var agentRunning = false

    private(set) var status: WorkspaceStatus?
    private(set) var statusFailure: String?
    private(set) var isLoadingStatus = false
    private(set) var detail: WorkspacePullRequestDetail?
    private(set) var editors: [WorkspaceEditor] = []
    private(set) var branches: [WorkspaceBranch] = []
    private(set) var branchTotal = 0
    private(set) var isLoadingBranches = false

    var isOpen = false
    var showsBranches = false
    var branchQuery = ""
    var commitMessage = ""
    var mergeMethod: PullRequestMergeMethod = .squash
    var confirmation: Confirmation?
    private(set) var busy: String?
    private(set) var progress: [String] = []
    private(set) var notice: Notice?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Derived

    var isRepository: Bool { status?.isRepository == true }
    var isBusy: Bool { busy != nil }
    var selectedEditor: WorkspaceEditor? {
        WorkspaceEditor.preferred(remembered: defaults.string(forKey: Self.editorDefaultsKey), among: editors)
    }

    var folderName: String { path.map { URL(filePath: $0).lastPathComponent } ?? "Folder" }
    var folderExists: Bool { path.map { FileManager.default.fileExists(atPath: $0) } ?? false }

    var canCommit: Bool { status?.hasUncommittedChanges == true && !isBusy }
    var canPush: Bool {
        guard let status, status.hasRemote, !isBusy else { return false }
        return status.ahead > 0 || !status.hasUpstream
    }
    var canPull: Bool { status?.hasUpstream == true && !isBusy }

    var canCreatePullRequest: Bool {
        guard let status, status.hasRemote, status.pullRequest == nil, !status.isDefaultBranch, status.branch != nil,
              !isBusy else { return false }
        return status.ahead > 0 || status.hasUncommittedChanges || !status.hasUpstream
    }

    var createPullRequestAction: GitActionKind {
        status?.hasUncommittedChanges == true ? .commitPushAndCreatePullRequest : .createPullRequest
    }

    // MARK: Binding to the open thread

    /// Called whenever the open thread, its folder, its run state or the connection changes.
    func bind(threadID: String, projectID: String?, path: String?, agentRunning: Bool, connected: Bool) {
        let changed = threadID != self.threadID || path != self.path
        self.projectID = projectID
        self.agentRunning = agentRunning
        if changed {
            reset()
            self.threadID = threadID
            self.path = path
        }
        let finishedRun = wasRunning && !agentRunning
        let reconnected = connected && !wasConnected
        wasRunning = agentRunning
        wasConnected = connected
        guard connected, path != nil, changed || finishedRun || reconnected else { return }
        refresh()
    }

    func unbind() {
        reset()
        threadID = nil
        path = nil
    }

    private func reset() {
        generation += 1
        task?.cancel()
        searchTask?.cancel()
        task = nil
        status = nil
        statusFailure = nil
        detail = nil
        branches = []
        branchTotal = 0
        isOpen = false
        showsBranches = false
        branchQuery = ""
        commitMessage = ""
        confirmation = nil
        busy = nil
        progress = []
        notice = nil
        isLoadingStatus = false
        isLoadingBranches = false
    }

    // MARK: Reads

    func refresh() {
        guard let path, let backend = backend() else { return }
        let token = generation
        isLoadingStatus = true
        Task {
            defer { if token == generation { isLoadingStatus = false } }
            do {
                let fresh = try await backend.workspaceStatus(cwd: path)
                guard token == generation else { return }
                status = fresh
                statusFailure = nil
                if fresh.pullRequest == nil { detail = nil }
                if isOpen { await loadDetail(backend: backend, token: token) }
            } catch {
                guard token == generation else { return }
                statusFailure = error.localizedDescription
                if status == nil { status = nil }
            }
        }
    }

    func toggleOpen() {
        isOpen ? close() : open(showingBranches: false)
    }

    /// The branch chip opens the menu straight onto the branch list, or closes it when already there.
    func toggleBranchSwitcher() {
        isOpen && showsBranches ? close() : open(showingBranches: true)
    }

    private func open(showingBranches: Bool) {
        isOpen = true
        showsBranches = showingBranches
        notice = nil
        refresh()
        loadEditors()
        if showingBranches { loadBranches() }
    }

    private func close() {
        isOpen = false
        showsBranches = false
        confirmation = nil
    }

    func toggleBranches() {
        showsBranches.toggle()
        confirmation = nil
        if showsBranches { loadBranches() }
    }

    private func loadEditors() {
        guard editors.isEmpty, let backend = backend() else { return }
        let token = generation
        Task {
            guard let found = try? await backend.availableEditors(), token == generation else { return }
            editors = found
        }
    }

    private func loadDetail(backend: any WorkspaceBackend, token: Int) async {
        guard let pullRequest = status?.pullRequest, let projectID else { return }
        let loaded = try? await backend.pullRequestDetail(of: pullRequest, projectID: projectID)
        guard token == generation, status?.pullRequest?.number == pullRequest.number else { return }
        detail = loaded
        if let loaded, !loaded.mergeMethods.contains(mergeMethod), let first = loaded.mergeMethods.first {
            mergeMethod = first
        }
    }

    func loadBranches() {
        guard let path, let backend = backend() else { return }
        let token = generation
        let query = branchQuery
        isLoadingBranches = true
        searchTask?.cancel()
        searchTask = Task {
            defer { if token == generation, !Task.isCancelled { isLoadingBranches = false } }
            do {
                let page = try await backend.workspaceBranches(cwd: path, query: query)
                guard token == generation, !Task.isCancelled else { return }
                branches = page.branches
                branchTotal = page.total
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                notice = .init(text: error.localizedDescription, isError: true)
            }
        }
    }

    /// Called as the search text changes; waits for a pause in typing.
    func searchBranches() {
        searchTask?.cancel()
        let token = generation
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, token == generation else { return }
            loadBranches()
        }
    }

    /// Whether the typed text names a branch that does not exist yet.
    var creatableBranchName: String? {
        let name = branchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !branches.contains(where: { $0.name == name || $0.shortName == name }) else { return nil }
        return name
    }

    // MARK: Branch actions

    func requestSwitch(to branch: WorkspaceBranch) {
        guard !isBusy else { return }
        switch BranchSwitchPolicy.evaluate(agentRunning: agentRunning,
                                           hasUncommittedChanges: status?.hasUncommittedChanges == true, target: branch) {
        case .blocked(let reason): notice = .init(text: reason, isError: true)
        case .confirmUncommitted: confirmation = .switchBranch(branch)
        case .allowed: performSwitch(to: branch)
        }
    }

    private func performSwitch(to branch: WorkspaceBranch) {
        guard let path else { return }
        let dirty = status?.hasUncommittedChanges == true
        run("Switching to \(branch.shortName)…") { backend in
            do {
                try await backend.switchBranch(cwd: path, name: branch.name)
            } catch {
                // The engine only reports that the checkout failed. With local changes the usual cause is a conflict.
                guard dirty else { throw error }
                throw WorkspaceError.actionFailed("\(error.localizedDescription). If your uncommitted changes conflict with \(branch.shortName), commit or stash them first.")
            }
            return "Switched to \(branch.shortName)."
        } afterSuccess: { [self] in
            showsBranches = false
            branchQuery = ""
        }
    }

    func createBranch() {
        guard !isBusy, let path else { return }
        guard !agentRunning else {
            notice = .init(text: "The agent is running in this thread. Stop it before changing branches.", isError: true)
            return
        }
        let name = branchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = BranchNameValidation.problem(name) {
            notice = .init(text: problem, isError: true)
            return
        }
        run("Creating \(name)…") { backend in
            let created = try await backend.createBranch(cwd: path, name: name)
            return "Created and switched to \(created)."
        } afterSuccess: { [self] in
            showsBranches = false
            branchQuery = ""
        }
    }

    // MARK: Git actions

    func request(_ kind: GitActionKind) {
        guard !isBusy else { return }
        switch kind {
        case .commit: perform(kind)
        case .push, .commitAndPush, .createPullRequest, .commitPushAndCreatePullRequest: confirmation = .action(kind)
        }
    }

    func requestPull() {
        guard !isBusy else { return }
        if status?.hasUncommittedChanges == true { confirmation = .pull } else { pull() }
    }

    private func perform(_ kind: GitActionKind) {
        guard let path, let backend = backend() else { return }
        let request = GitActionRequest(cwd: path, kind: kind, commitMessage: commitMessage,
                                       threadID: threadID, projectID: projectID)
        let label = switch kind {
        case .commit: "Committing…"
        case .commitAndPush: "Committing and pushing…"
        case .push: "Pushing…"
        case .createPullRequest: "Creating pull request…"
        case .commitPushAndCreatePullRequest: "Committing, pushing and creating pull request…"
        }
        begin(label)
        let token = generation
        task = Task {
            do {
                var outcome: GitActionOutcome?
                for try await event in backend.runGitAction(request) {
                    guard token == generation else { return }
                    switch event {
                    case .phase(let phase): busy = phase
                    case .output(let text): addProgress(text)
                    case .finished(let result): outcome = result
                    }
                }
                guard token == generation else { return }
                if let outcome {
                    commitMessage = ""
                    var text = outcome.title
                    if let detail = outcome.detail, !detail.isEmpty { text += " — " + detail }
                    notice = .init(text: text, isError: false)
                } else {
                    notice = .init(text: "Done.", isError: false)
                }
                finish()
            } catch {
                guard token == generation else { return }
                var text = error.localizedDescription
                if request.commitMessage == nil, text.contains("Text generation") {
                    text += " Type a commit message to skip it."
                }
                notice = .init(text: text, isError: true)
                finish()
            }
        }
    }

    func pull() {
        guard let path else { return }
        run("Pulling…") { backend in
            let result = try await backend.pullBranch(cwd: path)
            return result.upToDate ? "Already up to date." : "Pulled the latest changes into \(result.branch)."
        }
    }

    func requestMerge() {
        guard !isBusy, status?.pullRequest != nil else { return }
        guard let backend = backend() else { return }
        if detail != nil {
            confirmation = .merge
            return
        }
        // The merge options and checks are needed to confirm, so read them first.
        let token = generation
        begin("Checking the pull request…")
        task = Task {
            await loadDetail(backend: backend, token: token)
            guard token == generation else { return }
            if detail != nil { confirmation = .merge }
            else { notice = .init(text: "The pull request could not be read. Open it in the browser instead.", isError: true) }
            finish(refreshing: false)
        }
    }

    func confirm() {
        guard let pending = confirmation, !isBusy else { return }
        confirmation = nil
        switch pending {
        case .switchBranch(let branch): performSwitch(to: branch)
        case .action(let kind): perform(kind)
        case .pull: pull()
        case .merge: merge()
        }
    }

    func cancelConfirmation() { confirmation = nil }

    private func merge() {
        guard let detail, let projectID, let path else { return }
        let method = mergeMethod
        run("Merging #\(detail.pullRequest.number)…") { backend in
            try await backend.mergePullRequest(detail, projectID: projectID, method: method)
            // The host can take a moment to report the new state, so look it up rather than assume.
            let current = try? await backend.resolvePullRequest(cwd: path, reference: String(detail.pullRequest.number))
            switch current?.state {
            case .merged?: return "Merged #\(detail.pullRequest.number)."
            case .closed?: return "#\(detail.pullRequest.number) was closed."
            default: return "Merge requested for #\(detail.pullRequest.number). It may still be queued."
            }
        }
    }

    // MARK: Editor and Finder

    func chooseEditor(_ editor: WorkspaceEditor) {
        defaults.set(editor.id, forKey: Self.editorDefaultsKey)
    }

    func openInEditor() {
        guard let path, let editor = selectedEditor else {
            notice = .init(text: "No supported editor was found on this Mac.", isError: true)
            return
        }
        run("Opening in \(editor.name)…", refreshing: false) { backend in
            try await backend.openInEditor(cwd: path, editor: editor)
            return nil
        }
    }

    func revealInFinder() {
        guard let path, FileManager.default.fileExists(atPath: path) else {
            notice = .init(text: "This folder isn’t on this Mac.", isError: true)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
    }

    func openPullRequest() {
        guard let urlString = status?.pullRequest?.url, let url = URL(string: urlString),
              url.scheme == "https" || url.scheme == "http" else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Running

    private func begin(_ label: String) {
        busy = label
        progress = []
        notice = nil
    }

    private func addProgress(_ line: String) {
        progress.append(line)
        if progress.count > 4 { progress.removeFirst(progress.count - 4) }
    }

    private func finish(refreshing: Bool = true) {
        busy = nil
        progress = []
        if refreshing { refresh() }
    }

    /// Runs one backend call with a progress label. `success` is the message to show, if any.
    private func run(_ label: String, refreshing: Bool = true,
                     _ work: @escaping @MainActor (any WorkspaceBackend) async throws -> String?,
                     afterSuccess: (@MainActor () -> Void)? = nil) {
        guard let backend = backend() else {
            notice = .init(text: "The engine connection is unavailable.", isError: true)
            return
        }
        begin(label)
        let token = generation
        task = Task {
            do {
                let message = try await work(backend)
                guard token == generation else { return }
                notice = message.map { .init(text: $0, isError: false) }
                afterSuccess?()
            } catch {
                guard token == generation else { return }
                notice = .init(text: error.localizedDescription, isError: true)
            }
            finish(refreshing: refreshing)
            if token == generation, showsBranches { loadBranches() }
        }
    }

    /// Waits for the operation in flight. Used by tests.
    func settled() async {
        await task?.value
    }
}
