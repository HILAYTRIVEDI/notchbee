import SwiftUI
import NotchpilotCore

struct ProviderControls: View {
    enum Purpose { case defaults, detection }
    let backend: (any SettingsBackend)?
    let purpose: Purpose
    @State private var settings: WorkspaceSettings?
    @State private var selectedID = ""
    @State private var message = ""
    @State private var working = false
    @State private var downloadSDK: ProviderSettings?

    private var choices: [ProviderSettings] {
        settings?.providers ?? []
    }
    private var provider: ProviderSettings? { choices.first { $0.id == selectedID } ?? choices.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if purpose == .detection {
                ForEach(choices) { p in
                    VStack(alignment: .leading) {
                        Text(p.name).bold()
                        status(p)
                        commands(p)
                    }
                    Divider()
                }
            } else if let p = provider {
                Picker("Provider", selection: Binding(get: { p.id }, set: { selectedID = $0; message = "" })) {
                    ForEach(choices) { Text($0.name).tag($0.id) }
                }
                status(p)
                modelControls(p)
            } else if settings != nil {
                Text("No providers reported.")
            }
            if purpose == .detection {
                Button("Check again") {
                    run { service in
                        for p in choices { try await service.refreshProvider(id: p.id) }
                    }
                }
            } else if let p = provider {
                Button("Check again") { run { try await $0.refreshProvider(id: p.id) } }
            } else if settings == nil {
                Button("Reload providers") { run { _ in } }
            }
            if working { ProgressView().controlSize(.small) }
            if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
        }
        .disabled(working)
        .task { await load() }
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
    }

    private func status(_ p: ProviderSettings) -> some View {
        let auth = p.auth == "authenticated" ? "Signed in" : p.auth == "unauthenticated" ? "Signed out" : "Sign-in status unknown"
        return Text(p.sdkRequired ? "SDK download required" : [p.installed ? "Installed" : "Not installed", auth].joined(separator: " · "))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private func commands(_ p: ProviderSettings) -> some View {
        if p.sdkRequired {
            Button("Review SDK download…") { downloadSDK = p }
        }
        if !p.installed && p.canInstall {
            Button("Install " + p.name) { run { try await $0.installProvider(id: p.id) } }
        }
        if !p.installed, let command = p.installCommand { commandRow(command) }
        if p.auth != "authenticated", let command = p.loginCommand {
            commandRow(command)
            if p.driver == "pi" { Text("Then enter /login in Pi.").font(.caption) }
        }
        if let address = p.documentationURL, let url = URL(string: address), url.scheme == "https" {
            Link("Setup instructions", destination: url)
        }
    }

    private func commandRow(_ command: String) -> some View {
        HStack {
            Text(verbatim: command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }.labelStyle(.iconOnly)
        }
    }

    @ViewBuilder private func modelControls(_ p: ProviderSettings) -> some View {
        let current = settings?.selection.flatMap { selection in
            selection.instanceId == p.id && p.models.contains { $0.id == selection.model } ? selection : nil
        }
        if !p.models.isEmpty {
            let modelID = current?.model ?? p.defaultModel ?? p.models[0].id
            Picker("Default model", selection: Binding(get: { modelID }, set: { id in
                save(.init(instanceId: p.id, model: id))
            })) {
                ForEach(p.models) { Text($0.name).tag($0.id) }
            }
            if current == nil {
                Button("Use for new threads") { save(.init(instanceId: p.id, model: modelID)) }
            }
            ForEach(p.models.first { $0.id == modelID }?.options ?? []) { option in
                let values = current?.options ?? []
                let value = values.first { $0.id == option.id }?.value ?? option.currentValue
                let update: (ThreadModelSelection.Option.Value) -> Void = { newValue in
                    let options = values.filter { $0.id != option.id } + [.init(id: option.id, value: newValue)]
                    save(.init(instanceId: p.id, model: modelID, options: options))
                }
                if option.type == "boolean" {
                    Toggle(Product.displayText(option.label), isOn: Binding(get: { value == .toggle(true) }, set: { update(.toggle($0)) }))
                } else if let choices = option.options {
                    Picker(Product.displayText(option.label), selection: Binding(get: {
                        if case .choice(let id) = value { return id }
                        return choices.first { $0.isDefault == true }?.id ?? choices.first?.id ?? ""
                    }, set: { update(.choice($0)) })) {
                        ForEach(choices) { Text(Product.displayText($0.label)).tag($0.id) }
                    }
                }
            }
        }
    }

    private func save(_ selection: ThreadModelSelection) { run { try await $0.setDefaultModel(selection) } }

    private func load() async {
        guard let backend else { message = "Connect to the server to load providers."; return }
        do {
            settings = try await backend.workspaceSettings()
            if selectedID.isEmpty { selectedID = settings?.selection?.instanceId ?? "" }
            message = ""
        } catch { message = error.localizedDescription }
    }

    private func run(_ action: @escaping @MainActor (any SettingsBackend) async throws -> Void) {
        guard !working, let backend else { return }
        working = true
        Task {
            defer { working = false }
            do {
                try await action(backend)
                await load()
            } catch { message = error.localizedDescription }
        }
    }
}

struct ProviderSDKConsent: View {
    let sdk: ProviderSDK
    let accept: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Download provider SDK?").font(.headline)
            Text("\(Product.name) will download \(sdk.packageName) \(sdk.version) by \(sdk.vendor) from registry.npmjs.org and install it in your local engine data.")
                .fixedSize(horizontal: false, vertical: true)
            Link("\(sdk.vendor) license and terms", destination: sdk.terms)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Download and enable", action: accept)
            }
        }
        .padding(20)
        .frame(width: 430)
    }
}

struct ProviderKeyField: NSViewRepresentable {
    @Binding var text: String
    final class Field: NSSecureTextField {
        override var needsPanelToBecomeKey: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if let panel = window as? NotchPanel {
                panel.secureEditor = self
                panel.makeKey()
            }
            super.mouseDown(with: event)
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(_ text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? Field { text.wrappedValue = field.stringValue }
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            if let field = notification.object as? Field, let panel = field.window as? NotchPanel {
                panel.secureEditor = nil
                if panel.isKeyWindow { panel.resignKey() }
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator($text) }
    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.placeholderString = "API key"
        field.setAccessibilityLabel("API key")
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: Field, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }
}
