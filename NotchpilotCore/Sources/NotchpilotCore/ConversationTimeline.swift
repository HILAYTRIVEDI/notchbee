import Foundation

public enum ToolClassifier {
    public static func classify(_ name: String) -> ConversationDetail.Tool {
        let n = name.lowercased().replacingOccurrences(of: "-", with: "_")
        func has(_ words: [String]) -> Bool { words.contains { n.contains($0) } }
        if has(["websearch", "web_search", "webfetch", "web_fetch", "fetch_url", "browser"]) { return .web }
        if has(["grep", "glob", "search", "find", "ripgrep", "list_dir", "ls"]), !n.contains("replace") { return .search }
        if n == "read" || n.hasPrefix("read") || has(["view_file", "open_file", "cat"]) { return .read }
        if has(["bash", "shell", "exec", "command", "terminal"]) { return .command }
        if has(["edit", "write", "patch", "multiedit", "replace", "create_file", "notebook"]) { return .fileChange }
        return .other
    }
}

public extension ConversationDetail {
    /// Short past-tense verb used by work-log rows, for example "Ran" or "Edited".
    var verb: String {
        switch tool {
        case .command: "Ran"
        case .fileChange: "Edited"
        case .read: "Read"
        case .search: "Searched"
        case .web: "Browsed"
        case .other: toolName.map(Self.prettyToolName) ?? "Used tool"
        }
    }

    /// The subject of the verb: a command line, a trimmed path or a search pattern.
    var subject: String {
        switch tool {
        case .command:
            let line = title.split(whereSeparator: \.isNewline).first.map(String.init) ?? title
            return String(line.prefix(160))
        case .fileChange, .read:
            if tool == .fileChange, files.count > 1 {
                return "\(Self.shortPath(files[0].path)) +\(files.count - 1) more"
            }
            return Self.shortPath(title)
        case .search, .web, .other:
            return String(title.prefix(160))
        }
    }

    static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 3 else { return path }
        return "…/" + parts.suffix(3).joined(separator: "/")
    }

    static func prettyToolName(_ name: String) -> String {
        var name = name
        if name.hasPrefix("mcp__") { name = String(name.split(separator: "__").last ?? Substring(name)) }
        let spaced = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}

public struct WorkSummary: Equatable, Sendable {
    public var commands = 0
    public var reads = 0
    public var searches = 0
    public var web = 0
    public var editedFiles = 0
    public var thoughts = 0
    public var other = 0
    public var additions = 0
    public var deletions = 0
    public var failures = 0

    public var isEmpty: Bool { commands + reads + searches + web + editedFiles + thoughts + other == 0 }

    /// "Edited 2 files +12 −3 · Ran 3 commands · Read 4 files"
    public var text: String {
        func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        var parts: [String] = []
        if editedFiles > 0 {
            var part = "Edited " + count(editedFiles, "file")
            if additions + deletions > 0 { part += " +\(additions) −\(deletions)" }
            parts.append(part)
        }
        if commands > 0 { parts.append("Ran " + count(commands, "command")) }
        if reads > 0 { parts.append("Read " + count(reads, "file")) }
        if searches > 0 { parts.append(count(searches, "search").capitalizedFirst) }
        if web > 0 { parts.append("Browsed " + count(web, "page")) }
        if other > 0 { parts.append("Used " + count(other, "tool")) }
        if parts.isEmpty, thoughts > 0 { parts.append("Thought") }
        return parts.joined(separator: " · ")
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

public struct TimelineWorkGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let entries: [ConversationEntry]
    public let isActive: Bool
    public let startTimestamp: String
    public let endTimestamp: String
    public let summary: WorkSummary
    /// Parsed once when the group is built, so scrolling and streaming never re-parse timestamps.
    public let duration: TimeInterval?

    public init(id: String, entries: [ConversationEntry], isActive: Bool, startTimestamp: String,
                endTimestamp: String, summary: WorkSummary) {
        self.id = id
        self.entries = entries
        self.isActive = isActive
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
        self.summary = summary
        if let start = TimelineFormat.date(startTimestamp), let end = TimelineFormat.date(endTimestamp) {
            duration = max(0, end.timeIntervalSince(start))
        } else {
            duration = nil
        }
    }

    /// "Worked for 1m 23s", or "Working…" while the group is still running.
    public var title: String { title(active: isActive) }

    public func title(active: Bool) -> String {
        if active { return "Working…" }
        guard let duration, duration >= 1 else { return "Worked" }
        return "Worked for " + TimelineFormat.duration(duration)
    }

    public var latestEntry: ConversationEntry? {
        entries.last { $0.kind == .tool || $0.kind == .reasoning } ?? entries.last
    }
}

public enum TimelineRow: Identifiable, Equatable, Sendable {
    case message(ConversationEntry)
    case work(TimelineWorkGroup)
    case plan(ConversationEntry)
    case todo(ConversationEntry)
    case error(ConversationEntry)
    case approval(ConversationEntry)
    case notice(ConversationEntry)

    public var id: String {
        switch self {
        case .message(let entry), .plan(let entry), .todo(let entry), .error(let entry), .approval(let entry),
             .notice(let entry): entry.id
        case .work(let group): "work:" + group.id
        }
    }
}

public enum ConversationTimeline {
    /// Folds a flat conversation into T3-style rows: messages, one collapsible work log per stretch of tool
    /// calls and reasoning, plan and todo cards, approval records and error banners.
    public static func rows(_ entries: [ConversationEntry], threadRunning: Bool = false) -> [TimelineRow] {
        var rows = build(entries, from: 0, latestTodo: entries.last { $0.kind == .todo }?.id).rows
        if let id = activeWorkGroupID(in: rows, threadRunning: threadRunning),
           let index = rows.lastIndex(where: { $0.id == "work:" + id }), case .work(let group) = rows[index] {
            rows[index] = .work(TimelineWorkGroup(
                id: group.id, entries: group.entries, isActive: true, startTimestamp: group.startTimestamp,
                endTimestamp: group.endTimestamp, summary: group.summary))
        }
        return rows
    }

    /// The work group that should render as "Working…": the last group when it holds live tool calls, or when
    /// the thread is running and nothing has followed it.
    public static func activeWorkGroupID(in rows: [TimelineRow], threadRunning: Bool) -> String? {
        guard let index = rows.indices.last(where: { if case .work = rows[$0] { true } else { false } }),
              case .work(let group) = rows[index] else { return nil }
        let live = group.entries.contains { entry in
            entry.streaming || ["running", "pending", "waiting"].contains(entry.status ?? "")
        }
        return live || (threadRunning && index == rows.count - 1) ? group.id : nil
    }

    /// Builds rows for `entries[start...]`. `starts` holds the entry index each row begins at, so a caller can
    /// resume from the row containing a changed entry.
    static func build(_ entries: [ConversationEntry], from start: Int, latestTodo: String?)
        -> (rows: [TimelineRow], starts: [Int]) {
        var rows: [TimelineRow] = []
        var starts: [Int] = []
        var pending: [ConversationEntry] = []
        var pendingStart = start

        func flush() {
            guard let first = pending.first, let last = pending.last else { return }
            rows.append(.work(TimelineWorkGroup(
                id: first.id, entries: pending, isActive: false, startTimestamp: first.timestamp,
                endTimestamp: pending.compactMap { $0.detail?.endTimestamp }.max() ?? last.timestamp,
                summary: summary(of: pending))))
            starts.append(pendingStart)
            pending.removeAll()
        }

        guard start < entries.count else { return ([], []) }
        for index in start..<entries.count {
            let entry = entries[index]
            switch entry.kind {
            case .activity, .reasoning, .tool:
                if pending.isEmpty { pendingStart = index }
                pending.append(entry)
            case .notice:
                flush(); rows.append(.notice(entry)); starts.append(index)
            case .user, .assistant, .system:
                flush(); rows.append(.message(entry)); starts.append(index)
            case .plan:
                flush(); rows.append(.plan(entry)); starts.append(index)
            case .todo:
                flush()
                if entry.id == latestTodo { rows.append(.todo(entry)); starts.append(index) }
            case .error:
                flush(); rows.append(.error(entry)); starts.append(index)
            case .approval:
                flush(); rows.append(.approval(entry)); starts.append(index)
            }
        }
        flush()
        return (rows, starts)
    }

    static func summary(of entries: [ConversationEntry]) -> WorkSummary {
        var summary = WorkSummary()
        for entry in entries {
            switch entry.kind {
            case .reasoning: summary.thoughts += 1
            case .tool:
                guard let detail = entry.detail else { summary.other += 1; continue }
                if detail.failed { summary.failures += 1 }
                switch detail.tool {
                case .command: summary.commands += 1
                case .read: summary.reads += 1
                case .search: summary.searches += 1
                case .web: summary.web += 1
                case .other: summary.other += 1
                case .fileChange:
                    summary.editedFiles += max(1, detail.files.count)
                    summary.additions += detail.additions ?? 0
                    summary.deletions += detail.deletions ?? 0
                }
            default: break
            }
        }
        return summary
    }
}

public enum TimelineFormat {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    public static func date(_ timestamp: String) -> Date? {
        (try? Date(timestamp, strategy: fractional)) ?? (try? Date(timestamp, strategy: .iso8601))
    }

    /// "45s", "1m 23s", "2h 5m".
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }

    /// "3:42 PM" for today, "Mon 3:42 PM" within a week, otherwise "Nov 3, 3:42 PM".
    public static func time(_ timestamp: String, now: Date = .now, calendar: Calendar = .current,
                            locale: Locale = .current) -> String? {
        guard let date = date(timestamp) else { return nil }
        let clock = date.formatted(.dateTime.hour().minute().locale(locale))
        if calendar.isDate(date, inSameDayAs: now) { return clock }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                              to: calendar.startOfDay(for: now)).day, days < 7, days > 0 {
            return date.formatted(.dateTime.weekday(.abbreviated).locale(locale)) + " " + clock
        }
        return date.formatted(.dateTime.month(.abbreviated).day().locale(locale)) + ", " + clock
    }
}
