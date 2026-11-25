import AppKit
import NotchpilotCore
import Observation
import SwiftUI

/// One-click resolve; only failures raise a toast. Shared by the session rows, the thread header and ⌘⇧D.
@MainActor
@Observable
final class ResolveCoordinator {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let sessionID: String?
        let message: String
        let undoable: Bool
        let isError: Bool
    }

    private(set) var toast: Toast?
    @ObservationIgnored var backend: () -> (any AgentBackend)? = { nil }
    @ObservationIgnored private let state: AppState
    @ObservationIgnored private var dismissal: Task<Void, Never>?

    init(state: AppState) { self.state = state }

    private var connected: Bool { state.panelSnapshot.connection == .connected }

    func resolve(_ session: SessionSummary) {
        change(session, resolved: true)
    }

    func reopen(_ session: SessionSummary) {
        change(session, resolved: false)
    }

    /// ⌘⇧D: resolves the thread that is open in the panel.
    @discardableResult
    func resolveCurrentThread() -> Bool {
        let snapshot = state.panelSnapshot
        guard snapshot.panelTab == .thread, let id = snapshot.openThreadID,
              let session = snapshot.sessions.first(where: { $0.id == id }), !session.isSettled else { return false }
        resolve(session)
        return true
    }

    func undo() {
        guard let toast, toast.undoable, let id = toast.sessionID,
              let session = state.panelSnapshot.sessions.first(where: { $0.id == id }) else { return }
        change(session, resolved: false)
        show(.init(sessionID: nil, message: "Reopened", undoable: false, isError: false))
    }

    func dismiss() {
        dismissal?.cancel()
        toast = nil
    }

    private func change(_ session: SessionSummary, resolved: Bool) {
        guard connected, let backend = backend() else {
            show(.init(sessionID: nil, message: "Not connected", undoable: false, isError: true))
            return
        }
        let id = session.id
        state.apply(.sessionSettleChanged(sessionId: id, resolved: resolved))
        if resolved { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        if resolved, state.panelSnapshot.openThreadID == id, state.panelSnapshot.panelTab == .thread {
            state.apply(.selectPanelTab(.sessions))
        }
        // Success is silent: the row disappearing is the confirmation, and there is no undo.
        dismiss()
        Task {
            do {
                try await backend.mutateThread(sessionID: id, mutation: .resolve(resolved))
                if self.backend() === backend { state.apply(.sessionSettleFinished(sessionId: id, succeeded: true)) }
            } catch {
                if self.backend() === backend {
                    state.apply(.sessionSettleFinished(sessionId: id, succeeded: false))
                    show(.init(sessionID: nil, message: "Couldn’t \(resolved ? "resolve" : "reopen"): \(error.localizedDescription)",
                               undoable: false, isError: true))
                }
            }
        }
    }

    private func show(_ toast: Toast) {
        dismissal?.cancel()
        self.toast = toast
        let id = toast.id
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(toast.undoable ? 6 : 3.5))
            guard !Task.isCancelled, self?.toast?.id == id else { return }
            withAnimation(.snappy(duration: 0.2)) { self?.toast = nil }
        }
    }
}

struct ResolveToastView: View {
    let toast: ResolveCoordinator.Toast
    let undo: () -> Void
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(toast.isError ? T3.error : T3.success)
                .symbolEffect(.drawOn, options: .nonRepeating, isActive: !reduceMotion && !toast.isError)
            Text(verbatim: toast.message).lineLimit(2).font(.system(size: T3.small, weight: .medium))
            if toast.undoable {
                Button("Undo", action: undo)
                    .buttonStyle(.plain).clickableCursor()
                    .font(.system(size: T3.small, weight: .semibold))
                    .foregroundStyle(T3.link)
                    .padding(.horizontal, 7).frame(height: 22)
                    .hoverPlate(radius: 6)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(T3.muted)
                    .frame(width: 18, height: 18).hoverPlate(radius: 5)
            }
            .buttonStyle(.plain).clickableCursor()
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color(white: 0.13), in: Capsule())
        .overlay(Capsule().strokeBorder(T3.borderStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
        .foregroundStyle(T3.foreground)
    }
}
