import Foundation

public enum Product {
    public static let name = "Notchbee"

    // Only call this for display prose. Chat, commands, file paths, and wire values
    // are passed through separately. Preserve technical spans embedded in prose.
    private static let displayPattern = try! NSRegularExpression(
        pattern: [
            #"```.*?```|`[^`\n]*`"#,
            #"\b[a-z][a-z0-9+.-]*://[^\s<>]+"#,
            #"(?:[/~.]|\b[\w.-]+/)[^\s<>]*"#,
            #"\b(t3(?:[ \t]+(?:code|tools)|code)?)\b"#
        ].joined(separator: "|"), options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    public static func displayText(_ text: String) -> String {
        guard text.range(of: "t3", options: .caseInsensitive) != nil else { return text }
        let result = NSMutableString(string: text)
        for match in displayPattern.matches(in: text, range: NSRange(location: 0, length: result.length)).reversed() {
            let brand = match.range(at: 1)
            if brand.location != NSNotFound { result.replaceCharacters(in: brand, with: name) }
        }
        return result as String
    }
}
