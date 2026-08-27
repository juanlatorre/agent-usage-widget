import SwiftUI
import WidgetKit
import AgentUsageCore

// MARK: - Style primitives

private func statusColor(_ status: AccountStatus) -> Color {
    switch status {
    case .available: return .green
    case .blocked: return .orange
    case .error, .unavailable: return .red
    case .authenticationRequired: return .purple
    case .loading: return .blue
    case .notConnected: return .gray
    }
}

private func statusCaption(_ status: AccountStatus) -> String {
    switch status {
    case .available: return "Available"
    case .blocked: return "Blocked"
    case .error: return "Refresh failed"
    case .unavailable: return "Unavailable"
    case .authenticationRequired: return "Reconnect"
    case .loading: return "Loading…"
    case .notConnected: return "Not connected"
    }
}

private func statusSymbol(_ status: AccountStatus) -> String {
    switch status {
    case .available: return "checkmark.circle.fill"
    case .blocked: return "exclamationmark.triangle.fill"
    case .error, .unavailable: return "xmark.circle.fill"
    case .authenticationRequired: return "key.slash"
    case .loading: return "circle.dotted"
    case .notConnected: return "circle.slash"
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

private func shortWindowName(_ kind: UsageWindowKind) -> String {
    switch kind {
    case .fiveHour: return "5h"
    case .weekly: return "7d"
    case .monthly: return "30d"
    }
}

private struct StatusDot: View {
    let status: AccountStatus
    var body: some View {
        Circle()
            .fill(statusColor(status))
            .frame(width: 6, height: 6)
    }
}

/// Right-aligned monospaced percentage, large and rounded.
private struct PercentText: View {
    let fraction: Double
    var large: Bool = false
    var tint: Color = .primary
    var body: some View {
        Text("\(Int((fraction * 100).rounded()))%")
            .font(large
                  ? .system(.body, design: .rounded).monospacedDigit().weight(.semibold)
                  : .system(.callout, design: .rounded).monospacedDigit().weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

/// Thin usage bar. Fill = status color (gray when degraded history).
private struct UsageBar: View {
    let fraction: Double
    let status: AccountStatus
    var height: CGFloat = 5
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(barColor)
                    .frame(width: max(3, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
    private var barColor: Color {
        switch status {
        case .available: return .green
        case .blocked: return .orange
        case .loading: return .blue
        default: return .gray
        }
    }
}

/// Countdown to a reset, monospaced, right-aligned, stable width.
/// Upper bound is the reset date: after it passes the timer clamps instead
/// of counting toward a distant bound (the old `resetAt...distantFuture`
/// range rendered "17306572:01:48" — hours until year 4001 — once a cached
/// entry outlived its reset).
private struct ResetCountdown: View {
    let resetAt: Date
    var tint: Color = .secondary
    var body: some View {
        if resetAt > Date() {
            Text(timerInterval: Date()...resetAt, countsDown: true)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(tint)
                .frame(minWidth: 32, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } else {
            Text("reset…")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(minWidth: 32, alignment: .trailing)
                .lineLimit(1)
        }
    }
}

// MARK: - Row (Medium + Large)

/// Two-line compact row: dot+name+countdown+percent, thin bar below.
/// Not-connected slots collapse to one line. `large` scales typography for
/// the Large widget (344pt tall — all six rows fit with room to breathe).
private struct AccountRow: View {
    let p: AccountPresentation
    let displayMode: DisplayPreferences.DisplayMode
    var large: Bool = false

    var body: some View {
        if p.status == .notConnected {
            HStack(spacing: 6) {
                StatusDot(status: p.status)
                Text(shortLabel(p.label))
                    .font(large ? .subheadline.weight(.medium) : .footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("Connect in app").font(.caption2).foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(p.label), not connected")
        } else {
            VStack(alignment: .leading, spacing: large ? 5 : 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    StatusDot(status: p.status)
                        .frame(width: large ? 7 : 6, height: large ? 7 : 6)
                    Text(shortLabel(p.label))
                        .font(large ? .subheadline.weight(.medium) : .footnote.weight(.medium))
                        .lineLimit(1)
                    if let kind = p.limitingWindow?.kind {
                        Text(shortWindowName(kind))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                    if let limiting = p.limitingWindow {
                        if p.status == .blocked {
                            ResetCountdown(resetAt: limiting.resetAt, tint: .orange)
                        } else {
                            ResetCountdown(resetAt: limiting.resetAt)
                        }
                        PercentText(
                            fraction: limiting.fraction(for: displayMode),
                            large: large,
                            tint: p.status == .blocked ? .orange : .primary)
                    } else {
                        Text(statusCaption(p.status)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let limiting = p.limitingWindow {
                    UsageBar(
                        fraction: limiting.fraction(for: displayMode),
                        status: p.status,
                        height: large ? 6 : 5)
                } else {
                    Text(statusCaption(p.status)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(p.label), \(statusCaption(p.status))\(p.limitingWindow.map { ", \(Int($0.usedFraction * 100))% used" } ?? "")")
        }
    }
}

// MARK: - Header

private struct WidgetHeader: View {
    let title: String
    let updated: Date
    let accountIDs: [String]
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.footnote.weight(.semibold))
            Spacer(minLength: 6)
            Text("Updated \(updated, style: .relative) ago")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Button(intent: RefreshWidgetIntent(accountIDs: accountIDs)) {
                Image(systemName: "arrow.clockwise")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Refresh accounts")
        }
    }
}

// MARK: - Small

struct SmallView: View {
    let entry: AgentUsageEntry
    var body: some View {
        if entry.isUnconfigured || entry.presentations.isEmpty {
            ContentUnavailableView("Choose an account", systemImage: "rectangle.dashed", description: Text("Edit widget to select one."))
                .widgetURL(URL(string: "agent-usage://open"))
        } else {
            let p = entry.presentations[0]
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    StatusDot(status: p.status)
                    Text(shortLabel(p.label)).font(.footnote.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(statusCaption(p.status))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                ZStack {
                    Circle().stroke(lineWidth: 6).foregroundStyle(.quaternary)
                    Circle().trim(from: 0, to: min(max(p.limitingWindow?.fraction(for: entry.displayMode) ?? 0, 0), 1))
                        .stroke(style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .foregroundStyle(statusColor(p.status))
                        .rotationEffect(.degrees(-90))
                    if let limiting = p.limitingWindow {
                        Text("\(Int((limiting.fraction(for: entry.displayMode) * 100).rounded()))%")
                            .font(.system(.title3, design: .rounded).monospacedDigit().weight(.bold))
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                    } else {
                        Image(systemName: statusSymbol(p.status))
                            .font(.title3)
                            .foregroundStyle(statusColor(p.status))
                    }
                }
                .frame(width: 84, height: 84)
                .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                if let limiting = p.limitingWindow {
                    HStack {
                        Text("\(shortWindowName(limiting.kind)) · resets in")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        ResetCountdown(resetAt: limiting.resetAt, tint: p.status == .blocked ? .orange : .secondary)
                    }
                } else {
                    Text(p.status == .authenticationRequired ? "Reconnect in the app." : "Waiting for data…")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .widgetURL(URL(string: "agent-usage://open"))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(p.label), \(statusCaption(p.status))")
        }
    }
}

// MARK: - Medium

struct MediumView: View {
    let entry: AgentUsageEntry
    var body: some View {
        if entry.isUnconfigured || entry.presentations.isEmpty {
            ContentUnavailableView("Choose accounts", systemImage: "rectangle.dashed", description: Text("Edit widget to select up to three."))
                .widgetURL(URL(string: "agent-usage://open"))
        } else {
            let ordered = WidgetOrdering.sorted(entry.presentations)
            VStack(alignment: .leading, spacing: 12) {
                WidgetHeader(
                    title: "Agent Usage",
                    updated: entry.date,
                    accountIDs: ordered.map { $0.slotID.rawValue })
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(ordered) { p in
                        AccountRow(p: p, displayMode: entry.displayMode)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .widgetURL(URL(string: "agent-usage://open"))
        }
    }
}

// MARK: - Large

struct LargeView: View {
    let entry: AgentUsageEntry
    var body: some View {
        let ordered = WidgetOrdering.sorted(entry.presentations)
        if ordered.isEmpty {
            ContentUnavailableView("Agent Usage", systemImage: "rectangle.dashed", description: Text("Connect accounts in the app."))
                .widgetURL(URL(string: "agent-usage://open"))
        } else {
            VStack(alignment: .leading, spacing: 12) {
                WidgetHeader(
                    title: "Agent Usage",
                    updated: entry.date,
                    accountIDs: ordered.map { $0.slotID.rawValue })
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(ordered) { p in
                        AccountRow(p: p, displayMode: entry.displayMode, large: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .widgetURL(URL(string: "agent-usage://open"))
        }
    }
}
