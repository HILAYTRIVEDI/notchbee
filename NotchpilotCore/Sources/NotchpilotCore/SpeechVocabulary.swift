import Foundation

public struct SpeechCustomWord: Codable, Equatable, Sendable {
    public let term: String
    public let aliases: [String]

    public init(term: String, aliases: [String]) {
        self.term = term
        self.aliases = aliases
    }
}

public struct SpeechVocabulary: Sendable {
    public let words: [SpeechCustomWord]
    private let replacements: [String: String]
    private let pattern: NSRegularExpression?

    public init(words: [SpeechCustomWord]) {
        self.words = words
        var replacements: [String: String] = [:]
        for word in words where !word.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            replacements[Self.key(word.term)] = word.term
        }
        for word in words where !word.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for alias in word.aliases where !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let key = Self.key(alias)
                if replacements[key] == nil { replacements[key] = word.term }
            }
        }
        self.replacements = replacements
        let alternatives = replacements.keys.sorted { ($0.count, $0) > ($1.count, $1) }.map {
            $0.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#)
        }
        pattern = alternatives.isEmpty ? nil : try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}\p{M}_])(?:"# + alternatives.joined(separator: "|") + #")(?![\p{L}\p{N}\p{M}_])"#,
            options: [.caseInsensitive]
        )
    }

    public func apply(to text: String) -> String {
        guard let pattern else { return text }
        let result = NSMutableString(string: text)
        let source = text as NSString
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            if let term = replacements[Self.key(source.substring(with: match.range))] {
                result.replaceCharacters(in: match.range, with: term)
            }
        }
        return result as String
    }

    private static func key(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}
