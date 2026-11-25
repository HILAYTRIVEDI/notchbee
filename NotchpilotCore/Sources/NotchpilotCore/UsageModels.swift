import Foundation

/// A subscription-limit window reported by a provider, such as "Session" or "Weekly".
public struct UsageWindow: Decodable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case session, weekly, monthly, other
        var order: Int { switch self { case .session: 0; case .weekly: 1; case .monthly: 2; case .other: 3 } }
    }

    public enum Pace: String, Sendable { case ahead, on, under }

    public let id: String
    public let kind: Kind
    public let label: String
    public let usedPercent: Double
    public let resetsAt: Date?
    public let windowDurationMins: Int?

    public init(id: String, kind: Kind, label: String, usedPercent: Double, resetsAt: Date? = nil,
                windowDurationMins: Int? = nil) {
        self.id = id
        self.kind = kind
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowDurationMins = windowDurationMins
    }

    private enum CodingKeys: String, CodingKey { case id, kind, label, usedPercent, resetsAt, windowDurationMins }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(String.self, forKey: .id)
        kind = (try? fields.decode(String.self, forKey: .kind)).flatMap(Kind.init(rawValue:)) ?? .other
        label = Product.displayText(try fields.decode(String.self, forKey: .label))
        usedPercent = try fields.decode(Double.self, forKey: .usedPercent)
        resetsAt = (try? fields.decodeIfPresent(String.self, forKey: .resetsAt)).flatMap { $0 }.flatMap(TimelineFormat.date)
        windowDurationMins = try? fields.decodeIfPresent(Int.self, forKey: .windowDurationMins)
    }

    /// "NN% left", rounded and clamped like T3's limit bars.
    public var remainingPercent: Int { Int((100 - min(100, max(0, usedPercent))).rounded()) }

    /// Share of the window that has already elapsed, when the reset time and window length are known.
    public func elapsedShare(now: Date) -> Double? {
        guard let resetsAt, let minutes = windowDurationMins, minutes > 0 else { return nil }
        let length = Double(minutes) * 60
        let start = resetsAt.timeIntervalSince1970 - length
        return min(1, max(0, (now.timeIntervalSince1970 - start) / length))
    }

    /// Where the pace marker sits: the percentage of the window still ahead, in terms of the bar.
    public func paceRemainingPercent(now: Date) -> Int? {
        elapsedShare(now: now).map { Int(((1 - $0) * 100).rounded()) }
    }

    public func pace(now: Date) -> Pace? {
        guard let elapsed = elapsedShare(now: now) else { return nil }
        let gap = usedPercent - elapsed * 100
        return gap > 5 ? .ahead : gap < -5 ? .under : .on
    }

    /// "4h 58m", "2d 3h", "12m" or `nil` when no reset time is known.
    public func resetsIn(now: Date) -> String? {
        guard let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining <= 0 { return "now" }
        if remaining < 60 { return "<1m" }
        return Self.duration(remaining)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let days = total / 86_400, hours = (total % 86_400) / 3_600, minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// Display order: session, weekly, monthly, then provider-specific windows.
    public static func sorted(_ windows: [UsageWindow]) -> [UsageWindow] {
        windows.enumerated().sorted { ($0.element.kind.order, $0.offset) < ($1.element.kind.order, $1.offset) }.map(\.element)
    }
}

public struct ProviderUsageLimits: Decodable, Equatable, Sendable {
    public let checkedAt: Date?
    public let windows: [UsageWindow]
    public let unavailableMessage: String?

    public init(checkedAt: Date? = nil, windows: [UsageWindow] = [], unavailableMessage: String? = nil) {
        self.checkedAt = checkedAt
        self.windows = windows
        self.unavailableMessage = unavailableMessage
    }

    private struct Unavailable: Decodable { let reason: String?; let message: String? }
    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }
    private enum CodingKeys: String, CodingKey { case checkedAt, windows, unavailable }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        checkedAt = (try? fields.decodeIfPresent(String.self, forKey: .checkedAt)).flatMap { $0 }.flatMap(TimelineFormat.date)
        windows = ((try? fields.decodeIfPresent([Lossy<UsageWindow>].self, forKey: .windows)) ?? nil)?.compactMap(\.value) ?? []
        let unavailable = try? fields.decodeIfPresent(Unavailable.self, forKey: .unavailable)
        unavailableMessage = unavailable.flatMap { $0 }.map { $0.message.map(Product.displayText) ?? ($0.reason == "unsupported"
            ? "This account has no subscription limits." : "Could not read limits.") }
    }

    public var sortedWindows: [UsageWindow] { UsageWindow.sorted(windows) }
}

/// The compact "17% weekly left" hint shown next to the model picker.
public struct UsageHint: Equatable, Sendable {
    public enum Level: Sendable { case normal, low, critical }
    public let text: String
    public let level: Level

    /// The leading percentage of `text` ("90% weekly left" → 90).
    public var remainingPercent: Int? { Int(text.prefix { $0.isNumber }) }

    /// Picks the most informative window (weekly, then monthly, then session) and colours it by what is left.
    public static func make(from windows: [UsageWindow]) -> UsageHint? {
        let chosen = [UsageWindow.Kind.weekly, .monthly, .session].lazy
            .compactMap { kind in windows.first { $0.kind == kind } }.first ?? windows.first
        guard let window = chosen else { return nil }
        let remaining = window.remainingPercent
        let name = switch window.kind {
        case .weekly: "weekly"
        case .monthly: "monthly"
        case .session: "session"
        case .other: window.label.lowercased()
        }
        return UsageHint(text: "\(remaining)% \(name) left", level: remaining < 5 ? .critical : remaining < 20 ? .low : .normal)
    }
}

/// Token and cost totals from `server.getUsageSummary`.
public struct UsageSummary: Decodable, Equatable, Sendable {
    public struct Bucket: Decodable, Equatable, Sendable {
        public let day: String
        public let provider: String
        public let model: String
        public let tokens: Int
        public let costUsd: Double
        public let sessions: Int

        private struct Totals: Decodable {
            let uncachedInputTokens: Int?, cachedInputTokens: Int?, cacheCreationTokens: Int?, outputTokens: Int?
        }
        private enum CodingKeys: String, CodingKey { case day, provider, model, totals, costUsd, sessions }

        public init(day: String, provider: String, model: String, tokens: Int, costUsd: Double, sessions: Int) {
            self.day = day; self.provider = provider; self.model = model
            self.tokens = tokens; self.costUsd = costUsd; self.sessions = sessions
        }

        public init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            day = try fields.decode(String.self, forKey: .day)
            provider = try fields.decode(String.self, forKey: .provider)
            model = try fields.decode(String.self, forKey: .model)
            let totals = try? fields.decodeIfPresent(Totals.self, forKey: .totals)
            tokens = [totals?.uncachedInputTokens, totals?.cachedInputTokens, totals?.cacheCreationTokens,
                      totals?.outputTokens].compactMap { $0 }.reduce(0, +)
            costUsd = (try? fields.decodeIfPresent(Double.self, forKey: .costUsd)) ?? 0
            sessions = (try? fields.decodeIfPresent(Int.self, forKey: .sessions)) ?? 0
        }
    }

    public struct ProviderTotals: Equatable, Sendable, Identifiable {
        public var id: String { provider }
        public let provider: String
        public let tokens: Int
        public let costUsd: Double
        public let sessions: Int
    }

    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }
    private struct Pricing: Decodable { let status: String? }

    public let readAt: String?
    public let sinceDay: String?
    public let untilDay: String?
    public let buckets: [Bucket]
    public let pricingStatus: String?

    private enum CodingKeys: String, CodingKey { case readAt, sinceDay, untilDay, buckets, pricing }

    public init(readAt: String? = nil, sinceDay: String? = nil, untilDay: String? = nil, buckets: [Bucket] = [],
                pricingStatus: String? = nil) {
        self.readAt = readAt; self.sinceDay = sinceDay; self.untilDay = untilDay
        self.buckets = buckets; self.pricingStatus = pricingStatus
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        readAt = try? fields.decodeIfPresent(String.self, forKey: .readAt)
        sinceDay = try? fields.decodeIfPresent(String.self, forKey: .sinceDay)
        untilDay = try? fields.decodeIfPresent(String.self, forKey: .untilDay)
        buckets = ((try? fields.decodeIfPresent([Lossy<Bucket>].self, forKey: .buckets)) ?? nil)?.compactMap(\.value) ?? []
        pricingStatus = ((try? fields.decodeIfPresent(Pricing.self, forKey: .pricing)) ?? nil)?.status
    }

    public var providerTotals: [ProviderTotals] {
        Dictionary(grouping: buckets, by: \.provider).map { provider, rows in
            ProviderTotals(provider: provider, tokens: rows.reduce(0) { $0 + $1.tokens },
                           costUsd: rows.reduce(0) { $0 + $1.costUsd }, sessions: rows.reduce(0) { $0 + $1.sessions })
        }.sorted { ($0.costUsd, $0.tokens) > ($1.costUsd, $1.tokens) }
    }

    public var totalTokens: Int { buckets.reduce(0) { $0 + $1.tokens } }
    public var totalCostUsd: Double { buckets.reduce(0) { $0 + $1.costUsd } }
}
