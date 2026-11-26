import NotchpilotCore
import ServiceManagement
import SwiftUI

struct GeneralSettingsPage: View {
    let model: ServerSettingsModel
    let connection: AgentConnection
    let openOnboarding: () -> Void
    @AppStorage("launchExpanded") private var launchExpanded = false
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        SettingsPage(title: "General", subtitle: "How \(Product.name) starts and how agents stream and update.") {
            SettingsSection(title: Product.name) {
                AppToggleRow(key: "launchExpanded", title: "Start with the panel expanded",
                             help: "Open the notch panel when the app launches.")
                SettingsRow(title: "Launch at login", help: loginError, showsDivider: false) {
                    Toggle("Launch at login", isOn: Binding(get: { login }, set: { enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch { loginError = error.localizedDescription }
                        login = SMAppService.mainApp.status == .enabled
                    })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                if SMAppService.mainApp.status == .requiresApproval {
                    SettingsRow(title: "Login item needs approval", showsDivider: false) {
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            }
            SettingsSection(title: "Updates and diagnostics") {
                SettingsRow(title: "Version / Build") { Text(AppMaintenance.version) }
                SettingsRow(title: "Automatically check for updates") {
                    Toggle("Automatically check for updates", isOn: Binding(
                        get: { AppMaintenance.updates.updater.automaticallyChecksForUpdates },
                        set: { AppMaintenance.updates.updater.automaticallyChecksForUpdates = $0 }
                    )).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(title: "Software updates") {
                    Button("Check for Updates…") { AppMaintenance.updates.checkForUpdates(nil) }
                }
                SettingsRow(title: "Diagnostics", showsDivider: false) {
                    Button("Copy diagnostics") { AppMaintenance.copyDiagnostics(connection: connection) }
                }
            }
            SettingsSection(title: "Agents") {
                ServerChoiceRow(model: model, key: "responseStreamingMode", title: "Response streaming",
                                help: "Stream replies paragraph by paragraph, or show each reply when its turn finishes.",
                                options: [("paragraph", "By paragraph"), ("turn", "When the turn ends")])
                ServerToggleRow(model: model, key: "enableAgentBrowserAccess", title: "Agent browser access",
                                help: "Let agents drive the built-in browser preview.")
                ServerToggleRow(model: model, key: "promptSuggestionsEnabled", title: "Prompt suggestions (beta)",
                                help: "Claude and Codex predict your next prompt after a turn.")
                ServerToggleRow(model: model, key: "enableProviderUpdateChecks", title: "Check for provider updates")
                ServerToggleRow(model: model, key: "continueThreadsAfterServerUpdate", title: "Continue threads after a server update")
            }
            SettingsSection {
                SettingsRow(title: "Welcome tour", help: "Revisit setup for providers, defaults and permissions.", showsDivider: false) {
                    Button("Open onboarding", action: openOnboarding)
                }
            }
            SettingsStatusLine(model: model)
        }
    }
}

struct AppearanceSettingsPage: View {
    var body: some View {
        SettingsPage(title: "Appearance", subtitle: "Customize the notch and thread view.") {
            SettingsSection(title: "Notch") {
                NotchAppearancePicker()
            }
            SettingsSection(title: "Thread view") {
                AppToggleRow(key: "showTimestamps", title: "Show message times",
                             help: "Show the time and a copy button when you hover a message.", defaultValue: true)
                AppToggleRow(key: "syntaxHighlighting", title: "Syntax highlighting",
                             help: "Color code blocks for common languages.", defaultValue: true)
                AppToggleRow(key: "expandWorkLogs", title: "Expand work logs",
                             help: "Show commands, reads and edits for finished turns instead of folding them.")
                AppToggleRow(key: "showReasoning", title: "Open reasoning blocks",
                             help: "Show the model’s thinking expanded. Collapsed by default.")
            }
        }
    }
}

struct NotificationSettingsPage: View {
    var body: some View {
        SettingsPage(title: "Notifications", subtitle: "Sounds for the moments that need you.") {
            SettingsSection(title: "Sounds") {
                AppToggleRow(key: "soundOnComplete", title: "Thread finished",
                             help: "Play a sound when a running thread completes.")
                AppToggleRow(key: "soundOnApproval", title: "Approval needed",
                             help: "Play a sound when an agent asks for permission.")
                AppToggleRow(key: "soundOnError", title: "Thread failed")
            }
        }
    }
}

struct ModelsSettingsPage: View {
    let model: ServerSettingsModel
    @AppStorage("defaultProject") private var defaultProject = ""
    let projects: [ThreadProject]

    var body: some View {
        SettingsPage(title: "Models & defaults", subtitle: "What new threads start with, and which model writes titles and cleans dictation.") {
            SettingsSection(title: "New threads") {
                SettingsRow(title: "Default project") {
                    Picker("Default project", selection: $defaultProject) {
                        Text("Quick session").tag("")
                        ForEach(projects) { Text($0.name).tag($0.id) }
                    }.labelsHidden().frame(width: 230)
                }
                SettingsRow(title: "Default model", help: "Used when a thread is created without choosing one.") {
                    ModelSelectionPicker(providers: model.providers, selection: model.settings.selection("defaultModelSelection")) {
                        model.setSelection("defaultModelSelection", $0)
                    }
                }
                SettingsRow(title: "Fallback model", help: "Used when the default model is unavailable.",
                            onReset: model.settings.selection("fallbackModelSelection") == nil ? nil : { model.reset("fallbackModelSelection") }) {
                    ModelSelectionPicker(providers: model.providers, selection: model.settings.selection("fallbackModelSelection"),
                                         noneLabel: "None") { model.setSelection("fallbackModelSelection", $0) }
                }
                ServerChoiceRow(model: model, key: "defaultRuntimeMode", title: "Approval mode",
                                help: "How much agents may do before asking.",
                                options: ThreadRuntimeMode.allCases.map { ($0.rawValue, $0.label) })
            }
            SettingsSection(title: "Text generation",
                            footer: "The built-in engine uses the thread’s model for its first title. Title regeneration, branch names and commit messages use the text-generation model. Dictation cleanup uses it unless you pick another model.") {
                SettingsRow(title: "Text-generation model") {
                    ModelSelectionPicker(providers: model.providers.filter { $0.enabled }, selection: model.settings.selection("textGenerationModelSelection")) {
                        if let selection = $0 { model.setSelection("textGenerationModelSelection", selection) }
                    }
                }
                SettingsRow(title: "Dictation cleanup model", help: "Cleans transcripts in Clean mode.",
                            onReset: model.settings.selection("speechPostProcessingModelSelection") == nil ? nil : { model.reset("speechPostProcessingModelSelection") }) {
                    ModelSelectionPicker(providers: model.providers, selection: model.settings.selection("speechPostProcessingModelSelection"),
                                         noneLabel: "Same as text generation") { model.setSelection("speechPostProcessingModelSelection", $0) }
                }
                ServerTextRow(model: model, key: "threadTitleInstructions", title: "Thread title instructions",
                              help: "Extra guidance for generated titles.", placeholder: "Optional", width: 260)
            }
            SettingsStatusLine(model: model)
        }
    }
}

struct ThreadsSettingsPage: View {
    let model: ServerSettingsModel

    private var autoSettle: Binding<Int> {
        Binding(get: { model.settings.values["sidebarAutoSettleAfterDays"] == .null ? 0 : (model.settings.int("sidebarAutoSettleAfterDays") ?? 7) },
                set: { model.set("sidebarAutoSettleAfterDays", $0 == 0 ? .null : .number($0)) })
    }

    var body: some View {
        SettingsPage(title: "Threads", subtitle: "Resolve, archive and limit behavior.") {
            SettingsSection(title: "Auto-resolve", footer: "Resolved threads leave the Active list. Reopen any time.") {
                SettingsRow(title: "Resolve idle threads after",
                            onReset: model.isDefault("sidebarAutoSettleAfterDays") ? nil : { model.reset("sidebarAutoSettleAfterDays") }) {
                    Picker("Resolve idle threads after", selection: autoSettle) {
                        Text("Never").tag(0)
                        ForEach([1, 2, 3, 7, 14, 30, 60, 90], id: \.self) { Text($0 == 1 ? "1 day" : "\($0) days").tag($0) }
                    }.labelsHidden().frame(width: 140)
                }
                ServerToggleRow(model: model, key: "sidebarAutoSettleOnMerge", title: "Resolve when the pull request merges")
                ServerToggleRow(model: model, key: "sidebarAutoSettleKeepPullRequests", title: "Keep threads with open pull requests")
            }
            SettingsSection(title: "Usage limits") {
                ServerToggleRow(model: model, key: "snoozeLimitedThreads", title: "Snooze limited threads",
                                help: "Pause a thread that hits a provider limit until it resets.")
                ServerToggleRow(model: model, key: "autoResumeLimitedThreads", title: "Resume automatically after a reset")
            }
            SettingsSection(title: "Context") {
                ServerChoiceRow(model: model, key: "idleCompaction", title: "Compact idle threads",
                                help: "When to compact a long idle thread.",
                                options: [("onReturn", "When you return"), ("beforeCacheExpires", "Before the cache expires (beta)"), ("off", "Never")])
            }
            SettingsStatusLine(model: model)
        }
    }
}

struct GitSettingsPage: View {
    let model: ServerSettingsModel

    private var fetchSeconds: Binding<Int> {
        Binding(get: { (model.settings.int("automaticGitFetchInterval") ?? 30_000) / 1000 },
                set: { model.set("automaticGitFetchInterval", .number($0 * 1000)) })
    }

    var body: some View {
        SettingsPage(title: "Git & worktrees", subtitle: "Where new threads run and how branches are named.") {
            SettingsSection(title: "New threads") {
                ServerChoiceRow(model: model, key: "defaultThreadEnvMode", title: "Default environment",
                                help: "Run in the project folder, or in a fresh worktree.",
                                options: [("local", "Local"), ("worktree", "New worktree")], unsetLabel: "Project default")
                ServerToggleRow(model: model, key: "newWorktreesStartFromOrigin", title: "Start worktrees from origin")
                ServerChoiceRow(model: model, key: "worktreeSubmodules", title: "Submodules",
                                options: [("recursive", "Recursive"), ("top-level", "Top level"), ("none", "None")],
                                unsetLabel: "Project default")
                ServerTextRow(model: model, key: "worktreesDirectory", title: "Worktrees folder",
                              help: "Leave empty for the default location.", placeholder: "Default", width: 260)
                ServerToggleRow(model: model, key: "fastWorktreeCheckout", title: "Fast worktree checkout (beta)",
                                help: "Clone worktrees from a cached checkout on macOS.")
            }
            SettingsSection(title: "Sync") {
                ServerToggleRow(model: model, key: "defaultAutoPull", title: "Pull before starting a thread")
                SettingsRow(title: "Fetch interval", help: "How often \(Product.name) fetches in the background.",
                            onReset: model.isDefault("automaticGitFetchInterval") ? nil : { model.reset("automaticGitFetchInterval") }) {
                    Picker("Fetch interval", selection: fetchSeconds) {
                        ForEach([15, 30, 60, 120, 300, 900], id: \.self) { Text($0 < 60 ? "\($0) seconds" : "\($0 / 60) min").tag($0) }
                    }.labelsHidden().frame(width: 140)
                }
            }
            SettingsSection(title: "Branches & pull requests") {
                ServerChoiceRow(model: model, key: "branchNamingMode", title: "Branch names",
                                options: [("static", "Static"), ("semantic", "Semantic"), ("custom", "Custom")])
                ServerTextRow(model: model, key: "branchNamePrefix", title: "Branch prefix", placeholder: "Engine default", width: 140)
                ServerTextRow(model: model, key: "branchNameInstructions", title: "Branch name instructions",
                              placeholder: "Optional", width: 260)
                ServerChoiceRow(model: model, key: "pullRequestMergeMethod", title: "Merge method",
                                options: [("merge", "Merge commit"), ("squash", "Squash"), ("rebase", "Rebase")],
                                unsetLabel: "Ask each time")
                ServerToggleRow(model: model, key: "removeAgentCreditsOnMerge", title: "Remove agent credits on merge")
            }
            SettingsSection(title: "Projects") {
                ServerTextRow(model: model, key: "addProjectBaseDirectory", title: "Clone folder",
                              help: "Where cloned repositories go.", placeholder: "Default", width: 260)
                ServerToggleRow(model: model, key: "ghqCloneLayout", title: "Use ghq layout",
                                help: "Clone into <folder>/<host>/<owner>/<repo>.")
            }
            SettingsStatusLine(model: model)
        }
    }
}

struct ShortcutsSettingsPage: View {
    private let rows: [(keys: String, action: String)] = [
        ("⌘⇧D", "Resolve the open thread"), ("⌘↵", "Approve the pending request"), ("⎋", "Collapse the notch"),
        ("⌘,", "Open Settings"), ("↵", "Send the reviewed voice command")
    ]

    var body: some View {
        SettingsPage(title: "Shortcuts", subtitle: "Global shortcuts for voice and dictation, and the notch’s own keys.") {
            SettingsSection(title: "In the notch") {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    SettingsRow(title: row.action, showsDivider: index < rows.count - 1) {
                        Text(row.keys).font(.system(size: 12, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 7).frame(height: 22)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
            HotkeySettingsView()
        }
    }
}
