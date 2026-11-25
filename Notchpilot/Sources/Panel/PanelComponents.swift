import NotchpilotCore
import SwiftUI

/// What the collapsed notch reports through its side wings. Idle, there are no wings at all.
enum NotchActivity: Equatable {
    case running(Int)
    case done
    case attention

    var label: String {
        switch self {
        case .running(let count): count > 1 ? "\(count) sessions running" : "Session running"
        case .done: "Session finished"
        case .attention: "Needs attention"
        }
    }
}

/// The live status shown in the panel header.
struct PanelStatus: Equatable {
    enum Tone: Equatable { case running, waiting, offline, failed, idle }
    let text: String
    let tone: Tone

    var color: Color {
        switch tone {
        case .running: T3.link
        case .waiting: T3.warning
        case .offline: T3.faint
        case .failed: T3.error
        case .idle: T3.success
        }
    }
}

/// An arc that turns continuously. A timeline drives it so it never fights other animations;
/// with Reduce Motion it holds still.
struct ActivitySpinner: View {
    var size: CGFloat = 13
    var color: Color = T3.link
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                arc(turns: 0)
            } else {
                TimelineView(.animation) { context in
                    arc(turns: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func arc(turns: Double) -> some View {
        Circle()
            .trim(from: 0.08, to: 0.78)
            .stroke(AngularGradient(colors: [color.opacity(0.08), color], center: .center),
                    style: StrokeStyle(lineWidth: max(1.6, size / 7), lineCap: .round))
            .rotationEffect(.degrees(turns * 360))
    }
}

/// The glyph in the left wing: a spinner, a check, or a yellow dot.
struct ActivityGlyph: View {
    let activity: NotchActivity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch activity {
            case .running:
                ActivitySpinner(size: 13)
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(T3.success)
            case .attention:
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(T3.warning)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activity.label)
    }
}

/// A compact dropdown: icon, small caption, current value, chevron.
struct PickerChip<Content: View>: View {
    let icon: String
    let title: String
    let value: String
    var loading = false
    @ViewBuilder let content: () -> Content
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(T3.link.opacity(0.85))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: T3.micro, weight: .medium))
                        .foregroundStyle(T3.faint)
                    Text(value)
                        .font(.system(size: T3.small, weight: .medium))
                        .foregroundStyle(T3.foreground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 2)
                if loading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(T3.faint)
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40)
            .background(hovering && isEnabled ? T3.fillHover : T3.fill,
                        in: RoundedRectangle(cornerRadius: T3.cardRadius - 2, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: T3.cardRadius - 2, style: .continuous)
                    .strokeBorder(hovering && isEnabled ? T3.borderStrong : T3.border, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: T3.cardRadius - 2, style: .continuous))
            .opacity(isEnabled ? 1 : 0.55)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .clickableCursor()
        .onHover { hovering = $0 }
        .accessibilityLabel("\(title): \(value)")
    }
}

/// The header's live status: a dot and a short phrase such as "1 running", "1 waiting" or "Offline".
struct PanelStatusLabel: View {
    let status: PanelStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.color)
                .frame(width: 6, height: 6)
            Text(status.text)
                .font(.system(size: T3.caption, weight: .medium))
                .foregroundStyle(T3.muted)
                .lineLimit(1)
                .fixedSize()
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: status)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(status.text)")
    }
}

/// Pill tabs with a highlight that slides between the selected tab. With Reduce Motion it just changes.
struct PanelTabBar: View {
    let tabs: [PanelTab]
    let selected: PanelTab?
    let reduceMotion: Bool
    let select: (PanelTab) -> Void
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.self) { tab in
                let isSelected = tab == selected
                Button { select(tab) } label: {
                    Text(tab.rawValue)
                        .font(.system(size: T3.small - 0.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.black : T3.muted)
                        .padding(.horizontal, 11)
                        .frame(height: 24)
                        .background { highlight(isSelected) }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain).clickableCursor()
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(T3.fill, in: Capsule())
        .overlay(Capsule().strokeBorder(T3.border, lineWidth: 1))
    }

    @ViewBuilder
    private func highlight(_ isSelected: Bool) -> some View {
        if isSelected {
            if reduceMotion {
                Capsule().fill(T3.foreground)
            } else {
                Capsule().fill(T3.foreground).matchedGeometryEffect(id: "selection", in: namespace)
            }
        }
    }
}

/// A capsule button with a leading icon. `.prominent` is the panel's primary action (filled, glowing);
/// `.quiet` is a bordered secondary action.
struct PanelPillButton: View {
    enum Style { case prominent, quiet }

    let title: String
    var icon: String?
    var style: Style = .quiet
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 10, weight: .bold))
                }
                Text(title).font(.system(size: T3.caption + 0.5, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background { background }
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(PressableStyle())
        .clickableCursor()
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var foreground: Color {
        switch style {
        case .prominent: .white
        case .quiet: hovering && isEnabled ? T3.foreground : T3.foreground.opacity(0.82)
        }
    }

    @ViewBuilder private var background: some View {
        switch style {
        case .prominent:
            Capsule()
                .fill(T3.primary)
                .brightness(hovering && isEnabled ? 0.06 : 0)
        case .quiet:
            Capsule()
                .fill(hovering && isEnabled ? T3.fillHover : T3.fill)
                .overlay(Capsule().strokeBorder(hovering && isEnabled ? T3.borderStrong : T3.border, lineWidth: 1))
        }
    }
}

/// A small round icon button with a hairline border, optionally tinted (e.g. green for resolve).
struct PanelIconButton: View {
    let icon: String
    var size: CGFloat = 28
    var tint: Color?
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tint ?? (hovering ? T3.foreground : T3.muted))
                .frame(width: size, height: size)
                .background((tint ?? .white).opacity(hovering && isEnabled ? 0.16 : (tint == nil ? 0.04 : 0.10)), in: Circle())
                .overlay(Circle().strokeBorder((tint ?? .white).opacity(tint == nil ? (hovering ? 0.14 : 0.08) : 0.28),
                                               lineWidth: 1))
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(PressableStyle())
        .clickableCursor()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
    }
}

/// Light that lives on the notch's edge. Running: a comet sweeps from the left edge, through the bottom curves,
/// to the right edge and back. Done: the whole edge breathes green. Reduce Motion holds a still glow.
struct NotchGlow: View {
    enum Mode: Equatable { case running, done }

    let shape: NotchShape
    let size: CGSize
    let mode: Mode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let comet = LinearGradient(
        colors: [Color(red: 0.35, green: 0.85, blue: 1.0), T3.link, Color(red: 0.62, green: 0.45, blue: 1.0),
                 Color(red: 0.35, green: 0.85, blue: 1.0)],
        startPoint: .leading, endPoint: .trailing)

    var body: some View {
        // Sit just outside the silhouette, so the bright line isn't lost under the hardware notch's cutout.
        var outset = shape
        outset.width += 3
        outset.height += 1.5
        let edge = outset.edge(in: CGRect(origin: .zero, size: size))
        return Group {
            if reduceMotion {
                layers(edge, time: 0)
            } else {
                TimelineView(.animation) { context in
                    layers(edge, time: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func layers(_ edge: Path, time: TimeInterval) -> some View {
        switch mode {
        case .running:
            // Ping-pong across the edge with an ease at each end, so it reads as one sweep and a return.
            let period = 1.9
            let phase = time.truncatingRemainder(dividingBy: 2 * period) / period
            let linear = phase < 1 ? phase : 2 - phase
            let center = linear * linear * (3 - 2 * linear)
            let span = 0.30
            let from = max(0, center * (1 + span) - span)
            let to = min(1, center * (1 + span))
            let breathe = 0.5 + 0.5 * sin(time * 2.4)
            ZStack {
                edge.stroke(T3.link.opacity(0.22 + 0.10 * breathe), lineWidth: 1.5)
                    .blur(radius: 2)
                edge.trim(from: from, to: to)
                    .stroke(Self.comet, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .blur(radius: 7).opacity(0.9)
                edge.trim(from: from, to: to)
                    .stroke(Self.comet, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .shadow(color: T3.link.opacity(0.9), radius: 4)
            }
        case .done:
            let breathe = reduceMotion ? 1 : 0.55 + 0.45 * sin(time * 3.2)
            ZStack {
                edge.stroke(T3.success.opacity(0.55 * breathe), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .blur(radius: 8)
                edge.stroke(T3.success.opacity(0.65 + 0.35 * breathe), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .shadow(color: T3.success.opacity(0.8), radius: 4)
            }
        }
    }
}
