import AppKit
import SwiftUI

struct NotchLayout: Equatable {
    /// Width of each status wing beside the hardware notch. Wings only exist while there is activity to report.
    static let statusWingWidth: CGFloat = 30
    /// Radius of the concave fillets where the panel meets the top screen edge beside the hardware notch.
    static let topEar: CGFloat = 6

    let centerX: CGFloat
    let topY: CGFloat
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let availableWidth: CGFloat
    let availableHeight: CGFloat

    init(screen: NSScreen) {
        self.init(frame: screen.frame, visibleFrame: screen.visibleFrame, notchInset: screen.safeAreaInsets.top,
                  leftAuxiliary: screen.auxiliaryTopLeftArea, rightAuxiliary: screen.auxiliaryTopRightArea)
    }

    init(frame: CGRect, visibleFrame: CGRect, notchInset: CGFloat, leftAuxiliary: CGRect?, rightAuxiliary: CGRect?) {
        if notchInset > 0 {
            let leftEdge = leftAuxiliary?.maxX ?? frame.midX - 100
            let rightEdge = rightAuxiliary?.minX ?? frame.midX + 100
            centerX = (leftEdge + rightEdge) / 2
            topY = frame.maxY
            notchWidth = max(rightEdge - leftEdge, 0)
            notchHeight = notchInset
        } else {
            centerX = frame.midX
            topY = visibleFrame.maxY - 5
            notchWidth = 0
            notchHeight = 0
        }

        availableWidth = 2 * min(centerX - frame.minX, frame.maxX - centerX)
        availableHeight = topY - frame.minY
    }

    var hasNotch: Bool { notchWidth > 0 }
    var topEar: CGFloat { hasNotch ? Self.topEar : 0 }
    var contentWidth: CGFloat { min(max(notchWidth, 530), max(0, availableWidth - 24)) }
    var maxContentHeight: CGFloat { min(600, max(0, availableHeight - notchHeight - 28)) }

    enum Layer: Equatable {
        case collapsed, peek, hover, workspace, voice
    }

    /// `activity` widens the collapsed shape into status wings. Idle, the collapsed shape is exactly the hardware notch.
    func shape(for layer: Layer, workspaceHeight: CGFloat? = nil, hoverHeight: CGFloat = 106,
               peekHeight: CGFloat = 36, activity: Bool = false) -> NotchShape {
        let width: CGFloat
        let height: CGFloat
        switch layer {
        case .collapsed:
            width = hasNotch ? notchWidth + (activity ? 2 * Self.statusWingWidth : 0) : (activity ? 176 : 136)
            height = hasNotch ? notchHeight : 30
        case .peek:
            width = peekHeight > 36 ? 430 : 392
            height = notchHeight + peekHeight
        case .hover:
            width = 410
            height = notchHeight + hoverHeight
        case .workspace:
            width = contentWidth
            height = notchHeight + (workspaceHeight ?? maxContentHeight)
        case .voice:
            width = contentWidth
            height = notchHeight + min(350, maxContentHeight)
        }
        return NotchShape(width: min(width, contentWidth), height: min(height, notchHeight + maxContentHeight),
                          topEar: topEar, topRadius: hasNotch ? 0 : layer == .collapsed ? 15 : 17,
                          bottomRadius: layer == .collapsed ? (hasNotch ? 10 : 15) : 18)
    }

    /// The collapsed shape with no activity: exactly the hardware notch.
    var idleSize: CGSize {
        let idle = shape(for: .collapsed)
        return CGSize(width: idle.width, height: idle.height)
    }

    var panelFrame: CGRect {
        let left = (centerX - min(availableWidth, contentWidth + 24) / 2).rounded(.up)
        let height = min(ceil(notchHeight + maxContentHeight + 24), availableHeight)
        return CGRect(x: left, y: topY - height, width: 2 * (centerX - left), height: height)
    }

    func containsPointer(_ point: CGPoint, in frame: CGRect, path: CGPath) -> Bool {
        guard frame.contains(point) else { return false }
        let local = CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y)
        return path.boundingBoxOfPath.contains(local) && path.contains(local)
    }
}

/// The notch silhouette: concave ears that merge with the screen's top edge, and rounded bottom corners.
struct NotchShape: Shape, Equatable {
    var width: CGFloat
    var height: CGFloat
    var topEar: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var interpolates = true

    typealias Metrics = AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>>

    var animatableData: Metrics {
        get { interpolates ? .init(.init(width, height), .init(topRadius, bottomRadius)) : .zero }
        set {
            guard interpolates else { return }
            width = newValue.first.first
            height = newValue.first.second
            topRadius = newValue.second.first
            bottomRadius = newValue.second.second
        }
    }

    func path(in bounds: CGRect) -> Path { outline(in: bounds, closed: true) }

    /// The visible edge only: down the left side, along the bottom and up the right, without the top edge
    /// that sits against the screen's top. Used for the activity glow.
    func edge(in bounds: CGRect) -> Path { outline(in: bounds, closed: false) }

    private func outline(in bounds: CGRect, closed: Bool) -> Path {
        let width = min(max(width, 0), bounds.width)
        let height = min(max(height, 0), bounds.height)
        let rect = CGRect(x: bounds.midX - width / 2, y: bounds.minY, width: width, height: height)
        let k: CGFloat = 0.5523
        let ear = min(topEar, rect.width / 4, rect.height / 2)
        let bottom = min(bottomRadius, (rect.width - 2 * ear) / 2, rect.height - ear)
        let top = min(topRadius, rect.width / 2, rect.height / 2)
        var path = Path()
        if ear > 0 {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addCurve(to: CGPoint(x: rect.minX + ear, y: rect.minY + ear),
                          control1: CGPoint(x: rect.minX + k * ear, y: rect.minY),
                          control2: CGPoint(x: rect.minX + ear, y: rect.minY + ear - k * ear))
            path.addLine(to: CGPoint(x: rect.minX + ear, y: rect.maxY - bottom))
            path.addCurve(to: CGPoint(x: rect.minX + ear + bottom, y: rect.maxY),
                          control1: CGPoint(x: rect.minX + ear, y: rect.maxY - bottom * (1 - k)),
                          control2: CGPoint(x: rect.minX + ear + bottom * (1 - k), y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX - ear - bottom, y: rect.maxY))
            path.addCurve(to: CGPoint(x: rect.maxX - ear, y: rect.maxY - bottom),
                          control1: CGPoint(x: rect.maxX - ear - bottom * (1 - k), y: rect.maxY),
                          control2: CGPoint(x: rect.maxX - ear, y: rect.maxY - bottom * (1 - k)))
            path.addLine(to: CGPoint(x: rect.maxX - ear, y: rect.minY + ear))
            path.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control1: CGPoint(x: rect.maxX - ear, y: rect.minY + ear - k * ear),
                          control2: CGPoint(x: rect.maxX - k * ear, y: rect.minY))
            if closed { path.closeSubpath() }
        } else {
            path.addPath(UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                                                bottomTrailingRadius: bottom, topTrailingRadius: top).path(in: rect))
        }
        return path
    }
}
