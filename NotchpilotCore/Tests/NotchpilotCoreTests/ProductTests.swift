import Foundation
import Testing
@testable import NotchpilotCore

struct ProductTests {
    @Test func externalDisplayTextUsesProductIdentity() {
        #expect(Product.displayText("T3 Code: restart T3, t3code or T3 Tools.") ==
                "\(Product.name): restart \(Product.name), \(Product.name) or \(Product.name).")
        #expect(Product.displayText("AT3 T30 other") == "AT3 T30 other")
    }

    @Test func preservesTechnicalSpansInServerProse() {
        let technical = "https://example.com/T3 /tmp/T3 ~/.t3 relative/T3 `t3 serve` ```\nT3 Code\n```"
        #expect(Product.displayText("T3 Code reported \(technical)") == "\(Product.name) reported \(technical)")
    }

    @Test func serverNoticesAreRebrandedAndConversationPayloadsAreVerbatim() throws {
        let payload = "T3 Code: run `t3 serve`"
        for kind in ["error", "system_notice", "assistant_message", "user_message", "command_execution"] {
            let data = try JSONEncoder().encode([
                "type": kind, "id": "item", "messageId": "message", "startedAt": "2026-01-01T10:00:00Z",
                "message": payload, "text": payload, "input": payload
            ])
            let item = try JSONDecoder().decode(T3Client.TurnItem.self, from: data)
            let entry = try #require(item.entry)
            let expected = kind == "error" || kind == "system_notice" ? "\(Product.name): run `t3 serve`" : payload
            #expect(entry.text == expected)
        }
    }
}
