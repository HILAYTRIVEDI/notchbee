import KeyboardShortcuts
import NotchpilotCore
import SwiftUI
import UniformTypeIdentifiers

extension KeyboardShortcuts.Name {
    static let anywhereDictation = Self(
        "anywhereDictation", initial: .init(.j, modifiers: [.control, .command])
    )
    static let cleanDictation = Self("cleanDictation")
    static let agentDictation = Self("agentDictation")
}

enum DictationSettings {
    static let pasteOverridesKey = "dictationPasteOverrides"

    static func pasteOverrideIDs(_ value: String) -> Set<String> {
        Set(value.split { $0.isWhitespace || $0 == "," }.map { $0.lowercased() })
    }

    static func shortcut(_ base: KeyboardShortcuts.Shortcut, for mode: DictationMode) -> KeyboardShortcuts.Shortcut {
        let extra: NSEvent.ModifierFlags = switch mode {
        case .raw: []
        case .clean: .shift
        case .agent: .option
        }
        let extraModifiers = KeyboardShortcuts.Shortcut(.j, modifiers: extra).carbonModifiers
        return .init(carbonKeyCode: base.carbonKeyCode, carbonModifiers: base.carbonModifiers | extraModifiers)
    }

    @MainActor
    static func updateShortcuts(_ base: KeyboardShortcuts.Shortcut?) {
        KeyboardShortcuts.setShortcut(base.map { shortcut($0, for: .clean) }, for: .cleanDictation)
        KeyboardShortcuts.setShortcut(base.map { shortcut($0, for: .agent) }, for: .agentDictation)
    }
}

struct HotkeySettingsView: View {
    @AppStorage(DictationSettings.pasteOverridesKey) private var pasteOverrides = ""
    @State private var showsAppPickerError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Global",
                            footer: "Hold to dictate in Raw mode. Add Shift for Clean or Option for Agent. Clean sends the transcript to the agent for cleanup. Agent lets you review the transcript and app context before sending.") {
                SettingsRow(title: "Voice commands") {
                    KeyboardShortcuts.Recorder(for: .pushToTalk)
                        .shortcutValidation { proposed in
                            if let base = KeyboardShortcuts.getShortcut(for: .anywhereDictation),
                               DictationMode.allCases.contains(where: { DictationSettings.shortcut(base, for: $0) == proposed }) {
                                return .disallow(reason: "This shortcut is used for dictation.")
                            }
                            return .allow
                        }
                }
                SettingsRow(title: "Dictation anywhere") {
                    KeyboardShortcuts.Recorder(for: .anywhereDictation) { shortcut in
                        DictationSettings.updateShortcuts(shortcut)
                    }
                    .shortcutValidation { proposed in
                        guard proposed.modifiers.intersection([.shift, .option]).isEmpty else {
                            return .disallow(reason: "Choose a base shortcut without Shift or Option.")
                        }
                        if let voice = KeyboardShortcuts.getShortcut(for: .pushToTalk),
                           DictationMode.allCases.contains(where: { DictationSettings.shortcut(proposed, for: $0) == voice }) {
                            return .disallow(reason: "One of the dictation modes conflicts with the voice command shortcut.")
                        }
                        return .allow
                    }
                }
                SettingsRow(title: "Accessibility",
                            help: "Lets \(Product.name) check for password fields and insert into the focused app. Agent dictation (Option) also sends that field's nearby text and the window title to your selected provider.",
                            showsDivider: false) {
                    Button("Allow Accessibility…", action: FocusedDictationTarget.requestAccessibility)
                }
            }
            SettingsSection(title: "Always paste in these apps", footer: "Enter app bundle identifiers, one per line.") {
                TextEditor(text: $pasteOverrides)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(height: 88)
                    .padding(8)
                    .accessibilityLabel("Bundle identifiers for apps that always use paste")
                SettingsRow(title: showsAppPickerError ? "The app has no bundle identifier." : "Add an app by choosing it", showsDivider: false) {
                    Button("Add App…", action: addApp)
                }
            }
        }
    }

    private func addApp() {
        let picker = NSOpenPanel()
        picker.directoryURL = URL(filePath: "/Applications")
        picker.allowedContentTypes = [.application]
        picker.canChooseDirectories = false
        guard picker.runModal() == .OK, let url = picker.url else { return }
        guard let id = Bundle(url: url)?.bundleIdentifier else {
            showsAppPickerError = true
            return
        }
        showsAppPickerError = false
        var ids = DictationSettings.pasteOverrideIDs(pasteOverrides)
        ids.insert(id.lowercased())
        pasteOverrides = ids.sorted().joined(separator: "\n")
    }
}
