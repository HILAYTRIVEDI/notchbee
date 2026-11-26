import Foundation
import SwiftParser
import SwiftSyntax

// Exact non-display literals retained by the built-in engine's protocol.
let internalLiterals: [String: Set<String>] = [
    "T3Client.swift": [".well-known/t3/environment", "urn:t3:params:oauth:token-type:environment-bootstrap"],
    "EngineSupervisor.swift": [".well-known/t3/environment"],
    "Product.swift": ["t3", #"\b(t3(?:[ \t]+(?:code|tools)|code)?)\b"#]
]
let prohibited = #"(?i)\b(?:t3|t3code)\b"#
var failures = 0

for root in ["Notchpilot/Sources", "NotchpilotCore/Sources"] {
    for case let file as URL in FileManager.default.enumerator(at: URL(fileURLWithPath: root),
                                                               includingPropertiesForKeys: nil)! {
        if file.lastPathComponent == "THIRD_PARTY_NOTICES" { continue }
        if file.pathExtension == "plist" || file.pathExtension == "strings" {
            let contents = try String(contentsOf: file, encoding: .utf8)
            if contents.range(of: prohibited, options: .regularExpression) != nil {
                print("\(file.path): prohibited branding in resource")
                failures += 1
            }
        }
        guard file.pathExtension == "swift" else { continue }
        let tree = Parser.parse(source: try String(contentsOf: file, encoding: .utf8))
        let locations = SourceLocationConverter(fileName: file.path, tree: tree)
        // String segments include multiline and nested interpolated literals, but skip
        // expressions (e.g. theme constants), comments, and source identifiers.
        for token in tree.tokens(viewMode: .sourceAccurate) {
            guard case .stringSegment(let value) = token.tokenKind,
                  value.range(of: prohibited, options: .regularExpression) != nil,
                  !internalLiterals[file.lastPathComponent, default: []].contains(value) else { continue }
            let location = locations.location(for: token.positionAfterSkippingLeadingTrivia)
            print("\(location.file):\(location.line): prohibited branding in string literal")
            failures += 1
        }
    }
}
if failures > 0 { exit(1) }
print("Branding check passed.")
