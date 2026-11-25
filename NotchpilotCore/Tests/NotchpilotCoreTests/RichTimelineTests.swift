import Foundation
import Testing
@testable import NotchpilotCore

struct RichTimelineTests {
    // MARK: Markdown

    @Test func parsesTablesWithAlignmentAndRaggedRows() throws {
        let source = "| Name | Qty | Note |\n|:--|--:|:-:|\n| `a|b` | 2 | ok |\n| c | 3 |\n\nafter"
        let blocks = MessageMarkdown.parse(source)
        guard case .table(let table) = try #require(blocks.first) else { Issue.record("Expected a table"); return }
        #expect(table.headers.map { String($0.characters) } == ["Name", "Qty", "Note"])
        #expect(table.alignments == [.leading, .trailing, .center])
        #expect(table.rows.count == 2)
        #expect(String(table.rows[0][0].characters) == "a|b")
        #expect(table.rows[1].count == 3)
        #expect(blocks.count == 2)
    }

    @Test func pipesWithoutSeparatorStayParagraphs() {
        #expect(MessageMarkdown.parse("a | b | c") == [.paragraph(AttributedString("a | b | c"))])
    }

    @Test func parsesDeepHeadingsAndTaskLists() throws {
        let blocks = MessageMarkdown.parse("#### Small\n\n- [x] done\n- [ ] todo\n- plain")
        #expect(blocks.first == .heading(4, AttributedString("Small")))
        guard case .list(let items) = try #require(blocks.last) else { Issue.record("Expected a list"); return }
        #expect(items.map(\.checked) == [true, false, nil])
        #expect(items.map { String($0.text.characters) } == ["done", "todo", "plain"])
    }

    // MARK: Highlighting

    @Test func highlightsKeywordsStringsCommentsAndFunctions() {
        let tokens = SyntaxHighlighter.tokens("let x = foo(\"hi\") // note\nreturn 42", language: "swift")
        func kind(_ text: String) -> SyntaxHighlighter.Kind? { tokens.first { $0.text == text }?.kind }
        #expect(kind("let") == .keyword)
        #expect(kind("foo") == .function)
        #expect(kind("\"hi\"") == .string)
        #expect(kind("// note") == .comment)
        #expect(kind("42") == .number)
        #expect(tokens.map(\.text).joined() == "let x = foo(\"hi\") // note\nreturn 42")
    }

    @Test func languageAliasesAndUnknownLanguages() {
        #expect(SyntaxHighlighter.canonicalLanguage("TS") == "typescript")
        #expect(SyntaxHighlighter.canonicalLanguage("language-sh") == "bash")
        #expect(SyntaxHighlighter.tokens("anything", language: "klingon") == [.init(text: "anything", kind: .plain)])
        #expect(SyntaxHighlighter.tokens("anything", language: nil).count == 1)
    }

    @Test func jsonKeysAreProperties() {
        let tokens = SyntaxHighlighter.tokens("{\"a\": \"b\", \"n\": 1}", language: "json")
        #expect(tokens.first { $0.text == "\"a\"" }?.kind == .property)
        #expect(tokens.first { $0.text == "\"b\"" }?.kind == .string)
    }

    @Test func diffAndMarkupAndShell() {
        let diff = SyntaxHighlighter.tokens("+added\n-gone\n same", language: "diff")
        #expect(diff.map(\.kind) == [.addition, .deletion, .plain])
        let html = SyntaxHighlighter.tokens("<div class=\"x\">hi</div>", language: "html")
        #expect(html.contains { $0.text == "div" && $0.kind == .tag })
        #expect(html.contains { $0.text == "class" && $0.kind == .attribute })
        let shell = SyntaxHighlighter.tokens("echo $HOME # hi", language: "sh")
        #expect(shell.contains { $0.text == "$HOME" && $0.kind == .variable })
        #expect(shell.contains { $0.text == "# hi" && $0.kind == .comment })
    }

    @Test func tokensAlwaysReassembleTheSource() {
        let samples = ["func f() {\n  `x`\n}", "\"unterminated\nline", "a /* open", "'''doc'''", "<a href='x"]
        for language in ["swift", "python", "javascript", "html", "css", "yaml", "sql", "bash", "rust"] {
            for sample in samples {
                #expect(SyntaxHighlighter.tokens(sample, language: language).map(\.text).joined() == sample)
            }
        }
    }

    // MARK: Timeline

    private func tool(_ id: String, _ time: String, _ detail: ConversationDetail, status: String = "completed") -> ConversationEntry {
        .init(id: "activity:" + id, kind: .tool, text: detail.title, timestamp: time, status: status, detail: detail)
    }

    @Test func groupsWorkBetweenMessagesAndSummarisesIt() throws {
        var edit = ConversationDetail(tool: .fileChange, title: "a.swift", additions: 12, deletions: 3,
                                      files: [.init(path: "a.swift")])
        edit.endTimestamp = "2026-01-01T10:01:23.000Z"
        let entries: [ConversationEntry] = [
            .init(id: "message:u", kind: .user, text: "Fix it", timestamp: "2026-01-01T10:00:00.000Z"),
            tool("1", "2026-01-01T10:00:01.000Z", .init(tool: .command, title: "swift test")),
            tool("2", "2026-01-01T10:00:05.000Z", .init(tool: .read, title: "Sources/a.swift")),
            .init(id: "activity:r", kind: .reasoning, text: "Thinking", timestamp: "2026-01-01T10:00:06.000Z"),
            tool("3", "2026-01-01T10:00:10.000Z", edit),
            .init(id: "message:a", kind: .assistant, text: "Done", timestamp: "2026-01-01T10:01:30.000Z")
        ]
        let rows = ConversationTimeline.rows(entries)
        #expect(rows.count == 3)
        guard case .work(let group) = rows[1] else { Issue.record("Expected a work group"); return }
        #expect(group.entries.count == 4)
        #expect(!group.isActive)
        #expect(group.title == "Worked for 1m 22s")
        #expect(group.summary.text == "Edited 1 file +12 −3 · Ran 1 command · Read 1 file")
    }

    @Test func trailingWorkIsActiveWhileTheThreadRuns() throws {
        let entries: [ConversationEntry] = [
            .init(id: "message:u", kind: .user, text: "Go", timestamp: "2026-01-01T10:00:00.000Z"),
            tool("1", "2026-01-01T10:00:01.000Z", .init(tool: .command, title: "ls"), status: "completed")
        ]
        guard case .work(let idle) = ConversationTimeline.rows(entries)[1],
              case .work(let running) = ConversationTimeline.rows(entries, threadRunning: true)[1]
        else { Issue.record("Expected a work group"); return }
        #expect(!idle.isActive)
        #expect(running.isActive)
        #expect(running.title == "Working…")
    }

    @Test func keepsOnlyTheLatestTodoAndSurfacesErrorsAndPlans() {
        let todo = { (id: String, time: String) in
            ConversationEntry(id: id, kind: .todo, text: "", timestamp: time,
                              detail: .init(steps: [.init(text: "Step", status: "pending")]))
        }
        let entries: [ConversationEntry] = [
            todo("t1", "2026-01-01T10:00:00.000Z"),
            .init(id: "p", kind: .plan, text: "# Plan", timestamp: "2026-01-01T10:00:01.000Z"),
            todo("t2", "2026-01-01T10:00:02.000Z"),
            .init(id: "e", kind: .error, text: "Boom", timestamp: "2026-01-01T10:00:03.000Z")
        ]
        let rows = ConversationTimeline.rows(entries)
        #expect(rows.map(\.id) == ["p", "t2", "e"])
    }

    @Test func formatsDurationsAndToolRows() {
        #expect(TimelineFormat.duration(9) == "9s")
        #expect(TimelineFormat.duration(83) == "1m 23s")
        #expect(TimelineFormat.duration(7500) == "2h 5m")
        #expect(ToolClassifier.classify("Read") == .read)
        #expect(ToolClassifier.classify("Grep") == .search)
        #expect(ToolClassifier.classify("Bash") == .command)
        #expect(ToolClassifier.classify("MultiEdit") == .fileChange)
        #expect(ToolClassifier.classify("WebFetch") == .web)
        #expect(ToolClassifier.classify("Task") == .other)
        let multi = ConversationDetail(tool: .fileChange, title: "a/b/c/d/e.swift",
                                       files: [.init(path: "a/b/c/d/e.swift"), .init(path: "f.swift")])
        #expect(multi.subject == "…/c/d/e.swift +1 more")
        #expect(multi.verb == "Edited")
        #expect(ConversationDetail(toolName: "mcp__browser__click").verb == "Click")
    }

    // MARK: Wire decoding

    @Test func decodesTurnItemsIntoRichEntries() throws {
        func entry(_ json: String) throws -> ConversationEntry? {
            try JSONDecoder().decode(T3Client.TurnItem.self, from: Data(json.utf8)).entry
        }
        let command = try #require(try entry("""
        {"type":"command_execution","id":"c1","status":"failed","startedAt":"2026-01-01T10:00:00.000Z",
         "updatedAt":"2026-01-01T10:00:04.000Z","input":"npm test","output":"1 failed","exitCode":1}
        """))
        #expect(command.kind == .tool)
        #expect(command.detail?.tool == .command)
        #expect(command.detail?.failed == true)
        #expect(command.detail?.output == "1 failed")
        #expect(command.detail?.endTimestamp == "2026-01-01T10:00:04.000Z")

        let edit = try #require(try entry("""
        {"type":"file_change","id":"f1","status":"completed","startedAt":"2026-01-01T10:00:00.000Z",
         "updatedAt":"2026-01-01T10:00:01.000Z","fileName":"a.swift","additions":4,"deletions":1,
         "diffStr":"+a\\n-b","changes":[{"path":"a.swift","operation":"edit"}]}
        """))
        #expect(edit.detail?.additions == 4)
        #expect(edit.detail?.files.map(\.path) == ["a.swift"])

        let todo = try #require(try entry("""
        {"type":"todo_list","id":"t1","status":"completed","startedAt":"2026-01-01T10:00:00.000Z",
         "updatedAt":"2026-01-01T10:00:01.000Z","steps":[{"id":"1","text":"Do it","status":"running"}]}
        """))
        #expect(todo.kind == .todo)
        #expect(todo.detail?.steps == [.init(text: "Do it", status: "running")])

        let error = try #require(try entry("""
        {"type":"error","id":"e1","status":"failed","startedAt":"2026-01-01T10:00:00.000Z",
         "updatedAt":"2026-01-01T10:00:01.000Z","failure":{"class":"x","message":"Rate limited","code":null,"retryable":true}}
        """))
        #expect(error.kind == .error)
        #expect(error.text == "Rate limited")

        let dynamic = try #require(try entry("""
        {"type":"dynamic_tool","id":"d1","status":"completed","startedAt":"2026-01-01T10:00:00.000Z",
         "updatedAt":"2026-01-01T10:00:01.000Z","toolName":"Grep","input":{"pattern":"TODO"}}
        """))
        #expect(dynamic.detail?.tool == .search)
        #expect(dynamic.detail?.title == "TODO")

        let waiting = try entry("""
        {"type":"approval_request","id":"a1","status":"waiting","startedAt":"2026-01-01T10:00:00.000Z",
         "updatedAt":"2026-01-01T10:00:01.000Z","requestId":"r","requestKind":"command"}
        """)
        #expect(waiting == nil)
        let settled = try #require(try entry("""
        {"type":"approval_request","id":"a1","status":"completed","startedAt":"2026-01-01T10:00:00.000Z",
         "updatedAt":"2026-01-01T10:00:01.000Z","requestId":"r","requestKind":"command","prompt":"Run ls"}
        """))
        #expect(settled.kind == .approval)
        #expect(settled.text == "Run ls")
    }
}
