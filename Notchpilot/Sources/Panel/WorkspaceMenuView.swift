import NotchpilotCore
import SwiftUI

/// The compact workspace row under the thread title, and the menu it opens. The menu is drawn inside the panel
/// rather than as a popover, so it works while the notch panel is not the key window.
struct WorkspaceSection: View {
    let model: WorkspaceModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WorkspaceChipRow(model: model)
            if model.isOpen {
                WorkspaceMenu(model: model)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -6)))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.88), value: model.isOpen)
    }
}

// MARK: - Chips

struct WorkspaceChipRow: View {
    let model: WorkspaceModel

    var body: some View {
        HStack(spacing: 6) {
            if let status = model.status, status.isRepository {
                chip(icon: "arrow.triangle.branch", text: status.branch ?? "Detached HEAD", help: "Switch branch",
                     expanded: model.isOpen && model.showsBranches) { model.toggleBranchSwitcher() }
                if let comparison = status.comparison {
                    Button { model.toggleOpen() } label: {
                        counts(comparison.insertions, comparison.deletions)
                            .padding(.horizontal, 4).frame(height: 24)
                    }
                    .buttonStyle(.plain).clickableCursor()
                    .help("Changes \(comparison.label)")
                    .accessibilityLabel("\(comparison.insertions) lines added, \(comparison.deletions) removed, \(comparison.label)")
                }
                if let pullRequest = status.pullRequest {
                    pullRequestChip(pullRequest)
                }
            } else {
                chip(icon: "folder", text: model.folderName, help: "Workspace actions", expanded: model.isOpen) {
                    model.toggleOpen()
                }
            }
            if model.isLoadingStatus || model.isBusy {
                ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 14, height: 14)
            }
            Spacer(minLength: 0)
            Button { model.toggleOpen() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(model.isOpen ? 180 : 0))
                    .foregroundStyle(T3.muted)
                    .frame(width: 24, height: 24)
                    .hoverPlate()
            }
            .buttonStyle(.plain).clickableCursor()
            .accessibilityLabel(model.isOpen ? "Close workspace menu" : "Open workspace menu")
            .help("Workspace: branch, editor, changes and pull request")
        }
        .frame(height: 26)
    }

    private func chip(icon: String, text: String, help: String, expanded: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10.5, weight: .medium)).foregroundStyle(T3.link)
                Text(verbatim: text)
                    .font(.system(size: T3.caption, weight: .medium))
                    .foregroundStyle(T3.foreground)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(expanded ? T3.fillHover : T3.fill, in: Capsule())
            .overlay(Capsule().strokeBorder(expanded ? T3.borderStrong : T3.border, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).clickableCursor()
        .frame(maxWidth: 190, alignment: .leading)
        .help(help)
        .accessibilityLabel("\(help): \(text)")
    }

    private func pullRequestChip(_ pullRequest: WorkspacePullRequest) -> some View {
        let tint = WorkspaceStyle.tint(pullRequest.state, draft: pullRequest.isDraft)
        return Button { model.toggleOpen() } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.pull").font(.system(size: 10, weight: .medium))
                Text(verbatim: "#\(pullRequest.number)").font(.system(size: T3.caption, weight: .medium)).monospacedDigit()
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.32), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).clickableCursor()
        .help("\(pullRequest.title) (\(WorkspaceStyle.label(pullRequest)))")
        .accessibilityLabel("Pull request \(pullRequest.number), \(WorkspaceStyle.label(pullRequest))")
    }

    private func counts(_ added: Int, _ removed: Int) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: "+\(added)").foregroundStyle(T3.success)
            Text(verbatim: "−\(removed)").foregroundStyle(T3.error)
        }
        .font(.system(size: T3.caption, weight: .medium)).monospacedDigit()
    }
}

enum WorkspaceStyle {
    static func tint(_ state: WorkspacePullRequest.State, draft: Bool) -> Color {
        switch state {
        case .open: draft ? T3.muted : T3.success
        case .merged: Color(red: 0.66, green: 0.55, blue: 0.98)
        case .closed: T3.error
        }
    }

    static func label(_ pullRequest: WorkspacePullRequest) -> String {
        switch pullRequest.state {
        case .open: pullRequest.isDraft ? "draft" : "open"
        case .merged: "merged"
        case .closed: "closed"
        }
    }
}

// MARK: - Menu

struct WorkspaceMenu: View {
    let model: WorkspaceModel
    @State private var contentHeight: CGFloat = 220

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                locationRow
                divider
                if model.isRepository {
                    branchSection
                    divider
                    pullRequestSection
                    divider
                    changesSection
                } else if let failure = model.statusFailure {
                    note(failure, isError: true).padding(10)
                } else if !model.isLoadingStatus {
                    note("This folder isn’t a git repository, so branch and commit actions are unavailable.", isError: false)
                        .padding(10)
                }
                feedback
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(contentHeight, 330))
        .background(T3.fill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(T3.border, lineWidth: 1))
        .font(.system(size: T3.small))
    }

    private var divider: some View { Rectangle().fill(T3.border).frame(height: 1) }

    // MARK: Location and editor

    private var locationRow: some View {
        HStack(spacing: 6) {
            Button { model.revealInFinder() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "laptopcomputer").foregroundStyle(T3.muted)
                    Text(verbatim: Host.current().localizedName ?? "This Mac").foregroundStyle(T3.muted).lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(T3.faint)
                    Image(systemName: "folder").foregroundStyle(T3.link)
                    Text(verbatim: model.folderName).foregroundStyle(T3.foreground).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: T3.caption, weight: .medium))
                .padding(.horizontal, 8).frame(height: 28)
                .hoverPlate()
            }
            .buttonStyle(.plain).clickableCursor()
            .disabled(!model.folderExists)
            .help(model.path.map { "Reveal \($0) in Finder" } ?? "Reveal in Finder")
            .accessibilityLabel("Reveal \(model.folderName) in Finder")
            Spacer(minLength: 4)
            editorControl
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
    }

    private var editorControl: some View {
        HStack(spacing: 0) {
            Button { model.openInEditor() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 10, weight: .medium))
                    Text(verbatim: model.selectedEditor.map { "Open in \($0.name)" } ?? "Open in editor")
                        .lineLimit(1)
                }
                .font(.system(size: T3.caption, weight: .medium))
                .foregroundStyle(model.selectedEditor == nil ? T3.faint : T3.foreground)
                .padding(.horizontal, 8).frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).clickableCursor()
            .disabled(model.selectedEditor == nil || model.isBusy)
            .help(model.selectedEditor == nil ? "No supported editor found" : "Open this folder in the editor")
            Rectangle().fill(T3.border).frame(width: 1, height: 14)
            Menu {
                if model.editors.isEmpty {
                    Text("No editors found")
                } else {
                    ForEach(model.editors) { editor in
                        Button {
                            model.chooseEditor(editor)
                        } label: {
                            if editor == model.selectedEditor { Label(editor.name, systemImage: "checkmark") }
                            else { Text(verbatim: editor.name) }
                        }
                    }
                }
                Divider()
                Button("Reveal in Finder") { model.revealInFinder() }.disabled(!model.folderExists)
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(T3.muted)
                    .frame(width: 24, height: 26)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).clickableCursor()
            .fixedSize()
            .accessibilityLabel("Choose editor")
        }
        .background(T3.fill, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(T3.border, lineWidth: 1))
    }

    // MARK: Branch

    @ViewBuilder
    private var branchSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { model.toggleBranches() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(T3.link)
                    Text(verbatim: model.status?.branch ?? "Detached HEAD").fontWeight(.medium).lineLimit(1)
                    if let status = model.status, status.isDefaultBranch {
                        Text("default").font(.system(size: T3.micro, weight: .medium)).foregroundStyle(T3.muted)
                            .padding(.horizontal, 5).background(T3.fill, in: Capsule())
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(T3.muted)
                        .rotationEffect(.degrees(model.showsBranches ? 180 : 0))
                }
                .foregroundStyle(T3.foreground)
                .padding(.horizontal, 8).frame(height: 28)
                .hoverPlate()
            }
            .buttonStyle(.plain).clickableCursor()
            .accessibilityLabel("Current branch \(model.status?.branch ?? "none"). Switch branch")
            if model.showsBranches { branchSwitcher }
            if let status = model.status, status.hasUpstream, status.ahead + status.behind > 0 {
                Text(verbatim: [status.ahead > 0 ? "\(status.ahead) to push" : nil,
                                status.behind > 0 ? "\(status.behind) to pull" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: T3.caption)).foregroundStyle(T3.muted).padding(.horizontal, 8)
            }
        }
        .padding(6)
    }

    @ViewBuilder
    private var branchSwitcher: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 4) {
            FocusedEditor(text: $model.branchQuery, placeholder: "Search or name a new branch", multiline: false, searchStyle: true) {
                if model.creatableBranchName != nil { model.createBranch() }
            }
            .onChange(of: model.branchQuery) { model.searchBranches() }
            if model.agentRunning {
                note("The agent is running in this thread. Stop it before switching branches.", isError: false)
            }
            let local = model.branches.filter { !$0.isRemote }
            let remote = model.branches.filter(\.isRemote)
            VStack(alignment: .leading, spacing: 0) {
                if let name = model.creatableBranchName {
                    row(icon: "plus", title: "Create branch “\(name)”", subtitle: "from \(model.status?.branch ?? "HEAD")",
                        tint: T3.link, disabled: model.isBusy || model.agentRunning) { model.createBranch() }
                }
                if !local.isEmpty { header("Local") }
                ForEach(local) { branch in branchRow(branch) }
                if !remote.isEmpty { header("Remote") }
                ForEach(remote) { branch in branchRow(branch) }
                if model.branches.isEmpty && model.creatableBranchName == nil {
                    Text(model.isLoadingBranches ? "Loading branches…" : "No branches found.")
                        .font(.system(size: T3.caption)).foregroundStyle(T3.muted).padding(8)
                }
            }
            if model.branchTotal > model.branches.count {
                Text("Showing \(model.branches.count) of \(model.branchTotal). Search to narrow the list.")
                    .font(.system(size: T3.micro)).foregroundStyle(T3.faint).padding(.horizontal, 8)
            }
            if case .switchBranch = model.confirmation { confirmBar }
        }
        .padding(.horizontal, 2)
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: T3.micro, weight: .semibold)).foregroundStyle(T3.faint)
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
    }

    private func branchRow(_ branch: WorkspaceBranch) -> some View {
        let blocked: Bool = {
            if case .blocked = BranchSwitchPolicy.evaluate(agentRunning: model.agentRunning, hasUncommittedChanges: false,
                                                           target: branch) { return !branch.isCurrent }
            return false
        }()
        return row(icon: branch.isCurrent ? "checkmark" : branch.isRemote ? "cloud" : "arrow.triangle.branch",
                   title: branch.name, subtitle: branch.isCurrent ? "current" : branch.worktreePath != nil ? "in another worktree" : (branch.isDefault ? "default" : nil),
                   tint: branch.isCurrent ? T3.success : T3.muted, disabled: model.isBusy || branch.isCurrent || blocked) {
            model.requestSwitch(to: branch)
        }
    }

    private func row(icon: String, title: String, subtitle: String?, tint: Color, disabled: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 10.5, weight: .medium)).foregroundStyle(tint).frame(width: 14)
                Text(verbatim: title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let subtitle { Text(verbatim: subtitle).font(.system(size: T3.micro)).foregroundStyle(T3.faint) }
            }
            .foregroundStyle(disabled ? T3.faint : T3.foreground)
            .padding(.horizontal, 8).frame(height: 26)
            .hoverPlate(radius: 6)
        }
        .buttonStyle(.plain).clickableCursor()
        .disabled(disabled)
        .accessibilityLabel(title)
    }

    // MARK: Pull request

    @ViewBuilder
    private var pullRequestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let pullRequest = model.status?.pullRequest {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.triangle.pull")
                        .foregroundStyle(WorkspaceStyle.tint(pullRequest.state, draft: pullRequest.isDraft))
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: pullRequest.title).fontWeight(.medium).lineLimit(2).help(pullRequest.title)
                        HStack(spacing: 6) {
                            Text(verbatim: "#\(pullRequest.number)").monospacedDigit()
                            Text(verbatim: WorkspaceStyle.label(pullRequest).capitalized)
                            if let detail = model.detail {
                                if let checks = detail.checks.summary {
                                    Text(verbatim: "Checks: \(checks)")
                                        .foregroundStyle(detail.checks.failing > 0 ? T3.error : detail.checks.pending > 0 ? T3.warning : T3.success)
                                }
                                if detail.mergeability == .conflicting { Text("Has conflicts").foregroundStyle(T3.error) }
                            }
                        }
                        .font(.system(size: T3.caption)).foregroundStyle(T3.muted)
                    }
                    Spacer(minLength: 4)
                    smallButton("Open", icon: "arrow.up.right") { model.openPullRequest() }
                    if pullRequest.state == .open {
                        smallButton("Merge", icon: "arrow.triangle.merge", prominent: true,
                                    disabled: model.isBusy || pullRequest.isDraft || model.detail?.mergeability == .conflicting) {
                            model.requestMerge()
                        }
                        .help(pullRequest.isDraft ? "Mark the pull request ready before merging" : "Merge this pull request")
                    }
                }
                if model.confirmation == .merge { mergeConfirm }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.pull").foregroundStyle(T3.faint)
                    Text(model.status?.isDefaultBranch == true ? "No pull request on the default branch"
                         : "No pull request for this branch")
                        .foregroundStyle(T3.muted)
                    Spacer(minLength: 4)
                    smallButton(model.createPullRequestAction == .createPullRequest ? "Create PR" : "Commit & create PR",
                                icon: "plus", prominent: true, disabled: !model.canCreatePullRequest) {
                        model.request(model.createPullRequestAction)
                    }
                    .help(model.canCreatePullRequest ? "Create a pull request for this branch"
                          : "Push commits on a feature branch with a remote to create a pull request")
                }
                if case .action(let kind) = model.confirmation,
                   kind == .createPullRequest || kind == .commitPushAndCreatePullRequest { confirmBar }
            }
        }
        .font(.system(size: T3.small))
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var mergeConfirm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "Merge #\(model.status?.pullRequest?.number ?? 0) into \(model.status?.pullRequest?.baseBranch ?? "the base branch")?")
                .fontWeight(.medium)
            if let detail = model.detail, detail.checks.failing > 0 || detail.checks.pending > 0 {
                Text(verbatim: detail.checks.failing > 0 ? "\(detail.checks.failing) checks are failing." : "\(detail.checks.pending) checks are still running.")
                    .font(.system(size: T3.caption)).foregroundStyle(T3.warning)
            }
            HStack(spacing: 8) {
                if let methods = model.detail?.mergeMethods, methods.count > 1 {
                    @Bindable var model = model
                    Picker("Method", selection: $model.mergeMethod) {
                        ForEach(methods, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize().clickableCursor()
                } else if let method = model.detail?.mergeMethods.first {
                    Text(method.label).foregroundStyle(T3.muted)
                }
                Spacer(minLength: 4)
                smallButton("Cancel") { model.cancelConfirmation() }
                smallButton("Merge", icon: "arrow.triangle.merge", prominent: true, disabled: model.isBusy) { model.confirm() }
            }
        }
        .padding(8)
        .background(T3.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(T3.warning.opacity(0.28), lineWidth: 1))
    }

    // MARK: Changes and commit

    @ViewBuilder
    private var changesSection: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Changes").fontWeight(.medium).fixedSize()
                    if let comparison = model.status?.comparison {
                        Text(verbatim: comparison.label).foregroundStyle(T3.muted).lineLimit(1).truncationMode(.middle)
                            .layoutPriority(-1)
                        Text(verbatim: "+\(comparison.insertions)").foregroundStyle(T3.success).monospacedDigit().fixedSize()
                        Text(verbatim: "−\(comparison.deletions)").foregroundStyle(T3.error).monospacedDigit().fixedSize()
                    } else {
                        Text("none").foregroundStyle(T3.muted)
                    }
                    Spacer(minLength: 0)
                }
                if let status = model.status, status.hasUncommittedChanges {
                    Text(verbatim: "\(status.changedFiles) uncommitted \(status.changedFiles == 1 ? "file" : "files") · +\(status.insertions) −\(status.deletions)")
                        .font(.system(size: T3.caption)).foregroundStyle(T3.muted).monospacedDigit()
                }
            }
            .font(.system(size: T3.small))
            if model.status?.hasUncommittedChanges == true {
                FocusedEditor(text: $model.commitMessage, placeholder: "Commit message (leave empty to have one written)",
                              multiline: false) {
                    if model.canCommit { model.request(.commit) }
                }
            }
            HStack(spacing: 6) {
                smallButton("Commit", icon: "checkmark.circle", disabled: !model.canCommit) { model.request(.commit) }
                smallButton("Commit & push", icon: "arrow.up.circle", disabled: !(model.canCommit && model.status?.hasRemote == true)) {
                    model.request(.commitAndPush)
                }
                smallButton("Push", icon: "arrow.up", disabled: !model.canPush) { model.request(.push) }
                smallButton("Pull", icon: "arrow.down", disabled: !model.canPull) { model.requestPull() }
                Spacer(minLength: 0)
            }
            if let status = model.status, !status.hasRemote {
                Text("This repository has no remote, so push and pull are unavailable.")
                    .font(.system(size: T3.caption)).foregroundStyle(T3.muted)
            }
            switch model.confirmation {
            case .action(.push), .action(.commitAndPush), .pull: confirmBar
            default: EmptyView()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    // MARK: Feedback

    private var confirmBar: some View {
        HStack(spacing: 8) {
            Text(verbatim: model.confirmation?.prompt ?? "").font(.system(size: T3.caption)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            smallButton("Cancel") { model.cancelConfirmation() }
            smallButton(model.confirmation?.button ?? "Confirm", prominent: true, disabled: model.isBusy) { model.confirm() }
        }
        .padding(8)
        .background(T3.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(T3.warning.opacity(0.28), lineWidth: 1))
    }

    @ViewBuilder
    private var feedback: some View {
        if let busy = model.busy {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text(verbatim: busy).foregroundStyle(T3.muted)
                }
                ForEach(Array(model.progress.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line).font(.system(size: T3.micro, design: .monospaced)).foregroundStyle(T3.faint).lineLimit(1)
                }
            }
            .font(.system(size: T3.caption))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        } else if let notice = model.notice {
            note(notice.text, isError: notice.isError).padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private func note(_ text: String, isError: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 10.5)).foregroundStyle(isError ? T3.error : T3.muted).padding(.top, 1)
            Text(verbatim: text).font(.system(size: T3.caption)).foregroundStyle(isError ? T3.error : T3.muted)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private func smallButton(_ title: String, icon: String? = nil, prominent: Bool = false, disabled: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
                Text(verbatim: title).lineLimit(1)
            }
            .font(.system(size: T3.caption, weight: .medium))
            .foregroundStyle(prominent ? Color.white : T3.foreground)
            .padding(.horizontal, 9).frame(height: 26)
            .background(prominent ? T3.primary : T3.fill, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(prominent ? Color.clear : T3.borderStrong, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(.plain).clickableCursor()
        .disabled(disabled)
    }
}
