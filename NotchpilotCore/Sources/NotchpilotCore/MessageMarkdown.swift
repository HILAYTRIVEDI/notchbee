import Foundation

public enum MessageMarkdown {
    public enum Block: Equatable, Sendable {
        case heading(Int, AttributedString)
        case paragraph(AttributedString)
        case list([ListItem])
        case quote(AttributedString)
        case rule
        case code(language: String?, text: String)
        case table(Table)
    }

    public struct ListItem: Equatable, Sendable {
        public let marker: String
        public let indent: Int
        public let text: AttributedString
        /// `true`/`false` for GitHub task-list items (`- [x]`), `nil` otherwise.
        public let checked: Bool?

        public init(marker: String, indent: Int, text: AttributedString, checked: Bool? = nil) {
            self.marker = marker
            self.indent = indent
            self.text = text
            self.checked = checked
        }
    }

    public struct Table: Equatable, Sendable {
        public enum Alignment: Sendable { case leading, center, trailing }
        public let headers: [AttributedString]
        public let alignments: [Alignment]
        public let rows: [[AttributedString]]
    }

    public static func parse(_ source: String) -> [Block] { parseDetailed(source).blocks }

    /// A parse plus the line each block starts on, which lets a streaming reply re-parse only its last block.
    public struct Parsed: Sendable, Equatable {
        public let source: String
        public let blocks: [Block]
        /// Line index (in `source`) where each block begins; parsing restarts cleanly at any of these.
        let starts: [Int]
    }

    /// Re-parses `source` reusing every block of `previous` except the last two, when the text before them is
    /// unchanged. The last block can change type as text streams in (a stray `-` becoming a list item) and then
    /// merge with the block before it, so the restart point is the second-to-last block. Equivalent to
    /// `parseDetailed(source)`.
    public static func parseIncremental(_ source: String, previous: Parsed?) -> Parsed {
        let normalized = normalize(source)
        guard let previous, previous.starts.count >= 3, case let restart = previous.starts[previous.starts.count - 2],
              restart > 0 else {
            return parseDetailed(source)
        }
        let previousLines = previous.source.components(separatedBy: "\n")
        let newLines = normalized.components(separatedBy: "\n")
        guard restart <= previousLines.count, restart <= newLines.count,
              previousLines[..<restart].elementsEqual(newLines[..<restart]) else {
            return parseDetailed(source)
        }
        let tail = parseDetailed(newLines[restart...].joined(separator: "\n"))
        let kept = previous.starts.count - 2
        return Parsed(source: normalized, blocks: Array(previous.blocks.prefix(kept)) + tail.blocks,
                      starts: Array(previous.starts.prefix(kept)) + tail.starts.map { $0 + restart })
    }

    private static func normalize(_ source: String) -> String {
        source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    public static func parseDetailed(_ source: String) -> Parsed {
        let listMarker = /^( *)([-+*]|[0-9]+[.)])[ \t]+(.*)$/
        let normalized = normalize(source)
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [Block] = []
        var starts: [Int] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var items: [ListItem] = []
        var paragraphStart = 0, quoteStart = 0, itemsStart = 0, fenceStart = 0
        var fence: (marker: Character, count: Int, language: String?)?
        var code: [String] = []

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(inline(paragraph.joined(separator: "\n")))); starts.append(paragraphStart) }
            if !quote.isEmpty { blocks.append(.quote(inline(quote.joined(separator: "\n")))); starts.append(quoteStart) }
            if !items.isEmpty { blocks.append(.list(items)); starts.append(itemsStart) }
            paragraph.removeAll()
            quote.removeAll()
            items.removeAll()
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let lineIndex = index
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let marker = trimmed.first
            let run = trimmed.prefix { $0 == marker }.count
            if let open = fence {
                if marker == open.marker, run >= open.count, trimmed.dropFirst(run).allSatisfy(\.isWhitespace) {
                    blocks.append(.code(language: open.language, text: code.joined(separator: "\n")))
                    starts.append(fenceStart)
                    code.removeAll()
                    fence = nil
                } else {
                    code.append(line)
                }
                continue
            }
            if let marker, (marker == "`" || marker == "~"), run >= 3 {
                flush()
                let language = trimmed.dropFirst(run).split(whereSeparator: \.isWhitespace).first.map(String.init)
                fence = (marker, run, language)
                fenceStart = lineIndex
            } else if trimmed.isEmpty {
                flush()
            } else if marker == "#", (1...6).contains(run), trimmed.dropFirst(run).first?.isWhitespace == true {
                flush()
                let title = trimmed.dropFirst(run).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(run, inline(title)))
                starts.append(lineIndex)
            } else if let marker, "-*_".contains(marker),
                      trimmed.filter({ $0 == marker }).count >= 3,
                      trimmed.allSatisfy({ $0 == marker || $0.isWhitespace }) {
                flush()
                blocks.append(.rule)
                starts.append(lineIndex)
            } else if trimmed.contains("|"), index < lines.count,
                      let alignments = tableAlignments(lines[index]),
                      case let headers = tableCells(trimmed), headers.count == alignments.count {
                flush()
                var rows: [[AttributedString]] = []
                index += 1
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    var cells = tableCells(row).map(inline)
                    if cells.count > headers.count { cells = Array(cells.prefix(headers.count)) }
                    while cells.count < headers.count { cells.append(AttributedString()) }
                    rows.append(cells)
                    index += 1
                }
                blocks.append(.table(Table(headers: headers.map(inline), alignments: alignments, rows: rows)))
                starts.append(lineIndex)
            } else if marker == ">" {
                if !paragraph.isEmpty || !items.isEmpty { flush() }
                let content = trimmed.dropFirst()
                if quote.isEmpty { quoteStart = lineIndex }
                quote.append(String(content.first == " " ? content.dropFirst() : content))
            } else if let match = line.wholeMatch(of: listMarker) {
                if !paragraph.isEmpty || !quote.isEmpty { flush() }
                let marker = String(match.2)
                var body = String(match.3)
                var checked: Bool?
                if body.hasPrefix("[ ] ") || body == "[ ]" { checked = false; body = String(body.dropFirst(3)) }
                else if body.hasPrefix("[x] ") || body.hasPrefix("[X] ") || body.lowercased() == "[x]" {
                    checked = true
                    body = String(body.dropFirst(3))
                }
                if items.isEmpty { itemsStart = lineIndex }
                items.append(ListItem(marker: marker.count == 1 ? "•" : marker, indent: match.1.count,
                                      text: inline(body.trimmingCharacters(in: .whitespaces)), checked: checked))
            } else if let last = items.last, line.prefix(while: { $0 == " " }).count >= last.indent + 2 {
                var text = last.text
                text.append(inline("\n" + trimmed))
                items[items.count - 1] = ListItem(marker: last.marker, indent: last.indent, text: text, checked: last.checked)
            } else {
                if !quote.isEmpty || !items.isEmpty { flush() }
                if paragraph.isEmpty { paragraphStart = lineIndex }
                paragraph.append(line)
            }
        }
        flush()
        if let fence {
            blocks.append(.code(language: fence.language, text: code.joined(separator: "\n")))
            starts.append(fenceStart)
        }
        return Parsed(source: normalized, blocks: blocks, starts: starts)
    }

    /// Cell text of a pipe-delimited row; escaped pipes stay in the cell.
    static func tableCells(_ row: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false
        for character in row {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
                current.append(character)
            } else if character == "`" {
                inCode.toggle()
                current.append(character)
            } else if character == "|", !inCode {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current)
        var trimmed = cells.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: "|") }
        if row.hasPrefix("|") { trimmed.removeFirst() }
        if row.hasSuffix("|"), !row.hasSuffix("\\|"), !trimmed.isEmpty { trimmed.removeLast() }
        return trimmed
    }

    static func tableAlignments(_ line: String) -> [Table.Alignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.allSatisfy({ "|:- ".contains($0) }) else { return nil }
        let cells = tableCells(trimmed)
        guard !cells.isEmpty, cells.allSatisfy({ cell in
            let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return !core.isEmpty && core.allSatisfy { $0 == "-" }
        }) else { return nil }
        return cells.map { cell in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): .center
            case (false, true): .trailing
            default: .leading
            }
        }
    }

    private static func inline(_ text: String) -> AttributedString {
        var result = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        // Model output is untrusted: a link could point at file://, shortcuts:// or another scheme that runs
        // something on click. Keep only web and mail links.
        for run in result.runs {
            guard let url = run.link else { continue }
            if !isSafeLink(url) { result[run.range].link = nil }
        }
        return result
    }

    public static func isSafeLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http" || scheme == "mailto"
    }
}
