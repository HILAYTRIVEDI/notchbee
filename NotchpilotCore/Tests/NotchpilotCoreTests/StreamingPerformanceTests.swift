import Foundation
import Testing
@testable import NotchpilotCore

struct StreamingPerformanceTests {
    private let document = """
    # Title

    First paragraph with **bold** and `code`.
    Second line.

    - one
      continued
    - two

    ```swift
    let x = 1

    let y = 2
    ```

    | A | B |
    |:--|--:|
    | 1 | 2 |
    | 3 | 4 |

    > quoted
    > text

    1. first
    2. second

    Closing paragraph.
    """

    @Test func incrementalParsingMatchesAFullParseAtEveryPrefix() {
        var previous: MessageMarkdown.Parsed?
        // Stream the document two characters at a time, like a provider delivering deltas.
        var index = document.startIndex
        while index < document.endIndex {
            index = document.index(index, offsetBy: 2, limitedBy: document.endIndex) ?? document.endIndex
            let prefix = String(document[..<index])
            let incremental = MessageMarkdown.parseIncremental(prefix, previous: previous)
            let full = MessageMarkdown.parseDetailed(prefix)
            #expect(incremental.blocks == full.blocks, "prefix: \(prefix.suffix(40))")
            #expect(incremental.starts == full.starts)
            previous = incremental
        }
    }

    @Test func incrementalParsingFallsBackWhenEarlierTextChanges() {
        let first = MessageMarkdown.parseDetailed("alpha\n\nbeta\n\ngamma")
        let edited = MessageMarkdown.parseIncremental("ALPHA\n\nbeta\n\ngamma tail", previous: first)
        #expect(edited.blocks == MessageMarkdown.parseDetailed("ALPHA\n\nbeta\n\ngamma tail").blocks)
    }

    private func message(_ id: String, _ text: String, _ second: Int, streaming: Bool = false) -> ConversationEntry {
        .init(id: id, kind: .assistant, text: text, timestamp: "2026-01-01T10:00:\(String(format: "%02d", second)).000Z", streaming: streaming)
    }

    private func tool(_ id: String, _ second: Int) -> ConversationEntry {
        .init(id: "activity:" + id, kind: .tool, text: id, timestamp: "2026-01-01T10:00:\(String(format: "%02d", second)).000Z",
              status: "completed", detail: .init(tool: .command, title: id))
    }

    @Test func conversationKeepsRowsInSyncWithAFullRebuildWhileUpserting() {
        var conversation = ThreadConversation([
            .init(id: "message:u", kind: .user, text: "go", timestamp: "2026-01-01T10:00:00.000Z"),
            tool("a", 1), tool("b", 2), message("message:a", "hi", 3)
        ])
        let steps: [ConversationEntry] = [
            message("message:a", "hi there", 3, streaming: true),
            tool("c", 4),                                    // new work group after the message
            tool("d", 5),
            message("message:b", "second", 6),
            tool("b", 2),                                    // in-place replacement inside the first group
            .init(id: "t1", kind: .todo, text: "", timestamp: "2026-01-01T10:00:07.000Z", detail: .init(steps: [])),
            .init(id: "t2", kind: .todo, text: "", timestamp: "2026-01-01T10:00:08.000Z", detail: .init(steps: [])),
            tool("early", 0)                                 // arrives out of order, before everything
        ]
        for step in steps {
            conversation.upsert(step)
            #expect(conversation.timelineRows == ConversationTimeline.rows(conversation.entries),
                    "after \(step.id)")
        }
        #expect(conversation.timelineRows.filter { if case .todo = $0 { true } else { false } }.count == 1)
    }

    @Test func activeGroupIsDerivedWithoutRewritingRows() {
        var conversation = ThreadConversation([
            .init(id: "message:u", kind: .user, text: "go", timestamp: "2026-01-01T10:00:00.000Z"),
            tool("a", 1)
        ])
        #expect(conversation.activeWorkGroupID(threadRunning: false) == nil)
        #expect(conversation.activeWorkGroupID(threadRunning: true) == "activity:a")
        conversation.upsert(message("message:a", "done", 5))
        #expect(conversation.activeWorkGroupID(threadRunning: true) == nil)
    }

    @Test func workGroupDurationIsParsedOnceAtBuildTime() {
        let rows = ConversationTimeline.rows([tool("a", 1), tool("b", 12)])
        guard case .work(let group) = rows[0] else { Issue.record("Expected a work group"); return }
        #expect(group.duration == 11)
        #expect(group.title(active: false) == "Worked for 11s")
        #expect(group.title(active: true) == "Working…")
    }

    @Test func coalescingKeepsOnlyTheNewestUpdatePerEntry() {
        let a1 = message("message:a", "h", 1), a2 = message("message:a", "hi", 1), b1 = message("message:b", "x", 2)
        let events: [AppEvent] = [
            .conversationEntry(sessionID: "s", entry: a1), .conversationEntry(sessionID: "s", entry: b1),
            .collapsePanel, .conversationEntry(sessionID: "s", entry: a2), .conversationEntry(sessionID: "other", entry: a1)
        ]
        #expect(AppEventCoalescer.coalesce(events) == [
            .conversationEntry(sessionID: "s", entry: b1), .collapsePanel,
            .conversationEntry(sessionID: "s", entry: a2), .conversationEntry(sessionID: "other", entry: a1)
        ])
        #expect(AppEventCoalescer.isStreamingOnly([.conversationEntry(sessionID: "s", entry: a1)]))
        #expect(!AppEventCoalescer.isStreamingOnly([.collapsePanel]))
    }
}
