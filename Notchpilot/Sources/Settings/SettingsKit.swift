import NotchpilotCore
import Observation
import SwiftUI

/// Server settings, loaded once per page and written through `server.updateSettings` patches.
@MainActor
@Observable
final class ServerSettingsModel {
    private(set) var settings = ServerSettings()
    private(set) var providers: [ProviderSettings] = []
    private(set) var loaded = false
    private(set) var failure: String?
    @ObservationIgnored let backend: () -> (any SettingsBackend)?

    init(backend: @escaping () -> (any SettingsBackend)?) { self.backend = backend }

    /// Defaults from `ServerSettings` in packages/contracts, used by the per-field reset buttons.
    static let defaults: [String: WireValue] = [
        "responseStreamingMode": .string("paragraph"), "enableProviderUpdateChecks": .bool(true),
        "continueThreadsAfterServerUpdate": .bool(true), "enableAgentBrowserAccess": .bool(true),
        "defaultRuntimeMode": .string("full-access"), "sidebarAutoSettleAfterDays": .number(7),
        "sidebarAutoSettleOnMerge": .bool(true), "sidebarAutoSettleKeepPullRequests": .bool(false),
        "snoozeLimitedThreads": .bool(false), "autoResumeLimitedThreads": .bool(false),
        "promptSuggestionsEnabled": .bool(false), "defaultThreadEnvMode": .null,
        "newWorktreesStartFromOrigin": .bool(true), "worktreeSubmodules": .null, "worktreesDirectory": .string(""),
        "fastWorktreeCheckout": .bool(false), "defaultAutoPull": .bool(false),
        "automaticGitFetchInterval": .number(30_000), "pullRequestMergeMethod": .null,
        "branchNamingMode": .string("static"), "branchNamePrefix": .string(Product.name.lowercased()), "branchNameInstructions": .string(""),
        "removeAgentCreditsOnMerge": .bool(false), "addProjectBaseDirectory": .string(""), "ghqCloneLayout": .bool(false),
        "threadTitleInstructions": .string(""), "idleCompaction": .string("onReturn"),
        "speechPostProcessingModelSelection": .null, "fallbackModelSelection": .null
    ]

    private func defaultValue(_ key: String) -> WireValue? {
        return Self.defaults[key]
    }

    func textFieldValue(_ key: String) -> String {
        let value = string(key)
        if ["threadTitleInstructions", "branchNameInstructions", "branchNamePrefix"].contains(key) {
            return Product.displayText(value)
        }
        return value
    }

    func load() async {
        guard let backend = backend() else {
            failure = "Connect to the server to load settings."
            return
        }
        do {
            let config = try await backend.settingsAndProviders()
            settings = config.settings
            providers = config.workspace.providers
            loaded = true
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    func bool(_ key: String) -> Bool {
        settings.bool(key, default: { if case .bool(let value) = defaultValue(key) { value } else { false } }())
    }

    func string(_ key: String) -> String {
        settings.string(key, default: { if case .string(let value) = defaultValue(key) { value } else { "" } }())
    }

    func isDefault(_ key: String) -> Bool {
        guard let fallback = defaultValue(key) else { return true }
        return (settings.values[key] ?? fallback) == fallback
    }

    func reset(_ key: String) {
        guard let value = defaultValue(key) else { return }
        set(key, value)
    }

    func set(_ key: String, _ value: WireValue, extra: [String: WireValue] = [:]) {
        guard let backend = backend() else { failure = "Connect to the server to change settings."; return }
        let previous = settings.values
        settings.values[key] = value
        for (extraKey, extraValue) in extra { settings.values[extraKey] = extraValue }
        var patch = extra
        patch[key] = value
        Task {
            do {
                try await backend.updateServerSettings(patch)
                failure = nil
            } catch {
                settings.values = previous
                failure = error.localizedDescription
            }
        }
    }

    func setSelection(_ key: String, _ selection: ThreadModelSelection?) {
        guard let selection else { set(key, .null); return }
        if let value = try? WireValue(encoding: selection) { set(key, value) }
    }
}

// MARK: Layout

/// A settings page: title, scrolling content, and a trailing error line.
struct SettingsPage<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 20, weight: .semibold))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(T3.muted)
                    }
                }
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 26)
            .padding(.vertical, 24)
        }
    }
}

/// A rounded group of rows with an optional heading, like T3's settings sections.
struct SettingsSection<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.4)
                    .foregroundStyle(T3.faint).padding(.leading, 2)
            }
            VStack(spacing: 0) { content() }
                .background(T3.fill, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(T3.border, lineWidth: 1))
            if let footer {
                Text(footer).font(.system(size: 11)).foregroundStyle(T3.faint).padding(.leading, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: String
    var help: String?
    var showsDivider = true
    var onReset: (() -> Void)?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13))
                    if let onReset {
                        Button(action: onReset) {
                            Image(systemName: "arrow.counterclockwise").font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(T3.muted).frame(width: 18, height: 18).hoverPlate(radius: 5)
                        }
                        .buttonStyle(.plain).clickableCursor()
                        .help("Reset to default")
                        .accessibilityLabel("Reset \(title) to default")
                    }
                }
                if let help {
                    Text(Product.displayText(help)).font(.system(size: 11.5)).foregroundStyle(T3.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if showsDivider { Rectangle().fill(T3.border).frame(height: 1).padding(.leading, 14) }
        }
    }
}

/// A server-backed toggle with a reset-to-default button.
struct ServerToggleRow: View {
    let model: ServerSettingsModel
    let key: String
    let title: String
    var help: String?

    var body: some View {
        SettingsRow(title: title, help: help, onReset: model.isDefault(key) ? nil : { model.reset(key) }) {
            Toggle(title, isOn: Binding(get: { model.bool(key) }, set: { model.set(key, .bool($0)) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

struct ServerChoiceRow: View {
    let model: ServerSettingsModel
    let key: String
    let title: String
    var help: String?
    let options: [(value: String, label: String)]
    /// What the picker shows while the setting is `null`.
    var unsetLabel: String?

    private var current: String {
        if case .string(let value) = model.settings.values[key] { return value }
        if unsetLabel != nil { return "" }
        return model.string(key)
    }

    var body: some View {
        SettingsRow(title: title, help: help, onReset: model.isDefault(key) ? nil : { model.reset(key) }) {
            Picker(title, selection: Binding(get: { current }, set: { value in
                if value.isEmpty { model.set(key, .null) } else { model.set(key, .string(value)) }
            })) {
                if let unsetLabel { Text(unsetLabel).tag("") }
                ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
            }
            .labelsHidden().frame(width: 190)
        }
    }
}

/// A text field that writes on Return or when it loses focus.
struct ServerTextRow: View {
    let model: ServerSettingsModel
    let key: String
    let title: String
    var help: String?
    var placeholder = ""
    var width: CGFloat = 220
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        SettingsRow(title: title, help: help, onReset: model.isDefault(key) ? nil : { model.reset(key); draft = model.textFieldValue(key) }) {
            TextField(placeholder, text: $draft)
                .textFieldStyle(.roundedBorder).frame(width: width)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { if !focused { commit() } }
        }
        .onAppear { draft = model.textFieldValue(key) }
        .onChange(of: model.string(key)) { if !focused { draft = model.textFieldValue(key) } }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != model.textFieldValue(key) else { return }
        model.set(key, .string(trimmed))
    }
}

struct AppToggleRow: View {
    let key: String
    let title: String
    var help: String?
    var defaultValue = false
    @AppStorage private var value: Bool

    init(key: String, title: String, help: String? = nil, defaultValue: Bool = false) {
        self.key = key
        self.title = title
        self.help = help
        self.defaultValue = defaultValue
        _value = AppStorage(wrappedValue: defaultValue, key)
    }

    var body: some View {
        SettingsRow(title: title, help: help, onReset: value == defaultValue ? nil : { value = defaultValue }) {
            Toggle(title, isOn: $value).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

struct SettingsStatusLine: View {
    let model: ServerSettingsModel

    var body: some View {
        if let failure = model.failure {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11.5)).foregroundStyle(T3.warning)
                .fixedSize(horizontal: false, vertical: true)
        } else if !model.loaded {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Loading settings…").foregroundStyle(T3.muted) }
                .font(.system(size: 11.5))
        }
    }
}

/// Picks a provider/model pair from the server's catalog.
struct ModelSelectionPicker: View {
    let providers: [ProviderSettings]
    let selection: ThreadModelSelection?
    var noneLabel: String?
    let onChange: (ThreadModelSelection?) -> Void

    private var tag: String { selection.map { "\($0.instanceId)\u{1F}\($0.model)" } ?? "" }

    var body: some View {
        Picker("Model", selection: Binding(get: { tag }, set: { value in
            let parts = value.components(separatedBy: "\u{1F}")
            guard parts.count == 2 else { onChange(nil); return }
            onChange(ThreadModelSelection(instanceId: parts[0], model: parts[1]))
        })) {
            if let noneLabel { Text(noneLabel).tag("") }
            if !tag.isEmpty, !providers.contains(where: { p in p.id == selection?.instanceId && p.models.contains { $0.id == selection?.model } }) {
                Text(Product.displayText(selection?.model ?? "")).tag(tag)
            }
            ForEach(providers.filter { $0.enabled && !$0.models.isEmpty }) { provider in
                Section(provider.name) {
                    ForEach(provider.models) { Text($0.name).tag("\(provider.id)\u{1F}\($0.id)") }
                }
            }
        }
        .labelsHidden().frame(width: 230)
    }
}
