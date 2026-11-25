import AppKit
import NotchpilotCore
import SwiftUI

/// Renders assistant Markdown with T3 Code's chat typography: 0.65rem block rhythm, bordered code blocks
/// with a language header and copy button, syntax highlighting, and borderless tables.
struct MarkdownMessageView: View {
    let id: String
    let content: String
    var size: CGFloat = T3.body
    var muted = false

    private struct CachedMessage {
        let content: String
        let parsed: MessageMarkdown.Parsed
    }

    private static let cache: NSCache<NSString, CacheEntry> = {
        let cache = NSCache<NSString, CacheEntry>()
        cache.countLimit = 256
        cache.totalCostLimit = 4_000_000
        return cache
    }()

    private final class CacheEntry {
        let value: CachedMessage

        init(_ value: CachedMessage) { self.value = value }
    }

    /// Blocks for the current content. While a reply streams, only its last two blocks are re-parsed.
    private var blocks: [MessageMarkdown.Block] {
        let key = id as NSString
        let cached = Self.cache.object(forKey: key)?.value
        if let cached, cached.content == content { return cached.parsed.blocks }
        let parsed = MessageMarkdown.parseIncremental(content, previous: cached?.parsed)
        Self.cache.setObject(CacheEntry(CachedMessage(content: content, parsed: parsed)), forKey: key, cost: content.utf8.count * 2)
        return parsed.blocks
    }

    var body: some View {
        let blocks = blocks
        VStack(alignment: .leading, spacing: (size * 0.9).rounded()) {
            ForEach(blocks.indices, id: \.self) { index in
                MarkdownBlockView(block: blocks[index], size: size, first: index == 0).equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(T3.link)
        .foregroundStyle(muted ? T3.muted : T3.foreground)
        .textSelection(.enabled)
        // Second guard behind MessageMarkdown's scheme filter: never hand a non-web link to the system.
        .environment(\.openURL, OpenURLAction { url in
            MessageMarkdown.isSafeLink(url) ? .systemAction : .discarded
        })
    }
}

private struct MarkdownBlockView: View, Equatable {
    let block: MessageMarkdown.Block
    let size: CGFloat
    let first: Bool

    var body: some View {
        switch block {
        case .heading(let level, let text):
            let scale: [CGFloat] = [1.38, 1.23, 1.11, 1, 1, 1]
            inline(text, size: size * scale[min(level, 6) - 1], weight: level <= 3 ? .semibold : .semibold)
                .foregroundStyle(level == 6 ? T3.muted : T3.foreground)
                .padding(.top, first ? 0 : 7)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            inline(text, size: size)
        case .list(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items.indices, id: \.self) { index in
                    listRow(items[index])
                }
            }
        case .quote(let text):
            inline(text, size: size)
                .foregroundStyle(T3.muted)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18)).frame(width: 2)
                }
        case .rule:
            Rectangle().fill(T3.border).frame(height: 1).padding(.vertical, 4)
        case .code(let language, let text):
            CodeBlockView(language: language, text: text)
        case .table(let table):
            MarkdownTableView(table: table, size: size)
        }
    }

    private func listRow(_ item: MessageMarkdown.ListItem) -> some View {
        let depth = min(item.indent / 2, 4)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Group {
                if let checked = item.checked {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(checked ? T3.primary : T3.muted)
                } else if item.marker == "•" {
                    Text(verbatim: ["•", "◦", "▪", "•", "◦"][depth]).foregroundStyle(T3.muted)
                } else {
                    Text(verbatim: item.marker).monospacedDigit().foregroundStyle(T3.muted)
                }
            }
            .font(.system(size: size - 1))
            .frame(minWidth: 14, alignment: .trailing)
            inline(item.text, size: size)
                .foregroundStyle(item.checked == true ? T3.muted : T3.foreground)
        }
        .padding(.leading, CGFloat(depth) * 16)
    }

    private func inline(_ source: AttributedString, size: CGFloat, weight: Font.Weight = .regular) -> some View {
        InlineMarkdownText(source: source, size: size, weight: weight)
    }
}

/// Inline Markdown with T3's inline-code chip (10% foreground fill, 4pt radius, 0.85em mono).
struct InlineMarkdownText: View {
    let source: AttributedString
    var size: CGFloat = T3.body
    var weight: Font.Weight = .regular

    var body: some View {
        var hasCode = false
        let text = source.runs.reduce(Text("")) { result, run in
            let intent = run.inlinePresentationIntent ?? []
            let isCode = intent.contains(.code)
            if isCode { hasCode = true }
            var fragment = AttributedString(source[run.range])
            fragment.font = isCode
                ? .system(size: size * 0.9, weight: .regular, design: .monospaced)
                : .system(size: size, weight: intent.contains(.stronglyEmphasized) ? .bold : weight)
            var text = Text(fragment)
            if isCode { text = text.customAttribute(InlineCode()) }
            if intent.contains(.strikethrough) { text = text.strikethrough() }
            return Text("\(result)\(text)")
        }
        let laidOut = text
            .lineSpacing(size * 0.28)
            .fixedSize(horizontal: false, vertical: true)
        if hasCode {
            // Selectable Text can use a platform view that bypasses custom drawing, so the chip fill is drawn by a
            // second, non-selectable layer. Paragraphs without inline code skip the extra layout entirely.
            laidOut.background(alignment: .topLeading) {
                text.lineSpacing(size * 0.28).textRenderer(InlineCodeBackground())
                    .textSelection(.disabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        } else {
            laidOut
        }
    }
}

private struct InlineCode: TextAttribute {}

private struct InlineCodeBackground: TextRenderer {
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line where run[InlineCode.self] != nil {
                let bounds = run.typographicBounds.rect.insetBy(dx: -2, dy: -1)
                context.fill(Path(roundedRect: bounds, cornerRadius: 4), with: .color(.white.opacity(0.10)))
            }
        }
    }
}

// MARK: Code blocks

struct CodeBlockView: View {
    let language: String?
    let text: String
    @State private var copied = false
    @State private var expanded = false
    @State private var hovering = false
    @AppStorage("syntaxHighlighting") private var highlights = true

    private static let collapsedLines = 24

    private var lineCount: Int { text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 } }
    private var collapsible: Bool { lineCount > Self.collapsedLines + 6 }

    private var displayed: String {
        guard collapsible, !expanded else { return text }
        return text.split(separator: "\n", maxSplits: Self.collapsedLines, omittingEmptySubsequences: false)
            .prefix(Self.collapsedLines).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(verbatim: (language?.isEmpty == false ? language! : "text").lowercased())
                    .font(.system(size: T3.micro + 0.5, design: .monospaced))
                    .foregroundStyle(T3.muted)
                Spacer(minLength: 0)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        copied = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        if copied { Text("Copied") }
                    }
                    .font(.system(size: T3.micro + 0.5, weight: .medium))
                    .foregroundStyle(copied ? T3.success : T3.muted)
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .hoverPlate(radius: 5)
                }
                .buttonStyle(.plain).clickableCursor()
                .opacity(hovering || copied ? 1 : 0.55)
                .help("Copy code")
                .accessibilityLabel("Copy code")
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .frame(height: 26)

            ScrollView(.horizontal) {
                Text(highlights ? CodeHighlighter.attributed(displayed, language: language) : AttributedString(displayed))
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(2)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .padding(.top, 2)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)

            if collapsible {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Text(expanded ? "Show less" : "Show \(lineCount - Self.collapsedLines) more lines")
                        .font(.system(size: T3.caption, weight: .medium))
                        .foregroundStyle(T3.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .hoverPlate(radius: 0)
                }
                .buttonStyle(.plain).clickableCursor()
                .overlay(alignment: .top) { Rectangle().fill(T3.border).frame(height: 1) }
            }
        }
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(T3.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
    }
}

// MARK: Tables

private struct MarkdownTableView: View {
    let table: MessageMarkdown.Table
    let size: CGFloat

    @State private var viewport: CGFloat = 0
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let columns = table.headers.count
        let font = NSFont.systemFont(ofSize: size - 1, weight: .semibold)
        let firstCells = [table.headers.first] + table.rows.map(\.first)
        let ideal = firstCells.compactMap { $0 }.map {
            (String($0.characters) as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        let firstWidth = columns == 1 ? max(80, viewport) : min(ceil(ideal) + 16, max(64, viewport * 0.35))
        let otherWidth = max(106, (viewport - firstWidth) / CGFloat(max(1, columns - 1)))

        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                row(table.headers, header: true, firstWidth: firstWidth, otherWidth: otherWidth)
                ForEach(table.rows.indices, id: \.self) { index in
                    row(table.rows[index], header: false, firstWidth: firstWidth, otherWidth: otherWidth)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { viewport = $0 }
        .fixedSize(horizontal: false, vertical: true)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private func row(_ cells: [AttributedString], header: Bool, firstWidth: CGFloat, otherWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(cells.indices, id: \.self) { column in
                cell(cells[column], column: column, header: header, width: column == 0 ? firstWidth : otherWidth)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(header ? 0.18 : 0.09)).frame(height: 1 / displayScale)
        }
    }

    private func cell(_ text: AttributedString, column: Int, header: Bool, width: CGFloat) -> some View {
        let alignment = table.alignments.indices.contains(column) ? table.alignments[column] : .leading
        let frameAlignment: Alignment = switch alignment {
        case .leading: .topLeading
        case .center: .top
        case .trailing: .topTrailing
        }
        return InlineMarkdownText(source: text, size: size - 1, weight: header ? .semibold : .regular)
            .padding(.horizontal, 8)
            .frame(width: width, alignment: frameAlignment)
    }
}
