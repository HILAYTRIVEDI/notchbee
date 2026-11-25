import Foundation
import Testing
@testable import NotchpilotCore

struct UsageModelsTests {
    private let now = TimelineFormat.date("2026-01-01T10:00:00.000Z")!

    @Test func decodesProviderLimitsAndIgnoresMalformedWindows() throws {
        let json = """
        {"checkedAt":"2026-01-01T09:55:00.000Z","windows":[
          {"id":"w","kind":"weekly","label":"Weekly","usedPercent":83,"resetsAt":"2026-01-03T10:00:00.000Z","windowDurationMins":10080},
          {"id":"s","kind":"session","label":"Session","usedPercent":12.4,"resetsAt":"2026-01-01T14:58:00.000Z","windowDurationMins":300},
          {"id":"g","kind":"surprise","label":"Go · Session","usedPercent":50},
          {"id":"bad","kind":"session"}]}
        """
        let limits = try JSONDecoder().decode(ProviderUsageLimits.self, from: Data(json.utf8))
        #expect(limits.windows.map(\.id) == ["w", "s", "g"])
        #expect(limits.sortedWindows.map(\.id) == ["s", "w", "g"])
        #expect(limits.windows[2].kind == .other)
        #expect(limits.checkedAt == TimelineFormat.date("2026-01-01T09:55:00.000Z"))
    }

    @Test func remainingPercentPaceAndResetChip() throws {
        let session = UsageWindow(id: "s", kind: .session, label: "Session", usedPercent: 12.4,
                                  resetsAt: TimelineFormat.date("2026-01-01T14:58:00.000Z"), windowDurationMins: 300)
        #expect(session.remainingPercent == 88)
        #expect(session.resetsIn(now: now) == "4h 58m")
        // Window started at 09:58, so 2 of 300 minutes have elapsed: 99% is still ahead and use is low.
        #expect(session.paceRemainingPercent(now: now) == 99)
        #expect(session.pace(now: now) == .ahead)
        let heavy = UsageWindow(id: "w", kind: .weekly, label: "Weekly", usedPercent: 83,
                                resetsAt: TimelineFormat.date("2026-01-03T10:00:00.000Z"), windowDurationMins: 10_080)
        #expect(heavy.pace(now: now) == .ahead)
        #expect(heavy.resetsIn(now: now) == "2d 0h")
        let untimed = UsageWindow(id: "g", kind: .other, label: "Go", usedPercent: 120)
        #expect(untimed.remainingPercent == 0)
        #expect(untimed.pace(now: now) == nil)
        #expect(untimed.resetsIn(now: now) == nil)
        let past = UsageWindow(id: "p", kind: .session, label: "P", usedPercent: 1,
                               resetsAt: now.addingTimeInterval(-5), windowDurationMins: 60)
        #expect(past.resetsIn(now: now) == "now")
    }

    @Test func hintPrefersWeeklyAndColoursByRemaining() {
        func window(_ kind: UsageWindow.Kind, used: Double) -> UsageWindow {
            UsageWindow(id: kind.rawValue, kind: kind, label: kind.rawValue.capitalized, usedPercent: used)
        }
        #expect(UsageHint.make(from: [window(.session, used: 10), window(.weekly, used: 83)])
            == UsageHint(text: "17% weekly left", level: .low))
        #expect(UsageHint.make(from: [window(.weekly, used: 50)])?.level == .normal)
        #expect(UsageHint.make(from: [window(.weekly, used: 85)])?.level == .low)
        #expect(UsageHint.make(from: [window(.weekly, used: 96)])?.level == .critical)
        #expect(UsageHint.make(from: [window(.session, used: 50)])?.text == "50% session left")
        #expect(UsageHint.make(from: []) == nil)
    }

    @Test func decodesUsageSummaryTotals() throws {
        let json = """
        {"contractVersion":6,"readAt":"2026-01-01T10:00:00Z","timeZone":"UTC","sinceDay":"2025-12-26","untilDay":"2026-01-01",
         "pricing":{"status":"fresh","source":"x","fetchedAt":null,"knownModels":3},
         "buckets":[
          {"day":"2026-01-01","provider":"codex","model":"a","totals":{"uncachedInputTokens":100,"cachedInputTokens":50,"cacheCreationTokens":0,"outputTokens":25,"reasoningTokens":5},"costUsd":1.5,"sessions":2},
          {"day":"2026-01-01","provider":"codex","model":"b","totals":{"uncachedInputTokens":10,"cachedInputTokens":0,"cacheCreationTokens":0,"outputTokens":0,"reasoningTokens":0},"costUsd":0.5,"sessions":1},
          {"day":"2026-01-01","provider":"claude","model":"c","totals":{"uncachedInputTokens":1000,"cachedInputTokens":0,"cacheCreationTokens":0,"outputTokens":0,"reasoningTokens":0},"costUsd":0.25,"sessions":1},
          {"nonsense":true}]}
        """
        let summary = try JSONDecoder().decode(UsageSummary.self, from: Data(json.utf8))
        #expect(summary.buckets.count == 3)
        #expect(summary.pricingStatus == "fresh")
        #expect(summary.totalTokens == 1185)
        #expect(summary.totalCostUsd == 2.25)
        #expect(summary.providerTotals.map(\.provider) == ["codex", "claude"])
        #expect(summary.providerTotals.first?.sessions == 3)
    }

    @Test func providerResultsExposeUsageThroughTheSharedDecoder() throws {
        let json = """
        {"contractVersion":6,"buckets":[],"pricing":{"status":"cached"}}
        """
        let value = try JSONDecoder().decode(T3Client.ResultValue.self, from: Data(json.utf8))
        #expect(value.usageSummary?.pricingStatus == "cached")
    }

    @Test func providerFieldsFollowTheDriverSchemas() {
        #expect(ProviderField.fields(forDriver: "codex").map(\.key) == ["binaryPath", "homePath", "shadowHomePath", "launchArgs"])
        #expect(ProviderField.fields(forDriver: "claudeAgent").map(\.key)
            == ["binaryPath", "homePath", "autoCompactWindow", "idleCompaction", "launchArgs"])
        #expect(ProviderField.fields(forDriver: "mystery").map(\.key) == ["binaryPath", "homePath", "launchArgs"])
    }

    @Test func authLineMatchesT3() {
        var provider = ProviderSettings(id: "codex", name: "Codex", driver: "codex", enabled: true, installed: true,
                                        auth: "authenticated", models: [], defaultModel: nil, canInstall: false,
                                        documentationURL: nil)
        provider.authLabel = "ChatGPT Plus Subscription"
        #expect(provider.authLine == "Authenticated · ChatGPT Plus Subscription")
        provider.auth = "unauthenticated"
        #expect(provider.authLine == "Not signed in")
    }
}
