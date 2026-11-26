import AppKit
import NotchpilotCore
import Testing
@testable import Notchpilot

struct NotchLayoutTests {
    @Test func idleNotchIsExactlyTheHardwareNotch() {
        let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let visible = CGRect(x: 0, y: 0, width: 1470, height: 924)
        let layout = NotchLayout(frame: screen, visibleFrame: visible, notchInset: 32,
                                 leftAuxiliary: CGRect(x: 0, y: 924, width: 646, height: 32),
                                 rightAuxiliary: CGRect(x: 825, y: 924, width: 645, height: 32))
        let idle = layout.shape(for: .collapsed)
        #expect(layout.panelFrame.maxY == screen.maxY)
        #expect(idle.width == layout.notchWidth && idle.height == layout.notchHeight)
        #expect(layout.idleSize == CGSize(width: 179, height: 32))
        #expect(layout.panelFrame.maxY - idle.height == visible.maxY)
        // The camera housing itself is the hover target, and nothing outside it is.
        #expect(contains(CGPoint(x: layout.centerX, y: visible.maxY + 5), layout: layout, shape: idle))
        #expect(contains(CGPoint(x: 660, y: visible.maxY + 5), layout: layout, shape: idle))
        #expect(!contains(CGPoint(x: 640, y: visible.maxY + 5), layout: layout, shape: idle))
        #expect(!contains(CGPoint(x: 830, y: visible.maxY + 5), layout: layout, shape: idle))
        #expect(!contains(CGPoint(x: layout.centerX, y: visible.maxY - 1), layout: layout, shape: idle))
    }

    @Test func activityAddsSmallWingsBesideTheNotch() {
        let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let visible = CGRect(x: 0, y: 0, width: 1470, height: 924)
        let layout = NotchLayout(frame: screen, visibleFrame: visible, notchInset: 32,
                                 leftAuxiliary: CGRect(x: 0, y: 924, width: 646, height: 32),
                                 rightAuxiliary: CGRect(x: 825, y: 924, width: 645, height: 32))
        let idle = layout.shape(for: .collapsed)
        let active = layout.shape(for: .collapsed, activity: true)
        #expect(active.height == idle.height)
        #expect(active.width == idle.width + 2 * NotchLayout.statusWingWidth)
        #expect(contains(CGPoint(x: 640, y: visible.maxY + 5), layout: layout, shape: active))
        #expect(contains(CGPoint(x: 830, y: visible.maxY + 5), layout: layout, shape: active))
        #expect(contains(CGPoint(x: layout.centerX, y: visible.maxY + 5), layout: layout, shape: active))
        #expect(!contains(CGPoint(x: layout.centerX - active.width / 2 - 2, y: visible.maxY + 5),
                          layout: layout, shape: active))
        #expect(active.width < layout.shape(for: .peek).width)
    }

    @Test(arguments: [
        CGSize(width: 1512, height: 982),
        CGSize(width: 1728, height: 1117),
        CGSize(width: 1280, height: 720)
    ])
    func containsAllLayersOnALargestStatePanel(screenSize: CGSize) {
        let screen = CGRect(origin: .zero, size: screenSize)
        let inset: CGFloat = screen.width == 1280 ? 0 : 37
        let menuBar: CGFloat = inset == 0 ? 24 : inset
        let visible = CGRect(x: 0, y: 0, width: screen.width, height: screen.height - menuBar)
        let layout = NotchLayout(frame: screen, visibleFrame: visible, notchInset: inset,
                                 leftAuxiliary: nil, rightAuxiliary: nil)
        let frame = layout.panelFrame
        let peek = layout.shape(for: .peek)
        let hover = layout.shape(for: .hover)
        let workspace = layout.shape(for: .workspace)
        #expect(screen.contains(frame))
        #expect(frame.midX == screen.midX)
        #expect(frame.maxY - layout.notchHeight <= visible.maxY)
        #expect(workspace.height == inset + layout.maxContentHeight)
        #expect(workspace.height < frame.height)
        #expect(workspace.width < frame.width)
        #expect(inset > 0 ? peek.topEar > 0 : peek.topEar == 0 && peek.topRadius > 0)

        let top = CGPoint(x: frame.midX, y: frame.maxY - 5)
        let belowHover = CGPoint(x: frame.midX, y: frame.maxY - hover.height - 2)
        let outsidePeek = CGPoint(x: frame.midX + peek.width / 2 + 2, y: frame.maxY - inset - 10)
        #expect(contains(top, layout: layout, shape: workspace))
        #expect(!contains(belowHover, layout: layout, shape: hover))
        #expect(contains(belowHover, layout: layout, shape: workspace))
        #expect(!contains(outsidePeek, layout: layout, shape: peek))
        #expect(contains(outsidePeek, layout: layout, shape: workspace))
    }

    private func contains(_ point: CGPoint, layout: NotchLayout, shape: NotchShape) -> Bool {
        let frame = layout.panelFrame
        let path = shape.path(in: CGRect(origin: .zero, size: frame.size)).cgPath
        return layout.containsPointer(point, in: frame, path: path)
    }
}

@MainActor
struct NotchPresentationTests {
    @Test func approvalsOutrankRunningAndRecentlyActiveSessions() {
        let running = SessionSummary(id: "running", title: "Running", providerInstanceId: "codex", status: .running)
        var recent = SessionSummary(id: "recent", title: "Recent", providerInstanceId: "codex", status: .idle)
        recent.lastActivity = .now
        let approval = SessionSummary(id: "approval", title: "Approval", providerInstanceId: "claudeAgent", status: .idle)
        let state = AppState()
        state.apply(.sessionsResynced([recent, running]))
        #expect(NotchPresentation.relevantSession(in: state.panelSnapshot)?.id == running.id)
        state.apply(.sessionUpdated(approval))
        state.apply(.approvalRequested(.init(id: "permission", threadId: approval.id, sessionName: approval.title,
                                             toolName: "Shell", command: "swift test")))
        #expect(NotchPresentation.relevantSession(in: state.panelSnapshot)?.id == approval.id)
    }

    @Test func hoverListOrdersApprovalsThenRunningThenRecentAndCapsAtFour() {
        func make(_ id: String, _ status: SessionSummary.Status, age: TimeInterval) -> SessionSummary {
            var session = SessionSummary(id: id, title: id, providerInstanceId: "codex", status: status)
            session.updatedAt = Date.now.addingTimeInterval(-age)
            return session
        }
        var settled = make("settled", .idle, age: 1)
        settled.isSettled = true
        let state = AppState()
        state.apply(.sessionsResynced([make("old", .idle, age: 900), make("new", .idle, age: 10), settled,
                                       make("run", .running, age: 500), make("ask", .idle, age: 800),
                                       make("extra", .idle, age: 2_000)]))
        state.apply(.approvalRequested(.init(id: "p", threadId: "ask", sessionName: "ask", toolName: "Shell", command: "ls")))
        #expect(NotchPresentation.relevantSessions(in: state.panelSnapshot).map(\.id) == ["ask", "run", "new", "old"])
    }

    @Test func wingsReportApprovalsThenRunningThenAFinishedCheck() {
        let state = AppState()
        #expect(NotchPresentation.activity(in: state.panelSnapshot, finishedRecently: false) == nil)
        #expect(NotchPresentation.activity(in: state.panelSnapshot, finishedRecently: true) == .done)
        let one = SessionSummary(id: "one", title: "One", providerInstanceId: "codex", status: .running)
        let two = SessionSummary(id: "two", title: "Two", providerInstanceId: "codex", status: .running)
        state.apply(.sessionsResynced([one, two]))
        #expect(NotchPresentation.activity(in: state.panelSnapshot, finishedRecently: true) == .running(2))
        state.apply(.approvalRequested(.init(id: "p", threadId: "one", sessionName: "One", toolName: "Shell", command: "ls")))
        #expect(NotchPresentation.activity(in: state.panelSnapshot, finishedRecently: true) == .attention)
    }

    @Test func aPendingQuestionWaitsLikeAnApprovalAndRanksFirst() {
        let state = AppState()
        let ask = SessionSummary(id: "ask", title: "Ask", providerInstanceId: "claude", status: .running)
        let busy = SessionSummary(id: "busy", title: "Busy", providerInstanceId: "codex", status: .running)
        state.apply(.sessionsResynced([busy, ask]))
        state.apply(.userInputRequested(.init(id: "q", threadId: "ask", sessionName: "Ask", questions: [
            .init(id: "a", header: "H", question: "Which?", options: [.init(label: "One")])])))
        #expect(state.panelSnapshot.uiState == .needsInput)
        #expect(NotchPresentation.activity(in: state.panelSnapshot, finishedRecently: false) == .attention)
        #expect(NotchPresentation.relevantSession(in: state.panelSnapshot)?.id == "ask")
        #expect(NotchPresentation.panelStatus(in: state.panelSnapshot).text == "1 waiting · 1 running")
        state.apply(.userInputWithdrawn(requestId: "q"))
        #expect(state.panelSnapshot.uiState == .running)
    }

    @Test func headerStatusSummarisesTheConnectionAndSessions() {
        let state = AppState()
        state.apply(.connectionChanged(.disconnected))
        #expect(NotchPresentation.panelStatus(in: state.panelSnapshot).text == "Offline")
        state.apply(.connectionChanged(.connected))
        #expect(NotchPresentation.panelStatus(in: state.panelSnapshot).text == "Idle")
        let one = SessionSummary(id: "one", title: "One", providerInstanceId: "codex", status: .running)
        let two = SessionSummary(id: "two", title: "Two", providerInstanceId: "codex", status: .running)
        state.apply(.sessionsResynced([one]))
        #expect(NotchPresentation.panelStatus(in: state.panelSnapshot) == PanelStatus(text: "1 running", tone: .running))
        state.apply(.approvalRequested(.init(id: "p", threadId: "one", sessionName: "One", toolName: "Shell", command: "ls")))
        #expect(NotchPresentation.panelStatus(in: state.panelSnapshot) == PanelStatus(text: "1 waiting", tone: .waiting))
        state.apply(.sessionUpdated(two))
        #expect(NotchPresentation.panelStatus(in: state.panelSnapshot).text == "1 waiting · 1 running")
    }

    @Test func approvalBurstsCoalesceRepeatedNoticesForOneThread() {
        let model = NotchPresentation()
        let state = AppState()
        defer { model.clearNotices() }
        let session = SessionSummary(id: "a", title: "Build", providerInstanceId: "claudeAgent", status: .running)
        state.apply(.sessionUpdated(session))
        func request(_ id: String) {
            let previous = state.panelSnapshot
            let event = AppEvent.approvalRequested(.init(id: id, threadId: session.id, sessionName: session.title,
                                                        toolName: "Shell", command: "swift test"))
            state.apply(event)
            model.receive(event, previous: previous, current: state.panelSnapshot)
        }
        request("one")
        request("one")
        #expect(model.notice?.count == 1)
        request("two")
        #expect(model.notice?.count == 2)
        #expect(model.notice?.sessionID == session.id)
        #expect(model.notice?.kind == .approval)
    }
}
