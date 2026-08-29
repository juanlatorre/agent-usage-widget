import SwiftUI
import AgentUsageCore

/// Menu bar menu content (native .menu style): crisp system-rendered items.
/// Informational rows are disabled Text items; actions are Buttons.
struct MenuBarMenuContent: View {
    @Environment(StatusModel.self) private var model

    var body: some View {
        ForEach(model.presentations) { p in
            Text(menuLine(p))
        }
        Divider()
        Button("Refresh Now") {
            Task { await model.refreshAllNow() }
        }
        Button("Open Dashboard") {
            AppDelegate.openMainWindow()
        }
        Divider()
        Button("Quit Agent Usage") {
            NSApp.terminate(nil)
        }
    }

    /// "Claude — 62% remaining · 7d resets 5:04 PM" / "Claude — stale (2h ago)"
    private func menuLine(_ p: AccountPresentation) -> String {
        let name = shortLabel(p.label)
        switch p.status {
        case .available, .blocked, .loading:
            guard let w = p.limitingWindow else { return "\(name) — \(p.status)" }
            let pct = Int((w.fraction(for: model.preferences.displayMode) * 100).rounded())
            let reset = w.resetAt.formatted(date: .omitted, time: .shortened)
            return "\(name) — \(pct)% \(displayMode == .used ? "used" : "remaining"), resets \(reset)"
        case .unavailable:
            return "\(name) — stale (\(agoText(p.snapshotAge)) ago), refresh to update"
        case .error:
            return "\(name) — last refresh failed, retrying"
        case .authenticationRequired:
            return "\(name) — reconnect required"
        case .notConnected:
            return "\(name) — not connected"
        }
    }

    private var displayMode: DisplayPreferences.DisplayMode { model.preferences.displayMode }

    private func shortLabel(_ label: String) -> String {
        if let sep = label.firstIndex(where: { $0 == "·" || $0 == "-" }) {
            let head = label[..<sep].trimmingCharacters(in: .whitespaces)
            if !head.isEmpty { return String(head) }
        }
        return label
    }

    private func agoText(_ seconds: TimeInterval) -> String {
        let s = max(seconds, 0)
        if s < 60 { return "\(Int(s))s" }
        let m = Int(s) / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return "\(h)h" }
        return "\(h / 24)d"
    }
}
