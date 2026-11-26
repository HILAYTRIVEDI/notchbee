import AVFoundation
import ServiceManagement
import SwiftUI
import NotchpilotCore

struct WorkspaceSettingsView: View {
    let state: AppState
    let backend: () -> (any SettingsBackend)?
    let speech: ParakeetTranscriber
    @State var onboarding: Bool
    let finish: () -> Void
    var showEngineLogs: () -> Void = {}
    @State private var step = 0
    @State private var section = "Providers"
    @State private var message = ""
    @State private var license = false
    @State private var remove: ThreadProject?
    @State private var downloading = false
    @State private var modelInstalled = VerifiedSpeechModels.parakeet.isInstalled(in: ParakeetTranscriber.defaultModelsDirectory)
    @State private var serverModel: ServerSettingsModel
    @AppStorage("defaultProject") private var defaultProject = ""
    @AppStorage("dictationCleanup") private var cleanup = true
    @AppStorage("dictationWords") private var words = ""

    init(state: AppState, backend: @escaping () -> (any SettingsBackend)?, speech: ParakeetTranscriber, onboarding: Bool,
         finish: @escaping () -> Void, showEngineLogs: @escaping () -> Void = {}) {
        self.state = state
        self.backend = backend
        self.speech = speech
        _onboarding = State(initialValue: onboarding)
        #if DEBUG
        if let debugSection = UserDefaults.standard.string(forKey: "debugSettingsSection") {
            _section = State(initialValue: debugSection)
        }
        #endif
        self.finish = finish
        self.showEngineLogs = showEngineLogs
        _serverModel = State(initialValue: ServerSettingsModel(backend: backend))
    }

    private struct Group { let title: String; let items: [(name: String, symbol: String)] }
    private let groups: [Group] = [
        .init(title: Product.name, items: [("General", "gearshape"), ("Appearance", "paintbrush"),
                                           ("Notifications", "bell"), ("Shortcuts", "command")]),
        .init(title: "Agents", items: [("Providers", "cpu"), ("Usage", "gauge.with.dots.needle.50percent"),
                                       ("Models & defaults", "slider.horizontal.3"), ("Threads", "bubble.left.and.text.bubble.right")]),
        .init(title: "Workspace", items: [("Projects", "folder"), ("Git & worktrees", "arrow.triangle.branch"),
                                          ("Dictation", "mic")]),
        .init(title: "System", items: [("Engine & About", "info.circle")])
    ]

    private var connected: Bool { state.panelSnapshot.connection == .connected }

    private let steps = ["Welcome", "Agent setup", "New thread defaults", "Permissions", "Ready"]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .onReceive(NotificationCenter.default.publisher(for: .showSettingsSection)) { note in
                    if let name = note.object as? String { section = name }
                }
            Rectangle().fill(T3.border).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                if onboarding {
                    onboardingShell
                } else {
                    settingsPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Color(white: 0.085))
        .preferredColorScheme(.dark)
        .task(id: connected) { if connected { await serverModel.load() } }
        .alert("Remove project?", isPresented: Binding(get: { remove != nil }, set: { if !$0 { remove = nil } }), presenting: remove) { project in
            Button("Remove", role: .destructive) { perform { try await $0.removeProject(id: project.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text($0.name) }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Product.name).font(.system(size: 15, weight: .semibold)).padding(.horizontal, 10).padding(.bottom, 10)
            if onboarding {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, item in
                    Text(item)
                        .font(.system(size: 12.5, weight: steps[min(step, steps.count - 1)] == item ? .semibold : .regular))
                        .foregroundStyle(steps[min(step, steps.count - 1)] == item ? T3.foreground : T3.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 28)
                        .background(steps[min(step, steps.count - 1)] == item ? Color.white.opacity(0.10) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .id(index)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(groups, id: \.title) { group in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.4)
                                    .foregroundStyle(T3.faint).padding(.horizontal, 10).padding(.bottom, 2)
                                ForEach(group.items, id: \.name) { item in sidebarItem(item.name, item.symbol) }
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 200)
        .background(Color.white.opacity(0.03))
    }

    private func sidebarItem(_ name: String, _ symbol: String) -> some View {
        let selected = section == name
        return Button {
            section = name
            message = ""
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 16)
                    .foregroundStyle(selected ? T3.foreground : T3.muted)
                Text(name).font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(selected ? Color.white.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain).clickableCursor()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Onboarding

    private var onboardingShell: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(steps[min(step, steps.count - 1)]).font(.system(size: 24, weight: .bold))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    onboardingPage
                    if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                Button(step == steps.count - 1 ? "Done" : "Continue") {
                    if step == steps.count - 1 { onboarding = false; finish() } else { step += 1 }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
    }

    private func providers(_ purpose: ProviderControls.Purpose) -> some View {
        ProviderControls(backend: backend(), purpose: purpose)
            .id("\(state.panelSnapshot.connection)-\(purpose)")
    }

    @ViewBuilder private var onboardingPage: some View {
        switch steps[min(step, steps.count - 1)] {
        case "Welcome": Text("Start agent sessions, review their work, and dictate from your Mac’s notch.")
        case "Agent setup": providers(.detection)
        case "New thread defaults": providers(.defaults)
        case "Permissions":
            Text("The microphone captures speech while you hold your dictation shortcut.")
            Button("Allow microphone…") { Task {
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                message = allowed ? "Microphone access granted." : "Enable microphone access in Privacy & Security."
            } }
            Text("Accessibility lets dictation identify the focused field and insert your transcript.")
            Button("Allow Accessibility…", action: FocusedDictationTarget.requestAccessibility)
        default: Text("Open the notch and choose New to start your first session.")
        }
    }

    // MARK: Pages

    @ViewBuilder private var settingsPage: some View {
        switch section {
        case "General":
            GeneralSettingsPage(model: serverModel, connection: state.panelSnapshot.connection) { step = 0; onboarding = true; message = "" }
        case "Appearance": AppearanceSettingsPage()
        case "Notifications": NotificationSettingsPage()
        case "Shortcuts": ShortcutsSettingsPage()
        case "Providers": ProvidersPage(backend: backend, connected: connected)
        case "Usage": UsagePage(backend: backend, connected: connected)
        case "Models & defaults": ModelsSettingsPage(model: serverModel, projects: state.panelSnapshot.projects)
        case "Threads": ThreadsSettingsPage(model: serverModel)
        case "Git & worktrees": GitSettingsPage(model: serverModel)
        case "Projects": projectsPage
        case "Dictation": dictationPage
        default: enginePage
        }
    }

    private var projectsPage: some View {
        SettingsPage(title: "Projects", subtitle: "Folders agents can work in.") {
            SettingsSection {
                if state.panelSnapshot.projects.isEmpty {
                    Text("No projects yet.").font(.system(size: 12.5)).foregroundStyle(T3.muted).padding(14)
                }
                ForEach(Array(state.panelSnapshot.projects.enumerated()), id: \.element.id) { index, project in
                    SettingsRow(title: project.name, showsDivider: index < state.panelSnapshot.projects.count - 1) {
                        Button("Remove…") { remove = project }
                    }
                }
            }
            Button("Add folder…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                if panel.runModal() == .OK, let url = panel.url { perform { _ = try await $0.addProject(folder: url) } }
            }
            if !message.isEmpty { Text(message).foregroundStyle(T3.warning).font(.system(size: 12)) }
        }
    }

    private var dictationPage: some View {
        SettingsPage(title: "Dictation", subtitle: "On-device speech to text.") {
            SettingsSection(title: "Speech model") {
                SettingsRow(title: modelInstalled ? "Speech model installed" : "Speech model available to download", showsDivider: false) {
                    if !modelInstalled {
                        Button("Download") {
                            downloading = true
                            Task {
                                defer { downloading = false }
                                do {
                                    try await speech.prepare(vocabulary: await VoiceController.loadVocabulary().words) { text, _ in message = text }
                                    modelInstalled = true
                                    message = ""
                                } catch { message = error.localizedDescription }
                            }
                        }.disabled(downloading)
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(T3.success)
                    }
                }
            }
            SettingsSection(title: "Cleanup") {
                SettingsRow(title: "Clean transcripts in Clean mode", showsDivider: false) {
                    Toggle("Clean transcripts", isOn: $cleanup).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
            SettingsSection(title: "Custom words", footer: "Enter one word or phrase per line.") {
                TextEditor(text: $words).font(.system(size: 12.5)).frame(height: 110).scrollContentBackground(.hidden).padding(8)
            }
            if !message.isEmpty { Text(message).foregroundStyle(T3.muted).font(.system(size: 12)) }
        }
    }

    private var enginePage: some View {
        SettingsPage(title: "Engine & About") {
            SettingsSection(title: "Engine", footer: "\(Product.name) runs its own engine and keeps its data separate.") {
                SettingsRow(title: "Engine logs", showsDivider: false) { Button("Show logs", action: showEngineLogs) }
            }
            SettingsSection(title: "About") {
                SettingsRow(title: Product.name, showsDivider: false) {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                        .foregroundStyle(T3.muted)
                }
            }
            DisclosureGroup("Open-source licenses", isExpanded: $license) {
                if license, let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: nil),
                   let notice = try? String(contentsOf: url, encoding: .utf8) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Bun 1.4.1 statically links JavaScriptCore/WebKit under the LGPL.")
                        Link("Corresponding Bun source", destination: URL(string: "https://github.com/oven-sh/bun/tree/4661e494f052c83c80dade1318e5710238340be6")!)
                        Link("Corresponding JavaScriptCore and WebKit source", destination: URL(string: "https://github.com/oven-sh/WebKit/tree/6119947592b6e1c1faef02a4c2e03174cf05d062")!)
                        Text("To relink the engine, set NOTCHBEE_BUN_RUNTIME to your rebuilt Bun executable and run scripts/build-engine.sh from the Notchbee source checkout.")
                        Text(notice).textSelection(.enabled)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func perform(_ action: @escaping @MainActor (any SettingsBackend) async throws -> Void) {
        guard let backend = backend() else { message = "\(Product.name) isn’t connected yet."; return }
        Task { do { try await action(backend); message = "" } catch { message = error.localizedDescription } }
    }
}

extension Notification.Name {
    /// Posted with a section title (for example "Providers") to switch the Settings window to that page.
    static let showSettingsSection = Notification.Name("NotchbeeShowSettingsSection")
}
