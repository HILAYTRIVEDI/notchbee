import AppKit
import Carbon
import NotchpilotCore

enum DictationTargetError: LocalizedError {
    case secure, permission, unavailable, changed, clipboard, event

    var errorDescription: String? {
        switch self {
        case .secure: "Dictation is unavailable in password fields or while Secure Keyboard Entry is on."
        case .permission: "Allow \(Product.name) in Privacy & Security → Accessibility to check the focused field and insert text."
        case .unavailable: "Click a text field in another app and try dictation again."
        case .changed: "The focused field changed. Return to the original field or start a new dictation."
        case .clipboard: "\(Product.name) couldn't use the clipboard for this paste."
        case .event: "\(Product.name) couldn't send the paste shortcut."
        }
    }
}

@MainActor
struct FocusedDictationTarget {
    private let app: NSRunningApplication
    private let element: AXUIElement
    let role: String
    let context: DictationAppContext?
    var appName: String { app.localizedName ?? app.bundleIdentifier ?? "Unknown app" }

    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func capture(includeContext: Bool) throws -> Self {
        let (app, application, element, role) = try focusedField()
        let context: DictationAppContext?
        if includeContext {
            let window = axElement(attribute(kAXFocusedWindowAttribute, on: application))
            if let window { AXUIElementSetMessagingTimeout(window, 0.25) }
            let title = window.flatMap { attribute(kAXTitleAttribute, on: $0) as? String }
            let selectedText = attribute(kAXSelectedTextAttribute, on: element) as? String
            let selection = selectedRange(on: element)
            let isTextField = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
            let value = (selectedText?.isEmpty ?? true) && (isTextField || selection != nil)
                ? attribute(kAXValueAttribute, on: element) as? String : nil
            context = .init(
                appName: app.localizedName ?? app.bundleIdentifier ?? "Unknown app",
                windowTitle: title, selectedText: selectedText, fieldValue: value, selection: selection
            )
        } else {
            context = nil
        }
        let target = Self(app: app, element: element, role: role, context: context)
        try target.validate()
        return target
    }

    func validate() throws {
        let (currentApp, _, currentElement, _) = try Self.focusedField()
        guard currentApp.processIdentifier == app.processIdentifier, CFEqual(element, currentElement) else {
            throw DictationTargetError.changed
        }
    }

    func insert(_ text: String, paste: DictationPaste) async throws {
        try validate()
        let forcedApps = DictationSettings.pasteOverrideIDs(
            UserDefaults.standard.string(forKey: DictationSettings.pasteOverridesKey) ?? ""
        )
        if !forcedApps.contains(app.bundleIdentifier?.lowercased() ?? ""),
           AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
            return
        }
        try await paste.insert(text, using: SystemDictationPasteboard()) {
            try validate()
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
            else { throw DictationTargetError.event }
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.postToPid(app.processIdentifier)
            up.postToPid(app.processIdentifier)
        }
    }

    private static func focusedField() throws -> (NSRunningApplication, AXUIElement, AXUIElement, String) {
        if IsSecureEventInputEnabled() { throw DictationTargetError.secure }
        guard AXIsProcessTrusted() else { throw DictationTargetError.permission }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw DictationTargetError.unavailable
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        guard let element = axElement(attribute(kAXFocusedUIElementAttribute, on: application)) else {
            throw DictationTargetError.unavailable
        }
        AXUIElementSetMessagingTimeout(element, 0.25)
        guard let role = attribute(kAXRoleAttribute, on: element) as? String else {
            throw DictationTargetError.unavailable
        }
        if DictationSafety.isSecure(role: role, subrole: nil, secureEventInput: false) {
            throw DictationTargetError.secure
        }
        var subroleValue: CFTypeRef?
        let subroleStatus = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue)
        guard subroleStatus == .success || subroleStatus == .noValue || subroleStatus == .attributeUnsupported else {
            throw DictationTargetError.unavailable
        }
        let subrole = subroleValue as? String
        guard !DictationSafety.isSecure(role: role, subrole: subrole, secureEventInput: IsSecureEventInputEnabled()) else {
            throw DictationTargetError.secure
        }
        return (app, application, element, role)
    }

    private static func attribute(_ name: String, on element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func axElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func selectedRange(on element: AXUIElement) -> NSRange? {
        guard let value = attribute(kAXSelectedTextRangeAttribute, on: element),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}

@MainActor
private struct SystemDictationPasteboard: DictationPasteboard {
    private let board = NSPasteboard.general
    var changeCount: Int { board.changeCount }

    func snapshot() throws -> [[PasteboardRepresentation]] {
        let count = changeCount
        let snapshot = try (board.pasteboardItems ?? []).map { item in
            try item.types.map { type in
                guard let data = item.data(forType: type) else { throw DictationTargetError.clipboard }
                return PasteboardRepresentation(type: type.rawValue, data: data)
            }
        }
        guard changeCount == count else { throw DictationTargetError.clipboard }
        return snapshot
    }

    func writeText(_ text: String) throws {
        board.clearContents()
        guard board.setString(text, forType: .string) else { throw DictationTargetError.clipboard }
        // Mark the transcript as transient and concealed (nspasteboard.org) so clipboard managers and
        // Universal Clipboard skip it during the brief paste window.
        for marker in ["org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType",
                       "org.nspasteboard.AutoGeneratedType"] {
            board.setData(Data(), forType: .init(marker))
        }
    }

    func restore(_ snapshot: [[PasteboardRepresentation]]) throws {
        let items = try snapshot.map { entries in
            let item = NSPasteboardItem()
            for entry in entries {
                guard item.setData(entry.data, forType: .init(entry.type)) else { throw DictationTargetError.clipboard }
            }
            return item
        }
        board.clearContents()
        guard items.isEmpty || board.writeObjects(items) else { throw DictationTargetError.clipboard }
    }
}
