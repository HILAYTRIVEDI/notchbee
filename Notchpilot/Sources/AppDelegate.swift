import AppKit
import KeyboardShortcuts
import SwiftUI
import NotchpilotCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let appState = AppState()
    private enum Mode: String {
        #if DEBUG
        case fake = "Fake"
        #endif
        case live = "Live"
    }

    private var mode: Mode?
    private var backend: (any AgentBackend)?
    private lazy var notchController = NotchPanelController(appState: appState, voice: voice)
    private let parakeet = ParakeetTranscriber()
    private lazy var voice = VoiceController(
        state: appState, microphone: Microphone(),
        recognition: SpeechRecognition(primary: parakeet, fallback: AppleSpeechTranscriber())
    )
    private var settingsWindow: NSWindow?
    private var modeItems: [Mode: NSMenuItem] = [:]
    private var statusItem: NSStatusItem?
    private var visibilityItem: NSMenuItem?
    private var engine: EngineSupervisor?
    private var eventTask: Task<Void, Never>?
    private lazy var eventBatcher = AppEventBatcher { [weak self] event in self?.receive(event) }
    private var completionTask: Task<Void, Never>?
    #if DEBUG
    private var showSessionsOnConnect = ProcessInfo.processInfo.arguments.contains("--show-sessions")
    private static var demoState: NotchUIState? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--demo-state"), index + 1 < args.count else { return nil }
        return NotchUIState(rawValue: args[index + 1])
    }
    /// Screenshot aid: `--open-tab New` opens the workspace on that tab once connected.
    private var openTabOnConnect: PanelTab? = {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--open-tab"), index + 1 < args.count else { return nil }
        return PanelTab(rawValue: args[index + 1])
    }()
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspace.addObserver(self, selector: #selector(workspaceChanged(_:)), name: name, object: nil)
        }
        #if DEBUG
        notchController.chooseBackend = { [weak self] value in
            guard let self, let mode = Mode(rawValue: value) else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: "backendMode")
            select(mode)
            appState.apply(.selectPanelTab(.sessions))
        }
        #endif
        notchController.showHotkeyRecorder = { [weak self] in self?.showSettings() }
        notchController.retryConnection = { [weak self] in self?.retryConnection() }
        notchController.showEngineLogs = { [weak self] in self?.showEngineLogs() }
        voice.registerShortcut { [weak self] in self?.showNotch() }
        #if DEBUG
        select(Mode(rawValue: UserDefaults.standard.string(forKey: "backendMode") ?? "") ?? .live)
        #else
        select(.live)
        #endif
        if UserDefaults.standard.bool(forKey: "launchExpanded") {
            appState.apply(.selectPanelTab(.sessions))
        }
        notchController.show()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--hover-bench") {
            // Benchmark only: toggles hover in-process so before/after builds see identical transitions.
            Task { @MainActor [appState] in
                try? await Task.sleep(for: .seconds(6))
                for _ in 0..<10 {
                    appState.apply(.hoverChanged(true))
                    try? await Task.sleep(for: .milliseconds(250))
                    appState.apply(.hoverChanged(false))
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--open-settings") { showSettings() }
        #endif
        let appMenu = NSMenu()
        let appItem = NSMenuItem()
        appMenu.addItem(appItem)
        let commands = NSMenu()
        let settings = addItem("Settings…", action: #selector(showSettings), to: commands)
        settings.keyEquivalent = ","
        addUpdateItem(to: commands)
        appItem.submenu = commands
        // Standard Edit menu so copy, paste and undo work in the Settings window's text fields.
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        appMenu.addItem(editItem)
        NSApp.mainMenu = appMenu
        if !UserDefaults.standard.bool(forKey: "onboardingCompleted") { showSettings() }
        Task(priority: .utility) {
            let vocabulary = await VoiceController.loadVocabulary()
            parakeet.warmIfInstalled(vocabulary: vocabulary.words)
        }
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        notchController.queueDisplayUpdate()
    }

    @objc private func workspaceChanged(_ notification: Notification) {
        notchController.queueDisplayUpdate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopBackend()
        notchController.hide()
    }

    private func receive(_ event: AppEvent) {
        let previous = appState.panelSnapshot
        appState.apply(event)
        #if DEBUG
        if showSessionsOnConnect, event == .connectionChanged(.connected) {
            showSessionsOnConnect = false
            appState.apply(.setSessionsPanel(true))
        }
        if let tab = openTabOnConnect, appState.panelSnapshot.connection == .connected, event != .demoReset {
            openTabOnConnect = nil
            appState.apply(.selectPanelTab(tab))
        }
        #endif
        let current = appState.panelSnapshot
        if notchController.isShown {
            notchController.presentation.receive(event, previous: previous, current: current)
        }
        playSounds(previous: previous, current: current)
        guard current.completedSessionID != previous.completedSessionID ||
                current.failedSessionID != previous.failedSessionID else { return }
        completionTask?.cancel()
        completionTask = nil
        guard current.completedSessionID != nil || current.failedSessionID != nil else { return }
        completionTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(4))
                try Task.checkCancellation()
                self?.appState.apply(.idleTimeout)
            } catch {
                // A newer state replaced this completion notice.
            }
        }
    }

    private func playSounds(previous: StateSnapshot, current: StateSnapshot) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "soundOnComplete"), current.completedSessionID != nil,
           current.completedSessionID != previous.completedSessionID {
            NSSound(named: "Glass")?.play()
        } else if defaults.bool(forKey: "soundOnError"), current.failedSessionID != nil,
                  current.failedSessionID != previous.failedSessionID {
            NSSound(named: "Basso")?.play()
        } else if defaults.bool(forKey: "soundOnApproval"),
                  current.pendingApprovals.contains(where: { request in !previous.pendingApprovals.contains { $0.id == request.id } })
                    || current.pendingUserInputs.contains(where: { request in !previous.pendingUserInputs.contains { $0.id == request.id } }) {
            NSSound(named: "Ping")?.play()
        }
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(
            systemSymbolName: "capsule.fill", accessibilityDescription: "\(Product.name)"
        )

        let menu = NSMenu()
        addUpdateItem(to: menu)
        visibilityItem = addItem("Hide \(Product.name)", action: #selector(toggleNotch), to: menu)
        let settings = addItem("Settings…", action: #selector(showSettings), to: menu)
        settings.keyEquivalent = ","
        #if DEBUG
        menu.addItem(.separator())
        let debugMenu = NSMenu(title: "Debug")
        for mode in [Mode.fake, .live] {
            let item = addItem(mode.rawValue, action: #selector(selectMode(_:)), to: debugMenu)
            item.representedObject = mode.rawValue
            modeItems[mode] = item
        }
        debugMenu.addItem(.separator())
        for state in NotchUIState.allCases {
            let item = addItem(state.rawValue, action: #selector(jumpToState(_:)), to: debugMenu)
            item.representedObject = state.rawValue
        }
        addItem("3 agents waiting for approval", action: #selector(jumpToMultiApproval), to: debugMenu)
        debugMenu.addItem(.separator())
        addItem("Start Fake Feed", action: #selector(startFakeFeed), to: debugMenu)
        addItem("Stop Fake Feed", action: #selector(stopFakeFeed), to: debugMenu)
        let debugItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        menu.addItem(debugItem)
        menu.setSubmenu(debugMenu, for: debugItem)
        #endif

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit \(Product.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApplication.shared
        menu.addItem(quitItem)
        statusItem?.menu = menu
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func addUpdateItem(to menu: NSMenu) {
        let controller = AppMaintenance.updates
        let item = menu.addItem(withTitle: "Check for Updates…", action: #selector(controller.checkForUpdates(_:)), keyEquivalent: "")
        item.target = controller
    }

    @objc private func toggleNotch() {
        if notchController.isShown {
            voice.cancel()
            notchController.hide()
            visibilityItem?.title = "Show \(Product.name)"
        } else {
            showNotch()
        }
    }

    private func showNotch() {
        notchController.show()
        visibilityItem?.title = "Hide \(Product.name)"
    }

    @objc private func showSettings() {
        voice.cancel()
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 940, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
            )
            window.delegate = self
            window.title = Product.name + " Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: WorkspaceSettingsView(
                state: appState, backend: { [weak self] in self?.backend as? any SettingsBackend },
                speech: parakeet, onboarding: !UserDefaults.standard.bool(forKey: "onboardingCompleted"),
                finish: { UserDefaults.standard.set(true, forKey: "onboardingCompleted") },
                showEngineLogs: { [weak self] in self?.showEngineLogs() }
            ))
            settingsWindow = window
            window.center()
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow { settingsWindow = nil }
    }

    #if DEBUG
    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let mode = Mode(rawValue: value) else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: "backendMode")
        select(mode)
        showNotch()
    }

    #endif

    private func select(_ mode: Mode) {
        if mode == self.mode {
            guard case .failed = appState.panelSnapshot.connection else { return }
        }
        stopBackend()
        appState.apply(.demoReset)
        self.mode = mode
        for (value, item) in modeItems { item.state = value == mode ? .on : .off }

        #if DEBUG
        if mode == .fake {
            let fake = FakeBackend()
            attach(fake)
            if ProcessInfo.processInfo.arguments.contains("--demo-rich") {
                fake.showRichDemo()
                showNotch()
            } else if ProcessInfo.processInfo.arguments.contains("--demo-question") {
                fake.showUserInputDemo(openingThread: true)
                showNotch()
            } else if let state = Self.demoState {
                // Screenshot aid: `--demo-state Running` (any NotchUIState name), optionally with `--hover`.
                fake.showDemo(state)
                if ProcessInfo.processInfo.arguments.contains("--hover") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                        self?.appState.apply(.hoverChanged(true))
                    }
                }
            } else if ProcessInfo.processInfo.arguments.contains("--demo-hover") {
                fake.showDemo(.needsApproval)
            } else if ProcessInfo.processInfo.arguments.contains("--demo-sessions") {
                fake.showSessionsWorkspace()
                showNotch()
            } else {
                fake.startEventFeed()
            }
            return
        }
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "--fixture-server"), arguments.indices.contains(flag + 1),
           let url = URL(string: arguments[flag + 1]) {
            startClient(T3Client(replayOrigin: url))
            return
        }
        #endif
        startBuiltInEngine()
    }

    private func preferredProject() -> String? {
        let id = UserDefaults.standard.string(forKey: "defaultProject")
        return id?.isEmpty == false ? id : nil
    }

    private func attach(_ backend: any AgentBackend) {
        self.backend = backend
        notchController.backend = backend
        voice.backend = backend
        observe(backend)
    }

    private func startClient(_ client: T3Client) {
        attach(client)
        appState.apply(.connectionChanged(.disconnected))
        client.start()
    }

    // MARK: Built-in engine

    private func startBuiltInEngine() {
        let executable = Bundle.main.bundleURL.appending(path: "Contents/Helpers/notchbee-engine")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            receive(.connectionChanged(.engineFailed("The engine is missing from the app bundle.")))
            return
        }
        let supervisor = EngineSupervisor.standard(executable: executable)
        supervisor.onStatus = { [weak self] status in
            switch status {
            case .starting: self?.appState.apply(.connectionChanged(.engineStarting))
            case .restarting: self?.appState.apply(.connectionChanged(.engineRestarting))
            case .failed(let message): self?.receive(.connectionChanged(.engineFailed(message)))
            case .running, .stopped: break
            }
        }
        supervisor.onReady = { [weak self] endpoint in
            guard let self else { return }
            stopClient()
            startClient(T3Client(bundledEngine: endpoint, preferredProject: preferredProject))
        }
        supervisor.onLost = { [weak self] in
            self?.stopClient()
            self?.appState.apply(.demoReset)
        }
        engine = supervisor
        appState.apply(.connectionChanged(.engineStarting))
        supervisor.start()
    }

    private func retryConnection() {
        if let engine, case .failed = engine.status {
            appState.apply(.connectionChanged(.engineStarting))
            engine.retry()
        } else {
            (backend as? T3Client)?.retryConnection()
        }
    }

    private func showEngineLogs() {
        let files = FileManager.default
        let locations = EngineLocations.standard
        try? files.createDirectory(at: locations.logs, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        if files.fileExists(atPath: locations.logs.appending(path: "engine.log").path) {
            NSWorkspace.shared.activateFileViewerSelecting([locations.logs.appending(path: "engine.log")])
        } else {
            NSWorkspace.shared.open(locations.logs)
        }
    }

    private func observe(_ backend: any AgentBackend) {
        guard eventTask == nil else { return }
        let events = backend.eventStream()
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.eventBatcher.push(event)
            }
            if !Task.isCancelled { self?.eventTask = nil }
        }
    }

    private func stopBackend() {
        if let engine {
            self.engine = nil
            engine.onStatus = nil
            engine.onReady = nil
            engine.onLost = nil
            engine.stopImmediately()
        }
        stopClient()
    }

    private func stopClient() {
        voice.reset()
        voice.backend = nil
        eventTask?.cancel()
        eventTask = nil
        eventBatcher.discard()
        completionTask?.cancel()
        notchController.presentation.clearNotices()
        (backend as? T3Client)?.stop()
        (backend as? FakeBackend)?.stopEventFeed()
        notchController.backend = nil
        backend = nil
    }

    #if DEBUG
    private func fakeBackend() -> FakeBackend? {
        select(.fake)
        guard let fake = backend as? FakeBackend else { return nil }
        observe(fake)
        return fake
    }

    @objc private func jumpToState(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let state = NotchUIState(rawValue: name) else { return }
        showNotch()
        fakeBackend()?.showDemo(state)
    }

    @objc private func jumpToMultiApproval() {
        showNotch()
        fakeBackend()?.showMultipleApprovals()
    }

    @objc private func startFakeFeed() {
        showNotch()
        fakeBackend()?.startEventFeed()
    }

    @objc private func stopFakeFeed() {
        guard let fake = backend as? FakeBackend else { return }
        eventTask?.cancel()
        eventTask = nil
        eventBatcher.discard()
        fake.stopEventFeed()
        observe(fake)
    }
    #endif
}
