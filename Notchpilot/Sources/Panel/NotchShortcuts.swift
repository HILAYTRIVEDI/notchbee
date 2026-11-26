import Carbon

/// Carbon hotkeys work without making the panel key or requesting Input Monitoring.
@MainActor
final class NotchShortcuts {
    enum Scope {
        case none, panel, approval, voice, voiceReview
    }
    private static let signature: OSType = 0x4E544348 // NTCH
    private var handler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private var pressedKeys: Set<UInt32> = []
    private var scope: Scope = .none
    private let currentScope: () -> Scope
    private let escape: () -> Void
    private let approve: () -> Void
    private let settings: () -> Void
    private let sendVoice: () -> Void
    private let resolve: () -> Void

    init(
        currentScope: @escaping () -> Scope, escape: @escaping () -> Void,
        approve: @escaping () -> Void, sendVoice: @escaping () -> Void, settings: @escaping () -> Void,
        resolve: @escaping () -> Void
    ) {
        self.resolve = resolve
        self.currentScope = currentScope
        self.escape = escape
        self.approve = approve
        self.settings = settings
        self.sendVoice = sendVoice
    }

    func setScope(_ scope: Scope) {
        guard scope != self.scope else { return }
        self.scope = scope
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
        pressedKeys.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        guard scope != .none else { return }

        let eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let target = GetApplicationEventTarget()
        let result = InstallEventHandler(target, { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let shortcuts = Unmanaged<NotchShortcuts>.fromOpaque(context).takeUnretainedValue()
            return MainActor.assumeIsolated { shortcuts.handle(event) }
        }, eventTypes.count, eventTypes, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { return }

        register(key: UInt32(kVK_Escape), modifiers: 0, id: 2, target: target)
        register(key: UInt32(kVK_ANSI_Comma), modifiers: UInt32(cmdKey), id: 6, target: target)
        if scope == .panel || scope == .approval {
            register(key: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey | shiftKey), id: 7, target: target)
        }
        if scope == .approval {
            register(key: UInt32(kVK_Return), modifiers: UInt32(cmdKey), id: 1, target: target)
            register(key: UInt32(kVK_ANSI_KeypadEnter), modifiers: UInt32(cmdKey), id: 3, target: target)
        } else if scope == .voiceReview {
            register(key: UInt32(kVK_Return), modifiers: 0, id: 4, target: target)
            register(key: UInt32(kVK_ANSI_KeypadEnter), modifiers: 0, id: 5, target: target)
        }
    }

    private func register(key: UInt32, modifiers: UInt32, id: UInt32, target: EventTargetRef?) {
        var hotKey: EventHotKeyRef?
        let keyID = EventHotKeyID(signature: Self.signature, id: id)
        if RegisterEventHotKey(key, modifiers, keyID, target, 0, &hotKey) == noErr, let hotKey {
            hotKeys.append(hotKey)
        }
    }

    private func handle(_ event: EventRef) -> OSStatus {
        guard scope != .none, scope == currentScope() else { return OSStatus(eventNotHandledErr) }
        var keyID = EventHotKeyID()
        let result = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &keyID
        )
        guard result == noErr, keyID.signature == Self.signature else { return OSStatus(eventNotHandledErr) }
        if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
            pressedKeys.remove(keyID.id)
        } else if pressedKeys.insert(keyID.id).inserted {
            switch keyID.id {
            case 6: settings()
            case 7: resolve()
            case 2: escape()
            case 4, 5: sendVoice()
            default: approve()
            }
        }
        return noErr
    }
}
