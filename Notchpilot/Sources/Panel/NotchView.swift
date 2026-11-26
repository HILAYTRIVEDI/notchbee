import AppKit
import NotchpilotCore
import ServiceManagement
import SwiftUI

struct NotchView: View {
    let state: AppState
    let layout: NotchLayout
    let voice: VoiceController
    let presentation: NotchPresentation
    let present: (CGPath, Bool) -> Void
    let updateShortcuts: () -> Void
    let respond: (ApprovalRequest, ApprovalDecision) -> Void
    let answerInput: (UserInputRequest, [String: UserInputAnswer]) -> Void
    let dismissInput: (UserInputRequest) -> Void
    let backend: () -> (any AgentBackend)?
    let collapse: () -> Void
    let endEditing: () -> Void
    let chooseFolder: @MainActor () async -> URL?
    let chooseBackend: (String) -> Void
    let showHotkeyRecorder: () -> Void
    let retryConnection: () -> Void
    let showEngineLogs: () -> Void
    let resolver: ResolveCoordinator

    #if DEBUG
    @AppStorage("backendMode") private var backendMode = "Live"
    #endif
    @AppStorage("launchExpanded") private var launchExpanded = false
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var approvalHeight: CGFloat = 54
    @AppStorage(NotchAppearance.defaultsKey) private var appearance = NotchAppearance.glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var island
    @Namespace private var tabs
    @State private var replyFocus: UUID?
    @State private var replyThreadID: String?
    @State private var subscribedThreadID: String?
    @State private var query = ""
    @State private var filter: SessionFilter = .active
    @State private var drafts: [String: String] = [:]
    @State private var newPrompt = ""
    @AppStorage("defaultProject") private var defaultProject = ""
    @State private var projectID = ""
    @State private var pickedProjectID: String?
    @State private var openingFolder = false
    @State private var folderError: String?
    @State private var catalog: ThreadProviderCatalog?
    /// Providers for the open thread's project: its model menu and `/` commands.
    @State private var threadCatalog: (projectID: String?, catalog: ThreadProviderCatalog)?
    @State private var catalogProjectID: String?
    @State private var catalogFailure: (projectID: String, message: String)?
    @State private var providerID = ""
    @State private var modelID = ""
    @State private var runtimeMode: ThreadRuntimeMode = .approvalRequired
    @State private var launchIDs = ThreadLaunch.IDs()
    @State private var providerLoad: UUID?
    @State private var launching = false
    @State private var launchError: String?
    @State private var managing: Management?
    @State private var titleDraft = ""
    @State private var busy = false
    @State private var actionError: String?
    @State private var workspace = WorkspaceModel()
    @State private var newFocus: UUID?
    @State private var explicitQuickSession = false
    /// Measured pieces of the expanded panel, so it is only as tall as what it shows.
    @State private var chromeHeight: CGFloat = 44
    @State private var bodyHeight: CGFloat = 120
    @State private var footerHeight: CGFloat = 0

    private enum SessionFilter: String, CaseIterable {
        case active = "Active"
        case archived = "Archived"
        case all = "All"
    }

    private enum Management { case rename, delete }
    private var snapshot: StateSnapshot { state.panelSnapshot }
    private var connected: Bool { snapshot.connection == .connected }
    private var voiceVisible: Bool {
        snapshot.voiceCommand != nil || snapshot.voiceMode != nil || voice.anywhere.isShowing
    }
    private var layer: NotchLayout.Layer {
        if voiceVisible { return .voice }
        if snapshot.workspaceOpen || (snapshot.showsSessions && snapshot.isHovering) { return .workspace }
        if presentation.notice != nil { return .peek }
        if snapshot.hoverSuppressed { return .collapsed }
        if snapshot.isHovering { return .hover }
        return .collapsed
    }
    private var relevantSession: SessionSummary? { NotchPresentation.relevantSession(in: snapshot) }
    private var previewSession: SessionSummary? { layer == .hover ? relevantSession : nil }
    private var isExpanded: Bool { layer == .workspace || layer == .voice }
    private var pullDown: some Gesture {
        DragGesture(minimumDistance: 12)
            .onEnded { gesture in
                guard !isExpanded, gesture.translation.height > 16,
                      gesture.translation.height > abs(gesture.translation.width) else { return }
                showWorkspace(preferred: presentation.notice?.sessionID ?? previewSession?.id)
            }
    }
    private var isThread: Bool { snapshot.panelTab == .thread && !voiceVisible }
    private var session: SessionSummary? { snapshot.sessions.first { $0.id == snapshot.openThreadID } }
    private var visibleThreadID: String? { isThread && layer == .workspace ? snapshot.openThreadID : nil }
    private var providers: [ThreadProvider] { catalogProjectID == projectID ? catalog?.providers ?? [] : [] }
    private var provider: ThreadProvider? { providers.first { $0.id == providerID } }
    private var catalogError: String? { catalogFailure?.projectID == projectID ? catalogFailure?.message : nil }
    /// Real projects only: the engine's scratch folder is what "Quick session" already means.
    private var projectChoices: [ThreadProject] {
        let projects = snapshot.projects.filter { $0.name != "\(Product.name) Scratch" }
        let availableIDs = Set(projects.map(\.id))
        let recentID = snapshot.sessions.filter { $0.projectID.map(availableIDs.contains) == true }
            .max { ($0.updatedAt ?? $0.lastActivity ?? .distantPast, $0.id) <
                   ($1.updatedAt ?? $1.lastActivity ?? .distantPast, $1.id) }?.projectID
        let preferredID = session?.projectID.flatMap { availableIDs.contains($0) ? $0 : nil } ?? recentID
        return projects.filter { $0.id == preferredID } + projects.filter { $0.id != preferredID }
    }
    private var providerLoadProjectID: String? {
        snapshot.panelTab == .new && connected && layer == .workspace ? projectID : nil
    }
    private var approvals: [ApprovalRequest] {
        if isThread { return snapshot.pendingApprovals.filter { $0.threadId == snapshot.openThreadID } }
        return snapshot.pendingApprovals
    }
    private var userInputs: [UserInputRequest] {
        if isThread { return snapshot.pendingUserInputs.filter { $0.threadId == snapshot.openThreadID } }
        return snapshot.pendingUserInputs
    }

    private struct Details: Equatable {
        let id: String?
        let preview: Bool
    }

    private var details: Details {
        Details(id: visibleThreadID ?? previewSession?.id, preview: previewSession != nil)
    }

    /// The thread view takes all the room it can; every other tab is exactly as tall as its content.
    private var workspaceHeight: CGFloat? {
        guard layer == .workspace, snapshot.panelTab != .thread else { return nil }
        return max(110, (4 + chromeHeight + bodyHeight + footerHeight + 10).rounded(.up))
    }

    /// The project a new thread starts in: the remembered default, else the most recent real project.
    private var preferredProjectID: String {
        if projectChoices.contains(where: { $0.id == defaultProject }) { return defaultProject }
        return projectChoices.first?.id ?? ""
    }

    private var notchActivity: NotchActivity? {
        NotchPresentation.activity(in: snapshot, finishedRecently: presentation.finishedFlash)
    }

    /// Running and done light up the notch's edge instead of widening it; only "needs you" keeps the wings.
    private var wingActivity: NotchActivity? { notchActivity == .attention ? .attention : nil }

    private var glowMode: NotchGlow.Mode? {
        guard layer == .collapsed || layer == .peek else { return nil }
        switch notchActivity {
        case .running?: return .running
        case .done?: return .done
        default: return nil
        }
    }

    private var peekHeight: CGFloat { presentation.notice?.kind == .completion ? 56 : 36 }

    private var silhouette: NotchShape {
        var shape = layout.shape(for: layer, workspaceHeight: workspaceHeight, hoverHeight: hoverHeight,
                                 peekHeight: peekHeight, activity: wingActivity != nil)
        shape.interpolates = !reduceMotion
        return shape
    }

    private var motion: Animation {
        if reduceMotion { return .easeInOut(duration: 0.16) }
        return layer == .collapsed || layer == .peek
            ? .spring(response: 0.27, dampingFraction: 0.88)
            : .spring(response: 0.35, dampingFraction: 0.82)
    }

    private var arrival: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: NotchContentAppearance(visible: false),
                                 identity: NotchContentAppearance(visible: true))
                .animation(.easeOut(duration: 0.17).delay(0.10)),
            removal: .opacity.animation(.easeOut(duration: 0.09))
        )
    }

    private var panelShell: some View {
        let shape = silhouette
        let provider = appearance == .tinted
            ? (isThread ? session?.providerInstanceId : nil) ?? presentation.notice?.provider ?? relevantSession?.providerInstanceId
            : nil
        return ZStack(alignment: .top) {
            NotchSurface(shape: shape, frame: layout.panelFrame, appearance: appearance,
                         tint: provider.map { ProviderBrand.tint(driver: ProviderBrand.driver(instanceID: $0)) },
                         idleSize: layout.hasNotch ? layout.idleSize : nil, present: present)
            if let glowMode {
                NotchGlow(shape: shape, size: layout.panelFrame.size, mode: glowMode)
                    .transition(.opacity.animation(.easeInOut(duration: 0.5)))
                    .id(glowMode)
            }
            ZStack(alignment: .top) {
                switch layer {
                case .collapsed:
                    collapsedLabel
                case .peek:
                    if let notice = presentation.notice { peek(notice).transition(arrival) }
                case .hover:
                    hoverCard.transition(arrival)
                case .workspace, .voice:
                    expanded
                        .frame(width: shape.width - 2 * layout.topEar, height: shape.height - layout.notchHeight)
                        .padding(.top, layout.notchHeight)
                        .transaction { if reduceMotion { $0.animation = nil } }
                        .transition(arrival)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .clipShape(shape)
            .overlay(alignment: .top) {
                // Resolving is instant and final; only a failure is worth a message.
                if let toast = resolver.toast, toast.isError, layer == .hover || layer == .workspace {
                    ResolveToastView(toast: toast, undo: resolver.undo, dismiss: resolver.dismiss)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: max(0, shape.width - 42))
                        .padding(.top, shape.height - 48)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.16) : .snappy(duration: 0.22), value: resolver.toast)
        }
        .frame(width: layout.panelFrame.width, height: layout.panelFrame.height, alignment: .top)
        .contentShape(shape)
        .foregroundStyle(.white)
        .animation(motion, value: shape)
        .simultaneousGesture(pullDown, isEnabled: !isExpanded)
    }

    var body: some View {
        let panel = panelShell
            .onChange(of: isExpanded) {
                if isExpanded { presentation.clearNotices() }
            }
            .onChange(of: details, initial: true) { _, details in
                updateDetails(details)
            }
            .onDisappear {
                if let id = subscribedThreadID { backend()?.setSessionDetailsVisible(false, sessionId: id) }
                presentation.setPreviewSession(nil)
            }
        return panel
            .onChange(of: snapshot.panelTab) {
                resetControls()
                if snapshot.panelTab == .new {
                    explicitQuickSession = false
                    projectID = pickedProjectID ?? preferredProjectID
                    pickedProjectID = nil
                    newFocus = UUID()
                }
            }
            .onChange(of: snapshot.settingsRevision) {
                if let id = providerLoadProjectID { catalogProjectID = nil; Task { await loadProviders(for: id) } }
            }
            .onChange(of: defaultProject) {
                if snapshot.panelTab == .new { projectID = preferredProjectID }
            }
            .onChange(of: snapshot.openThreadID) {
                resetControls()
                if snapshot.openThreadID != replyThreadID { replyFocus = nil }
            }
            .onChange(of: layer) {
                if layer != .workspace { replyFocus = nil }
                if layer == .workspace, snapshot.panelTab == .new { newFocus = UUID() }
            }
            .onChange(of: voiceVisible) { endEditing() }
            .onChange(of: snapshot.pendingApprovals) { updateShortcuts() }
            .onChange(of: snapshot.pendingUserInputs) { updateShortcuts() }
            .onChange(of: presentation.notice) { updateShortcuts() }
            .onChange(of: snapshot.voiceCommand?.phase) { updateShortcuts() }
            .task(id: providerLoadProjectID) {
                if let id = providerLoadProjectID { await loadProviders(for: id) }
            }
            .onChange(of: connected) {
                guard !connected else { return }
                providerLoad = nil
                catalog = nil
                catalogProjectID = nil
                catalogFailure = nil
            }
            .onChange(of: snapshot.projects) {
                let missing = !projectID.isEmpty && !snapshot.projects.contains(where: { $0.id == projectID })
                if missing || (projectID.isEmpty && !explicitQuickSession) { projectID = preferredProjectID }
            }
    }

    private func updateDetails(_ details: Details) {
        presentation.setPreviewSession(details.preview ? details.id : nil)
        if let subscribedThreadID, subscribedThreadID != details.id {
            backend()?.setSessionDetailsVisible(false, sessionId: subscribedThreadID)
        }
        subscribedThreadID = details.id
        // A hovered thread was already subscribed, but the workspace still needs its full snapshot.
        if let id = details.id { backend()?.setSessionDetailsVisible(true, sessionId: id) }
    }

    private func showWorkspace(preferred id: String?) {
        if let id, snapshot.sessions.contains(where: { $0.id == id }) {
            state.apply(.openThread(id))
        } else {
            state.apply(.selectPanelTab(.sessions))
        }
    }

    /// Idle, this is only a click target the size of the hardware notch. During activity the glyph sits in the
    /// left wing and, for several running sessions, their count in the right one.
    private var collapsedLabel: some View {
        let activity = wingActivity
        let shape = layout.shape(for: .collapsed, activity: activity != nil)
        let wing = layout.hasNotch ? max(0, (shape.width - layout.notchWidth) / 2) : 0
        let ear = layout.topEar
        var count = 0
        if case .running(let running)? = activity, running > 1 { count = running }
        return Button {
            showWorkspace(preferred: nil)
        } label: {
            ZStack {
                if let activity {
                    if layout.hasNotch {
                        HStack(spacing: 0) {
                            ActivityGlyph(activity: activity)
                                .frame(width: wing - ear).frame(width: wing, alignment: .trailing)
                            Color.clear.frame(width: layout.notchWidth)
                            Group {
                                if count > 0 {
                                    Text("\(count)")
                                        .font(.system(size: T3.caption, weight: .semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(T3.muted)
                                        .accessibilityHidden(true)
                                } else {
                                    Color.clear
                                }
                            }
                            .frame(width: wing - ear).frame(width: wing, alignment: .leading)
                        }
                    } else {
                        HStack(spacing: 6) {
                            ActivityGlyph(activity: activity)
                            if count > 0 {
                                Text("\(count)")
                                    .font(.system(size: T3.caption, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(T3.muted)
                            }
                        }
                    }
                }
            }
            .frame(width: shape.width, height: shape.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).clickableCursor()
        .accessibilityLabel("Open \(Product.name)")
        .accessibilityValue(notchActivity?.label ?? "")
    }

    @ViewBuilder
    private func peek(_ notice: NotchPresentation.Notice) -> some View {
        if notice.kind == .completion, let id = notice.sessionID {
            completionCard(notice, sessionID: id)
        } else {
            noticePeek(notice)
        }
    }

    /// "Done" moment: a green check, the task's title, who finished it, and a clear way in.
    private func completionCard(_ notice: NotchPresentation.Notice, sessionID id: String) -> some View {
        let provider = notice.provider.map { ProviderBrand.label(instanceID: $0) } ?? Product.name
        return HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(T3.success)
                .frame(width: 30, height: 30)
                .background(T3.success.opacity(0.16), in: Circle())
                .overlay(Circle().strokeBorder(T3.success.opacity(0.4), lineWidth: 1))
                .symbolEffect(.bounce, options: .nonRepeating, value: id)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: notice.title)
                    .font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    .notchMatch("title-\(id)", in: island, enabled: !reduceMotion)
                Text(notice.count > 1 ? "\(provider) finished · +\(notice.count - 1) more" : "\(provider) finished")
                    .font(.system(size: 11)).foregroundStyle(T3.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            PanelPillButton(title: "View", icon: "arrow.up.right", style: .prominent) {
                showWorkspace(preferred: id)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .contentShape(Rectangle())
        .onTapGesture { showWorkspace(preferred: id) }
        .frame(width: layout.shape(for: .peek, peekHeight: 56).width - 2 * layout.topEar)
        .padding(.top, layout.notchHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(provider) finished \(notice.title)")
        .accessibilityAddTraits(.isButton)
    }

    private func noticePeek(_ notice: NotchPresentation.Notice) -> some View {
        Button {
            showWorkspace(preferred: notice.sessionID)
        } label: {
            HStack(spacing: 8) {
                statusDot
                Image(systemName: notice.symbol)
                    .foregroundStyle(notice.tint)
                Group {
                    if notice.kind != .completion || notice.sessionID == nil {
                        Text(verbatim: notice.text)
                    } else if let id = notice.sessionID {
                        let provider = notice.provider.map { ProviderBrand.label(instanceID: $0) } ?? Product.name
                        HStack(spacing: 4) {
                            Text("\(provider) finished —").fixedSize()
                            Text(verbatim: notice.title).notchMatch("title-\(id)", in: island, enabled: !reduceMotion)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .fontWeight(.semibold)
                .lineLimit(1)
                if let provider = notice.provider { providerIcon(provider, id: notice.sessionID) }
                Spacer(minLength: 0)
                if notice.count > 1 {
                    Text("+\(notice.count - 1)")
                        .monospacedDigit()
                        .foregroundStyle(T3.muted)
                }
                Image(systemName: "chevron.right").foregroundStyle(T3.faint)
            }
            .font(.system(size: 12))
            .frame(height: 34)
            .padding(.horizontal, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).clickableCursor()
        .frame(width: layout.shape(for: .peek).width - 2 * layout.topEar)
        .padding(.top, layout.notchHeight)
        .accessibilityHint("Opens the thread")
    }

    private static let hoverRowHeight: CGFloat = 32
    private var hoverSessions: [SessionSummary] { NotchPresentation.relevantSessions(in: snapshot) }
    private var hoverHeight: CGFloat {
        if hoverSessions.isEmpty { return 8 + 48 + 12 }
        let rows = CGFloat(max(1, hoverSessions.count)) * Self.hoverRowHeight
        let preview: CGFloat = hoverSessions.isEmpty ? 0 : 20
        return 8 + rows + preview + 8 + 26 + 10
    }

    private var hoverCard: some View {
        let sessions = hoverSessions
        let topSummary = snapshot.approvalError ?? actionError
            ?? snapshot.pendingApprovals.first { $0.threadId == sessions.first?.id }?.command
            ?? snapshot.pendingUserInputs.first { $0.threadId == sessions.first?.id }?.questions.first?.question
            ?? presentation.previewLine
        return Group {
            if sessions.isEmpty {
                hoverEmptyState
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        hoverRow(session, preview: index == 0 ? topSummary : nil)
                    }
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        PanelPillButton(title: "All sessions", style: .quiet) { showWorkspace(preferred: nil) }
                        openFolderButton
                        PanelPillButton(title: "New", icon: "plus", style: .prominent) {
                            state.apply(.selectPanelTab(.new))
                        }
                        .disabled(!connected)
                    }
                    .padding(.horizontal, 4)
                    .frame(height: 26)
                    .padding(.top, 8)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .frame(width: layout.shape(for: .hover).width - 2 * layout.topEar, alignment: .leading)
        .padding(.top, layout.notchHeight)
    }

    /// One calm row: what is (not) happening on the left, the way forward on the right.
    private var hoverEmptyState: some View {
        let ready = connected && previewSession == nil
        return HStack(spacing: 10) {
            Image(systemName: ready ? (snapshot.sessions.isEmpty ? "sparkles" : "checkmark") : "bolt.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ready && !snapshot.sessions.isEmpty ? T3.success : T3.muted)
                .frame(width: 30, height: 30)
                .background(T3.fill, in: Circle())
                .overlay(Circle().strokeBorder(T3.border, lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: hoverSummary)
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(T3.foreground).lineLimit(1)
                if ready {
                    Text(snapshot.sessions.isEmpty ? "Start one from here" : "Nothing needs you")
                        .font(.system(size: 11)).foregroundStyle(T3.faint).lineLimit(1)
                        .fixedSize()
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if !snapshot.sessions.isEmpty {
                    PanelPillButton(title: "All sessions", style: .quiet) { showWorkspace(preferred: nil) }
                }
                openFolderButton
                PanelPillButton(title: "New", icon: "plus", style: .prominent) {
                    state.apply(.selectPanelTab(.new))
                }
                .disabled(!connected)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 48)
    }

    private func hoverRow(_ session: SessionSummary, preview: String?) -> some View {
        HoverSessionRow(
            session: session,
            preview: preview,
            request: snapshot.pendingApprovals.first { $0.threadId == session.id },
            needsReview: session.pendingRuntimeRequest?.isApproval == true,
            needsInput: session.pendingRuntimeRequest?.isUserInput == true ||
                snapshot.pendingUserInputs.contains { $0.threadId == session.id },
            connected: connected,
            reduceMotion: reduceMotion,
            rowHeight: Self.hoverRowHeight,
            icon: providerIcon(session.providerInstanceId, id: session.id),
            open: { showWorkspace(preferred: session.id) },
            respond: { respond($0, $1) },
            reply: {
                replyThreadID = session.id
                replyFocus = UUID()
                showWorkspace(preferred: session.id)
            },
            resolve: { resolver.resolve(session) }
        )
    }

    private var hoverSummary: String {
        if let previewSession { return sessionStatusText(previewSession).text }
        switch snapshot.connection {
        case .connected: return snapshot.sessions.isEmpty ? "No sessions yet" : "All caught up"
        case .engineFailed(let message), .failed(let message): return message
        case .disconnected: return "Disconnected"
        case .engineStarting, .engineRestarting: return "Connecting…"
        }
    }

    private func providerIcon(_ provider: String, id: String?) -> some View {
        ProviderBadge(driver: ProviderBrand.driver(instanceID: provider), size: 26)
            .notchMatch(id.map { "provider-\($0)" }, in: island, enabled: !reduceMotion)
            .accessibilityHidden(true)
    }

    private var statusDot: some View {
        let status = liveStatus
        return Group {
            if let status {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(status.color)
                    .symbolEffect(.pulse, options: .repeating, isActive: status.running && !reduceMotion)
                    .accessibilityLabel(status.label)
            } else {
                Color.clear.frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
        }
        .notchMatch("status", in: island, enabled: !reduceMotion)
    }

    private var liveStatus: (color: Color, label: String, running: Bool)? {
        if !snapshot.pendingApprovals.isEmpty || snapshot.sessions.contains(where: { $0.pendingRuntimeRequest?.isApproval == true }) {
            return (T3.warning, "Needs approval", false)
        }
        if !snapshot.pendingUserInputs.isEmpty || snapshot.sessions.contains(where: { $0.pendingRuntimeRequest?.isUserInput == true }) {
            return (T3.warning, "Needs input", false)
        }
        switch snapshot.connection {
        case .failed, .engineFailed: return (T3.error, "Error", false)
        default: break
        }
        if snapshot.sessions.contains(where: { $0.hasRecentFailure() && !$0.isSettled && !$0.isArchived }) {
            return (T3.error, "Error", false)
        }
        if snapshot.sessions.contains(where: { $0.status == .running }) { return (.cyan, "Running", true) }
        return nil
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                if !voiceVisible {
                    if snapshot.panelTab == .sessions { sessionSearch.padding(.top, 8) }
                    if isThread, let session { threadHeader(session).padding(.top, 8) }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chromeHeight = $0 }

            Group {
                if let visibleThreadID {
                    ThreadTimeline(state: state, threadRunning: session?.status == .running, sending: busy) {
                        threadContent
                    }
                    .id(visibleThreadID)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 9) { content }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .id(voice.anywhere.status?.phase == .result ? "dictation-reply" : voiceVisible ? "voice" : snapshot.panelTab.rawValue)
                }
            }
            .frame(maxHeight: .infinity)
            .transition(reduceMotion ? .opacity : .offset(x: 14).combined(with: .opacity))

            footer
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .font(.system(size: 12))
        .controlSize(.small)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.86),
                   value: snapshot.panelTab)
    }

    private var header: some View {
        HStack(spacing: 8) {
            PanelTabBar(tabs: PanelTab.allCases.filter { $0 != .settings && ($0 != .thread || snapshot.openThreadID != nil) },
                        selected: voiceVisible ? nil : snapshot.panelTab, reduceMotion: reduceMotion) { tab in
                if voiceVisible { voice.cancel() }
                state.apply(.selectPanelTab(tab))
            }
            Spacer(minLength: 2)
            let status = NotchPresentation.panelStatus(in: snapshot)
            if status.tone != .idle { PanelStatusLabel(status: status) }
            PanelIconButton(icon: "gearshape", help: "Settings (⌘,)", action: showHotkeyRecorder)
                .accessibilityLabel("Settings")
            Button(action: collapse) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 34, height: 30)
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain).clickableCursor()
            .accessibilityLabel("Collapse \(Product.name)")
            .help("Collapse \(Product.name) (Esc)")
        }
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var content: some View {
        if let status = voice.anywhere.status {
            anywhereContent(status)
        } else if let voice = snapshot.voiceCommand {
            voiceContent(voice.phase)
        } else {
            switch snapshot.panelTab {
            case .sessions: sessionsContent
            case .thread: EmptyView()
            case .new: newContent
            case .settings: settingsContent
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let status = voice.anywhere.status {
            anywhereControls(status)
        } else if !voiceVisible {
            switch snapshot.panelTab {
            case .thread:
                if !approvals.isEmpty || !userInputs.isEmpty {
                    ScrollView {
                        VStack(spacing: 7) {
                            if !approvals.isEmpty { approvalCards }
                            if !userInputs.isEmpty { userInputCards }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { approvalHeight = $0 }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: min(approvalHeight, layout.maxContentHeight * (userInputs.isEmpty ? 0.24 : 0.6)))
                    .padding(.bottom, 5)
                }
                if let session, !session.isArchived, managing == nil {
                    let draft = Binding(get: { drafts[session.id, default: ""] }, set: { drafts[session.id] = $0 })
                    VStack(alignment: .leading, spacing: 0) {
                        if !threadProviders(for: session).isEmpty {
                            threadModelMenu(session).padding(.top, 4).padding(.horizontal, 2)
                        }
                        PromptComposer(text: draft, placeholder: "Reply to this thread…", enabled: connected,
                                       busy: busy, button: "Send", voice: voice,
                                       focusRequest: replyThreadID == session.id ? replyFocus : nil,
                                       commands: threadProvider(for: session)?.commands ?? [],
                                       stop: session.status == .running ? { mutate(session.id, .stop) } : nil) {
                            send(session.id)
                        }
                    }
                    .id(session.id)
                    .task(id: ThreadCatalogKey(projectID: session.projectID, connected: connected)) {
                        await loadThreadCatalog(projectID: session.projectID)
                    }
                }
            case .new:
                if let launchError {
                    feedback(launchError)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 5)
                }
                PromptComposer(text: $newPrompt, placeholder: "What should we build?", placeholders: Self.promptIdeas,
                               enabled: true, busy: launching, button: "Start session", voice: voice,
                               validatesOnSubmit: true, focusRequest: newFocus, commands: provider?.commands ?? [],
                               submit: launch)
            default: EmptyView()
            }
        }
    }

    private static let promptIdeas = [
        "What should we build?",
        "Fix the failing tests in…",
        "Refactor this module so it…",
        "Explain how the auth flow works",
        "Add a dark mode toggle to settings",
        "Review my last commit for bugs",
    ]

    private var filteredSessions: [SessionSummary] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return snapshot.sessions.filter { session in
            guard snapshot.showResolved || !session.isSettled else { return false }
            guard filter == .all || session.isArchived == (filter == .archived) else { return false }
            return search.isEmpty || [session.title, session.providerInstanceId, session.project, session.repository, session.branch]
                .compactMap { $0 }.contains { $0.localizedStandardContains(search) }
        }
        .sorted { ($0.lastActivity ?? .distantPast, $0.id) > ($1.lastActivity ?? .distantPast, $1.id) }
    }

    private var sessionSearch: some View {
        HStack(spacing: 8) {
            editor($query, placeholder: "Search sessions", multiline: false, search: true) { endEditing() }
            Picker("Sessions", selection: $filter) {
                ForEach(SessionFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var sessionsContent: some View {
        connectionNotice
        if !approvals.isEmpty { approvalCards }
        if !userInputs.isEmpty { userInputCards }

        HStack {
            Toggle("Show resolved", isOn: Binding(get: { snapshot.showResolved }, set: { _ in state.apply(.toggleShowResolved) }))
                .toggleStyle(.checkbox)
                .font(.system(size: T3.caption))
                .foregroundStyle(T3.muted)
            Spacer()
        }
        if let actionError { feedback(actionError) }
        let sessions = filteredSessions
        if connected, snapshot.sessions.isEmpty {
            emptyState(icon: "sparkles", title: "No sessions yet", detail: "Start one and it will show up here.") {
                HStack(spacing: 6) {
                    openFolderButton
                    PanelPillButton(title: "New session", icon: "plus", style: .prominent) {
                        state.apply(.selectPanelTab(.new))
                    }
                }
            }
        } else if connected, sessions.isEmpty {
            emptyState(icon: "magnifyingglass", title: "No matching sessions",
                       detail: query.isEmpty ? "Nothing in this filter." : "Try a different search.") { EmptyView() }
        }
        ForEach(sessions) { session in
            let status = sessionStatusText(session)
            SessionRowView(session: session, statusText: status.text, statusWarning: status.warning,
                           forceHover: forceHover(session, in: sessions), enabled: connected,
                           open: { state.apply(.openThread(session.id)) },
                           match: reduceMotion ? nil : island,
                           toggleResolve: { session.isSettled ? resolver.reopen(session) : resolver.resolve(session) })
                .equatable()
        }
    }

    private func emptyState<Action: View>(icon: String, title: String, detail: String,
                                          @ViewBuilder action: () -> Action) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(T3.faint)
                .frame(width: 38, height: 38)
                .background(T3.fill, in: Circle())
                .overlay(Circle().strokeBorder(T3.border, lineWidth: 1))
                .padding(.bottom, 4)
            Text(title).font(.system(size: T3.body, weight: .semibold)).foregroundStyle(T3.foreground)
            Text(detail).font(.system(size: T3.caption + 0.5)).foregroundStyle(T3.muted)
            action().padding(.top, 8)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private func forceHover(_ session: SessionSummary, in sessions: [SessionSummary]) -> Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "debugHoverFirstRow") && sessions.first?.id == session.id
        #else
        return false
        #endif
    }

    private func sessionStatusText(_ session: SessionSummary) -> (text: String, warning: Bool) {
        let request = session.pendingRuntimeRequest
        let needsApproval = request?.isApproval == true || snapshot.pendingApprovals.contains { $0.threadId == session.id }
        let needsInput = request != nil || snapshot.pendingUserInputs.contains { $0.threadId == session.id }
        let label = needsApproval ? "Needs approval" : needsInput ? "Needs input" : session.displayStatus
        return (label, needsApproval || needsInput)
    }

    private func threadResolveButton(_ session: SessionSummary) -> some View {
        PanelIconButton(icon: session.isSettled ? "arrow.uturn.backward" : "checkmark",
                        tint: session.isSettled ? nil : T3.success,
                        help: session.isSettled ? "Reopen this thread" : "Resolve this thread (⌘⇧D)") {
            session.isSettled ? resolver.reopen(session) : resolver.resolve(session)
        }
        .disabled(!connected)
        .accessibilityLabel(session.isSettled ? "Reopen thread" : "Resolve thread")
    }

    private func threadHeader(_ session: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                providerIcon(session.providerInstanceId, id: session.id)
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.title).font(.system(size: 14, weight: .semibold))
                        .lineLimit(2).help(session.title)
                        .notchMatch("title-\(session.id)", in: island, enabled: !reduceMotion)
                    HStack(spacing: 8) {
                        sessionStatus(session)
                        if let diff = session.diff {
                            Text("\(diff.files) \(diff.files == 1 ? "file" : "files") · +\(diff.additions) −\(diff.deletions)")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        if session.isArchived { Text("Archived").foregroundStyle(.secondary) }
                    }
                }
                Spacer(minLength: 0)
                if session.status == .running && (session.isArchived || managing != nil) {
                    Button("Stop", systemImage: "stop.fill") { mutate(session.id, .stop) }
                        .disabled(!connected || busy)
                }
                threadResolveButton(session)
                threadMenu(session)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 10).fill(T3.fill)
                    .notchMatch("session-\(session.id)", in: island, enabled: !reduceMotion)
            }
            if session.workspacePath != nil, !session.isArchived {
                WorkspaceSection(model: workspace)
            }
            if case .rename = managing {
                HStack {
                    editor($titleDraft, placeholder: "Thread name", multiline: false) { rename(session.id) }
                    Button("Save") { rename(session.id) }.disabled(titleDraft.trimmed.isEmpty || !connected || busy)
                    Button("Cancel") { managing = nil }
                }
            }
            if case .delete = managing {
                HStack {
                    Text("Permanently delete this thread?").fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Delete", role: .destructive) { mutate(session.id, .delete) }
                        .disabled(!connected || busy)
                    Button("Cancel") { managing = nil }
                }
            }
            if let actionError { feedback(actionError).lineLimit(3).help(actionError) }
        }
        .task(id: WorkspaceBinding(session: session, connected: connected)) {
            workspace.backend = { backend() as? any WorkspaceBackend }
            workspace.bind(threadID: session.id, projectID: session.projectID, path: session.isArchived ? nil : session.workspacePath,
                           agentRunning: session.status == .running, connected: connected)
            #if DEBUG
            // Screenshot aid for the Fake backend: `--demo-workspace-menu` opens the menu on the first thread.
            if ProcessInfo.processInfo.arguments.contains("--demo-workspace-menu"), !workspace.isOpen,
               workspace.status == nil, session.workspacePath != nil {
                try? await Task.sleep(for: .milliseconds(600))
                if workspace.status != nil, !workspace.isOpen { workspace.toggleOpen() }
            }
            #endif
        }
    }

    private struct WorkspaceBinding: Hashable {
        let thread: String
        let project: String?
        let path: String?
        let archived: Bool
        let running: Bool
        let connected: Bool

        init(session: SessionSummary, connected: Bool) {
            thread = session.id
            project = session.projectID
            path = session.workspacePath
            archived = session.isArchived
            running = session.status == .running
            self.connected = connected
        }
    }

    @ViewBuilder
    private var threadContent: some View {
        connectionNotice
        if let error = session?.error { feedback(error) }
        if snapshot.conversationUnavailable {
            HStack {
                Text("Conversation unavailable").foregroundStyle(.secondary)
                Button("Retry") {
                    if let id = snapshot.openThreadID { backend()?.setSessionDetailsVisible(true, sessionId: id) }
                }
                .disabled(!connected)
            }
        }
    }

    private struct ThreadCatalogKey: Hashable {
        let projectID: String?
        let connected: Bool
    }

    private func threadProviders(for session: SessionSummary) -> [ThreadProvider] {
        guard let threadCatalog, threadCatalog.projectID == session.projectID else { return [] }
        return threadCatalog.catalog.providers
    }

    private func threadProvider(for session: SessionSummary) -> ThreadProvider? {
        let id = session.modelSelection?.instanceId ?? session.providerInstanceId
        return threadProviders(for: session).first { $0.id == id }
    }

    private func loadThreadCatalog(projectID: String?) async {
        guard connected, let backend = backend() else { return }
        do {
            let loaded = try await backend.providerCatalog(projectID: projectID)
            guard !Task.isCancelled, self.backend() === backend else { return }
            threadCatalog = (projectID, loaded)
        } catch {
            // The menu stays hidden and commands are empty; replies still work with the thread's model.
        }
    }

    /// The model for the thread's next turns. Another provider continues the conversation through a handoff.
    private func threadModelMenu(_ session: SessionSummary) -> some View {
        let providers = threadProviders(for: session)
        let current = session.modelSelection
        let currentProvider = threadProvider(for: session)
        let modelName = currentProvider?.models.first { $0.id == current?.model }?.name ?? current?.model ?? "Choose model"
        let running = session.status == .running
        let ordered = providers.sorted { a, b in (a.id == currentProvider?.id ? 0 : 1) < (b.id == currentProvider?.id ? 0 : 1) }
        return HStack(spacing: 6) {
            Menu {
                ForEach(ordered) { provider in
                    Section(provider.id == currentProvider?.id ? provider.name : "Switch to \(provider.name)") {
                        ForEach(provider.models) { model in
                            let selected = provider.id == current?.instanceId && model.id == current?.model
                            Button {
                                guard !selected else { return }
                                mutate(session.id, .setModel(.init(instanceId: provider.id, model: model.id)))
                            } label: {
                                if selected { Label(model.name, systemImage: "checkmark") } else { Text(model.name) }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(T3.link.opacity(0.85))
                    if let currentProvider {
                        Text(currentProvider.name).foregroundStyle(T3.muted)
                    }
                    Text(modelName).foregroundStyle(T3.foreground).truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(T3.faint)
                }
                .font(.system(size: T3.small, weight: .medium))
                .lineLimit(1)
                .padding(.leading, 9)
                .padding(.trailing, 8)
                .frame(height: 26)
                .background(T3.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(T3.border, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).clickableCursor()
            .fixedSize()
            .disabled(!connected || busy || running)
            .opacity(running ? 0.55 : 1)
            .help(running ? "Change the model after this turn finishes" : "Model for the next message")
            .accessibilityLabel("Model: \(modelName)")
            Spacer(minLength: 0)
        }
    }

    private func threadMenu(_ session: SessionSummary) -> some View {
        Menu {
            Button("Rename…") {
                titleDraft = session.title
                managing = .rename
            }
            .disabled(!connected || busy)
            if session.isArchived {
                Button("Unarchive") { mutate(session.id, .unarchive) }.disabled(!connected || busy)
            } else {
                Button("Archive") { mutate(session.id, .archive) }.disabled(!connected || busy)
            }
            Button("Delete…", role: .destructive) { managing = .delete }.disabled(!connected || busy)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(T3.muted)
                .frame(width: 28, height: 28)
                .background(T3.fill, in: Circle())
                .overlay(Circle().strokeBorder(T3.border, lineWidth: 1))
                .contentShape(Circle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).clickableCursor()
        .fixedSize()
        .accessibilityLabel("Thread options")
        .help("Thread options")
    }

    private var approvalCards: some View {
        VStack(spacing: 7) {
            if !approvals.isEmpty, let error = snapshot.approvalError { feedback(error) }
            ForEach(approvals) { request in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "shield.lefthalf.filled").foregroundStyle(T3.warning)
                        Text("\(request.toolName) approval").font(.system(size: T3.small + 0.5, weight: .semibold))
                        Spacer(minLength: 4)
                        if !isThread {
                            Text(verbatim: request.sessionName).font(.system(size: T3.caption)).foregroundStyle(T3.muted)
                                .lineLimit(1)
                        }
                    }
                    if !request.command.isEmpty {
                        Text(verbatim: request.command)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(T3.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                    }
                    if let context = request.context {
                        Text(verbatim: context).font(.system(size: T3.caption))
                            .foregroundStyle(T3.muted).lineLimit(2).help(context)
                    }
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button("Deny") { respond(request, .declined) }
                            .buttonStyle(.bordered).clickableCursor()
                        Button { respond(request, .accepted) } label: {
                            HStack(spacing: 5) { Text("Approve"); Text("⌘↵").opacity(0.6) }
                        }
                        .buttonStyle(.borderedProminent).clickableCursor()
                        .tint(T3.primary)
                        .disabled(!request.canApprove)
                    }
                }
                .disabled(!connected)
                .padding(10)
                .background(T3.warning.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(T3.warning.opacity(0.30), lineWidth: 1))
            }
        }
    }

    private var userInputCards: some View {
        VStack(spacing: 7) {
            ForEach(userInputs) { request in
                UserInputCard(
                    request: request, showsSession: !isThread,
                    error: snapshot.pendingUserInputs.first?.id == request.id ? snapshot.userInputError : nil,
                    submit: { answerInput(request, $0) }, dismiss: { dismissInput(request) }
                )
                .id(request.id)
                .disabled(!connected)
            }
        }
    }

    private var openFolderButton: some View {
        PanelIconButton(icon: "folder.badge.plus", size: 26, help: "Open folder…", action: openFolder)
            .accessibilityLabel("Open folder")
            .disabled(!connected || openingFolder)
    }

    /// Picker tag for the "Open folder…" entry in the Project menu. Never a real project id.
    private static let openFolderTag = "notchbee.open-folder"

    private func openFolder() {
        guard !openingFolder, let service = backend() as? any SettingsBackend else { return }
        openingFolder = true
        folderError = nil
        Task {
            defer { openingFolder = false }
            guard let folder = await chooseFolder() else { return }
            do {
                let id = try await service.addProject(folder: folder)
                if snapshot.panelTab != .new { pickedProjectID = id }
                explicitQuickSession = false
                projectID = id
                state.apply(.selectPanelTab(.new))
                newFocus = UUID()
            } catch {
                folderError = error.localizedDescription
                state.apply(.selectPanelTab(.new))
            }
        }
    }

    private var newContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            connectionNotice
            if let folderError { feedback(folderError) }
            launchOptions
        }
        .disabled(launching)
        .onChange(of: projectID) { launchInputChanged() }
        .onChange(of: providerID) { launchInputChanged() }
        .onChange(of: modelID) { launchInputChanged() }
        .onChange(of: runtimeMode) { launchInputChanged() }
        .onChange(of: newPrompt) { launchInputChanged() }
    }

    private var noProvidersMessage: String {
        projectID.isEmpty ? "No providers are available." : "No providers are available for this project."
    }

    /// Why the provider, model and runtime chips cannot be used yet, if they cannot.
    private var catalogState: (loading: Bool, message: String?) {
        guard let id = providerLoadProjectID else { return (false, nil) }
        if let catalogError { return (false, catalogError) }
        if catalogProjectID != id || providerLoad != nil { return (true, nil) }
        if providers.isEmpty { return (false, noProvidersMessage) }
        return (false, nil)
    }

    private func catalogNotice(_ message: String, projectID: String) -> some View {
        HStack {
            feedback(message)
            Button("Reload") { Task { await loadProviders(for: projectID) } }
                .buttonStyle(.bordered).clickableCursor()
        }
    }

    /// Project, provider, model and runtime as two rows of labelled dropdowns.
    private var launchOptions: some View {
        let catalog = catalogState
        let ready = providerLoadProjectID != nil && !catalog.loading && catalog.message == nil
        let placeholder = catalog.loading ? "Loading…" : "Unavailable"
        let projectName = projectChoices.first { $0.id == projectID }?.name ?? "Quick session"
        return VStack(alignment: .leading, spacing: 8) {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    PickerChip(icon: "folder", title: "Project", value: projectName) {
                        Picker("Project", selection: Binding(get: { projectID }, set: { id in
                            // Not a project: show the folder picker and keep the current selection until it resolves.
                            if id == Self.openFolderTag {
                                // Let the menu finish dismissing first; a modal picker started inside menu tracking ignores clicks.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { openFolder() }
                                return
                            }
                            folderError = nil
                            projectID = id
                            explicitQuickSession = id.isEmpty
                        })) {
                            Text("Open folder…").tag(Self.openFolderTag)
                            Divider()
                            Text("Quick session (no project)").tag("")
                            if !projectChoices.isEmpty { Divider() }
                            ForEach(projectChoices) { Text($0.name).tag($0.id) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    PickerChip(icon: "cpu", title: "Provider", value: ready ? provider?.name ?? "Choose" : placeholder,
                               loading: catalog.loading) {
                        Picker("Provider", selection: Binding(get: { providerID }, set: { id in
                            providerID = id
                            modelID = defaultModelID
                            selectRuntimeMode(runtimeMode)
                        })) {
                            ForEach(providers) { Text($0.name).tag($0.id) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    .disabled(!ready)
                }
                GridRow {
                    PickerChip(icon: "sparkles", title: "Model",
                               value: ready ? provider?.models.first { $0.id == modelID }?.name ?? "Choose" : placeholder,
                               loading: catalog.loading) {
                        Picker("Model", selection: $modelID) {
                            ForEach(provider?.models ?? []) { Text($0.name).tag($0.id) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    .disabled(!ready)
                    PickerChip(icon: "shield.lefthalf.filled", title: "Runtime",
                               value: ready ? runtimeMode.label : placeholder, loading: catalog.loading) {
                        Picker("Runtime mode", selection: $runtimeMode) {
                            ForEach(provider?.runtimeModes ?? [.approvalRequired], id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    .disabled(!ready)
                }
            }
            HStack(spacing: 8) {
                if ready, let hint = UsageHint.make(from: provider?.usage?.windows ?? []) {
                    UsageHintChip(hint: hint)
                }
                Spacer(minLength: 4)
                PanelPillButton(title: "Provider settings", icon: "plus", style: .quiet) {
                    showHotkeyRecorder()
                    // After the window exists, switch it to Providers (it may be open on another page).
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .showSettingsSection, object: "Providers")
                    }
                }
            }
            if let message = catalog.message, let id = providerLoadProjectID {
                catalogNotice(message, projectID: id)
            }
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            #if DEBUG
            Picker("Backend", selection: Binding(get: { backendMode }, set: { chooseBackend($0) })) {
                Text("Live").tag("Live")
                Text("Fake").tag("Fake")
            }
            .pickerStyle(.segmented)
            #endif
            HStack {
                Text("Settings")
                Spacer()
                Button("Open Settings…", action: showHotkeyRecorder)
            }
            Toggle("Start with panel expanded", isOn: $launchExpanded)
            Button {
                setLaunchAtLogin(!launchesAtLogin)
            } label: {
                Label("Launch at login", systemImage: launchesAtLogin ? "checkmark.square" : "square")
            }
            .buttonStyle(.plain).clickableCursor()
            .accessibilityValue(launchesAtLogin ? "On" : "Off")
            if SMAppService.mainApp.status == .requiresApproval {
                Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
            }
            if let actionError { feedback(actionError) }
        }
    }

    @ViewBuilder
    private var connectionNotice: some View {
        switch snapshot.connection {
        case .engineStarting:
            connectionCard("Engine starting…") { EmptyView() }
        case .engineRestarting:
            connectionCard("Engine restarting…") { EmptyView() }
        case .engineFailed(let message):
            connectionCard("Engine failed to start", detail: message) {
                retryConnectionButton
                Button("Show logs", action: showEngineLogs).buttonStyle(.bordered).clickableCursor()
            }
        case .disconnected:
            connectionCard("Connecting to the engine…") { retryConnectionButton }
        case .failed(let message):
            connectionCard(message) {
                retryConnectionButton
                Button("Show logs", action: showEngineLogs).buttonStyle(.bordered).clickableCursor()
            }
        case .connected: EmptyView()
        }
    }

    private var retryConnectionButton: some View {
        Button("Retry", action: retryConnection)
            .buttonStyle(.bordered).clickableCursor()
    }

    private func connectionCard<Actions: View>(
        _ message: String, detail: String? = nil, @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(Product.displayText(detail)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack { actions() }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func feedback(_ message: String) -> some View {
        Text(message).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
    }

    private func sessionStatus(_ session: SessionSummary) -> some View {
        let status = sessionStatusText(session)
        let dot: Color = status.warning ? T3.warning : session.status == .running ? .cyan
            : session.status == .failed ? T3.error : T3.faint
        return HStack(spacing: 5) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(status.text).foregroundStyle(status.warning ? T3.warning : T3.muted).lineLimit(1)
        }
    }

    private func editor(_ text: Binding<String>, placeholder: String, multiline: Bool, search: Bool = false,
                        submit: @escaping () -> Void) -> some View {
        FocusedEditor(text: text, placeholder: placeholder, multiline: multiline, searchStyle: search, submit: submit)
    }

    private var launchValidation: String? {
        guard connected else { return "Connect to the server to create a thread." }
        guard projectID.isEmpty || snapshot.projects.contains(where: { $0.id == projectID }) else { return "Choose a project." }
        if let catalogError { return catalogError }
        guard catalog != nil, catalogProjectID == projectID, providerLoad == nil else {
            return "Waiting for the provider catalog."
        }
        guard !providers.isEmpty else { return noProvidersMessage }
        guard let provider else { return "Choose a provider." }
        guard provider.models.contains(where: { $0.id == modelID }) else { return "Choose a model." }
        guard provider.runtimeModes.contains(runtimeMode) else { return "Choose a supported runtime mode." }
        guard !newPrompt.trimmed.isEmpty else { return "Enter a first prompt." }
        return nil
    }

    private func send(_ id: String) {
        let text = drafts[id, default: ""]
        guard session?.id == id, session?.isArchived == false, !text.trimmed.isEmpty else { return }
        perform { backend in
            try await backend.sendPrompt(sessionId: id, text: text)
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            if drafts[id] == text { drafts[id] = nil }
        }
    }

    private func launch() {
        guard !launching else { return }
        if let message = launchValidation {
            launchError = message
            return
        }
        guard let backend = backend() else {
            launchError = "The \(Product.name) engine connection is unavailable."
            return
        }
        let selection: ThreadModelSelection
        if let model = catalog?.defaultSelection, model.instanceId == providerID, model.model == modelID {
            selection = model
        } else {
            selection = .init(instanceId: providerID, model: modelID)
        }
        let request = ThreadLaunch(projectID: projectID.isEmpty ? nil : projectID, modelSelection: selection,
                                   runtimeMode: runtimeMode, prompt: newPrompt, ids: launchIDs)
        launchError = nil
        launching = true
        endEditing()
        Task {
            defer { launching = false }
            do {
                let id = try await backend.launchThread(request)
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                if newPrompt == request.prompt { newPrompt = "" }
                launchIDs = .init()
                guard self.backend() === backend else {
                    launchError = "Thread created. Reconnect to its backend to open it."
                    return
                }
                if snapshot.workspaceOpen, snapshot.panelTab == .new { state.apply(.openThread(id)) }
            } catch {
                launchError = error.localizedDescription
            }
        }
    }

    private func launchInputChanged() {
        launchIDs = .init()
        if !launching { launchError = nil }
    }

    private func mutate(_ id: String, _ mutation: ThreadMutation) {
        guard session?.id == id else { return }
        perform { backend in
            try await backend.mutateThread(sessionID: id, mutation: mutation)
            if snapshot.openThreadID == id { managing = nil }
        }
    }

    private func rename(_ id: String) {
        let title = titleDraft.trimmed
        if !title.isEmpty {
            mutate(id, .rename(title))
            endEditing()
        }
    }

    private func perform(_ action: @escaping @MainActor (any AgentBackend) async throws -> Void) {
        guard connected, !busy, let backend = backend() else { return }
        actionError = nil
        busy = true
        Task {
            defer { busy = false }
            do { try await action(backend) }
            catch { if self.backend() === backend { actionError = error.localizedDescription } }
        }
    }

    private func loadProviders(for project: String) async {
        guard providerLoadProjectID == project else { return }
        guard let backend = backend() else {
            catalogFailure = (project, "The \(Product.name) engine connection is unavailable.")
            return
        }
        let run = UUID()
        providerLoad = run
        catalogFailure = nil
        defer { if providerLoad == run { providerLoad = nil } }
        do {
            let updated = try await backend.providerCatalog(projectID: project.isEmpty ? nil : project)
            guard !Task.isCancelled, providerLoad == run, providerLoadProjectID == project, self.backend() === backend else { return }
            let newProject = catalogProjectID != project
            catalogProjectID = project
            catalog = updated
            if newProject || provider == nil { providerID = updated.defaultSelection?.instanceId ?? "" }
            if newProject || provider?.models.contains(where: { $0.id == modelID }) != true { modelID = defaultModelID }
            selectRuntimeMode(newProject ? updated.defaultRuntimeMode : runtimeMode)
        } catch {
            if !Task.isCancelled, providerLoad == run, providerLoadProjectID == project, self.backend() === backend {
                catalogFailure = (project, error.localizedDescription)
            }
        }
    }

    private var defaultModelID: String {
        if let model = catalog?.defaultSelection, model.instanceId == providerID { return model.model }
        return provider?.models.first?.id ?? ""
    }

    private func selectRuntimeMode(_ preferred: ThreadRuntimeMode) {
        let modes = provider?.runtimeModes ?? []
        runtimeMode = modes.contains(preferred) ? preferred : modes.first ?? .approvalRequired
    }

    private func resetControls() {
        endEditing()
        updateShortcuts()
        managing = nil
        actionError = nil
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        defer { launchesAtLogin = SMAppService.mainApp.status == .enabled }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            actionError = nil
        } catch { actionError = error.localizedDescription }
    }
    @ViewBuilder
    private func anywhereContent(_ status: AnywhereDictationController.Status) -> some View {
        let dictation = voice.anywhere
        Label("Dictation · \(status.mode.rawValue)", systemImage: "mic")
            .font(.system(size: 12, weight: .semibold))
        HStack(spacing: 6) {
            if status.phase == .cleaning || status.phase == .sending {
                Image(systemName: "arrow.trianglehead.clockwise.rotate.90")
                    .symbolEffect(.rotate, options: .repeating, isActive: !reduceMotion)
                    .accessibilityHidden(true)
            }
            if !status.message.isEmpty {
                Text(status.message)
                    .foregroundStyle(.secondary)
            }
        }
        if let progress = status.progress, status.phase == .preparing {
            ProgressView(value: progress)
        }
        if !status.text.isEmpty {
            Text(verbatim: status.text)
                .lineLimit(status.phase == .recording || status.phase == .finishing ? 4 : nil)
                .truncationMode(.head)
                .fixedSize(horizontal: false, vertical: true)
        }
        if status.phase == .review {
            Text("Sending shares your transcript, app name, window title, and the field text shown below with the thread’s AI provider.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let context = dictation.context {
                Divider()
                Text(verbatim: [context.appName, context.windowTitle].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                if let text = context.selectedText ?? context.nearbyText {
                    Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func anywhereControls(_ status: AnywhereDictationController.Status) -> some View {
        let dictation = voice.anywhere
        switch status.phase {
        case .review:
            HStack {
                if let destination = dictation.destination {
                    Picker("Send to", selection: Binding(
                        get: { dictation.newThread }, set: { dictation.chooseNewThread($0) }
                    )) {
                        Text(destination.title).tag(false)
                        Text("New thread").tag(true)
                    }
                    .labelsHidden()
                    .accessibilityLabel("Send to")
                    .help(dictation.newThread ? "Create a thread in the last active thread's project" : destination.title)
                } else if let project = dictation.newThreadProject {
                    Text("New thread in \(project.name)").lineLimit(1)
                } else {
                    Text(dictation.isConnected ? "No project available" : "Connect to the server").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: dictation.cancel)
                Button("Send to provider", action: dictation.send)
                    .buttonStyle(.borderedProminent).clickableCursor()
                    .disabled(!dictation.canSend)
            }
            .padding(.top, 4)
        case .result:
            HStack {
                Spacer()
                Button("Dismiss", action: dictation.cancel)
                Button("Insert result", action: dictation.insertResult)
                    .buttonStyle(.borderedProminent).clickableCursor()
            }
            .padding(.top, 4)
        case .notice where status.offersAccessibility:
            Button("Allow Accessibility…", action: FocusedDictationTarget.requestAccessibility)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func voiceContent(_ phase: VoiceCommandPhase) -> some View {
        switch phase {
        case .preparing(let message, let progress):
            Text(message).foregroundStyle(.secondary)
            if let progress {
                ProgressView(value: progress)
                    .accessibilityLabel(message)
            }
        case .listening(let text, let target):
            Label("Listening", systemImage: "mic.fill")
                .foregroundStyle(T3.error)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            voiceTranscript(text, target: target, placeholder: "Listening…")
        case .finishing(let text, let target):
            voiceTranscript(text, target: target, placeholder: "Finishing transcription…")
        case .reviewing(let draft):
            Button(action: voice.edit) {
                VStack(alignment: .leading, spacing: 5) {
                    voiceTranscript(draft.text, target: draft.target, placeholder: "", lines: 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain).clickableCursor()
            .help("Edit voice command")
            HStack {
                Button("Cancel", action: voice.cancel).controlSize(.small)
                Spacer()
                Button("Edit", action: voice.edit).controlSize(.small)
                Button("Send", action: voice.submit)
                    .buttonStyle(.borderedProminent).clickableCursor()
                    .controlSize(.small)
                    .help("Send with Return while the panel is hovered or focused")
            }
        case .editing(let draft):
            Label(draft.target.label, systemImage: "pencil")
                .foregroundStyle(.secondary)
        case .sending(let draft):
            Label("Sending to \(draft.target.label)…", systemImage: "paperplane")
                .foregroundStyle(.secondary)
        case .notice(let message):
            Text(message).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func voiceTranscript(
        _ text: String, target: VoiceTarget?, placeholder: String, lines: Int = 3
    ) -> some View {
        if let target {
            Label(target.label, systemImage: "arrow.turn.up.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        Text(text.isEmpty ? placeholder : text)
            .font(.system(size: 12))
            .foregroundStyle(text.isEmpty ? .secondary : .primary)
            .lineLimit(lines)
            .truncationMode(.head)
    }

}

/// "90% weekly left" beside a small meter: green from half, yellow from a fifth, red below that.
struct UsageHintChip: View {
    let hint: UsageHint

    private var fraction: Double { Double(min(100, max(0, hint.remainingPercent ?? 0))) / 100 }

    private var color: Color {
        if hint.level == .critical || fraction < 0.2 { return T3.error }
        if fraction < 0.5 { return T3.warning }
        return T3.success
    }

    var body: some View {
        HStack(spacing: 7) {
            Capsule()
                .fill(Color.white.opacity(0.10))
                .frame(width: 44, height: 5)
                .overlay(alignment: .leading) {
                    Capsule().fill(color).frame(width: max(5, 44 * fraction), height: 5)
                        .shadow(color: color.opacity(0.5), radius: 3)
                }
            Text(hint.text)
                .font(.system(size: T3.caption, weight: .medium)).monospacedDigit()
                .foregroundStyle(T3.muted)
        }
        .fixedSize()
        .help("Remaining subscription limit")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hint.text)
    }
}

private struct SessionRowView: View, Equatable {
    let session: SessionSummary
    let statusText: String
    let statusWarning: Bool
    var forceHover = false
    let enabled: Bool
    let open: () -> Void
    let match: Namespace.ID?
    let toggleResolve: () -> Void
    @State private var pointerInside = false
    private var hovering: Bool { pointerInside || forceHover }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.session == rhs.session && lhs.statusText == rhs.statusText && lhs.statusWarning == rhs.statusWarning
            && lhs.forceHover == rhs.forceHover && lhs.enabled == rhs.enabled && lhs.match == rhs.match
    }

    private var dotColor: Color {
        if statusWarning { return T3.warning }
        switch session.status {
        case .running: return .cyan
        case .failed: return T3.error
        case .completed: return T3.success
        default: return T3.faint
        }
    }


    private var subtitle: String {
        [ProviderBrand.label(instanceID: session.providerInstanceId), session.project, session.branch]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        // The row is one button; the resolve check replaces the status in the same slot, so nothing is reserved
        // for it while the pointer is elsewhere.
        ZStack(alignment: .trailing) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        ProviderBadge(driver: ProviderBrand.driver(instanceID: session.providerInstanceId), size: 24)
                            .notchMatch("provider-\(session.id)", in: match)
                            .accessibilityHidden(true)
                        Text(session.title).font(.system(size: T3.body, weight: .semibold)).lineLimit(1)
                            .foregroundStyle(session.isSettled ? T3.muted : T3.foreground)
                            .notchMatch("title-\(session.id)", in: match)
                        Spacer(minLength: 8)
                        HStack(spacing: 5) {
                            Circle().fill(dotColor).frame(width: 6, height: 6)
                            Text(statusText).font(.system(size: T3.caption, weight: .medium))
                                .foregroundStyle(statusWarning ? T3.warning : T3.muted)
                                .lineLimit(1)
                        }
                        .frame(height: 20)
                        .opacity(hovering ? 0 : 1)
                    }
                    Text(subtitle).font(.system(size: T3.caption + 0.5)).foregroundStyle(T3.faint).lineLimit(1)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).clickableCursor()

            HStack(spacing: 6) {
                PanelIconButton(icon: session.isSettled ? "arrow.uturn.backward" : "checkmark", size: 26,
                                tint: session.isSettled ? nil : T3.success,
                                help: session.isSettled ? "Reopen" : "Resolve", action: toggleResolve)
                    .disabled(!enabled || !hovering)
                    .accessibilityLabel(session.isSettled ? "Reopen \(session.title)" : "Resolve \(session.title)")
            }
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .padding(.trailing, 10)
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .background {
            RoundedRectangle(cornerRadius: 10).fill(hovering ? T3.fillHover : T3.fill)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hovering ? T3.borderStrong : T3.border, lineWidth: 1))
                .notchMatch("session-\(session.id)", in: match)
        }
        .onHover { pointerInside = $0 }
        .accessibilityElement(children: .contain)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

private struct NotchContentAppearance: ViewModifier {
    let visible: Bool

    func body(content: Content) -> some View {
        content.blur(radius: visible ? 0 : 4).opacity(visible ? 1 : 0)
    }
}

private extension View {
    @ViewBuilder
    func notchMatch(_ key: String?, in namespace: Namespace.ID?, enabled: Bool = true) -> some View {
        if enabled, let key, let namespace { matchedGeometryEffect(id: key, in: namespace) }
        else { self }
    }
}

private struct HoverSessionRow: View {
    let session: SessionSummary
    let preview: String?
    let request: ApprovalRequest?
    let needsReview: Bool
    let needsInput: Bool
    let connected: Bool
    let reduceMotion: Bool
    let rowHeight: CGFloat
    let icon: AnyView
    let open: () -> Void
    let respond: (ApprovalRequest, ApprovalDecision) -> Void
    let reply: () -> Void
    let resolve: () -> Void
    @State private var hovering = false

    init(session: SessionSummary, preview: String?, request: ApprovalRequest?, needsReview: Bool, needsInput: Bool, connected: Bool,
         reduceMotion: Bool, rowHeight: CGFloat, icon: some View, open: @escaping () -> Void,
         respond: @escaping (ApprovalRequest, ApprovalDecision) -> Void, reply: @escaping () -> Void,
         resolve: @escaping () -> Void) {
        self.session = session; self.preview = preview; self.request = request; self.needsReview = needsReview
        self.needsInput = needsInput
        self.connected = connected; self.reduceMotion = reduceMotion; self.rowHeight = rowHeight
        self.icon = AnyView(icon); self.open = open; self.respond = respond; self.reply = reply; self.resolve = resolve
    }

    private var dot: (color: Color, label: String, running: Bool)? {
        if request != nil || needsReview { return (T3.warning, "Needs approval", false) }
        if needsInput { return (T3.warning, "Needs input", false) }
        if session.hasRecentFailure() {
            return (T3.error, session.error ?? "The latest turn failed", false)
        }
        if session.status == .running { return (.cyan, "Running", true) }
        return nil
    }

    private var timeText: String {
        guard let date = session.updatedAt ?? session.lastActivity else { return "" }
        let seconds = Int(Date.now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: open) {
                    HStack(spacing: 8) {
                        icon.scaleEffect(0.75).frame(width: 20, height: 20)
                        Text(verbatim: session.title)
                            .font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        if !hovering {
                            dotView
                            Text(timeText).font(.system(size: 11)).foregroundStyle(T3.faint).monospacedDigit()
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).clickableCursor()
                if hovering { actions }
            }
            .frame(height: rowHeight)
            if let preview {
                Text(verbatim: preview)
                    .font(.system(size: 11)).foregroundStyle(T3.muted).lineLimit(1)
                    .padding(.leading, 28).padding(.trailing, 8).frame(height: 20, alignment: .top)
            }
        }
        .padding(.horizontal, 8)
        .background(hovering ? Color.white.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }

    @ViewBuilder private var dotView: some View {
        if let dot {
            Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(dot.color)
                .symbolEffect(.pulse, options: .repeating, isActive: dot.running && !reduceMotion)
                .help(dot.label).accessibilityLabel(dot.label)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            if let request {
                if request.canApprove {
                    Button("Approve") { respond(request, .accepted) }.buttonStyle(.borderedProminent).clickableCursor()
                }
                Button("Deny") { respond(request, .declined) }
            } else if needsReview {
                Button("Review", action: open)
            } else if needsInput {
                Button("Answer", action: open).buttonStyle(.borderedProminent).clickableCursor()
            }
            if !session.isArchived { Button("Reply", action: reply) }
            Button(action: resolve) { Image(systemName: "checkmark") }
                .disabled(!connected || session.isSettled)
                .help("Resolve").accessibilityLabel("Resolve")
        }
        .controlSize(.small)
        .fixedSize()
    }
}
