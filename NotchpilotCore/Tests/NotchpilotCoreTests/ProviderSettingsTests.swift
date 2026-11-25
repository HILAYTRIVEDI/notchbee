import Foundation
import Testing
@testable import NotchpilotCore

struct ProviderSettingsTests {
    @Test func resolveAndReopenReconcileWithServerSnapshots() {
        var session = SessionSummary(id: "a", title: "One", providerInstanceId: "agent", status: .idle)
        var state = reduce(state: .init(), event: .sessionUpdated(session))
        state = reduce(state: state, event: .sessionSettleChanged(sessionId: "a", resolved: true))
        #expect(state.sessions.first?.displayStatus == "Done")
        #expect(!state.showResolved)
        let failed = reduce(state: state, event: .sessionSettleFinished(sessionId: "a", succeeded: false))
        #expect(failed.sessions.first?.isSettled == false)
        state = reduce(state: state, event: .toggleShowResolved)
        #expect(state.showResolved)
        state = reduce(state: state, event: .sessionUpdated(session))
        #expect(state.sessions.first?.displayStatus == "Idle")
        session.isSettled = true
        state = reduce(state: state, event: .sessionsResynced([session]))
        state = reduce(state: state, event: .sessionSettleFinished(sessionId: "a", succeeded: false))
        #expect(state.sessions.first?.isSettled == true)
        state = reduce(state: state, event: .sessionSettleChanged(sessionId: "a", resolved: false))
        #expect(state.sessions.first?.isSettled == false)
    }

    @Test func instanceUpdatePreservesUnknownFieldsAndRedactedSecrets() throws {
        let data = Data(#"{"driver":"cursor","config":{"enabled":false,"customFlag":"keep"},"environment":[{"name":"OTHER","value":"","sensitive":true,"valueRedacted":true}]}"#.utf8)
        let existing = try JSONDecoder().decode([String: WireValue].self, from: data)
        let update = try T3Client.providerMutation(id: "work", driver: "cursor", existing: existing, enabled: true, apiKey: "example")
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(update)) as? [String: Any])
        #expect(json["operation"] as? String == "upsert")
        #expect(json["instanceId"] as? String == "work")
        let instance = try #require(json["instance"] as? [String: Any])
        let config = try #require(instance["config"] as? [String: Any])
        #expect(config["enabled"] as? Bool == true)
        #expect(config["customFlag"] as? String == "keep")
        let variables = try #require(instance["environment"] as? [[String: Any]])
        #expect(variables.count == 2)
        #expect(variables[0]["valueRedacted"] as? Bool == true)
        #expect(variables[1]["name"] as? String == "CURSOR_API_KEY")
        #expect(variables[1]["sensitive"] as? Bool == true)
    }

    @Test(arguments: ["thread.settled", "thread.unsettled"])
    func decodesThreadResolutionEvent(type: String) throws {
        let resolved = type == "thread.settled"
        let data = try JSONSerialization.data(withJSONObject: ["type": type, "payload": [
            "id": "thread", "title": "Review", "projectId": "one", "providerInstanceId": "codex",
            "updatedAt": "2026-01-01T00:00:00Z", "settledOverride": resolved ? "settled" : "active"
        ]])
        guard case .thread(let thread) = try JSONDecoder().decode(T3Client.DomainEvent.self, from: data) else {
            Issue.record("Unrecognized resolution event")
            return
        }
        #expect((thread.settledOverride == "settled") == resolved)
    }
}
