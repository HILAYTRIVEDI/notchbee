import Foundation

public struct ThreadProject: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct ThreadProvider: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let models: [Model]
    public let runtimeModes: [ThreadRuntimeMode]
    public var usage: ProviderUsageLimits?
    /// Slash commands and skills for the composer's `/` menu, for the catalog's project folder when scanned.
    public var commands: [ComposerCommand]

    public struct Model: Identifiable, Sendable, Equatable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public init(id: String, name: String, models: [Model], runtimeModes: [ThreadRuntimeMode],
                usage: ProviderUsageLimits? = nil, commands: [ComposerCommand] = []) {
        self.usage = usage
        self.commands = commands
        self.id = id
        self.name = name
        self.models = models
        self.runtimeModes = runtimeModes
    }
}

public enum ThreadRuntimeMode: String, CaseIterable, Sendable {
    case approvalRequired = "approval-required"
    case autoAcceptEdits = "auto-accept-edits"
    case auto
    case fullAccess = "full-access"

    public var label: String {
        switch self {
        case .approvalRequired: "Approval required"
        case .autoAcceptEdits: "Auto-accept edits"
        case .auto: "Auto"
        case .fullAccess: "Full access"
        }
    }
}

public struct ThreadModelSelection: Codable, Sendable, Equatable {
    public struct Option: Codable, Sendable, Equatable {
        public let id: String
        public let value: Value

        public init(id: String, value: Value) { self.id = id; self.value = value }

        public enum Value: Codable, Sendable, Equatable {
            case choice(String)
            case toggle(Bool)

            public init(from decoder: Decoder) throws {
                let value = try decoder.singleValueContainer()
                if let toggle = try? value.decode(Bool.self) {
                    self = .toggle(toggle)
                } else {
                    self = .choice(try value.decode(String.self))
                }
            }

            public func encode(to encoder: Encoder) throws {
                var value = encoder.singleValueContainer()
                switch self {
                case .choice(let choice): try value.encode(choice)
                case .toggle(let toggle): try value.encode(toggle)
                }
            }
        }
    }

    public let instanceId: String
    public let model: String
    public let options: [Option]?

    public init(instanceId: String, model: String, options: [Option]? = nil) {
        self.instanceId = instanceId
        self.model = model
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case instanceId, model, options
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        instanceId = try fields.decode(String.self, forKey: .instanceId)
        model = try fields.decode(String.self, forKey: .model)
        if let legacy = try? fields.decode([String: Option.Value].self, forKey: .options) {
            options = legacy.keys.sorted().compactMap { id in legacy[id].map { Option(id: id, value: $0) } }
        } else {
            options = try fields.decodeIfPresent([Option].self, forKey: .options)
        }
    }
}

public struct ThreadProviderCatalog: Sendable {
    public let providers: [ThreadProvider]
    public let defaultSelection: ThreadModelSelection?
    public let defaultRuntimeMode: ThreadRuntimeMode

    public init(providers: [ThreadProvider], defaultSelection: ThreadModelSelection? = nil,
                defaultRuntimeMode: ThreadRuntimeMode = .approvalRequired) {
        self.providers = providers
        self.defaultSelection = defaultSelection
        self.defaultRuntimeMode = defaultRuntimeMode
    }
}

public struct ThreadLaunch: Sendable {
    public struct IDs: Sendable {
        public let command = UUID().uuidString.lowercased()
        public let thread = UUID().uuidString.lowercased()
        public let message = UUID().uuidString.lowercased()

        public init() {}
    }

    public let projectID: String?
    public let modelSelection: ThreadModelSelection
    public let runtimeMode: ThreadRuntimeMode
    public let prompt: String
    public let title: String?
    public let ids: IDs

    public init(
        projectID: String?, modelSelection: ThreadModelSelection, runtimeMode: ThreadRuntimeMode,
        prompt: String, title: String? = nil, ids: IDs = .init()
    ) {
        self.projectID = projectID
        self.modelSelection = modelSelection
        self.runtimeMode = runtimeMode
        self.prompt = prompt
        self.title = title
        self.ids = ids
    }
}

public enum ThreadMutation: Sendable {
    case stop
    case resolve(Bool)
    case rename(String)
    /// Changes the model for the thread's next turns. A different provider takes over with a handoff.
    case setModel(ThreadModelSelection)
    case archive
    case unarchive
    case delete
}

/// Structured payload for tool calls, plans, approvals and errors.
public struct ConversationDetail: Equatable, Sendable {
    public enum Tool: String, Sendable { case command, fileChange, read, search, web, other }

    public struct FileChange: Equatable, Sendable {
        public let path: String
        public let oldPath: String?
        public let operation: String?

        public init(path: String, oldPath: String? = nil, operation: String? = nil) {
            self.path = path
            self.oldPath = oldPath
            self.operation = operation
        }
    }

    public struct Step: Equatable, Sendable {
        public let text: String
        public let status: String

        public init(text: String, status: String) {
            self.text = text
            self.status = status
        }
    }

    public var tool: Tool = .other
    /// Primary label: the command line, file name, search pattern or tool name.
    public var title: String = ""
    public var output: String?
    public var exitCode: Int?
    public var additions: Int?
    public var deletions: Int?
    public var diff: String?
    public var files: [FileChange] = []
    public var steps: [Step] = []
    public var endTimestamp: String?
    public var failed = false
    /// Provider tool name for `.other` tools (for example `Task` or `mcp__browser__click`).
    public var toolName: String?

    public init(tool: Tool = .other, title: String = "", toolName: String? = nil, output: String? = nil, exitCode: Int? = nil,
                additions: Int? = nil, deletions: Int? = nil, diff: String? = nil, files: [FileChange] = [],
                steps: [Step] = [], endTimestamp: String? = nil, failed: Bool = false) {
        self.tool = tool
        self.title = title
        self.toolName = toolName
        self.output = output
        self.exitCode = exitCode
        self.additions = additions
        self.deletions = deletions
        self.diff = diff
        self.files = files
        self.steps = steps
        self.endTimestamp = endTimestamp
        self.failed = failed
    }
}

public struct ConversationEntry: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case user = "You"
        case assistant = "Assistant"
        case activity = "Activity"
        case system = "System"
        case reasoning = "Thinking"
        case tool = "Tool"
        case plan = "Plan"
        case todo = "Todo"
        case approval = "Approval"
        case error = "Error"
        case notice = "Notice"

        /// Entries that belong to a turn's folded work log.
        public var isWork: Bool {
            switch self {
            case .activity, .reasoning, .tool: true
            default: false
            }
        }
    }

    public let id: String
    public let kind: Kind
    public let text: String
    public let timestamp: String
    public var status: String? = nil
    public var streaming: Bool = false
    public var detail: ConversationDetail? = nil

    public init(id: String, kind: Kind, text: String, timestamp: String, status: String? = nil,
                streaming: Bool = false, detail: ConversationDetail? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.timestamp = timestamp
        self.status = status
        self.streaming = streaming
        self.detail = detail
    }
}

public struct ThreadConversation: Sendable, Equatable {
    public private(set) var entries: [ConversationEntry]
    private var indices: [String: Int]
    /// Rows folded from `entries`, kept current by `upsert` so views never rescan the whole thread.
    public private(set) var timelineRows: [TimelineRow] = []
    private var rowStarts: [Int] = []
    private var latestTodoID: String?
    /// Bumps whenever the entries change; views use it to pin the scroll position once per batch.
    public private(set) var revision = 0

    public init(_ entries: [ConversationEntry]) {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        self.entries = byID.values.sorted(by: Self.precedes)
        indices = Dictionary(uniqueKeysWithValues: self.entries.enumerated().map { ($0.element.id, $0.offset) })
        rebuildTimeline(from: 0, full: true)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.entries == rhs.entries }

    func entry(withID id: String) -> ConversationEntry? {
        indices[id].map { entries[$0] }
    }

    public func activeWorkGroupID(threadRunning: Bool) -> String? {
        ConversationTimeline.activeWorkGroupID(in: timelineRows, threadRunning: threadRunning)
    }

    mutating func upsert(_ entry: ConversationEntry) {
        revision += 1
        var reindexFrom = entries.count
        var dirty: Int
        var full = entry.kind == .todo
        if let index = indices[entry.id] {
            if entries[index].kind != entry.kind { full = true }
            if entries[index].timestamp == entry.timestamp {
                entries[index] = entry
                rebuildTimeline(from: index, full: full)
                return
            }
            entries.remove(at: index)
            reindexFrom = index
            dirty = index
        } else {
            dirty = entries.count
        }

        var lower = 0
        var upper = entries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if Self.precedes(entries[middle], entry) {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        entries.insert(entry, at: lower)
        for index in min(reindexFrom, lower)..<entries.count {
            indices[entries[index].id] = index
        }
        dirty = min(dirty, lower)
        rebuildTimeline(from: dirty, full: full)
    }

    /// Rebuilds rows from the row that contains `index`; a todo update rebuilds everything because only the
    /// latest todo card is shown.
    private mutating func rebuildTimeline(from index: Int, full: Bool) {
        if full || timelineRows.isEmpty {
            latestTodoID = entries.last { $0.kind == .todo }?.id
            let built = ConversationTimeline.build(entries, from: 0, latestTodo: latestTodoID)
            timelineRows = built.rows
            rowStarts = built.starts
            return
        }
        let row = rowStarts.lastIndex { $0 <= index } ?? 0
        let built = ConversationTimeline.build(entries, from: rowStarts[row], latestTodo: latestTodoID)
        timelineRows.removeSubrange(row...)
        rowStarts.removeSubrange(row...)
        timelineRows += built.rows
        rowStarts += built.starts
    }

    private static func precedes(_ lhs: ConversationEntry, _ rhs: ConversationEntry) -> Bool {
        (lhs.timestamp, lhs.id) < (rhs.timestamp, rhs.id)
    }
}

public enum PanelTab: String, CaseIterable, Sendable {
    case sessions = "Sessions"
    case thread = "Thread"
    case new = "New"
    case settings = "Settings"
}
