import SwiftUI
import AgentUsageCore

/// Menu bar extra: compact per-account rings in the bar, popover with usage
/// rows, refresh and dashboard actions. Shares the app's StatusModel, so it
/// always reflects the same state as the main window and the widgets.
struct MenuBarContentView: View {
    @Environment(StatusModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @State private var refreshing = false

    private var presentations: [AccountPresentation] {
        WidgetOrdering.sorted(model.presentations)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Agent Usage").font(.footnote.weight(.semibold))
                Spacer(minLength: 6)
                if refreshing {
                    ProgressView().controlSize(.mini)
                } else {
                    Button {
                        refreshing = true
                        Task { @MainActor in
                            await model.refreshAllNow()
                            refreshing = false
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh all accounts")
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                ForEach(presentations) { p in
                    MenuBarRow(p: p, displayMode: model.preferences.displayMode)
                }
            }

            Divider()
            Button {
                openWindow(id: "main")
            } label: {
                Label("Open dashboard", systemImage: "rectangle.inset.filled")
                    .font(.footnote)
            }
            .buttonStyle(.plain)

            Button {
                if let url = URL(string: "x-apple.systemprefs:com.apple.LoginItems-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Login Items…", systemImage: "person.badge.key")
                    .font(.footnote)
            }
            .buttonStyle(.plain)

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit Agent Usage", systemImage: "power")
                    .font(.footnote)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 280)
        .onAppear {
            // Poller: activation-style refresh when the menu opens; the
            // scheduler gates anything not due.
            Task { await model.handleAppActivation() }
        }
    }
}

/// Compact slot name: "Command Code · GOAT" → "Command Code".
private func shortLabel(_ label: String) -> String {
    if let sep = label.firstIndex(where: { $0 == "·" || $0 == "-" }) {
        let head = label[..<sep].trimmingCharacters(in: .whitespaces)
        if !head.isEmpty { return String(head) }
    }
    return label
}

/// One menu-bar row: ring + short name + status/age + percent.
struct MenuBarRow: View {
    let p: AccountPresentation
    let displayMode: DisplayPreferences.DisplayMode

    private var percent: Int {
        Int(((p.limitingWindow?.fraction(for: displayMode))
             ?? (p.historicalWindows.first.map { displayMode == .used ? $0.clampedUsedFraction : 1 - $0.clampedUsedFraction })
             ?? 0) * 100)
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(lineWidth: 3).foregroundStyle(.quaternary)
                if let limiting = p.limitingWindow {
                    Circle().trim(from: 0, to: min(max(limiting.fraction(for: displayMode), 0), 1))
                        .stroke(statusTint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(shortLabel(p.label)).font(.footnote.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text("\(percent)%")
                .font(.system(.callout, design: .rounded).monospacedDigit().weight(.semibold))
                .foregroundStyle(degraded ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.primary))
                .lineLimit(1)
        }
        .opacity(degraded ? 0.75 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(p.label), \(statusCaption)")
    }

    private var degraded: Bool {
        p.status == .error || p.status == .unavailable
    }

    private var statusTint: Color {
        switch p.status {
        case .available: return .green
        case .blocked: return .orange
        case .error: return .red
        case .unavailable, .notConnected: return .gray
        case .authenticationRequired: return .purple
        case .loading: return .blue
        }
    }

    private var statusCaption: String {
        switch p.status {
        case .available: return "Available"
        case .blocked: return "Blocked"
        case .error: return "Refresh failed"
        case .unavailable: return "Stale · open app"
        case .authenticationRequired: return "Reconnect"
        case .loading: return "Loading…"
        case .notConnected: return "Not connected"
        }
    }

    private var subtitle: String {
        if let limiting = p.limitingWindow {
            return limiting.name
        }
        if p.status == .unavailable {
            return "\(agoText(p.snapshotAge)) ago"
        }
        return statusCaption
    }

    private var agoText: (TimeInterval) -> String {
        { s in
            let sec = max(s, 0)
            if sec < 60 { return "\(Int(sec))s" }
            let m = Int(sec) / 60
            if m < 60 { return "\(m)m" }
            let h = m / 60
            if h < 24 { return "\(h)h" }
            return "\(h / 24)d"
        }
    }
}
