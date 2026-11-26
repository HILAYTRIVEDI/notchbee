import NotchpilotCore
import Observation
import SwiftUI

@MainActor
@Observable
final class UsageModel {
    private(set) var providers: [ProviderSettings] = []
    private(set) var summary: UsageSummary?
    private(set) var loading = false
    private(set) var failure: String?
    private(set) var summaryNote: String?
    private(set) var loadedAt: Date?
    @ObservationIgnored let backend: () -> (any SettingsBackend)?
    @ObservationIgnored private var probed = false

    init(backend: @escaping () -> (any SettingsBackend)?) { self.backend = backend }

    /// Runs when the page opens, and again if the engine connects afterwards: refresh pricing, then read.
    /// There is no polling.
    func open() async {
        await reload(refreshProviders: false)
    }

    /// Manual refresh: pricing and provider limits are re-read from the server.
    func refresh() async { await reload(refreshProviders: true) }

    private func reload(refreshProviders: Bool) async {
        guard !loading else { return }
        guard let service = backend() else { failure = "Connect to the server to read usage."; return }
        loading = true
        defer { loading = false }
        do {
            try? await service.refreshUsageRates()
            if refreshProviders { try? await service.refreshProviders(instanceID: nil) }
            providers = try await service.workspaceSettings().providers
            // A freshly started engine has not read subscription limits yet: probe once on open, never on a timer.
            if !probed, providers.contains(where: { $0.enabled && $0.usage == nil }) {
                probed = true
                try? await service.refreshProviders(instanceID: nil)
                providers = try await service.workspaceSettings().providers
            }
            do {
                summary = try await service.usageSummary(days: 7)
                summaryNote = nil
            } catch {
                summary = nil
                summaryNote = "Token usage is unavailable: \(error.localizedDescription)"
            }
            loadedAt = .now
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

struct UsagePage: View {
    @State private var model: UsageModel
    let connected: Bool

    init(backend: @escaping () -> (any SettingsBackend)?, connected: Bool) {
        _model = State(initialValue: UsageModel(backend: backend))
        self.connected = connected
    }

    private var limited: [ProviderSettings] {
        model.providers.filter { $0.enabled && ($0.usage?.windows.isEmpty == false || $0.usage?.unavailableMessage != nil) }
    }

    var body: some View {
        SettingsPage(title: "Usage", subtitle: "Subscription limits and token spend across your providers.") {
            HStack(spacing: 8) {
                if let age = relativeAge(model.loadedAt) {
                    Text("Updated \(age)").font(.system(size: 11.5)).foregroundStyle(T3.muted)
                }
                Spacer()
                Button { Task { await model.refresh() } } label: {
                    HStack(spacing: 5) {
                        if model.loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                        Text("Refresh")
                    }
                }
                .disabled(model.loading)
                .help("Refresh pricing and provider limits")
            }
            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11.5)).foregroundStyle(T3.warning)
            }
            if limited.isEmpty, !model.loading, model.failure == nil {
                SettingsSection { Text("No provider reported subscription limits.").font(.system(size: 12.5)).foregroundStyle(T3.muted).padding(14) }
            }
            ForEach(limited) { provider in
                ProviderLimitsCard(provider: provider, now: model.loadedAt ?? .now)
            }
            if let summary = model.summary { TokenUsageSection(summary: summary, providers: model.providers) }
            else if let note = model.summaryNote {
                Text(note).font(.system(size: 11.5)).foregroundStyle(T3.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: connected) { if connected { await model.open() } }
    }
}

private struct ProviderLimitsCard: View {
    let provider: ProviderSettings
    let now: Date

    var body: some View {
        let tint = ProviderBrand.tint(driver: provider.driver, accent: provider.accentColor)
        let limits = provider.usage
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProviderBadge(driver: provider.driver, accent: provider.accentColor, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.name).font(.system(size: 13.5, weight: .semibold))
                    if let plan = provider.authLabel {
                        Text(plan).font(.system(size: 11)).foregroundStyle(T3.muted)
                    }
                }
                Spacer()
                if let age = relativeAge(limits?.checkedAt) {
                    Text("Checked \(age)").font(.system(size: 10.5)).foregroundStyle(T3.faint)
                }
            }
            if let windows = limits?.sortedWindows, !windows.isEmpty {
                ForEach(windows) { window in LimitWindowRow(window: window, tint: tint, now: now) }
            } else if let note = limits?.unavailableMessage {
                Text(note).font(.system(size: 12)).foregroundStyle(T3.muted)
            }
        }
        .padding(16)
        .background(T3.fill, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(T3.border, lineWidth: 1))
    }
}

private struct LimitWindowRow: View {
    let window: UsageWindow
    let tint: Color
    let now: Date

    private var paceText: String? {
        switch window.pace(now: now) {
        case .ahead: "Ahead of pace"
        case .under: "Under pace"
        case .on: "On pace"
        case nil: nil
        }
    }

    private var remainingColor: Color {
        switch window.remainingPercent {
        case ..<5: T3.error
        case ..<20: T3.warning
        default: T3.foreground
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(T3.muted)
                Spacer()
                if let reset = window.resetsIn(now: now) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .bold))
                        Text(reset).monospacedDigit()
                    }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(T3.muted)
                    .padding(.horizontal, 8).frame(height: 20)
                    .background(Color.white.opacity(0.07), in: Capsule())
                    .help("Resets in \(reset)")
                    .accessibilityLabel("Resets in \(reset)")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(window.remainingPercent)%").font(.system(size: 26, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(remainingColor)
                Text("left").font(.system(size: 13)).foregroundStyle(T3.muted)
                Spacer()
                if let paceText {
                    Text(paceText).font(.system(size: 11)).foregroundStyle(T3.faint)
                }
            }
            UsageBar(remaining: window.remainingPercent, paceRemaining: window.paceRemainingPercent(now: now), tint: tint)
                .frame(height: 12)
                .accessibilityElement()
                .accessibilityLabel("\(window.label): \(window.remainingPercent)% left")
        }
    }
}

/// The remaining share in the provider's tint, the spent share hatched, and a tick where even spending would be.
struct UsageBar: View {
    let remaining: Int
    let paceRemaining: Int?
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let fill = width * CGFloat(max(0, min(100, remaining))) / 100
            ZStack(alignment: .leading) {
                Canvas { context, size in
                    let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
                    context.fill(track, with: .color(.white.opacity(0.06)))
                    context.clip(to: track)
                    var hatch = Path()
                    var x: CGFloat = -size.height
                    while x < size.width + size.height {
                        hatch.move(to: CGPoint(x: x, y: size.height))
                        hatch.addLine(to: CGPoint(x: x + size.height, y: 0))
                        x += 5
                    }
                    context.stroke(hatch, with: .color(.white.opacity(0.13)), lineWidth: 1)
                }
                if fill > 0 {
                    RoundedRectangle(cornerRadius: height / 2).fill(tint).frame(width: max(fill, height))
                }
                if let paceRemaining {
                    let at = min(max(width * CGFloat(paceRemaining) / 100, 3), width - 3)
                    Rectangle().fill(Color(white: 0.085)).frame(width: 6, height: height + 8).offset(x: at - 3)
                    Capsule().fill(T3.foreground).frame(width: 2, height: height + 6).offset(x: at - 1)
                }
            }
            .frame(height: height)
        }
    }
}

private struct TokenUsageSection: View {
    let summary: UsageSummary
    let providers: [ProviderSettings]

    private func name(_ kind: String) -> String {
        providers.first { $0.driver == kind || $0.driver == (kind == "claude" ? "claudeAgent" : kind) }
            .map { ProviderBrand.label(driver: $0.driver) } ?? ProviderBrand.label(driver: kind)
    }

    private func tokens(_ value: Int) -> String {
        value >= 1_000_000 ? String(format: "%.1fM", Double(value) / 1_000_000)
            : value >= 1_000 ? String(format: "%.1fK", Double(value) / 1_000) : "\(value)"
    }

    var body: some View {
        let totals = summary.providerTotals
        let maxTokens = max(1, totals.map(\.tokens).max() ?? 1)
        SettingsSection(title: "Last 7 days", footer: summary.pricingStatus.map { "Pricing: \($0)." }) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.totalCostUsd, format: .currency(code: "USD")).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                    Text("estimated spend").font(.system(size: 11)).foregroundStyle(T3.muted)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(tokens(summary.totalTokens)).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                    Text("tokens").font(.system(size: 11)).foregroundStyle(T3.muted)
                }
                Spacer()
            }
            .padding(14)
            ForEach(totals) { row in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(name(row.provider)).font(.system(size: 12.5, weight: .medium))
                        Spacer()
                        Text("\(tokens(row.tokens)) · \(row.costUsd.formatted(.currency(code: "USD")))")
                            .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(T3.muted)
                    }
                    GeometryReader { proxy in
                        Capsule().fill(Color.white.opacity(0.07)).overlay(alignment: .leading) {
                            Capsule().fill(ProviderBrand.tint(driver: row.provider == "claude" ? "claudeAgent" : row.provider))
                                .frame(width: max(4, proxy.size.width * CGFloat(row.tokens) / CGFloat(maxTokens)))
                        }
                    }.frame(height: 5)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .overlay(alignment: .top) { Rectangle().fill(T3.border).frame(height: 1).padding(.leading, 14) }
            }
        }
    }
}
