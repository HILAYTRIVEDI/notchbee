import AppKit
import NotchpilotCore
import SwiftUI

/// Design tokens mirrored from T3 Code's dark theme (apps/web index.css), scaled for the notch.
enum T3 {
    static let foreground = Color(white: 0.96)
    static let muted = Color(white: 0.64)
    static let faint = Color(white: 0.45)
    static let card = Color(white: 0.062)
    /// The user's message bubble: clearly lifted off the near-black panel.
    static let message = Color(white: 0.175)
    static let fill = Color.white.opacity(0.04)
    static let fillHover = Color.white.opacity(0.08)
    static let border = Color.white.opacity(0.08)
    static let borderStrong = Color.white.opacity(0.14)
    static let primary = Color(red: 0.30, green: 0.38, blue: 0.92)
    static let link = Color(red: 0.45, green: 0.66, blue: 0.99)
    static let success = Color(red: 0.20, green: 0.83, blue: 0.60)
    static let warning = Color(red: 0.98, green: 0.75, blue: 0.14)
    static let error = Color(red: 0.97, green: 0.47, blue: 0.47)

    // Type scale (points).
    static let body: CGFloat = 13
    static let small: CGFloat = 12
    static let caption: CGFloat = 11
    static let micro: CGFloat = 10

    static let radius: CGFloat = 8
    static let cardRadius: CGFloat = 12
}

/// A quiet rounded hover plate used by rows and icon buttons.
struct HoverPlate: ViewModifier {
    var radius: CGFloat = 7
    var resting: Color = .clear
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(hovering ? T3.fillHover : resting, in: RoundedRectangle(cornerRadius: radius))
            .contentShape(RoundedRectangle(cornerRadius: radius))
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverPlate(radius: CGFloat = 7, resting: Color = .clear) -> some View {
        modifier(HoverPlate(radius: radius, resting: resting))
    }
}

extension SyntaxHighlighter.Kind {
    var color: Color {
        switch self {
        case .plain: Color(white: 0.88)
        case .keyword: Color(red: 1.0, green: 0.48, blue: 0.45)
        case .string: Color(red: 0.65, green: 0.84, blue: 1.0)
        case .number: Color(red: 0.47, green: 0.75, blue: 1.0)
        case .comment: Color(white: 0.52)
        case .type: Color(red: 1.0, green: 0.65, blue: 0.34)
        case .function: Color(red: 0.82, green: 0.66, blue: 1.0)
        case .property: Color(red: 0.47, green: 0.75, blue: 1.0)
        case .tag: Color(red: 0.49, green: 0.91, blue: 0.53)
        case .attribute: Color(red: 0.47, green: 0.75, blue: 1.0)
        case .punctuation: Color(white: 0.68)
        case .variable: Color(red: 1.0, green: 0.65, blue: 0.34)
        case .addition: Color(red: 0.25, green: 0.73, blue: 0.31)
        case .deletion: Color(red: 0.97, green: 0.32, blue: 0.29)
        case .heading: Color(red: 0.47, green: 0.75, blue: 1.0)
        }
    }
}

/// Highlighted code as an `AttributedString`, cached per language and text so streaming and scrolling stay cheap.
@MainActor
enum CodeHighlighter {
    private final class Entry {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 300
        cache.totalCostLimit = 4_000_000
        return cache
    }()

    static func attributed(_ code: String, language: String?) -> AttributedString {
        let key = "\(SyntaxHighlighter.canonicalLanguage(language) ?? "")\u{0}\(code.hashValue)\u{0}\(code.utf8.count)" as NSString
        if let cached = cache.object(forKey: key) { return cached.value }
        var result = AttributedString()
        for token in SyntaxHighlighter.tokens(code, language: language) {
            var run = AttributedString(token.text)
            run.foregroundColor = token.kind.color
            result.append(run)
        }
        cache.setObject(Entry(result), forKey: key, cost: code.utf8.count * 4)
        return result
    }
}

/// Provider tints from T3's usage presentation (apps/web usageProviders.ts).
enum ProviderBrand {
    static func tint(driver: String, accent: String? = nil) -> Color {
        if let accent, let color = Color(hex: accent) { return color }
        switch driver {
        case "codex": return Color(white: 0.92)
        case "claudeAgent", "claude": return Color(red: 0.85, green: 0.46, blue: 0.34)
        case "grok": return Color(white: 0.7)
        case "cursor": return Color(white: 0.55)
        case "opencode": return Color(red: 0.36, green: 0.61, blue: 0.74)
        case "antigravity": return Color(red: 0.55, green: 0.48, blue: 0.82)
        case "pi": return Color(red: 0.30, green: 0.62, blue: 0.54)
        case "muse": return Color(red: 0.03, green: 0.40, blue: 1.0)
        default: return Color(white: 0.75)
        }
    }

    static func label(driver: String) -> String {
        switch driver {
        case "codex": "Codex"
        case "claudeAgent": "Claude"
        case "grok": "Grok Build"
        case "cursor": "Cursor"
        case "opencode": "OpenCode"
        case "antigravity": "Antigravity"
        case "pi": "Pi"
        case "muse": "Muse Code"
        case "kiro": "Kiro"
        case "fx": "FX"
        default: Product.displayText(driver.prefix(1).uppercased() + driver.dropFirst())
        }
    }

    static func driver(instanceID: String) -> String {
        let prefix = instanceID.split(whereSeparator: { $0 == "_" || $0 == "-" }).first.map(String.init)
        guard let prefix else { return instanceID }
        let driver = prefix.lowercased()
        return driver == "claude" || driver == "claudeagent" ? "claudeAgent" : driver
    }

    /// Display name for a provider *instance* id such as `claudeAgent`, `codex` or `codex_work`.
    static func label(instanceID: String) -> String {
        let known = ["codex", "claudeAgent", "claude", "grok", "cursor", "opencode", "antigravity", "pi", "muse", "kiro", "fx"]
        if known.contains(instanceID) { return label(driver: instanceID == "claude" ? "claudeAgent" : instanceID) }
        let prefix = instanceID.split(whereSeparator: { $0 == "_" || $0 == "-" }).first.map(String.init) ?? instanceID
        if known.contains(prefix) {
            let suffix = instanceID.dropFirst(prefix.count).drop { $0 == "_" || $0 == "-" }
            let base = label(driver: prefix == "claude" ? "claudeAgent" : prefix)
            return suffix.isEmpty ? base : "\(base) · \(Product.displayText(String(suffix)))"
        }
        return label(driver: instanceID)
    }

    static func symbol(driver: String) -> String {
        switch driver {
        case "codex": "chevron.left.forwardslash.chevron.right"
        case "claudeAgent": "sparkle"
        case "grok": "bolt.fill"
        case "cursor": "cursorarrow.rays"
        case "opencode": "curlybraces"
        case "antigravity": "arrow.up.forward.circle.fill"
        case "pi": "function"
        default: "cpu"
        }
    }
}

extension Color {
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

struct ProviderBadge: View {
    let driver: String
    var accent: String?
    var size: CGFloat = 30

    var body: some View {
        let tint = ProviderBrand.tint(driver: driver, accent: accent)
        Image(systemName: ProviderBrand.symbol(driver: driver))
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.28))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28).strokeBorder(tint.opacity(0.28), lineWidth: 1))
    }
}

/// Shows the pointing-hand cursor over a clickable area. The notch panel never becomes key, so the cursor-rect
/// based `pointerStyle` alone is not enough; the hover push/pop covers the non-key case.
private struct ClickableCursor: ViewModifier {
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .pointerStyle(.link)
            .onHover { inside in
                if inside, !pushed { NSCursor.pointingHand.push(); pushed = true }
                else if !inside, pushed { NSCursor.pop(); pushed = false }
            }
            .onDisappear { if pushed { NSCursor.pop(); pushed = false } }
    }
}

extension View {
    func clickableCursor() -> some View { modifier(ClickableCursor()) }
}
