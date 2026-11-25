import Foundation

public struct ProviderOption: Decodable, Sendable, Identifiable {
    public struct Choice: Decodable, Sendable, Identifiable {
        public let id: String
        public let label: String
        public let isDefault: Bool?
    }
    public let id: String
    public let label: String
    public let type: String
    public let currentValue: ThreadModelSelection.Option.Value?
    public let options: [Choice]?
}

public struct ProviderSDK: Decodable, Sendable {
    public let driver: String
    public let packageName: String
    public let version: String
    public let vendor: String
    public let terms: URL
    public let installed: Bool
}

public struct ProviderSettings: Sendable, Identifiable {
    public struct Model: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let options: [ProviderOption]
    }
    public let id: String
    public let name: String
    public let driver: String
    public let enabled: Bool
    public let installed: Bool
    public var auth: String
    public let models: [Model]
    public let defaultModel: String?
    public let canInstall: Bool
    public let documentationURL: String?
    public var displayName: String?
    public var accentColor: String?
    public var version: String?
    public var latestVersion: String?
    public var updateAvailable = false
    public var canUpdate = false
    public var updateStatus: String?
    public var updateMessage: String?
    public var authType: String?
    public var authLabel: String?
    public var authEmail: String?
    public var checkedAt: Date?
    public var statusMessage: String?
    public var usage: ProviderUsageLimits?
    /// The instance's raw `config` object, so unknown fields survive an edit.
    public var config: [String: WireValue] = [:]
    public var homePath: String?
    public var shadowHomePath: String?
    public var sdk: ProviderSDK?
    public var sdkRequired: Bool { sdk?.installed == false }
    public static func secretVariable(for driver: String) -> String? {
        switch driver {
        case "claudeAgent": "ANTHROPIC_API_KEY"
        case "cursor": "CURSOR_API_KEY"
        case "kiro": "KIRO_API_KEY"
        case "muse": "META_API_KEY"
        case "grok": "XAI_API_KEY"
        default: nil
        }
    }
    /// "Authenticated · ChatGPT Plus Subscription", "Signed out", …
    public var authLine: String {
        if sdkRequired { return "SDK download required" }
        switch auth {
        case "authenticated":
            let detail = authLabel ?? authType.map { $0.prefix(1).uppercased() + $0.dropFirst() }
            return ["Authenticated", detail].compactMap { $0 }.joined(separator: " · ")
        case "unauthenticated": return "Not signed in"
        default: return installed ? "Sign-in status unknown" : "Not installed"
        }
    }

    public var acceptsAPIKey: Bool { driver == "antigravity" || Self.secretVariable(for: driver) != nil }
    public var installCommand: String? {
        switch driver {
        case "codex": "npm install -g @openai/codex"
        case "claudeAgent": "npm install -g @anthropic-ai/claude-code"
        case "opencode": "npm install -g opencode-ai"
        case "cursor": "curl https://cursor.com/install -fsS | bash"
        case "kiro": "curl -fsSL https://cli.kiro.dev/install | bash"
        case "pi": "npm install -g --ignore-scripts @earendil-works/pi-coding-agent"
        case "fx": "curl -fsSL https://fx.sh/setup.sh | bash"
        case "muse": "open https://dev.meta.ai/docs/muse-code"
        case "grok": "open https://x.ai/cli"
        default: nil
        }
    }
    public var loginCommand: String? {
        switch driver {
        case "codex": "codex login"
        case "claudeAgent": "claude auth login"
        case "opencode": "opencode auth login"
        case "kiro": "kiro-cli login"
        case "cursor": "agent login"
        case "grok", "fx", "muse": driver + " login"
        case "pi": "pi"
        default: nil
        }
    }
}

/// An editable runtime field of a provider instance, mirroring the provider settings form in T3 Code.
public struct ProviderField: Identifiable, Sendable, Equatable {
    public enum Control: Sendable, Equatable { case text, choice([String: String]) }
    public let key: String
    public let title: String
    public let placeholder: String
    public let help: String
    public let control: Control
    public var id: String { key }

    static func text(_ key: String, _ title: String, _ placeholder: String, _ help: String) -> Self {
        .init(key: key, title: title, placeholder: placeholder, help: help, control: .text)
    }

    /// Per-driver fields from `packages/contracts` (`CodexSettings`, `ClaudeSettings`, …), minus hidden ones.
    public static func fields(forDriver driver: String) -> [ProviderField] {
        switch driver {
        case "codex":
            [.text("binaryPath", "Binary path", "codex", "Path to the Codex binary used by this instance."),
             .text("homePath", "CODEX_HOME path", "~/.codex", "Custom Codex home and config directory."),
             .text("shadowHomePath", "Shadow home path", "~/codex-accounts/personal",
                   "Account-specific Codex home. Keeps auth.json separate while sharing state from CODEX_HOME."),
             .text("launchArgs", "Launch arguments", "", "Additional CLI arguments passed to codex app-server on session start.")]
        case "claudeAgent":
            [.text("binaryPath", "Binary path", "claude", "Path to the Claude binary used by this instance."),
             .text("homePath", "CLAUDE_CONFIG_DIR path", "~/.claude",
                   "Custom Claude home and config directory. Keeps .claude.json and .claude separate."),
             .text("autoCompactWindow", "Auto-compact after", "e.g. 300000",
                   "Compact after 100,000 to 1,000,000 tokens. Leave empty to use Claude's default."),
             .init(key: "idleCompaction", title: "Compact idle threads", placeholder: "", help:
                   "When to compact an idle thread over 200,000 tokens: after you return, just before its prompt cache expires, or never.",
                   control: .choice(["default": "Use default", "onReturn": "When you return",
                                     "beforeCacheExpires": "Before the cache expires (beta)", "off": "Never"])),
             .text("launchArgs", "Launch arguments", "e.g. --chrome", "Additional CLI arguments passed on session start.")]
        case "antigravity":
            [.init(key: "authMethod", title: "Sign-in method", placeholder: "", help: "How Antigravity signs in.",
                   control: .choice(["oauth-personal": "Google account", "oauth-business": "Gemini Enterprise",
                                     "gemini-api-key": "Gemini API key", "agent-platform": "Agent Platform (Vertex AI)"])),
             .text("gcpProject", "GCP project", "my-project-id", "Project used with Agent Platform sign-in."),
             .text("gcpLocation", "GCP location", "us-central1", "Region used with Agent Platform sign-in."),
             .text("binaryPath", "Binary path", "", "Path to the Antigravity binary used by this instance.")]
        default:
            [.text("binaryPath", "Binary path", driver, "Path to the \(driver) binary used by this instance."),
             .text("homePath", "Home path", "", "Custom home and config directory."),
             .text("launchArgs", "Launch arguments", "", "Additional CLI arguments passed on session start.")]
        }
    }
}

enum SettingsChangeError: LocalizedError {
    case busy, secret
    var errorDescription: String? {
        switch self {
        case .busy: "Another change to this provider is in progress."
        case .secret: "Could not save the API key in the server’s secret store."
        }
    }
}

public struct WorkspaceSettings: Sendable {
    public let providers: [ProviderSettings]
    public let selection: ThreadModelSelection?
}

@MainActor public protocol SettingsBackend: AnyObject {
    func workspaceSettings() async throws -> WorkspaceSettings
    func updateProvider(id: String, enabled: Bool, apiKey: String?) async throws
    func installProviderSDK(id: String, sdk: ProviderSDK) async throws
    func installProvider(id: String) async throws
    func refreshProvider(id: String) async throws
    func setDefaultModel(_ selection: ThreadModelSelection) async throws
    func serverSettings() async throws -> ServerSettings
    /// Both settings views from a single `server.getConfig` round trip.
    func settingsAndProviders() async throws -> (settings: ServerSettings, workspace: WorkspaceSettings)
    /// Sends a `server.updateSettings` patch; keys are the server's settings field names.
    func updateServerSettings(_ patch: [String: WireValue]) async throws
    /// `server.refreshProviders` with `fresh`, for one instance or all of them.
    func refreshProviders(instanceID: String?) async throws
    /// `server.updateProvider`: installs the latest CLI version for a driver.
    func updateProviderVersion(driver: String, instanceID: String?) async throws
    /// Upserts non-secret instance fields: `displayName` and `config` keys. A `nil` value removes the key.
    func saveProviderFields(id: String, displayName: String??, config: [String: String?]) async throws
    func addProvider(driver: String, displayName: String) async throws -> String
    /// `server.getUsageSummary` over the last `days` days.
    func usageSummary(days: Int) async throws -> UsageSummary
    /// `server.refreshUsageRates`: refreshes model pricing. Call on open and manual refresh only.
    func refreshUsageRates() async throws
    @discardableResult func addProject(folder: URL) async throws -> String
    func removeProject(id: String) async throws
}

/// Opaque JSON preserved across reads and writes, including redacted fields on an instance upsert.
public indirect enum WireValue: Codable, Sendable, Equatable {
    case object([String: Self]), array([Self]), string(String), number(Decimal), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode(Decimal.self) { self = .number(value) }
        else if let value = try? c.decode([Self].self) { self = .array(value) }
        else { self = .object(try c.decode([String: Self].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .object(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .bool(let value): try c.encode(value)
        }
    }

    public init(encoding value: some Encodable) throws {
        self = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }

    public static func number(_ value: Int) -> Self { .number(Decimal(value)) }

    public func decoded<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// The server's settings document as the Settings window edits it.
public struct ServerSettings: Sendable, Equatable {
    public var values: [String: WireValue]

    public init(values: [String: WireValue] = [:]) { self.values = values }

    public func bool(_ key: String, default fallback: Bool = false) -> Bool {
        if case .bool(let value) = values[key] { return value }
        return fallback
    }

    public func string(_ key: String, default fallback: String = "") -> String {
        if case .string(let value) = values[key] { return value }
        return fallback
    }

    /// An integer setting, or `nil` when it is unset or `null`.
    public func int(_ key: String) -> Int? {
        if case .number(let value) = values[key] { return NSDecimalNumber(decimal: value).intValue }
        return nil
    }

    public func selection(_ key: String) -> ThreadModelSelection? {
        values[key]?.decoded(ThreadModelSelection.self)
    }
}
