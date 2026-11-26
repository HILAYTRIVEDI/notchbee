import AppKit
import NotchpilotCore
import SwiftUI

/// The thread's scrolling timeline: messages, folded work logs, plan/todo cards, approvals and errors.
struct ThreadTimeline<Header: View>: View {
    let state: AppState
    let threadRunning: Bool
    /// A message was just sent and the thread has not reported running yet.
    var sending = false
    @ViewBuilder let header: () -> Header

    @State private var nearBottom = !ThreadTimeline<EmptyView>.startsAtTop

    fileprivate static var startsAtTop: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "debugScrollTop")
        #else
        false
        #endif
    }

    var body: some View {
        let conversation = state.conversation
        let rows = conversation?.timelineRows ?? []
        let activeGroup = conversation?.activeWorkGroupID(threadRunning: threadRunning)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                header()
                if !state.panelSnapshot.conversationUnavailable, rows.isEmpty {
                    Text(conversation == nil ? "Loading conversation…" : "No messages yet")
                        .font(.system(size: T3.small)).foregroundStyle(T3.muted)
                }
                ForEach(rows) { row in
                    TimelineRowView(row: row, activeGroup: activeGroup).equatable()
                }
                if showsThinking(rows: rows, activeGroup: activeGroup) {
                    ThinkingIndicator()
                        .id("thinking")
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
        .defaultScrollAnchor(Self.startsAtTop ? .top : .bottom, for: .initialOffset)
        // Let the scroll view preserve the edge as a streamed message grows, until the reader scrolls away.
        .defaultScrollAnchor(nearBottom && !Self.startsAtTop ? .bottom : nil, for: .sizeChanges)
        .mask(alignment: .top) {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 10)
                Rectangle()
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .animation(.easeOut(duration: 0.2), value: showsThinking(rows: rows, activeGroup: activeGroup))
        .onScrollGeometryChange(for: Bool.self, of: { geometry in
            geometry.contentSize.height - geometry.visibleRect.maxY < 32
        }) { _, value in nearBottom = value }
    }
}

extension ThreadTimeline {
    /// Fill the gap between sending and visible output: no streamed text yet and no live work log.
    fileprivate func showsThinking(rows: [TimelineRow], activeGroup: String?) -> Bool {
        guard threadRunning || sending, activeGroup == nil else { return false }
        switch rows.last {
        case .message(let entry)? where entry.kind != .user:
            // A streaming reply with text, or an empty one that already says "Thinking…".
            return !entry.streaming
        case .work?: return false
        default: return true
        }
    }
}

/// Pulsing dots and a shimmer while the model works on a reply.
private struct ThinkingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date.now

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSince(start)
            let elapsed = Int(t)
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(0..<3) { i in
                        let phase = reduceMotion ? 1 : (sin(t * 5 - Double(i) * 0.7) + 1) / 2
                        Circle()
                            .fill(T3.link)
                            .frame(width: 6, height: 6)
                            .opacity(0.35 + 0.65 * phase)
                            .scaleEffect(0.8 + 0.25 * phase)
                    }
                }
                Text("Thinking…")
                    .font(.system(size: T3.body, weight: .medium))
                    .foregroundStyle(T3.muted)
                    .overlay {
                        if !reduceMotion {
                            GeometryReader { geo in
                                let x = (t.truncatingRemainder(dividingBy: 1.8) / 1.8) * (geo.size.width + 60) - 30
                                LinearGradient(colors: [.clear, .white.opacity(0.55), .clear],
                                               startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 30)
                                    .offset(x: x)
                            }
                            .mask(Text("Thinking…").font(.system(size: T3.body, weight: .medium)))
                        }
                    }
                if elapsed >= 3 {
                    Text("\(elapsed)s")
                        .font(.system(size: T3.caption).monospacedDigit())
                        .foregroundStyle(T3.faint)
                }
            }
        }
        .padding(.horizontal, 1)
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The model is thinking")
    }
}

private struct TimelineRowView: View, Equatable {
    let row: TimelineRow
    let activeGroup: String?

    var body: some View {
        switch row {
        case .message(let entry):
            if entry.kind == .user { UserMessageView(entry: entry) } else { AssistantMessageView(entry: entry) }
        case .work(let group): WorkGroupView(group: group, isActive: group.id == activeGroup)
        case .plan(let entry): PlanCardView(entry: entry)
        case .todo(let entry): TodoCardView(entry: entry)
        case .error(let entry): ErrorBannerView(entry: entry)
        case .approval(let entry): ApprovalRecordView(entry: entry)
        case .notice(let entry): NoticeDivider(text: entry.text)
        }
    }
}

// MARK: Messages

private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(copied ? T3.success : T3.muted)
                .frame(width: 22, height: 20)
                .hoverPlate(radius: 5)
        }
        .buttonStyle(.plain).clickableCursor()
        .help("Copy message")
        .accessibilityLabel("Copy message")
    }
}

private struct MessageMeta: View {
    let entry: ConversationEntry
    let hovering: Bool
    var trailing = false
    @AppStorage("showTimestamps") private var showTimestamps = true

    var body: some View {
        HStack(spacing: 4) {
            if trailing { Spacer(minLength: 0) }
            if showTimestamps, let time = TimelineFormat.time(entry.timestamp) {
                Text(time).font(.system(size: T3.micro + 0.5)).monospacedDigit().foregroundStyle(T3.faint)
            }
            CopyButton(text: entry.text)
            if !trailing { Spacer(minLength: 0) }
        }
        .opacity(hovering ? 1 : 0)
        .frame(height: 18)
        .accessibilityHidden(!hovering)
    }
}

private struct UserMessageView: View {
    let entry: ConversationEntry
    @State private var hovering = false
    @State private var expanded = false

    private var folded: Bool { entry.text.count > 520 || entry.text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } > 8 }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 0) {
                Spacer(minLength: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: entry.text)
                        .font(.system(size: T3.body))
                        .foregroundStyle(T3.foreground)
                        .lineLimit(folded && !expanded ? 8 : nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if folded {
                        Button(expanded ? "Show less" : "Show more") {
                            withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                        }
                        .buttonStyle(.plain).clickableCursor()
                        .font(.system(size: T3.caption, weight: .medium))
                        .foregroundStyle(T3.muted)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(T3.message, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(T3.borderStrong, lineWidth: 1))
            }
            MessageMeta(entry: entry, hovering: hovering, trailing: true)
        }
        .onHover { hovering = $0 }
    }
}

private struct AssistantMessageView: View {
    let entry: ConversationEntry
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if entry.kind == .system {
                Text("System").font(.system(size: T3.caption, weight: .semibold)).foregroundStyle(T3.muted)
            }
            if entry.text.isEmpty {
                if entry.streaming {
                    ThinkingIndicator()
                }
            } else {
                MarkdownMessageView(id: entry.id, content: entry.text)
            }
            HStack(spacing: 6) {
                if entry.streaming && !entry.text.isEmpty {
                    Circle().fill(T3.muted).frame(width: 6, height: 6)
                        .symbolEffect(.pulse, isActive: true)
                        .accessibilityLabel("Streaming")
                }
                MessageMeta(entry: entry, hovering: hovering && !entry.streaming)
            }
        }
        .padding(.horizontal, 1)
        .onHover { hovering = $0 }
    }
}

// MARK: Work log

private struct WorkGroupView: View {
    let group: TimelineWorkGroup
    let isActive: Bool
    @AppStorage("expandWorkLogs") private var expandByDefault = false
    @State private var expanded: Bool? = nil
    private var isExpanded: Bool { expanded ?? expandByDefault }

    private var showsRows: Bool { isExpanded || isActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded = !isExpanded }
            } label: {
                HStack(spacing: 6) {
                    if isActive {
                        ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 12)
                    }
                    Text(group.title(active: isActive)).font(.system(size: T3.small + 0.5)).monospacedDigit()
                    if !group.summary.isEmpty {
                        Text("·").foregroundStyle(T3.faint)
                        Text(group.summary.text)
                            .font(.system(size: T3.caption + 0.5))
                            .foregroundStyle(T3.faint)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    if group.summary.failures > 0 {
                        Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10.5)).foregroundStyle(T3.error)
                            .help("\(group.summary.failures) failed")
                    }
                }
                .foregroundStyle(T3.muted)
                .padding(.horizontal, 4)
                .frame(height: 26)
                .hoverPlate(radius: 6)
            }
            .buttonStyle(.plain).clickableCursor()
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if showsRows {
                VStack(alignment: .leading, spacing: 1) {
                    let rows = isActive && !isExpanded ? Array(group.entries.suffix(3)) : group.entries
                    ForEach(rows) { entry in
                        WorkEntryRow(entry: entry).equatable()
                    }
                }
                .padding(.leading, 8)
                .padding(.top, 2)
                .transition(.opacity)
            }
        }
        .padding(.bottom, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(T3.border).frame(height: 1) }
    }
}

private struct WorkEntryRow: View, Equatable {
    let entry: ConversationEntry
    @AppStorage("showReasoning") private var openReasoning = false
    @State private var override: Bool? = nil
    private var expanded: Bool { override ?? (entry.kind == .reasoning && openReasoning) }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.entry == rhs.entry }

    private var detail: ConversationDetail? { entry.detail }
    private var running: Bool { entry.status == "running" || entry.status == "pending" }
    private var hasBody: Bool {
        if entry.kind == .reasoning { return !entry.text.isEmpty }
        guard let detail else { return false }
        return detail.output?.isEmpty == false || detail.diff?.isEmpty == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if hasBody { withAnimation(.snappy(duration: 0.2)) { override = !expanded } }
            } label: {
                HStack(spacing: 7) {
                    icon.frame(width: 14)
                    label
                    Spacer(minLength: 4)
                    trailing
                }
                .padding(.horizontal, 4)
                .frame(minHeight: 24)
                .contentShape(Rectangle())
                .hoverPlate(radius: 6)
            }
            .buttonStyle(.plain).clickableCursor()
            .disabled(!hasBody)
            .accessibilityValue(hasBody ? (expanded ? "Expanded" : "Collapsed") : "")

            if expanded { expandedBody.padding(.leading, 25).padding(.trailing, 4).padding(.bottom, 4) }
        }
    }

    @ViewBuilder private var icon: some View {
        if running {
            ProgressView().controlSize(.mini).scaleEffect(0.7)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(detail?.failed == true ? T3.error : T3.muted)
        }
    }

    private var symbol: String {
        if entry.kind == .reasoning { return "brain" }
        switch detail?.tool {
        case .command: return "terminal"
        case .fileChange: return "square.and.pencil"
        case .read: return "eye"
        case .search: return "magnifyingglass"
        case .web: return "globe"
        default: return "wrench.and.screwdriver"
        }
    }

    @ViewBuilder private var label: some View {
        if entry.kind == .reasoning {
            let first = entry.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Thinking"
            HStack(spacing: 5) {
                Text(running ? "Thinking…" : "Thought")
                if !expanded {
                    Text(first.replacingOccurrences(of: "**", with: "")).foregroundStyle(T3.faint).lineLimit(1)
                }
            }
            .font(.system(size: T3.small))
            .foregroundStyle(T3.muted)
        } else if let detail {
            HStack(spacing: 5) {
                Text(detail.verb).font(.system(size: T3.small)).foregroundStyle(T3.muted)
                Text(verbatim: detail.subject)
                    .font(.system(size: T3.small - (detail.tool == .command || detail.tool == .fileChange || detail.tool == .read ? 0.5 : 0),
                                  design: detail.tool == .search || detail.tool == .web || detail.tool == .other ? .default : .monospaced))
                    .foregroundStyle(T3.foreground.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            Text(verbatim: entry.text).font(.system(size: T3.small)).foregroundStyle(T3.muted).lineLimit(1)
        }
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 6) {
            if let detail, detail.tool == .fileChange, (detail.additions ?? 0) + (detail.deletions ?? 0) > 0 {
                HStack(spacing: 4) {
                    Text("+\(detail.additions ?? 0)").foregroundStyle(T3.success)
                    Text("−\(detail.deletions ?? 0)").foregroundStyle(T3.error)
                }
                .font(.system(size: T3.caption, weight: .medium)).monospacedDigit()
            }
            if let detail, detail.tool == .command, let code = detail.exitCode, code != 0 {
                Text("exit \(code)").font(.system(size: T3.micro + 0.5, weight: .medium)).monospacedDigit()
                    .foregroundStyle(T3.error)
                    .padding(.horizontal, 5).frame(height: 16)
                    .background(T3.error.opacity(0.14), in: Capsule())
            }
            if hasBody {
                Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(T3.faint)
            }
        }
    }

    @ViewBuilder private var expandedBody: some View {
        if entry.kind == .reasoning {
            MarkdownMessageView(id: entry.id, content: entry.text, size: T3.small, muted: true)
        } else if let detail {
            if let diff = detail.diff, !diff.isEmpty {
                DiffSnippet(diff: diff)
            }
            if let output = detail.output, !output.isEmpty {
                OutputSnippet(text: output)
            }
        }
    }
}

private struct OutputSnippet: View {
    let text: String

    private var clipped: String {
        text.count > 6_000 ? String(text.prefix(6_000)) + "\n… output truncated" : text
    }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(verbatim: clipped)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(T3.foreground.opacity(0.85))
                .fixedSize(horizontal: true, vertical: true)
                .textSelection(.enabled)
                .padding(8)
        }
        .frame(maxHeight: 180)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(T3.border, lineWidth: 1))
    }
}

private struct DiffSnippet: View {
    let diff: String
    @State private var viewport: CGFloat = 0

    var body: some View {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).prefix(80)
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    let added = line.hasPrefix("+") && !line.hasPrefix("+++")
                    let removed = line.hasPrefix("-") && !line.hasPrefix("---")
                    Text(verbatim: String(line).isEmpty ? " " : String(line))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(added ? T3.success : removed ? T3.error : T3.muted)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(added ? T3.success.opacity(0.10) : removed ? T3.error.opacity(0.10) : .clear)
                }
            }
            .padding(.vertical, 4)
            .frame(minWidth: viewport, alignment: .leading)
            .textSelection(.enabled)
        }
        // Line highlights span the full snippet width even when every line is short.
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.containerSize.width }) { _, width in
            if abs(width - viewport) >= 1 { viewport = width }
        }
        .frame(maxHeight: 200)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(T3.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: Cards

private struct PlanCardView: View {
    let entry: ConversationEntry
    @State private var expanded = false

    private var long: Bool { entry.text.count > 700 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "list.bullet.rectangle").font(.system(size: 11.5)).foregroundStyle(T3.muted)
                Text("Plan").font(.system(size: T3.small + 0.5, weight: .medium))
                Spacer()
                CopyButton(text: entry.text)
            }
            MarkdownMessageView(id: entry.id, content: entry.text, size: T3.small + 0.5)
                .frame(maxHeight: long && !expanded ? 220 : nil, alignment: .top)
                .clipped()
                .overlay(alignment: .bottom) {
                    if long && !expanded {
                        LinearGradient(colors: [.clear, T3.card], startPoint: .top, endPoint: .bottom).frame(height: 56)
                            .allowsHitTesting(false)
                    }
                }
            if long {
                Button(expanded ? "Collapse plan" : "Expand plan") {
                    withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                }
                .buttonStyle(.plain).clickableCursor()
                .font(.system(size: T3.caption, weight: .medium))
                .foregroundStyle(T3.muted)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .background(T3.card, in: RoundedRectangle(cornerRadius: T3.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: T3.cardRadius).strokeBorder(T3.borderStrong, lineWidth: 1))
    }
}

private struct TodoCardView: View {
    let entry: ConversationEntry

    var body: some View {
        let steps = entry.detail?.steps ?? []
        let done = steps.filter { $0.status == "completed" }.count
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "checklist").font(.system(size: 11.5)).foregroundStyle(T3.muted)
                Text("Tasks").font(.system(size: T3.small + 0.5, weight: .medium))
                Text("\(done)/\(steps.count)").font(.system(size: T3.caption)).monospacedDigit().foregroundStyle(T3.faint)
                Spacer()
            }
            ProgressView(value: Double(done), total: Double(max(steps.count, 1)))
                .progressViewStyle(.linear).tint(T3.success).controlSize(.mini)
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Group {
                        switch step.status {
                        case "completed": Image(systemName: "checkmark.circle.fill").foregroundStyle(T3.success)
                        case "running": Image(systemName: "circle.dotted").foregroundStyle(T3.warning)
                        default: Image(systemName: "circle").foregroundStyle(T3.faint)
                        }
                    }
                    .font(.system(size: 12))
                    Text(verbatim: step.text)
                        .font(.system(size: T3.small + 0.5))
                        .strikethrough(step.status == "completed", color: T3.faint)
                        .foregroundStyle(step.status == "completed" ? T3.faint : T3.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(T3.card, in: RoundedRectangle(cornerRadius: T3.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: T3.cardRadius).strokeBorder(T3.borderStrong, lineWidth: 1))
    }
}

private struct ErrorBannerView: View {
    let entry: ConversationEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(T3.error)
            Text(verbatim: entry.text)
                .font(.system(size: T3.small + 0.5))
                .foregroundStyle(T3.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            CopyButton(text: entry.text)
        }
        .padding(10)
        .background(T3.error.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(T3.error.opacity(0.28), lineWidth: 1))
    }
}

private struct ApprovalRecordView: View {
    let entry: ConversationEntry

    var body: some View {
        let denied = entry.detail?.failed == true
        HStack(spacing: 7) {
            Image(systemName: denied ? "xmark.shield" : "checkmark.shield")
                .font(.system(size: 11.5)).foregroundStyle(denied ? T3.error : T3.success)
            Text(denied ? "Declined" : "Approved").font(.system(size: T3.small, weight: .medium))
                .foregroundStyle(denied ? T3.error : T3.success)
            Text(verbatim: entry.text).font(.system(size: T3.small, design: .monospaced))
                .foregroundStyle(T3.muted).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(T3.fill, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct NoticeDivider: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(T3.border).frame(height: 1)
            Text(verbatim: text).font(.system(size: T3.caption)).foregroundStyle(T3.faint).lineLimit(1)
                .layoutPriority(1)
            Rectangle().fill(T3.border).frame(height: 1)
        }
        .padding(.vertical, 2)
    }
}
