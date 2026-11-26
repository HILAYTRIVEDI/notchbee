import Foundation
import Testing
import NotchpilotCore

struct MessageMarkdownTests {
    @Test func headingLevelsAndPlainParagraphs() {
        #expect(MessageMarkdown.parse("# Part 1\n## Detail\n### Note\n\nPlain text\nsecond line") == [
            .heading(1, AttributedString("Part 1")),
            .heading(2, AttributedString("Detail")),
            .heading(3, AttributedString("Note")),
            .paragraph(AttributedString("Plain text\nsecond line"))
        ])
        #expect(MessageMarkdown.parse("") == [])
    }

    @Test func listsKeepMarkersIndentAndContinuation() throws {
        let blocks = MessageMarkdown.parse("- First\n  continued\n  + Nested\n9. Numbered")
        guard case .list(let items) = try #require(blocks.first) else {
            Issue.record("Expected a list")
            return
        }
        #expect(items.map(\.marker) == ["•", "•", "9."])
        #expect(items.map(\.indent) == [0, 2, 0])
        #expect(items.map { String($0.text.characters) } == ["First\ncontinued", "Nested", "Numbered"])
    }

    @Test func nestedInlineStylesAndLinks() throws {
        let markdown = "**bold *and italic***, `code`, ~~gone~~, [Link](https://example.com)"
        guard case .paragraph(let text) = try #require(MessageMarkdown.parse(markdown).first) else {
            Issue.record("Expected a paragraph")
            return
        }
        #expect(String(text.characters) == "bold and italic, code, gone, Link")
        #expect(text.runs.contains { $0.inlinePresentationIntent?.contains([.stronglyEmphasized, .emphasized]) == true })
        #expect(text.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        #expect(text.runs.contains { $0.inlinePresentationIntent?.contains(.strikethrough) == true })
        #expect(text.runs.contains { $0.link?.host == "example.com" })
    }

    @Test func fencesPreserveCodeAndRenderBeforeClosing() {
        #expect(MessageMarkdown.parse("```python\n  # comment\n\n```\nAfter") == [
            .code(language: "python", text: "  # comment\n"),
            .paragraph(AttributedString("After"))
        ])
        #expect(MessageMarkdown.parse("Before\n```\n  unfinished") == [
            .paragraph(AttributedString("Before")), .code(language: nil, text: "  unfinished")
        ])
    }

    @Test func quoteAndRule() {
        #expect(MessageMarkdown.parse("> One\n> Two\n* * *") == [
            .quote(AttributedString("One\nTwo")), .rule
        ])
    }

    @Test func tableCellsKeepFullWrappingTextAndInlineMarkdown() throws {
        let long = String(repeating: "wraps across several lines ", count: 6)
        let blocks = MessageMarkdown.parse("| Surface | Detail |\n|:--|--:|\n| **Row** | \(long) |")
        guard case .table(let table) = try #require(blocks.first) else {
            Issue.record("Expected a table")
            return
        }
        #expect(table.headers.count == 2 && table.rows.count == 1)
        #expect(String(table.rows[0][1].characters) == long.trimmingCharacters(in: .whitespaces))
        #expect(String(table.rows[0][0].characters) == "Row")
    }
}

@Suite struct MessageLinkSafetyTests {
    @Test func keepsWebLinksAndDropsOthers() {
        #expect(MessageMarkdown.isSafeLink(URL(string: "https://example.com")!))
        #expect(MessageMarkdown.isSafeLink(URL(string: "mailto:a@b.c")!))
        #expect(!MessageMarkdown.isSafeLink(URL(string: "file:///tmp/x.command")!))
        #expect(!MessageMarkdown.isSafeLink(URL(string: "shortcuts://run-shortcut?name=x")!))
        #expect(!MessageMarkdown.isSafeLink(URL(string: "ssh://host")!))
    }
}
