import Foundation

public enum VoiceTarget: Sendable, Equatable {
    case session(id: String, title: String)
    case newThread(baseSessionID: String, project: String)
    case quickSession

    public var label: String {
        switch self {
        case .session(_, let title): title
        case .newThread(_, let project): "New thread in \(project)"
        case .quickSession: "New quick session"
        }
    }
}

public struct VoiceDraft: Sendable, Equatable {
    public let target: VoiceTarget
    public var text: String

    public init(target: VoiceTarget, text: String) {
        self.target = target
        self.text = text
    }
}

public enum VoiceRouting {
    public enum Failure: LocalizedError, Equatable {
        case noSpeech, noSessions, noPrompt, unknownTarget, ambiguousTarget

        public var errorDescription: String? {
            switch self {
            case .noSpeech: "No speech detected. Hold the shortcut while speaking."
            case .noSessions: "Open a session before using voice commands."
            case .noPrompt: "Say a message after the voice command."
            case .unknownTarget: "No matching session. Try its full title or project name."
            case .ambiguousTarget: "Several sessions match. Try the full session title."
            }
        }
    }

    public static func resolve(_ transcript: String, sessions: [SessionSummary]) throws -> VoiceDraft {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = tokenize(text)
        guard !words.isEmpty else { throw Failure.noSpeech }
        let active = activeSessionsByRecency(sessions)
        if words.prefix(2).map(\.key) == ["new", "thread"] {
            if let last = active.first, let project = last.project {
                return try draft(.newThread(baseSessionID: last.id, project: project), text, after: words[1])
            }
            return try draft(.quickSession, text, after: words[1])
        }
        guard let last = active.first else { throw Failure.noSessions }
        guard words[0].key == "tell" else {
            return VoiceDraft(target: target(last), text: text)
        }

        let spoken = Array(words.dropFirst())
        guard !spoken.isEmpty else { throw Failure.unknownTarget }
        let candidates = active.enumerated().flatMap { index, session -> [Match] in
            let names: [(String, Bool)] = [(session.title, true), (session.project ?? "", false)]
            return names.flatMap { name, isTitle in
                let keys = tokenize(name).map(\.key)
                return matches(for: keys, spoken: spoken, index: index, isTitle: isTitle)
            }
        }.sorted { $0.rank > $1.rank }
        guard let best = candidates.first else { throw Failure.unknownTarget }

        let tied = candidates.prefix { $0.rank == best.rank }
        let indexes = Set(tied.map(\.index))
        if indexes.count > 1, (best.isTitle || Set(tied.map(\.name)).count > 1) {
            throw Failure.ambiguousTarget
        }
        let session = active[indexes.min() ?? best.index]
        return try draft(target(session), text, after: spoken[best.count - 1])
    }

    public static func activeSessionsByRecency(_ sessions: [SessionSummary]) -> [SessionSummary] {
        return sessions.enumerated().filter { !$0.element.isArchived }.sorted {
            if $0.element.lastActivity != $1.element.lastActivity {
                return ($0.element.lastActivity ?? .distantPast) > ($1.element.lastActivity ?? .distantPast)
            }
            return $0.offset < $1.offset
        }.map(\.element)
    }

    private static func target(_ session: SessionSummary) -> VoiceTarget {
        .session(id: session.id, title: session.title)
    }

    private static func draft(_ target: VoiceTarget, _ text: String, after word: Word) throws -> VoiceDraft {
        let separators: Set<Character> = [",", ":", ";", ".", "!", "?", "—", "–"]
        let remainder = text[word.end...].drop(while: { separators.contains($0) })
        let prompt = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw Failure.noPrompt }
        return VoiceDraft(target: target, text: prompt)
    }

    private struct Word {
        let key: String
        let end: String.Index
    }

    private static let wordPattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}\p{M}]+"#)

    private static func tokenize(_ text: String) -> [Word] {
        wordPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            let key = text[range].folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
            return Word(key: key, end: range.upperBound)
        }
    }

    private struct Match {
        let index: Int
        let name: String
        let count: Int
        let similarity: Int
        let isTitle: Bool

        var rank: (Int, Int, Int) { (similarity, count, isTitle ? 1 : 0) }
    }

    private static func matches(for keys: [String], spoken: [Word], index: Int, isTitle: Bool) -> [Match] {
        guard !keys.isEmpty else { return [] }
        let name = keys.joined()
        let minimum = max(1, keys.count - 1)
        let maximum = min(keys.count + 1, spoken.count)
        guard minimum <= maximum else { return [] }
        return (minimum...maximum).compactMap { count in
            let candidate = spoken.prefix(count).map(\.key).joined()
            let length = max(name.count, candidate.count)
            guard abs(name.count - candidate.count) <= max(1, length / 4) else { return nil }
            let distance = editDistance(Array(name), Array(candidate))
            guard distance == 0 || (length >= 4 && distance <= max(1, length / 4)) else { return nil }
            return Match(index: index, name: name, count: count,
                         similarity: 100 - (100 * distance / length), isTitle: isTitle)
        }
    }

    private static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        var row = Array(0...rhs.count)
        for (i, a) in lhs.enumerated() {
            var diagonal = row[0]
            row[0] = i + 1
            for (j, b) in rhs.enumerated() {
                let above = row[j + 1]
                row[j + 1] = min(above + 1, row[j] + 1, diagonal + (a == b ? 0 : 1))
                diagonal = above
            }
        }
        return row[rhs.count]
    }
}
