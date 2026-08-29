import SwiftUI
import AgentUsageCore

/// The menu bar icon: one compact donut per connected account, colored by
/// status, drawn in an NSImage so it renders crisply at template scale in
/// the menu bar. With zero connected accounts, falls back to the app glyph.
struct MenuBarIconView: View {
    let presentations: [AccountPresentation]

    var body: some View {
        if presentations.isEmpty {
            Image(systemName: "gauge.with.needle")
        } else {
            Image(nsImage: MenuBarIconRenderer.image(for: presentations))
                .renderingMode(.template)
        }
    }
}

/// Draws 18×18pt rings (one per connected account, max five) into a single
/// template NSImage for the menu bar.
@MainActor
enum MenuBarIconRenderer {
    static func image(for presentations: [AccountPresentation]) -> NSImage {
        let connected = presentations.filter { $0.status != .notConnected }
        let count = max(connected.count, 1)
        let ring: CGFloat = count == 1 ? 14 : (count <= 3 ? 9 : 6)
        let size = NSSize(width: ceil(ring * 2 * CGFloat(count)) + 2, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            for (index, presentation) in connected.prefix(5).enumerated() {
                let fraction = ringFraction(presentation)
                let tint = color(for: presentation.status)
                let cx = ring + CGFloat(index) * (ring * 2 + 1.5)
                let center = NSPoint(x: cx, y: 9)
                drawTrack(center: center, radius: ring - 1)
                drawArc(center: center, radius: ring - 1, fraction: fraction, color: tint)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func ringFraction(_ p: AccountPresentation) -> CGFloat {
        if let limiting = p.limitingWindow {
            return min(max(limiting.usedFraction, 0), 1)
        }
        if let first = p.historicalWindows.first {
            return min(max(first.clampedUsedFraction, 0), 1)
        }
        return 0
    }

    private static func color(for status: AccountStatus) -> NSColor {
        switch status {
        case .available: return NSColor.systemGreen
        case .blocked: return NSColor.systemOrange
        case .error, .unavailable: return NSColor.systemGray
        case .authenticationRequired: return NSColor.systemPurple
        case .loading: return NSColor.systemBlue
        case .notConnected: return NSColor.systemGray
        }
    }

    private static func drawTrack(center: NSPoint, radius: CGFloat) {
        NSColor.systemGray.withAlphaComponent(0.35).setStroke()
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        path.lineWidth = 2
        path.stroke()
    }

    private static func drawArc(center: NSPoint, radius: CGFloat, fraction: CGFloat, color: NSColor) {
        let clamped = min(max(fraction, 0.001), 1)
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius,
                      startAngle: 90, endAngle: 90 - 360 * clamped, clockwise: true)
        arc.lineWidth = 2
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
    }

}
