import Foundation
import Testing
@testable import NotchpilotCore

struct UserInputTests {
    private static let threadID = "651702a8-7a77-4682-a900-cbaeb48359f5"

    private static func thread(_ id: String = threadID) -> String {
        """
        {"createdBy":"user","creationSource":"web","id":"\(id)","projectId":"p1","title":"T3 Code question",
         "providerInstanceId":"claudeAgent","modelSelection":{"instanceId":"claudeAgent","model":"m"},
         "runtimeMode":"approval-required","interactionMode":"default","branch":null,"worktreePath":null,
         "pullRequests":[],"activeProviderThreadId":null,
         "lineage":{"parentThreadId":null,"relationshipToParent":null,"rootThreadId":"\(id)"},
         "forkedFrom":null,"createdAt":"2026-11-19T17:13:54.365Z","updatedAt":"2026-11-19T17:13:54.365Z",
         "archivedAt":null,"settledOverride":null,"settledAt":null,"snoozedUntil":null,"snoozedAt":null,
         "lastVisitedAt":null,"deletedAt":null}
        """
    }

    private static func request(status: String = "pending", capability: String = #"{"type":"live","providerSessionId":"s1"}"#,
                                kind: String = "user_input") -> String {
        """
        {"id":"req-1","kind":"\(kind)","status":"\(status)","responseCapability":\(capability),
         "createdAt":"2026-11-19T17:14:00.000Z","resolvedAt":null}
        """
    }

    private static let item = """
    {"type":"user_input_request","id":"item-1","requestId":"req-1","status":"waiting",
     "startedAt":"2026-11-19T17:14:00.000Z","updatedAt":"2026-11-19T17:14:00.000Z",
     "questions":[
      {"id":"Which database?","header":"Database","question":"Which database should T3 Code use?",
       "options":[{"label":"Postgres","description":"Relational"},{"label":"SQLite","description":"Embedded","value":"sqlite"}],
       "multiSelect":false,"allowCustomAnswer":false},
      {"id":"features","header":"Features","question":"Pick features",
       "options":[{"label":"Auth","description":"Sign in"},{"label":"Billing","description":"Payments"}],
       "multiSelect":true,"allowCustomAnswer":true,"required":false},
      {"id":"note","header":"Note","question":"Anything else?","options":[]}
     ]}
    """

    private static func snapshot(requests: [String], items: [String]) throws -> T3Client.ThreadProjection {
        let json = """
        {"thread":\(thread()),"runs":[],"runtimeRequests":[\(requests.joined(separator: ","))],
         "turnItems":[\(items.joined(separator: ","))],"checkpoints":[],"messages":[]}
        """
        return try JSONDecoder().decode(T3Client.ThreadProjection.self, from: Data(json.utf8))
    }

    private static func requested(_ events: [AppEvent]) -> UserInputRequest? {
        for case .userInputRequested(let request) in events { return request }
        return nil
    }

    @Test func decodesAUserInputRequestAndItsQuestions() throws {
        let snapshot = try Self.snapshot(requests: [Self.request()], items: [Self.item])
        #expect(snapshot.runtimeRequests.first?.canAnswer == true)
        #expect(snapshot.runtimeRequests.first?.canRespond == false)

        var projection = T3Client.Projection()
        let events = projection.apply(.detailSnapshot(snapshot), detailThreadID: Self.threadID)
        let request = try #require(Self.requested(events))
        #expect(request.id == "req-1")
        #expect(request.threadId == Self.threadID)
        #expect(request.sessionName == "Notchbee question")
        #expect(request.questions.map(\.id) == ["Which database?", "features", "note"])

        let database = request.questions[0]
        #expect(database.header == "Database")
        #expect(database.question == "Which database should Notchbee use?")
        #expect(database.options.map(\.label) == ["Postgres", "SQLite"])
        #expect(database.options.map(\.answerValue) == ["Postgres", "sqlite"])
        #expect(!database.multiSelect && !database.offersCustomAnswer && database.required)

        let features = request.questions[1]
        #expect(features.multiSelect && features.allowCustomAnswer && !features.required)

        let note = request.questions[2]
        #expect(note.options.isEmpty && note.offersCustomAnswer)
        #expect(projection.needsApprovalDetails(Self.threadID))
    }

    @Test func aQuestionWaitsForItsTurnItemAndLaterResolves() throws {
        var projection = T3Client.Projection()
        var events = projection.apply(.detailSnapshot(try Self.snapshot(requests: [Self.request()], items: [])),
                                      detailThreadID: Self.threadID)
        #expect(Self.requested(events) == nil)

        let itemJSON = Data(Self.item.utf8)
        let item = try JSONDecoder().decode(T3Client.TurnItem.self, from: itemJSON)
        events = projection.apply(.detailEvent(.item(item)), detailThreadID: Self.threadID)
        #expect(Self.requested(events)?.questions.count == 3)

        let resolved = try JSONDecoder().decode(T3Client.RuntimeRequest.self,
                                                from: Data(Self.request(status: "resolved").utf8))
        events = projection.apply(.detailEvent(.request(resolved)), detailThreadID: Self.threadID)
        #expect(events == [.userInputResolved(requestId: "req-1")])
        #expect(!projection.needsApprovalDetails(Self.threadID))

        var state = StateSnapshot()
        state = reduce(state: state, event: .userInputRequested(UserInputRequest(
            id: "req-1", threadId: Self.threadID, sessionName: "s", questions: [])))
        #expect(state.uiState == .needsInput)
        state = reduce(state: state, event: .userInputResolved(requestId: "req-1"))
        #expect(state.pendingUserInputs.isEmpty)
    }

    @Test func onlyLivePendingUserInputRequestsAreAnswerable() throws {
        for (status, capability) in [("resolved", #"{"type":"live","providerSessionId":"s1"}"#),
                                     ("pending", #"{"type":"message"}"#),
                                     ("pending", #"{"type":"not_resumable","reason":"gone"}"#)] {
            let request = try JSONDecoder().decode(
                T3Client.RuntimeRequest.self, from: Data(Self.request(status: status, capability: capability).utf8))
            #expect(!request.canAnswer)
        }
        let approval = try JSONDecoder().decode(
            T3Client.RuntimeRequest.self, from: Data(Self.request(kind: "command").utf8))
        #expect(approval.canRespond && !approval.canAnswer && !approval.isUserInput)
    }

    @Test func respondCommandEncodesSingleMultiAndCustomAnswers() throws {
        let snapshot = try Self.snapshot(requests: [Self.request()], items: [Self.item])
        var projection = T3Client.Projection()
        let request = try #require(Self.requested(projection.apply(.detailSnapshot(snapshot), detailThreadID: Self.threadID)))
        let database = request.questions[0], features = request.questions[1], note = request.questions[2]

        var draft = UserInputDraft(for: request)
        #expect(!draft.isComplete(for: request))
        draft.toggle(database.options[1], in: database)
        #expect(!draft.isComplete(for: request))
        draft.setCustom("  Use the existing schema  ", for: note)
        #expect(draft.isComplete(for: request))
        draft.toggle(features.options[0], in: features)
        draft.toggle(features.options[1], in: features)
        draft.setCustom("SSO", for: features)

        let command = T3Client.AnswerUserInput(threadId: Self.threadID, requestId: "req-1",
                                               answers: draft.answers(for: request))
        let data = try JSONEncoder().encode(command)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "runtime-request.respond")
        #expect(object["threadId"] as? String == Self.threadID)
        #expect(object["requestId"] as? String == "req-1")
        #expect(!(object["commandId"] as? String ?? "").isEmpty)
        let answers = try #require(object["answers"] as? [String: Any])
        #expect(answers["Which database?"] as? String == "sqlite")
        #expect(answers["features"] as? [String] == ["Auth", "Billing", "SSO"])
        #expect(answers["note"] as? String == "Use the existing schema")
        #expect(answers.count == 3)
    }

    @Test func draftRulesFollowSelectionMode() throws {
        let single = UserInputQuestion(id: "q", header: "H", question: "Q",
                                       options: [.init(label: "A"), .init(label: "B")], allowCustomAnswer: true)
        let request = UserInputRequest(id: "r", threadId: "t", sessionName: "s", questions: [single])
        var draft = UserInputDraft(for: request)
        draft.toggle(single.options[0], in: single)
        draft.toggle(single.options[1], in: single)
        #expect(draft.answer(for: single) == .single("B"))
        draft.setCustom("Other", for: single)
        #expect(draft.answer(for: single) == .single("Other"))
        draft.toggle(single.options[0], in: single)
        #expect(draft.answer(for: single) == .single("A"))
        draft.toggle(single.options[0], in: single)
        #expect(draft.answer(for: single) == nil)
        #expect(draft.answers(for: request).isEmpty)

        let seeded = UserInputQuestion(id: "s", header: "H", question: "Q", options: [.init(label: "A")], initialAnswer: "A")
        #expect(UserInputDraft(for: .init(id: "r", threadId: "t", sessionName: "s", questions: [seeded]))
            .answer(for: seeded) == .single("A"))
    }

    @Test func dismissCommandEncodesTheDismissType() throws {
        let data = try JSONEncoder().encode(T3Client.DismissUserInput(threadId: "t", requestId: "r"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "thread.user-input.dismiss")
        #expect(object["requestId"] as? String == "r")
        #expect(object["answers"] == nil)
    }
}
