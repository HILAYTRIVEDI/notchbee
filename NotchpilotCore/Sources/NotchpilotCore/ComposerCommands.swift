import Foundation

/// A provider slash command or user-invocable skill offered by the composer's `/` menu.
public struct ComposerCommand: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case command, skill }

    public let kind: Kind
    public let name: String
    public let detail: String?
    /// Argument hint the provider advertises, such as "[file]".
    public let inputHint: String?

    public var id: String { "\(kind.rawValue):\(name)" }

    /// What the menu row shows.
    public var label: String { "/\(name)" }

    /// The prompt text that invokes it. The engine expands `$name` into each provider's native skill syntax.
    public var insertion: String {
        switch kind {
        case .command: "/\(name) "
        case .skill: "$\(name) "
        }
    }

    public init(kind: Kind, name: String, detail: String? = nil, inputHint: String? = nil) {
        self.kind = kind
        self.name = name
        self.detail = detail
        self.inputHint = inputHint
    }

    public struct SlashCommandSource: Sendable {
        public let name: String
        public let description: String?
        public let inputHint: String?

        public init(name: String, description: String? = nil, inputHint: String? = nil) {
            self.name = name
            self.description = description
            self.inputHint = inputHint
        }
    }

    public struct SkillSource: Sendable {
        public let name: String
        public let description: String?
        public let shortDescription: String?
        public let enabled: Bool
        /// `false` for agent-only skills (Claude's `user-invocable: false`), which the menu hides.
        public let userInvocable: Bool?

        public init(name: String, description: String? = nil, shortDescription: String? = nil,
                    enabled: Bool = true, userInvocable: Bool? = nil) {
            self.name = name
            self.description = description
            self.shortDescription = shortDescription
            self.enabled = enabled
            self.userInvocable = userInvocable
        }
    }

    /// Mirrors the T3 web composer: enabled, user-invocable skills deduplicated by name, then the
    /// provider's slash commands minus any that a visible skill already covers.
    public static func menu(slashCommands: [SlashCommandSource], skills: [SkillSource]) -> [ComposerCommand] {
        var seen = Set<String>()
        let visibleSkills = skills.filter { skill in
            guard skill.enabled, skill.userInvocable != false, isSafeName(skill.name.trimmed) else { return false }
            return seen.insert(skill.name.trimmed.lowercased()).inserted
        }
        var commandNames = Set<String>()
        let commands = slashCommands.compactMap { command -> ComposerCommand? in
            let key = command.name.trimmed.lowercased()
            guard isSafeName(command.name.trimmed), !seen.contains(key), commandNames.insert(key).inserted else { return nil }
            return ComposerCommand(kind: .command, name: command.name.trimmed,
                                   detail: command.description, inputHint: command.inputHint)
        }
        return commands + visibleSkills.map {
            ComposerCommand(kind: .skill, name: $0.name.trimmed, detail: $0.shortDescription ?? $0.description)
        }
    }

    /// Names come from provider and repository files. Refuse ones whose inserted text could differ from
    /// what the row shows: whitespace, control or bidirectional formatting characters, or a leading sigil.
    static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128, !name.hasPrefix("/"), !name.hasPrefix("$") else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.controlCharacters.contains(scalar)
                && scalar.properties.generalCategory != .format
        }
    }

    /// The search text when the draft is a bare `/query` at the start of the prompt, where providers
    /// recognise commands. `nil` once the draft holds anything else, such as a space.
    public static func query(in draft: String) -> String? {
        guard draft.hasPrefix("/") else { return nil }
        let query = draft.dropFirst()
        guard !query.contains(where: { $0.isWhitespace || $0 == "/" }) else { return nil }
        return String(query)
    }

    /// Name-prefix matches first, then names containing the query, then descriptions containing it.
    public static func filter(_ commands: [ComposerCommand], query: String) -> [ComposerCommand] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return commands }
        func rank(_ command: ComposerCommand) -> Int? {
            let name = command.name.lowercased()
            if name.hasPrefix(needle) { return 0 }
            if name.contains(needle) { return 1 }
            if command.detail?.lowercased().contains(needle) == true { return 2 }
            return nil
        }
        return commands.enumerated()
            .compactMap { index, command in rank(command).map { (rank: $0, index: index, command: command) } }
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
            .map(\.command)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
