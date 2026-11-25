import AppKit
import NotchpilotCore
import SwiftUI

func relativeAge(_ date: Date?, now: Date = .now) -> String? {
    guard let date else { return nil }
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 45 { return "just now" }
    if seconds < 3_600 { return "\(Int(seconds / 60 + 0.5))m ago" }
    if seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }
    return "\(Int(seconds / 86_400))d ago"
}

/// Providers like T3's settings: a list on the left and the selected provider's detail on the right.
struct ProvidersPage: View {
    let backend: () -> (any SettingsBackend)?
    /// Changes when the engine connects or drops, so the page loads as soon as it can.
    let connected: Bool
    @State private var providers: [ProviderSettings] = []
    @State private var selectedID = ""
    @State private var loaded = false
    @State private var working = false
    @State private var message = ""
    @State private var showsAdd = false
    @State private var didProbe = false
    @State private var downloadSDK: ProviderSettings?

    private var selected: ProviderSettings? { providers.first { $0.id == selectedID } ?? providers.first }
    private var checkedAt: Date? { providers.compactMap(\.checkedAt).max() }
    private var updatable: [ProviderSettings] { providers.filter { $0.enabled && $0.updateAvailable && $0.canUpdate } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(T3.border).frame(height: 1)
            HStack(spacing: 0) {
                list.frame(width: 272)
                Rectangle().fill(T3.border).frame(width: 1)
                if let selected {
                    ProviderDetail(provider: selected, backend: backend, run: run, requestSDK: { downloadSDK = selected }, message: $message)
                        .id(selected.id)
                } else {
                    VStack(spacing: 8) {
                        if !connected {
                            ProgressView().controlSize(.small)
                            Text("Connecting to the engine…").foregroundStyle(T3.muted)
                        } else if loaded {
                            Text(message.isEmpty ? "No providers reported." : message).foregroundStyle(T3.muted)
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: connected) { if connected { await load() } }
        .sheet(item: $downloadSDK) { provider in
            if let sdk = provider.sdk {
                ProviderSDKConsent(sdk: sdk) {
                    downloadSDK = nil
                    run { service in
                        try await service.installProviderSDK(id: provider.id, sdk: sdk)
                        if !provider.enabled { try await service.updateProvider(id: provider.id, enabled: true, apiKey: nil) }
                        try await service.refreshProvider(id: provider.id)
                    }
                } cancel: { downloadSDK = nil }
            }
        }
        .sheet(isPresented: $showsAdd) {
            AddProviderSheet(existing: providers) { driver, name in
                showsAdd = false
                run { service in selectedID = try await service.addProvider(driver: driver, displayName: name) }
            } cancel: { showsAdd = false }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Providers").font(.system(size: 20, weight: .semibold))
            Spacer()
            if let age = relativeAge(checkedAt) {
                Text("Checked \(age)").font(.system(size: 11.5)).foregroundStyle(T3.muted)
            }
            Button { run { try await $0.refreshProviders(instanceID: nil) } } label: {
                Group {
                    if working { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .frame(width: 26, height: 24)
            }
            .help("Check providers again")
            .accessibilityLabel("Refresh providers")
            .disabled(working)
            Button("Update all") {
                let targets = updatable
                run { service in
                    for provider in targets { try await service.updateProviderVersion(driver: provider.driver, instanceID: provider.id) }
                    try await service.refreshProviders(instanceID: nil)
                }
            }
            .disabled(updatable.isEmpty || working)
            .help(updatable.isEmpty ? "All providers are up to date" : "Update \(updatable.count) provider\(updatable.count == 1 ? "" : "s")")
            Button { showsAdd = true } label: { Label("Add provider", systemImage: "plus") }
                .disabled(working)
        }
        .padding(.horizontal, 22)
        .frame(height: 54)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(providers) { provider in
                    ProviderListRow(provider: provider, selected: provider.id == selected?.id) {
                        selectedID = provider.id
                    } toggle: { enabled in
                        if enabled, provider.sdkRequired {
                            selectedID = provider.id
                            downloadSDK = provider
                            return
                        }
                        run { service in
                            try await service.updateProvider(id: provider.id, enabled: enabled, apiKey: nil)
                            if enabled { try await service.refreshProvider(id: provider.id) }
                        }
                    }
                }
            }
            .padding(10)
        }
    }

    private func load() async {
        guard let service = backend() else { message = "Connect to the server to load providers."; loaded = true; return }
        do {
            providers = try await service.workspaceSettings().providers
            message = ""
            // A fresh engine has not probed its providers yet. Check once on open, not on a timer.
            if !didProbe, providers.contains(where: { $0.statusMessage?.contains("not been checked") == true }) {
                didProbe = true
                loaded = true
                try? await service.refreshProviders(instanceID: nil)
                providers = try await service.workspaceSettings().providers
            }
        } catch { message = error.localizedDescription }
        loaded = true
    }

    private func run(_ action: @escaping @MainActor (any SettingsBackend) async throws -> Void) {
        guard !working, let service = backend() else { return }
        working = true
        Task {
            defer { working = false }
            do {
                try await action(service)
                await load()
            } catch {
                await load()
                message = error.localizedDescription
            }
        }
    }
}

private struct ProviderListRow: View {
    let provider: ProviderSettings
    let selected: Bool
    let select: () -> Void
    let toggle: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: select) {
                HStack(spacing: 10) {
                    ProviderBadge(driver: provider.driver, accent: provider.accentColor, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(provider.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            if let version = provider.version {
                                Text("v\(version)").font(.system(size: 10.5)).foregroundStyle(T3.faint).lineLimit(1)
                            }
                            if provider.updateAvailable {
                                Image(systemName: "arrow.up.circle.fill").font(.system(size: 12)).foregroundStyle(T3.link)
                                    .help("Update available\(provider.latestVersion.map { ": v\($0)" } ?? "")")
                                    .accessibilityLabel("Update available")
                            }
                        }
                        Text(provider.authLine).font(.system(size: 11)).foregroundStyle(T3.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).clickableCursor()
            Toggle(provider.name, isOn: Binding(get: { provider.enabled && !provider.sdkRequired }, set: toggle))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .background(selected ? Color.white.opacity(0.10) : hovering ? T3.fill : .clear, in: RoundedRectangle(cornerRadius: 9))
        .onHover { hovering = $0 }
    }
}

private struct ProviderDetail: View {
    let provider: ProviderSettings
    let backend: () -> (any SettingsBackend)?
    let run: (@escaping @MainActor (any SettingsBackend) async throws -> Void) -> Void
    let requestSDK: () -> Void
    @Binding var message: String

    @State private var drafts: [String: String] = [:]
    @State private var nameDraft = ""
    @State private var revealed = false
    @State private var hoveringEmail = false
    @State private var key = ""
    @FocusState private var nameFocused: Bool

    private var fields: [ProviderField] { ProviderField.fields(forDriver: provider.driver) }
    private func stored(_ field: ProviderField) -> String {
        if case .string(let value) = provider.config[field.key] { return value }
        return ""
    }
    private var dirty: Bool { fields.contains { field in field.control == .text && (drafts[field.key] ?? "") != stored(field) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    ProviderBadge(driver: provider.driver, accent: provider.accentColor, size: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(provider.name).font(.system(size: 18, weight: .semibold))
                        Text(ProviderBrand.label(driver: provider.driver)).font(.system(size: 12)).foregroundStyle(T3.muted)
                    }
                    Spacer()
                }
                statusSection
                if !message.isEmpty {
                    Text(message).font(.system(size: 11.5)).foregroundStyle(T3.warning).fixedSize(horizontal: false, vertical: true)
                }
                SettingsSection(title: "Display name") {
                    SettingsRow(title: "Name", help: "Shown in pickers and threads.", showsDivider: false,
                                onReset: provider.displayName == nil ? nil : { save(displayName: .some(nil)) }) {
                        TextField(ProviderBrand.label(driver: provider.driver), text: $nameDraft)
                            .textFieldStyle(.roundedBorder).frame(width: 230)
                            .focused($nameFocused)
                            .onSubmit(commitName)
                            .onChange(of: nameFocused) { if !nameFocused { commitName() } }
                    }
                }
                runtimeSection
                if provider.acceptsAPIKey && !provider.sdkRequired { keySection }
                modelsSection
                setupSection
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity)
        .onAppear { nameDraft = provider.displayName.map(Product.displayText) ?? ""; drafts = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, stored($0)) }) }
    }

    private var statusSection: some View {
        SettingsSection(title: "Status") {
            SettingsRow(title: "Account") {
                Text(verbatim: provider.authEmail ?? "—")
                    .font(.system(size: 12.5)).textSelection(.enabled)
                    .blur(radius: provider.authEmail != nil && !(revealed || hoveringEmail) ? 5 : 0)
                    .animation(.easeOut(duration: 0.12), value: revealed || hoveringEmail)
                    .onHover { hoveringEmail = $0 }
                    .onTapGesture { revealed.toggle() }
                    .help(provider.authEmail == nil ? "" : "Hover or click to reveal")
            }
            SettingsRow(title: "Plan") {
                Text(provider.authLabel ?? provider.authType?.capitalized ?? "—").font(.system(size: 12.5)).foregroundStyle(T3.muted)
            }
            SettingsRow(title: "State", help: provider.statusMessage) {
                Text(provider.authLine).font(.system(size: 12.5)).foregroundStyle(provider.auth == "authenticated" ? T3.success : T3.warning)
            }
            SettingsRow(title: "Version", help: provider.updateMessage, showsDivider: provider.sdkRequired) {
                HStack(spacing: 8) {
                    Text(provider.version.map { "v\($0)" } ?? "—").font(.system(size: 12.5)).foregroundStyle(T3.muted)
                    if provider.updateStatus == "running" || provider.updateStatus == "queued" {
                        ProgressView().controlSize(.small)
                    } else if provider.updateAvailable {
                        Button("Update\(provider.latestVersion.map { " to v\($0)" } ?? "")") {
                            run { service in
                                try await service.updateProviderVersion(driver: provider.driver, instanceID: provider.id)
                                try await service.refreshProviders(instanceID: provider.id)
                            }
                        }
                        .disabled(!provider.canUpdate)
                    }
                    Button { run { try await $0.refreshProviders(instanceID: provider.id) } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Check this provider again").accessibilityLabel("Check again")
                }
            }
            if provider.sdkRequired {
                SettingsRow(title: "Provider SDK", showsDivider: false) {
                    Button("Review download…", action: requestSDK)
                }
            }
        }
    }

    private var runtimeSection: some View {
        SettingsSection(title: "Runtime") {
            ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                fieldRow(field, isLast: index == fields.count - 1 && !dirty)
            }
            if dirty {
                HStack {
                    Spacer()
                    Button("Revert") { drafts = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, stored($0)) }) }
                    Button("Save changes") { commit() }.buttonStyle(.borderedProminent).tint(T3.primary)
                }
                .padding(10)
            }
        }
    }

    private func fieldRow(_ field: ProviderField, isLast: Bool) -> some View {
        let reset: (() -> Void)? = stored(field).isEmpty ? nil : {
            drafts[field.key] = ""
            setConfig(field.key, nil)
        }
        return SettingsRow(title: field.title, help: field.help, showsDivider: !isLast, onReset: reset) {
            fieldControl(field)
        }
    }

    @ViewBuilder private func fieldControl(_ field: ProviderField) -> some View {
        switch field.control {
        case .text:
            TextField(effectivePlaceholder(field), text: draftBinding(field))
                .textFieldStyle(.roundedBorder).frame(width: 240)
                .onSubmit { commit() }
        case .choice(let choices):
            Picker(field.title, selection: choiceBinding(field)) {
                Text("Default").tag("")
                ForEach(sortedChoices(choices), id: \.key) { choice in
                    Text(choice.value).tag(choice.key)
                }
            }.labelsHidden().frame(width: 220)
        }
    }

    private func draftBinding(_ field: ProviderField) -> Binding<String> {
        Binding(get: { drafts[field.key] ?? "" }, set: { drafts[field.key] = $0 })
    }

    private func choiceBinding(_ field: ProviderField) -> Binding<String> {
        Binding(get: { stored(field) }, set: { value in setConfig(field.key, value.isEmpty ? nil : value) })
    }

    private func setConfig(_ key: String, _ value: String?) {
        var changes: [String: String?] = [:]
        changes[key] = .some(value)
        saveConfig(changes)
    }

    private func sortedChoices(_ choices: [String: String]) -> [(key: String, value: String)] {
        choices.sorted { $0.value < $1.value }.map { (key: $0.key, value: $0.value) }
    }

    private func effectivePlaceholder(_ field: ProviderField) -> String {
        switch field.key {
        case "homePath": provider.homePath ?? field.placeholder
        case "shadowHomePath": provider.shadowHomePath ?? field.placeholder
        default: field.placeholder
        }
    }

    private var keySection: some View {
        SettingsSection(title: "API key", footer: "Stored in the server’s secret store, never in settings.json.") {
            SettingsRow(title: "Key", showsDivider: false) {
                HStack {
                    ProviderKeyField(text: $key).frame(width: 190, height: 23)
                    Button("Save") {
                        let credential = key
                        key = ""
                        run { service in
                            try await service.updateProvider(id: provider.id, enabled: true, apiKey: credential)
                            try await service.refreshProvider(id: provider.id)
                        }
                    }.disabled(key.isEmpty)
                }
            }
        }
    }

    private var modelsSection: some View {
        SettingsSection(title: "Models") {
            SettingsRow(title: modelsTitle, help: modelsHelp, showsDivider: false) {
                if !provider.models.isEmpty {
                    Picker("Default model", selection: Binding(get: { provider.defaultModel ?? provider.models[0].id }, set: { id in
                        run { try await $0.setDefaultModel(.init(instanceId: provider.id, model: id)) }
                    })) { ForEach(provider.models) { Text($0.name).tag($0.id) } }
                    .labelsHidden().frame(width: 210)
                    .help("Default model for new threads on this provider")
                }
            }
        }
    }

    private var modelsTitle: String {
        let count = provider.models.count
        return "\(count) model\(count == 1 ? "" : "s")"
    }

    private var modelsHelp: String {
        let names: [String] = provider.models.prefix(6).map { $0.name }
        let suffix = provider.models.count > 6 ? " …" : ""
        return names.joined(separator: " · ") + suffix
    }

    @ViewBuilder private var setupSection: some View {
        if !provider.installed || provider.auth != "authenticated" {
            SettingsSection(title: "Setup") {
                if !provider.installed {
                    if provider.canInstall {
                        SettingsRow(title: "Install \(provider.name)", showsDivider: provider.installCommand != nil) {
                            Button("Install") { run { try await $0.installProvider(id: provider.id) } }
                        }
                    }
                    if let command = provider.installCommand { commandRow("Install command", command, last: provider.loginCommand == nil) }
                }
                if provider.auth != "authenticated", let command = provider.loginCommand { commandRow("Sign in", command, last: true) }
            }
        }
    }

    private func commandRow(_ title: String, _ command: String, last: Bool) -> some View {
        SettingsRow(title: title, showsDivider: !last) {
            HStack {
                Text(verbatim: command).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string) } label: {
                    Image(systemName: "doc.on.doc")
                }.help("Copy").accessibilityLabel("Copy command")
            }
        }
    }

    /// Saves the display name on Return or when the field loses focus, so an edit is never silently dropped.
    private func commitName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespaces)
        guard trimmed != (provider.displayName.map(Product.displayText) ?? "") else { return }
        save(displayName: .some(trimmed))
    }

    private func commit() {
        var changes: [String: String?] = [:]
        for field in fields where field.control == .text {
            let value = (drafts[field.key] ?? "").trimmingCharacters(in: .whitespaces)
            if value != stored(field) { changes[field.key] = value.isEmpty ? .some(nil) : .some(value) }
        }
        if !changes.isEmpty { saveConfig(changes) }
    }

    private func saveConfig(_ changes: [String: String?]) {
        run { try await $0.saveProviderFields(id: provider.id, displayName: nil, config: changes) }
    }

    private func save(displayName: String??) {
        run { try await $0.saveProviderFields(id: provider.id, displayName: displayName, config: [:]) }
    }
}

private struct AddProviderSheet: View {
    let existing: [ProviderSettings]
    let add: (String, String) -> Void
    let cancel: () -> Void
    @State private var driver = "codex"
    @State private var name = ""

    private let drivers = ["codex", "claudeAgent", "opencode", "cursor", "antigravity", "grok", "pi", "kiro", "muse"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add provider").font(.system(size: 16, weight: .semibold))
            Text("Create another instance of a provider, for example a second account with its own home folder.")
                .font(.system(size: 12)).foregroundStyle(T3.muted).fixedSize(horizontal: false, vertical: true)
            Picker("Provider", selection: $driver) {
                ForEach(drivers, id: \.self) { Text(ProviderBrand.label(driver: $0)).tag($0) }
            }
            TextField("Display name (for example “Codex · Work”)", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Add") { add(driver, name.trimmingCharacters(in: .whitespaces)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 400)
    }
}
