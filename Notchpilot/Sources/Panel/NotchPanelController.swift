import NotchpilotCore
import AppKit
import CoreGraphics
import SwiftUI

final class NotchPanel: NSPanel {
    private weak var editor: PanelTextView?
    var didBeginEditing: () -> Void = {}
    var didEndEditing: () -> Void = {}
    weak var secureEditor: NSSecureTextField?
    /// Set once the pointer selects text in a reply, so the selection draws active and ⌘C reaches it.
    private var selectingText = false
    override var canBecomeKey: Bool { editor != nil || secureEditor != nil || selectingText }
    override var canBecomeMain: Bool { false }

    /// The panel never activates the app, so the main menu's Edit items do not receive key equivalents.
    /// Route the standard editing shortcuts straight to the focused field.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
           let key = event.charactersIgnoringModifiers?.lowercased() {
            let shift = flags.contains(.shift)
            let action: Selector? = switch (key, shift) {
            case ("x", false): #selector(NSText.cut(_:))
            case ("c", false): #selector(NSText.copy(_:))
            case ("v", false): #selector(NSText.paste(_:))
            case ("v", true): #selector(NSTextView.pasteAsPlainText(_:))
            case ("a", false): #selector(NSText.selectAll(_:))
            case ("z", false): Selector(("undo:"))
            case ("z", true): Selector(("redo:"))
            default: nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    func beginEditing(_ editor: PanelTextView) {
        self.editor = editor
        // AppKit is still installing the first responder during becomeFirstResponder.
        DispatchQueue.main.async { [weak self, weak editor] in
            guard let self, let editor, self.editor === editor, firstResponder === editor else { return }
            makeKey()
            if isKeyWindow { didBeginEditing() }
        }
    }

    func editorResigned(_ editor: PanelTextView) {
        guard self.editor === editor else { return }
        self.editor = nil
        DispatchQueue.main.async { [weak self] in
            if let self, self.editor == nil, !selectingText, isKeyWindow { resignKey() }
        }
    }

    func endEditing() {
        if editor != nil || secureEditor != nil { makeFirstResponder(nil) }
        if isKeyWindow { resignKey() }
    }

    override func resignKey() {
        selectingText = false
        super.resignKey()
        if editor != nil || secureEditor != nil { makeFirstResponder(nil) }
        didEndEditing()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown,
           let contentView, let editor {
            if contentView.hitTest(event.locationInWindow) !== editor { endEditing() }
        }
        // Selectable reply text is an NSTextField under SwiftUI. Take key status before it sees the click so the
        // click focuses it: the selection then draws active and ⌘C copies it. Clicks on buttons never take focus.
        if event.type == .leftMouseDown, secureEditor == nil,
           let field = contentView?.hitTest(event.locationInWindow) as? NSTextField,
           field.isSelectable, !field.isEditable {
            selectingText = true
            makeKey()
        }
        super.sendEvent(event)
    }

    // The menu bar and camera housing are outside the ordinary visible frame.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class NotchHostingView: NSHostingView<NotchView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotchPanelController {
    private let panel: NotchPanel
    private let appState: AppState
    private let voice: VoiceController
    var backend: (any AgentBackend)? {
        didSet { submitting.removeAll() }
    }
    private(set) lazy var resolver: ResolveCoordinator = {
        let coordinator = ResolveCoordinator(state: appState)
        coordinator.backend = { [weak self] in self?.backend }
        return coordinator
    }()
    private var choosingFolder = false
    /// A pop-up or pull-down menu from the notch is open. Its items can sit outside the notch silhouette.
    private var menuTracking = false
    /// After a menu closes the pointer is often below the notch; give it time to come back before collapsing.
    private var menuGraceUntil = Date.distantPast
    private var menuObservers: [NSObjectProtocol] = []
    private var layout: NotchLayout?
    private var displayUpdateQueued = false
    let presentation = NotchPresentation()
    private var visiblePath: CGPath?
    private var effect: NSVisualEffectView?
    private let effectMask = CAShapeLayer()
    private var pointerWasInside = false
    private var hoverSyncQueued = false
    private var exitTask: Task<Void, Never>?
    private var localMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalMouseMonitor: Any?
    private var hostGeneration = 0
    private var visibilityRequested = false
    private var submitting: Set<String> = []
    var showHotkeyRecorder: () -> Void = {}
    var chooseBackend: (String) -> Void = { _ in }
    var retryConnection: () -> Void = {}
    var showEngineLogs: () -> Void = {}
    private lazy var shortcuts = NotchShortcuts(
        currentScope: { [weak self] in self?.shortcutScope ?? .none },
        escape: { [weak self] in self?.escape() },
        approve: { [weak self] in
            // Approve only the request that has been on screen long enough to read. If a different request
            // moved to the front just before the keypress, ignore the key rather than approve it unseen.
            guard let self, let request = shortcutApproval, request.id == armedApproval?.id,
                  let since = armedApproval?.since, Date.now.timeIntervalSince(since) >= 0.6 else { return }
            respond(to: request, decision: .accepted)
        },
        sendVoice: { [weak self] in self?.voice.submit() },
        settings: { [weak self] in self?.showHotkeyRecorder() },
        resolve: { [weak self] in self?.resolver.resolveCurrentThread() }
    )

    init(appState: AppState, voice: VoiceController) {
        self.appState = appState
        self.voice = voice
        panel = NotchPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.didBeginEditing = { [weak self] in
            guard let self else { return }
            if !appState.panelSnapshot.workspaceOpen {
                appState.apply(.selectPanelTab(appState.panelSnapshot.panelTab))
            }
            updateShortcuts()
        }
        panel.didEndEditing = { [weak self] in
            self?.updateShortcuts()
            self?.queueDisplayUpdate()
        }
        voice.dictationActivityChanged = { [weak self] in self?.updateShortcuts() }
    }

    var isShown: Bool { visibilityRequested }

    func show() {
        guard !visibilityRequested else { return }
        visibilityRequested = true
        // A non-key or click-through window cannot reliably receive its own mouse-moved events.
        // The monitors track the pointer even while it crosses the transparent portion of the panel.
        let motion: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp, .rightMouseUp]
        let outsidePress: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: motion.union(outsidePress)) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if outsidePress.contains(NSEvent.EventTypeMask(rawValue: 1 << event.type.rawValue)) {
                    self.panel.endEditing()
                }
                self.updatePointer()
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: motion) { [weak self] event in
            self?.updatePointer()
            return event
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.panel.isKeyWindow else { return false }
                if event.keyCode == 53 {
                    self.escape()
                    return true
                }
                let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
                if event.keyCode == 2, modifiers == [.command, .shift], !event.isARepeat {
                    return self.resolver.resolveCurrentThread()
                }
                if (event.keyCode == 36 || event.keyCode == 76), !event.isARepeat, modifiers.isEmpty,
                   self.isReviewingVoice {
                    self.voice.submit()
                    return true
                }
                return false
            }
            return handled ? nil : event
        }
        let center = NotificationCenter.default
        menuObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuDidBeginTracking() }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuDidEndTracking() }
            },
        ]
        updateDisplay()
    }

    private func menuDidBeginTracking() {
        guard visibilityRequested, appState.panelSnapshot.isHovering else { return }
        menuTracking = true
        exitTask?.cancel()
        exitTask = nil
    }

    private func menuDidEndTracking() {
        guard menuTracking else { return }
        // The chosen item's action runs after tracking ends; let it update state before re-checking hover.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            menuTracking = false
            menuGraceUntil = Date.now.addingTimeInterval(1.2)
            pointerWasInside = pointerIsInside
            syncHover()
        }
    }

    func hide() {
        visibilityRequested = false
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        localKeyMonitor = nil
        globalMouseMonitor = nil
        localMouseMonitor = nil
        menuObservers.forEach(NotificationCenter.default.removeObserver)
        menuObservers = []
        menuTracking = false
        exitTask?.cancel()
        exitTask = nil
        pointerWasInside = false
        presentation.clearNotices()
        hostGeneration += 1
        collapse()
        shortcuts.setScope(.none)
        appState.apply(.hoverChanged(false))
        panel.orderOut(nil)
        panel.contentView = nil
        layout = nil
        effect = nil
        visiblePath = nil
    }

    func queueDisplayUpdate() {
        guard visibilityRequested, !displayUpdateQueued else { return }
        displayUpdateQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            displayUpdateQueued = false
            updateDisplay()
        }
    }

    private func updateDisplay() {
        guard visibilityRequested else { return }
        if panel.isKeyWindow { updatePointer(); return }
        let screens = NSScreen.screens
        guard let screen = frontmostWindowScreen(in: screens)
            ?? screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else {
            return
        }
        let newLayout = NotchLayout(screen: screen)
        if newLayout != layout {
            hostGeneration += 1
            let generation = hostGeneration
            layout = newLayout
            appState.apply(.hoverChanged(false))
            exitTask?.cancel()
            exitTask = nil
            pointerWasInside = false
            visiblePath = nil
            panel.ignoresMouseEvents = true
            panel.setFrame(newLayout.panelFrame, display: false)

            let view = NotchView(
                state: appState, layout: newLayout, voice: voice, presentation: presentation,
                present: { [weak self] path, glass in
                    guard let self, hostGeneration == generation else { return }
                    present(path, glass: glass)
                },
                updateShortcuts: { [weak self] in
                    guard let self, hostGeneration == generation else { return }
                    updateShortcuts()
                },
                respond: { [weak self] request, decision in self?.respond(to: request, decision: decision) },
                answerInput: { [weak self] request, answers in self?.answer(request, answers: answers) },
                dismissInput: { [weak self] request in self?.answer(request, answers: nil) },
                backend: { [weak self] in self?.backend },
                collapse: { [weak self] in self?.collapse() },
                endEditing: { [weak self] in self?.panel.endEditing() },
                chooseFolder: { [weak self] in await self?.chooseFolder() },
                chooseBackend: { [weak self] in self?.chooseBackend($0) },
                showHotkeyRecorder: { [weak self] in self?.showHotkeyRecorder() },
                retryConnection: { [weak self] in self?.retryConnection() },
                showEngineLogs: { [weak self] in self?.showEngineLogs() },
                resolver: resolver
            )
            let hostingView = NotchHostingView(rootView: view)
            hostingView.sizingOptions = []
            hostingView.safeAreaRegions = []
            hostingView.appearance = NSAppearance(named: .darkAqua)
            let container = NSView(frame: CGRect(origin: .zero, size: newLayout.panelFrame.size))
            let backdrop = NSVisualEffectView(frame: container.bounds)
            backdrop.blendingMode = .behindWindow
            backdrop.material = .hudWindow
            backdrop.state = .active
            backdrop.appearance = NSAppearance(named: .darkAqua)
            backdrop.wantsLayer = true
            backdrop.layer?.mask = effectMask
            backdrop.isHidden = true
            effect = backdrop
            container.addSubview(backdrop)
            hostingView.frame = container.bounds
            container.addSubview(hostingView)
            panel.contentView = container
        }

        if !panel.isVisible { panel.orderFrontRegardless() }
        updatePointer()
    }

    private func present(_ path: CGPath, glass: Bool) {
        visiblePath = path
        if let effect {
            if effect.isHidden != !glass { effect.isHidden = !glass }
            if glass {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                effectMask.frame = effect.bounds
                var transform = CGAffineTransform(translationX: 0, y: effect.bounds.height).scaledBy(x: 1, y: -1)
                effectMask.path = path.copy(using: &transform)
                CATransaction.commit()
            }
        }
        updatePointer()
    }

    private func frontmostWindowScreen(in screens: [NSScreen]) -> NSScreen? {
        if screens.count == 1 { return screens.first }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let primary = screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        // The list is front to back. The first normal window for this process is the
        // available proxy for another application's key window.
        for window in windows where window[kCGWindowOwnerPID as String] as? pid_t == pid {
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), !rect.isEmpty
            else { continue }
            let appFrame = CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
            var bestScreen: NSScreen?
            var bestArea: CGFloat = 0
            for screen in screens {
                let overlap = screen.frame.intersection(appFrame)
                let area = overlap.width * overlap.height
                if area > bestArea {
                    bestScreen = screen
                    bestArea = area
                }
            }
            if let bestScreen { return bestScreen }
        }
        return nil
    }

    private var pointerIsInside: Bool {
        guard panel.isVisible, let layout, let visiblePath else { return false }
        return layout.containsPointer(NSEvent.mouseLocation, in: panel.frame, path: visiblePath)
    }

    private var isReviewingVoice: Bool {
        if case .reviewing = appState.panelSnapshot.voiceCommand?.phase { return true }
        return false
    }

    private var shortcutScope: NotchShortcuts.Scope {
        guard visibilityRequested else { return .none }
        if voice.dictation.isActive || voice.anywhere.isShowing { return panel.isKeyWindow ? .none : .voice }
        if isReviewingVoice && pointerIsInside && !panel.isKeyWindow { return .voiceReview }
        if appState.panelSnapshot.voiceCommand?.phase.canCancelWithGlobalEscape == true { return .voice }
        guard pointerWasInside, !panel.isKeyWindow,
              !appState.panelSnapshot.hoverSuppressed || appState.panelSnapshot.workspaceOpen ||
                  presentation.notice != nil else { return .none }
        return shortcutApproval?.canApprove == true ? .approval : .panel
    }

    private func updatePointer() {
        guard visibilityRequested else { return }
        let inside = pointerIsInside
        // Keep a mouse-down sequence intact, including pull-downs that leave the original silhouette.
        let dragging = NSEvent.pressedMouseButtons != 0
        let ignoresMouse = !inside && (!dragging || panel.ignoresMouseEvents)
        if panel.ignoresMouseEvents != ignoresMouse { panel.ignoresMouseEvents = ignoresMouse }
        guard inside != pointerWasInside else { return }
        pointerWasInside = inside
        // Presentation samples can arrive during a SwiftUI render. Defer observable state changes.
        guard !hoverSyncQueued else { return }
        hoverSyncQueued = true
        DispatchQueue.main.async { [weak self] in self?.syncHover() }
    }

    private func syncHover() {
        hoverSyncQueued = false
        guard visibilityRequested, !menuTracking else { return }
        exitTask?.cancel()
        exitTask = nil
        if pointerWasInside {
            if !appState.panelSnapshot.isHovering { appState.apply(.hoverChanged(true)) }
        } else if appState.panelSnapshot.isHovering {
            let delay = max(0.28, menuGraceUntil.timeIntervalSinceNow)
            exitTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, !pointerWasInside, !choosingFolder, !menuTracking else { return }
                appState.apply(.hoverChanged(false))
                let state = appState.panelSnapshot
                if state.workspaceOpen, state.voiceCommand == nil, state.voiceMode == nil,
                   !voice.dictation.isActive, !voice.anywhere.isShowing {
                    collapse()
                }
                exitTask = nil
            }
        }
        updateShortcuts()
    }

    /// The approval the ⌘↵ shortcut targets, and when it became the target.
    private var armedApproval: (id: String, since: Date)?

    private func updateShortcuts() {
        let target = shortcutApproval?.id
        if target != armedApproval?.id { armedApproval = target.map { ($0, Date.now) } }
        shortcuts.setScope(shortcutScope)
    }

    private var shortcutApproval: ApprovalRequest? {
        let state = appState.panelSnapshot
        switch state.panelTab {
        case .sessions:
            if state.workspaceOpen { return state.pendingApprovals.first }
            if let notice = presentation.notice {
                guard notice.kind == .approval else { return nil }
                return state.pendingApprovals.first { $0.threadId == notice.sessionID }
            }
            let id = NotchPresentation.relevantSession(in: state)?.id
            return state.pendingApprovals.first { $0.threadId == id }
        case .thread: return state.pendingApprovals.first { $0.threadId == state.openThreadID }
        case .new, .settings: return nil
        }
    }

    private func escape() {
        if voice.anywhere.isShowing {
            voice.anywhere.cancel()
        } else if voice.dictation.isActive {
            voice.stopDictation()
        } else if panel.isKeyWindow || pointerIsInside {
            collapse()
        } else if appState.panelSnapshot.voiceCommand?.phase.canCancelWithGlobalEscape == true {
            voice.cancel()
        }
    }

    /// Shows a non-modal folder picker in front of everything. The notch is a non-activating status-bar panel in a
    /// UI-element app, so a modal picker run from it can sit behind the notch or never receive clicks. Instead the
    /// notch drops below normal windows, the app activates, and the picker is ordered front and made key.
    private func chooseFolder() async -> URL? {
        guard !choosingFolder else { return nil }
        choosingFolder = true
        exitTask?.cancel()
        exitTask = nil
        panel.endEditing()
        let previousApp = NSWorkspace.shared.frontmostApplication
        let notchLevel = panel.level
        panel.level = .normal
        let picker = NSOpenPanel()
        picker.title = "Open folder"
        picker.message = "Choose a folder to start a session in."
        picker.prompt = "Open"
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.canCreateDirectories = true
        picker.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        let response = await withCheckedContinuation { (done: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            picker.begin { done.resume(returning: $0) }
            picker.orderFrontRegardless()
            picker.makeKey()
        }
        panel.level = notchLevel
        if NSApp.isActive, let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp.activate()
        }
        choosingFolder = false
        if !pointerIsInside, appState.panelSnapshot.isHovering {
            appState.apply(.hoverChanged(false))
        }
        return response == .OK ? picker.url : nil
    }

    private func collapse() {
        panel.endEditing()
        voice.cancel()
        presentation.clearNotices()
        appState.apply(.collapsePanel)
        updateShortcuts()
    }

    private func answer(_ request: UserInputRequest, answers: [String: UserInputAnswer]?) {
        guard let backend, appState.panelSnapshot.connection == .connected,
              appState.panelSnapshot.pendingUserInputs.contains(request),
              submitting.insert(request.id).inserted else { return }
        Task {
            defer {
                if self.backend === backend { submitting.remove(request.id) }
            }
            do {
                if let answers {
                    try await backend.answerUserInput(requestId: request.id, threadId: request.threadId, answers: answers)
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                } else {
                    try await backend.dismissUserInput(requestId: request.id, threadId: request.threadId)
                }
            } catch {
                if self.backend === backend, appState.panelSnapshot.pendingUserInputs.contains(where: { $0.id == request.id }) {
                    appState.apply(.userInputResponseFailed(error.localizedDescription))
                    NSSound.beep()
                }
            }
        }
    }

    private func respond(to request: ApprovalRequest, decision: ApprovalDecision) {
        guard let backend, appState.panelSnapshot.connection == .connected,
              appState.panelSnapshot.pendingApprovals.contains(where: {
                  $0 == request && (decision != .accepted || $0.canApprove)
              }),
              submitting.insert(request.id).inserted else { return }
        Task {
            defer {
                if self.backend === backend { submitting.remove(request.id) }
            }
            do {
                switch decision {
                case .accepted:
                    try await backend.approve(requestId: request.id, threadId: request.threadId)
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                case .declined: try await backend.deny(requestId: request.id, threadId: request.threadId)
                }
            } catch {
                if self.backend === backend,
                   appState.panelSnapshot.pendingApprovals.contains(where: { $0.id == request.id }) {
                    appState.apply(.approvalResponseFailed(error.localizedDescription))
                    NSSound.beep()
                }
            }
        }
    }
}
