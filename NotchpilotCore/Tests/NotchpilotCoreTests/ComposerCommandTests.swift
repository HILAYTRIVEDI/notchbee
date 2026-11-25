import Foundation
import Testing
@testable import NotchpilotCore

struct ComposerCommandTests {
    @Test func menuHidesAgentOnlyAndDisabledSkillsAndDeduplicates() {
        let menu = ComposerCommand.menu(
            slashCommands: [.init(name: "review", description: "Review changes", inputHint: "[pr]"),
                            .init(name: "Explain"), .init(name: "review"), .init(name: "  ")],
            skills: [.init(name: "explain", description: "Long", shortDescription: "Short"),
                     .init(name: "explain", description: "Duplicate"),
                     .init(name: "hidden", userInvocable: false),
                     .init(name: "off", enabled: false)])
        #expect(menu.map(\.id) == ["command:review", "skill:explain"])
        #expect(menu.first?.inputHint == "[pr]")
        #expect(menu.last?.detail == "Short")
    }

    @Test func menuRefusesNamesThatCouldSpoofTheInsertedText() {
        let menu = ComposerCommand.menu(
            slashCommands: [.init(name: "ok-name"), .init(name: "two words"), .init(name: "line\nbreak"),
                            .init(name: "rtl\u{202E}gpj"), .init(name: "zero\u{200B}width"), .init(name: "/double"),
                            .init(name: String(repeating: "a", count: 129))],
            skills: [.init(name: "tab\tskill"), .init(name: "$sigil"), .init(name: "réview")])
        #expect(menu.map(\.name) == ["ok-name", "réview"])
    }

    @Test func commandsAndSkillsInsertTheirInvocation() {
        #expect(ComposerCommand(kind: .command, name: "compact").insertion == "/compact ")
        #expect(ComposerCommand(kind: .skill, name: "pdf").insertion == "$pdf ")
        #expect(ComposerCommand(kind: .skill, name: "pdf").label == "/pdf")
    }

    @Test(arguments: [
        ("/", ""), ("/rev", "rev"), ("/skill-creator", "skill-creator"),
    ])
    func queryOpensForABareSlashToken(draft: String, expected: String) {
        #expect(ComposerCommand.query(in: draft) == expected)
    }

    @Test(arguments: ["", "review", " /review", "/review ", "/review the diff", "/usr/bin", "path /x"])
    func queryStaysClosedOtherwise(draft: String) {
        #expect(ComposerCommand.query(in: draft) == nil)
    }

    @Test func filterRanksPrefixThenNameThenDescription() {
        let commands = [
            ComposerCommand(kind: .command, name: "pr-comments", detail: "Fetch comments"),
            ComposerCommand(kind: .skill, name: "simplify", detail: "Review and clean up code"),
            ComposerCommand(kind: .command, name: "review", detail: "Review a pull request"),
            ComposerCommand(kind: .command, name: "security-review"),
        ]
        #expect(ComposerCommand.filter(commands, query: "REV").map(\.name) == ["review", "security-review", "simplify"])
        #expect(ComposerCommand.filter(commands, query: "").count == 4)
        #expect(ComposerCommand.filter(commands, query: "zzz").isEmpty)
    }

    @Test func providerCatalogCarriesCommandsAndPrefersTheProjectSnapshot() throws {
        let config = Data(#"""
        {"_tag":"Exit","requestId":"1","exit":{"_tag":"Success","value":{"providers":[
          {"instanceId":"claude","driver":"claudeAgent","installed":true,"enabled":true,"status":"ready",
           "models":[{"slug":"opus","name":"Opus","isDefault":true}],
           "slashCommands":[{"name":"compact","description":"Compact the conversation"},{"name":"init","input":{"hint":"[path]"}},{"bad":1}],
           "skills":[{"name":"pdf","path":"/u/.claude/skills/pdf/SKILL.md","enabled":true,"shortDescription":"PDF tools"},
                     {"name":"internal","path":"/x","enabled":true,"userInvocable":false}],
           "workspaceSnapshots":[{"cwd":"/work/app","checkedAt":"2026-11-26T00:00:00Z",
             "slashCommands":[{"name":"deploy"}],
             "skills":[{"name":"repo-skill","path":"/work/app/.claude/skills/r/SKILL.md","enabled":true}]}]},
          {"instanceId":"codex","driver":"codex","installed":true,"enabled":true,"status":"ready",
           "models":[{"slug":"gpt","name":"GPT"}]}
        ]}}}
        """#.utf8)
        guard case .exit(_, let exit) = try JSONDecoder().decode(T3Client.Frame.self, from: config) else {
            Issue.record("Expected a config result")
            return
        }
        let value = try #require(exit.value)
        let machine = value.providerCatalog(project: nil)
        #expect(machine.providers.first?.commands.map(\.id) == ["command:compact", "command:init", "skill:pdf"])
        #expect(machine.providers.first?.commands[1].inputHint == "[path]")
        #expect(machine.providers.last?.commands.isEmpty == true)

        let project = try JSONDecoder().decode(T3Client.Project.self,
            from: Data(#"{"id":"app","title":"App","workspaceRoot":"/work/app"}"#.utf8))
        #expect(value.providerCatalog(project: project).providers.first?.commands.map(\.id)
                == ["command:deploy", "skill:repo-skill"])
    }

    @Test func setModelDispatchesTheEngineCommand() throws {
        let command = T3Client.threadCommand(
            sessionID: "t1", mutation: .setModel(.init(instanceId: "codex", model: "gpt-5")))
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? [String: Any])
        #expect(json["type"] as? String == "thread.model-selection.set")
        #expect(json["threadId"] as? String == "t1")
        let selection = try #require(json["modelSelection"] as? [String: Any])
        #expect(selection["instanceId"] as? String == "codex")
        #expect(selection["model"] as? String == "gpt-5")
        #expect(json["commandId"] is String)

        let rename = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(T3Client.threadCommand(sessionID: "t1", mutation: .rename("x")))) as? [String: Any])
        #expect(rename["modelSelection"] == nil)
    }

    @Test func sessionSummaryExposesTheThreadModel() throws {
        let data = Data(#"""
        {"kind":"snapshot","snapshot":{"snapshotSequence":1,"projects":[],"threads":[
          {"id":"main","title":"Main","projectId":"p","providerInstanceId":"claude","updatedAt":"2026-01-01T10:00:00Z",
           "status":"idle","modelSelection":{"instanceId":"claude","model":"opus"}}
        ]}}
        """#.utf8)
        let item = try JSONDecoder().decode(T3Client.StreamItem.self, from: data)
        var projection = T3Client.Projection()
        var state = StateSnapshot()
        for event in projection.apply(item) { state = reduce(state: state, event: event) }
        #expect(state.sessions.first?.modelSelection == ThreadModelSelection(instanceId: "claude", model: "opus"))
    }
}
