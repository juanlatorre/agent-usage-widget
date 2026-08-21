import SwiftUI
import AgentUsageCore

/// Detailed account view rendering every required window without provider branching (AC5).
struct AccountDetailView: View {
    let presentation: AccountPresentation
    let displayMode: DisplayPreferences.DisplayMode

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                statusBanner
                if presentation.status == .blocked {
                    blockersSection
                }
                windowsSection
                diagnosticsSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(presentation.label)
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            if let limiting = presentation.limitingWindow {
                ZStack {
                    UsageRing(fraction: limiting.fraction(for: displayMode),
                              status: presentation.status)
                        .frame(width: 72, height: 72)
                    Text(percentText(limiting.fraction(for: displayMode)))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(statusName)
                    .font(.title2.weight(.semibold))
                if let availableAt = presentation.availableAt {
                    Text("Available at \(availableAt.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(.secondary)
                }
                Text("Snapshot age: \(ageText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch presentation.status {
        case .notConnected:
            banner("Connect this account to start tracking usage.",
                   systemImage: "link.badge.plus", tint: .secondary)
        case .loading:
            banner("Waiting for the first successful refresh.",
                   systemImage: "circle.dotted", tint: .blue)
        case .error:
            banner("The last refresh failed. Showing the most recent successful data as history.",
                   systemImage: "arrow.clockwise.circle", tint: .red)
        case .unavailable:
            banner("Current availability cannot be confirmed. History is context only.",
                   systemImage: "questionmark.circle", tint: .red)
        case .available, .blocked:
            EmptyView()
        }
    }

    private var blockersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Blocking windows")
                .font(.headline)
            ForEach(presentation.blockers) { blocker in
                HStack {
                    Label(blocker.name, systemImage: "pause.circle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Text("Resets \(blocker.resetAt.formatted(date: .omitted, time: .shortened))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var windowsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Usage windows")
                .font(.headline)
            let windows = presentation.historicalWindows
            if windows.isEmpty {
                Text("No usage data yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(windows, id: \.id) { window in
                    WindowBar(window: window, displayMode: displayMode,
                              degraded: presentation.status != .available
                                        && presentation.status != .blocked)
                }
            }
        }
    }

    @ViewBuilder
    private var diagnosticsSection: some View {
        if !presentation.diagnosticNotes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Diagnostics")
                    .font(.headline)
                ForEach(presentation.diagnosticNotes, id: \.self) { note in
                    Text("• \(note)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Helpers

    private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .foregroundStyle(tint)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusName: String {
        switch presentation.status {
        case .notConnected: return "Not connected"
        case .loading: return "Loading"
        case .available: return "Available"
        case .blocked: return "Blocked"
        case .error: return "Refresh failed"
        case .unavailable: return "Unavailable"
        }
    }

    private var ageText: String {
        let formatter = Duration.UnitsFormatStyle(
            allowedUnits: [.minutes, .seconds],
            width: .narrow,
            maximumUnitCount: 2)
        return Duration.seconds(presentation.snapshotAge).formatted(formatter)
    }

    private func percentText(_ fraction: Double) -> String {
        let percent = Int((fraction * 100).rounded())
        return "\(percent)%"
    }
}

/// One window bar. Layout depends only on generic window data, never provider type.
struct WindowBar: View {
    let window: UsageWindow
    let displayMode: DisplayPreferences.DisplayMode
    let degraded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.name)
                Spacer()
                Text(label)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text("Resets \(window.resetAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(degraded ? Color.gray : barColor)
                        .frame(width: max(4, geo.size.width * fraction))
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.name), \(label)")
    }

    private var fraction: Double {
        switch displayMode {
        case .used: return window.clampedUsedFraction
        case .remaining: return window.clampedUsedFraction * 0 + (1 - window.clampedUsedFraction)
        }
    }

    private var label: String {
        let percent = Int((fraction * 100).rounded())
        let noun = displayMode == .used ? "used" : "remaining"
        return "\(percent)% \(noun)"
    }

    private var barColor: Color {
        window.isBlocking ? .orange : .green
    }
}
