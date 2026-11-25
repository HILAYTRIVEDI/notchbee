import AppKit
import NotchpilotCore
import SwiftUI

/// AppKit handles marked text and mouse focus before the panel temporarily takes key status.
struct PanelComposer: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let multiline: Bool
    var reference: ComposerEditorReference? = nil
    /// Reports first-responder changes so the surface can draw a focus ring.
    var focused: Binding<Bool>? = nil
    /// Reports the height the text needs, for auto-growing composers.
    var contentHeight: Binding<CGFloat>? = nil
    var leadingInset: CGFloat = 7
    var verticalInset: CGFloat = 6
    var fontSize: CGFloat = 13
    /// Off when SwiftUI draws its own (animated) placeholder over the editor.
    var drawsPlaceholder = true
    /// Lets an open suggestion menu take arrow, Return, Tab and Escape before the editor does.
    var commandKeys: ((PanelTextView.CommandKey) -> Bool)? = nil
    let submit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = multiline
        scroll.autohidesScrollers = true

        let editor = PanelTextView(frame: .zero)
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: leadingInset, height: verticalInset)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.drawsBackground = false
        editor.string = text
        editor.font = .systemFont(ofSize: fontSize)
        editor.setAccessibilityLabel(placeholder)
        editor.delegate = context.coordinator
        context.coordinator.editor = editor
        editor.onFocusChange = { [weak coordinator = context.coordinator] isFocused in coordinator?.focusChanged(isFocused) }
        editor.onContentChange = { [weak coordinator = context.coordinator] in coordinator?.reportHeight() }
        scroll.documentView = editor
        reference?.editor = editor
        context.coordinator.reportHeight()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? PanelTextView else { return }
        context.coordinator.text = $text
        context.coordinator.focused = focused
        context.coordinator.contentHeight = contentHeight
        if !editor.isDictating, editor.string != text { editor.string = text }
        context.coordinator.reportHeight()
        editor.submit = submit
        editor.commandKeys = commandKeys
        editor.multiline = multiline
        editor.setAccessibilityLabel(placeholder)
        editor.placeholder = drawsPlaceholder ? placeholder : ""
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let editor = scroll.documentView as? PanelTextView,
              let panel = editor.window as? NotchPanel, panel.firstResponder === editor else { return }
        panel.endEditing()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var focused: Binding<Bool>?
        var contentHeight: Binding<CGFloat>?
        weak var editor: PanelTextView?

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? PanelTextView, !editor.isDictating else { return }
            text.wrappedValue = editor.string
        }

        func focusChanged(_ isFocused: Bool) {
            guard let focused, focused.wrappedValue != isFocused else { return }
            DispatchQueue.main.async { focused.wrappedValue = isFocused }
        }

        @MainActor func reportHeight() {
            guard let contentHeight, let editor else { return }
            let height = editor.contentHeight()
            guard abs(contentHeight.wrappedValue - height) >= 1 else { return }
            DispatchQueue.main.async { contentHeight.wrappedValue = height }
        }
    }
}

@MainActor
final class ComposerEditorReference {
    weak var editor: PanelTextView?
    /// Send once the transcript is final: set by Send or Return while dictating.
    var sendWhenDictationEnds = false
}

struct PromptComposer: View {
    @Binding var text: String
    let placeholder: String
    /// When there is more than one, the empty field cycles through them as examples.
    var placeholders: [String] = []
    let enabled: Bool
    let busy: Bool
    /// What the send button does, for VoiceOver and the tooltip ("Send", "Create thread").
    let button: String
    let voice: VoiceController
    var validatesOnSubmit = false
    var focusRequest: UUID?
    /// Provider slash commands and skills offered when the draft starts with `/`.
    var commands: [ComposerCommand] = []
    var stop: (() -> Void)?
    let submit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var highlighted = 0
    /// The draft whose menu Escape closed; typing reopens it.
    @State private var dismissedDraft: String?

    @State private var owner = UUID()
    @State private var reference = ComposerEditorReference()
    @State private var focused = false
    @State private var contentHeight: CGFloat = Self.minHeight
    @State private var hint = 0

    /// 14pt text with 12pt of padding on every side; one line is about 41pt.
    private static let inset = CGSize(width: 12, height: 12)
    private static let minHeight: CGFloat = 42
    private static let maxHeight: CGFloat = 150
    static let buttonSize: CGFloat = 34

    private var status: ComposerDictation.Status? {
        guard let status = voice.dictation.status, status.owner == owner else { return nil }
        return status
    }

    private var hints: [String] { placeholders.isEmpty ? [placeholder] : placeholders }

    private var commandQuery: String? {
        guard !commands.isEmpty, text != dismissedDraft else { return nil }
        return ComposerCommand.query(in: text)
    }

    private var commandMatches: [ComposerCommand] {
        commandQuery.map { ComposerCommand.filter(commands, query: $0) } ?? []
    }

    private func handleCommandKey(_ key: PanelTextView.CommandKey) -> Bool {
        let matches = commandMatches
        guard !matches.isEmpty else { return false }
        let current = min(highlighted, matches.count - 1)
        switch key {
        case .up: highlighted = (current - 1 + matches.count) % matches.count
        case .down: highlighted = (current + 1) % matches.count
        case .accept: accept(matches[current])
        case .dismiss: dismissedDraft = text
        }
        return true
    }

    private func accept(_ command: ComposerCommand) {
        text = command.insertion
        highlighted = 0
        dismissedDraft = nil
        if let editor = reference.editor {
            editor.string = command.insertion
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.window?.makeFirstResponder(editor)
        }
    }

    @ViewBuilder
    private var commandMenu: some View {
        let matches = commandMatches
        if !matches.isEmpty {
            ComposerCommandMenu(matches: matches, highlighted: $highlighted, accept: accept)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    var body: some View {
        let active = voice.dictation.isActive
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canSend = enabled && !busy && !active && (validatesOnSubmit || hasText)
        let running = stop != nil
        // While listening, Send stops dictation and sends the finished transcript in one step.
        let canSendSpeech = enabled && !busy && status?.phase == .recording
        let height = min(Self.maxHeight, max(Self.minHeight, contentHeight))
        let commandKeys: ((PanelTextView.CommandKey) -> Bool)? = commands.isEmpty ? nil : { handleCommandKey($0) }
        VStack(alignment: .leading, spacing: 6) {
            if let status {
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.message)
                        .font(.system(size: T3.caption))
                        .foregroundStyle(status.phase == .failed ? T3.error : T3.muted)
                    if let progress = status.progress {
                        ProgressView(value: progress).accessibilityLabel(status.message)
                    }
                }
                .padding(.horizontal, 4)
            }
            commandMenu
            HStack(alignment: .bottom, spacing: 8) {
                PanelComposer(text: $text, placeholder: hints[hint % hints.count], multiline: true, reference: reference,
                              focused: $focused, contentHeight: $contentHeight,
                              leadingInset: Self.inset.width, verticalInset: Self.inset.height, fontSize: 14,
                              drawsPlaceholder: false, commandKeys: commandKeys) {
                    if canSend { submit() } else if canSendSpeech { sendSpeech() }
                }
                .frame(height: height)
                .overlay(alignment: .topLeading) { placeholderView(visible: text.isEmpty && !active) }
                .inputSurface(focused: focused, radius: 14)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: height)

                ComposerCircleButton(kind: .mic(recording: status?.phase == .recording, active: active),
                                     enabled: !busy && status?.phase != .finishing,
                                     help: active ? "Stop dictation (Esc)" : "Dictate",
                                     action: toggleDictation)
                .padding(.bottom, (Self.minHeight - Self.buttonSize) / 2)

                if running, canSend || canSendSpeech, hasText || canSendSpeech {
                    ComposerCircleButton(kind: .send(busy: false), enabled: true,
                                         help: canSendSpeech ? "Stop listening and send (Return)" : "Send follow-up",
                                         action: canSendSpeech ? sendSpeech : submit)
                        .padding(.bottom, (Self.minHeight - Self.buttonSize) / 2)
                        .transition(.scale.combined(with: .opacity))
                }
                ComposerCircleButton(kind: running ? .stop : .send(busy: busy),
                                     enabled: running ? enabled && !busy : canSend || canSendSpeech,
                                     help: running ? "Stop" : canSendSpeech ? "Stop listening and \(button.lowercased()) (Return)"
                                         : "\(button) (Return)",
                                     action: stop ?? (canSendSpeech ? sendSpeech : submit))
                .padding(.bottom, (Self.minHeight - Self.buttonSize) / 2)
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.25), value: running)
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.25), value: canSend)
        }
        .padding(.top, 6)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: commandQuery)
        .onChange(of: commandQuery) { _, _ in highlighted = 0 }
        .task(id: focusRequest) {
            guard focusRequest != nil else { return }
            // Wait for the composer to enter the window before transferring first responder.
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let editor = reference.editor else { return }
            editor.window?.makeFirstResponder(editor)
        }
        .task(id: text.isEmpty && hints.count > 1) {
            guard text.isEmpty, hints.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3.2))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.45)) { hint += 1 }
            }
        }
        .onDisappear { voice.cancelDictation(owner: owner) }
    }

    @ViewBuilder
    private func placeholderView(visible: Bool) -> some View {
        if visible {
            // NSTextView adds 5pt of line-fragment padding inside its inset.
            Text(verbatim: hints[hint % hints.count])
                .font(.system(size: 14))
                .foregroundStyle(T3.faint)
                .lineLimit(1)
                .id(hint % hints.count)
                .transition(reduceMotion ? .opacity
                            : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                          removal: .move(edge: .top).combined(with: .opacity)))
                .padding(.leading, Self.inset.width + 5)
                .padding(.top, Self.inset.height - 0.5)
                .padding(.trailing, 12)
                .frame(maxWidth: .infinity, maxHeight: Self.minHeight, alignment: .topLeading)
                .clipped()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func sendSpeech() {
        reference.sendWhenDictationEnds = true
        voice.stopDictation()
    }

    private func toggleDictation() {
        if voice.dictation.isActive {
            voice.stopDictation()
        } else if let editor = reference.editor {
            let draft = $text
            let reference = reference
            let submit = submit
            let validates = validatesOnSubmit
            let voice = voice
            reference.sendWhenDictationEnds = false
            voice.startDictation(owner: owner, begin: {
                editor.beginDictation()
            }, partial: { [weak editor] transcript in
                editor?.previewDictation(transcript)
            }, finish: {
                editor.finishDictation()
                if draft.wrappedValue != editor.string { draft.wrappedValue = editor.string }
                guard reference.sendWhenDictationEnds else { return }
                reference.sendWhenDictationEnds = false
                // Let the draft binding settle; skip if dictation failed or the composer went away.
                DispatchQueue.main.async {
                    guard voice.dictation.status?.phase != .failed, editor.window != nil,
                          validates || !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    submit()
                }
            })
        }
    }
}

/// The composer's `/` menu: a scrolling list that keeps the highlighted row visible.
struct ComposerCommandMenu: View {
    let matches: [ComposerCommand]
    @Binding var highlighted: Int
    let accept: (ComposerCommand) -> Void

    private var current: Int { min(highlighted, matches.count - 1) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(matches.indices, id: \.self) { index in
                        row(index)
                    }
                }
                .padding(4)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 186)
            .fixedSize(horizontal: false, vertical: true)
            .background(T3.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(T3.border, lineWidth: 1))
            .onChange(of: current) { _, row in
                if matches.indices.contains(row) { proxy.scrollTo(row) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commands and skills")
    }

    private func row(_ index: Int) -> some View {
        let command = matches[index]
        return ComposerCommandRow(command: command, highlighted: index == current) { accept(command) }
            .id(index)
            .onHover { hovering in if hovering { highlighted = index } }
    }
}

/// One row of the composer's `/` menu.
struct ComposerCommandRow: View {
    let command: ComposerCommand
    let highlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: command.kind == .skill ? "wand.and.stars" : "command")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(T3.link.opacity(0.85))
                    .frame(width: 16)
                Text(command.label)
                    .font(.system(size: T3.small, weight: .semibold, design: .monospaced))
                    .foregroundStyle(T3.foreground)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let hint = command.inputHint {
                    Text(hint)
                        .font(.system(size: T3.small, design: .monospaced))
                        .foregroundStyle(T3.faint)
                        .lineLimit(1)
                }
                if let detail = command.detail {
                    Text(detail)
                        .font(.system(size: T3.small))
                        .foregroundStyle(T3.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                if command.kind == .skill {
                    Text("Skill")
                        .font(.system(size: T3.micro, weight: .medium))
                        .foregroundStyle(T3.faint)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(highlighted ? T3.fillHover : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .accessibilityLabel([command.label, command.detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}

/// The composer's round buttons: a quiet mic, a luminous send, and a red stop.
struct ComposerCircleButton: View {
    enum Kind: Equatable {
        case mic(recording: Bool, active: Bool)
        case send(busy: Bool)
        case stop
    }

    let kind: Kind
    let enabled: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var size: CGFloat { PromptComposer.buttonSize }

    var body: some View {
        Button(action: action) {
            ZStack {
                background
                glyph
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .scaleEffect(hovering && enabled && !reduceMotion ? 1.06 : 1)
            .opacity(enabled ? 1 : 0.9)
        }
        .buttonStyle(PressableStyle())
        .clickableCursor()
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch kind {
        case .mic(_, let active): active ? "Stop dictation" : "Dictate prompt"
        case .send(let busy): busy ? "Working" : help
        case .stop: "Stop"
        }
    }

    @ViewBuilder private var background: some View {
        switch kind {
        case .mic(let recording, _):
            Circle().fill(recording ? T3.error.opacity(0.18) : (hovering && enabled ? T3.fillHover : T3.fill))
                .overlay(Circle().strokeBorder(recording ? T3.error.opacity(0.5) : (hovering ? T3.borderStrong : T3.border),
                                               lineWidth: 1))
        case .send:
            if enabled {
                Circle()
                    .fill(T3.primary)
                    .brightness(hovering ? 0.06 : 0)
            } else {
                Circle().fill(T3.fill).overlay(Circle().strokeBorder(T3.border, lineWidth: 1))
            }
        case .stop:
            Circle().fill(T3.error.opacity(hovering ? 0.30 : 0.20))
                .overlay(Circle().strokeBorder(T3.error.opacity(0.5), lineWidth: 1))
        }
    }

    @ViewBuilder private var glyph: some View {
        switch kind {
        case .mic(let recording, let active):
            Image(systemName: recording ? "waveform" : active ? "stop.fill" : "mic.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(recording ? T3.error : T3.foreground.opacity(0.9))
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: recording && !reduceMotion)
                .contentTransition(.symbolEffect(.replace))
        case .send(let busy):
            if busy {
                ActivitySpinner(size: 14, color: .white)
            } else {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .rotationEffect(.degrees(45))
                    .offset(x: -1, y: 0.5)
                    .foregroundStyle(enabled ? Color.white : T3.faint)
            }
        case .stop:
            RoundedRectangle(cornerRadius: 2.5).fill(T3.error).frame(width: 10, height: 10)
        }
    }
}

/// Dips slightly while pressed.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

final class PanelTextView: NSTextView {
    enum CommandKey { case up, down, accept, dismiss }

    var submit: () -> Void = {}
    var commandKeys: ((CommandKey) -> Bool)?
    var multiline = false
    var placeholder = "" { didSet { if oldValue != placeholder { needsDisplay = true } } }
    private var hasFocused = false
    private var dictationRange: NSRange?
    private var dictationBefore: Character?
    private var dictationAfter: Character?
    var isDictating: Bool { dictationRange != nil }
    var onFocusChange: ((Bool) -> Void)?
    var onContentChange: (() -> Void)?

    /// The height the current text needs, including the vertical inset.
    func contentHeight() -> CGFloat {
        guard let layoutManager, let container = textContainer else { return 0 }
        layoutManager.ensureLayout(for: container)
        return ceil(layoutManager.usedRect(for: container).height + 2 * textContainerInset.height)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        hasFocused = true
        (window as? NotchPanel)?.beginEditing(self)
        onFocusChange?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        (window as? NotchPanel)?.editorResigned(self)
        onFocusChange?(false)
        return true
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
        onContentChange?()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard !multiline, let text = string as? String ?? (string as? NSAttributedString)?.string,
              text.contains(where: \.isNewline) else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        super.insertText(Self.singleLine(text), replacementRange: replacementRange)
    }

    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            (placeholder as NSString).draw(
                at: NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0),
                            y: textContainerOrigin.y),
                withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor]
            )
        }
    }

    override func keyDown(with event: NSEvent) {
        if let commandKeys, !hasMarkedText(),
           event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty {
            let key: CommandKey? = switch event.keyCode {
            case 126: .up
            case 125: .down
            case 36, 76, 48: .accept
            case 53: .dismiss
            default: nil
            }
            if let key, commandKeys(key) { return }
        }
        if [36, 76].contains(event.keyCode), !hasMarkedText() {
            let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
            if modifiers == .shift, multiline {
                insertNewline(nil)
            } else if modifiers.isEmpty {
                submit()
            }
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        if multiline {
            pasteAsPlainText(sender)
        } else if let text = NSPasteboard.general.string(forType: .string) {
            insertText(Self.singleLine(text), replacementRange: selectedRange())
        }
    }

    func beginDictation() {
        if hasMarkedText() { unmarkText() }
        let end = string.utf16.count
        let position = hasFocused ? min(NSMaxRange(selectedRange()), end) : end
        let draft = string as NSString
        dictationBefore = draft.substring(to: position).last
        dictationAfter = draft.substring(from: position).first
        dictationRange = NSRange(location: position, length: 0)
        isEditable = false
    }

    func previewDictation(_ transcript: String) {
        guard let range = dictationRange else { return }
        var insertion = transcript
        if !insertion.isEmpty {
            if let before = dictationBefore, !before.isWhitespace {
                insertion = " " + insertion
            }
            if let after = dictationAfter, !after.isWhitespace, !after.isPunctuation {
                insertion += " "
            }
        }
        guard (string as NSString).substring(with: range) != insertion else { return }
        // A bare string takes the storage's default attributes (black, default font) when the box is empty.
        var attributes = typingAttributes
        attributes[.font] = attributes[.font] ?? font ?? NSFont.systemFont(ofSize: 14)
        attributes[.foregroundColor] = textColor ?? NSColor.labelColor
        textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: insertion, attributes: attributes))
        let updated = NSRange(location: range.location, length: insertion.utf16.count)
        dictationRange = updated
        let cursor = NSRange(location: NSMaxRange(updated), length: 0)
        setSelectedRange(cursor)
        scrollRangeToVisible(cursor)
        needsDisplay = true
        onContentChange?()
    }

    func finishDictation() {
        guard let range = dictationRange else { return }
        let transcript = (string as NSString).substring(with: range)
        textStorage?.replaceCharacters(in: range, with: "")
        dictationRange = nil
        isEditable = true
        if !transcript.isEmpty {
            // Register the final transcript as one normal, undoable edit.
            breakUndoCoalescing()
            insertText(transcript, replacementRange: NSRange(location: range.location, length: 0))
            breakUndoCoalescing()
        }
        needsDisplay = true
    }
}

extension View {
    /// T3's input surface: a card fill with a hairline border that turns primary, with a soft outer ring, on focus.
    func inputSurface(focused: Bool, radius: CGFloat = 8) -> some View {
        background(T3.card, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(focused ? T3.primary : T3.border, lineWidth: 1))
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: radius + 1).strokeBorder(T3.primary.opacity(0.25), lineWidth: 2)
                        .padding(-2)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// A single-line (or fixed-height) editor with the focus ring, an optional leading search icon and a clear button.
struct FocusedEditor: View {
    @Binding var text: String
    let placeholder: String
    var multiline = false
    var searchStyle = false
    let submit: () -> Void
    @State private var focused = false

    var body: some View {
        PanelComposer(text: $text, placeholder: placeholder, multiline: multiline, focused: $focused,
                      leadingInset: searchStyle ? 26 : 7, submit: submit)
            .frame(height: multiline ? 56 : 28)
            .inputSurface(focused: focused)
            .overlay(alignment: .leading) {
                if searchStyle {
                    Image(systemName: "magnifyingglass").font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(T3.muted).padding(.leading, 9).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .trailing) {
                if searchStyle, !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(T3.muted)
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).clickableCursor().padding(.trailing, 4)
                    .accessibilityLabel("Clear search")
                }
            }
    }
}
