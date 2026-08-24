import SwiftUI
import WidgetKit
import AgentUsageCore

// MARK: - Shared primitives

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

private func statusCaption(_ status: AccountStatus) -> String {
    switch status {
    case .available: return "Available"
    case .blocked: return "Blocked"
    case .error: return "Refresh failed"
    case .unavailable: return "Unavailable"
    case .authenticationRequired: return "Reconnection required"
    case .loading: return "Loading…"
    case .notConnected: return "Not connected"
    }
}

private struct RingView: View {
    let fraction: Double
    let status: AccountStatus
    var body: some View {
        ZStack {
            Circle().stroke(lineWidth: 4).foregroundStyle(.quaternary)
            Circle().trim(from: 0, to: fraction)
                .stroke(style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .foregroundStyle(statusColor(status))
                .rotationEffect(.degrees(-90))
        }
    }
}

private struct BlockerPill: View {
    let blocker: BlockingWindow
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
            Text(blocker.name).font(.caption2).lineLimit(1)
            Spacer(minLength: 4)
            Text(timerInterval: blocker.resetAt...Date.distantFuture, countsDown: true)
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(.quaternary.opacity(0.4), in: Capsule())
        .accessibilityLabel("\(blocker.name) blocking, resets \(blocker.resetAt.formatted(date: .omitted, time: .shortened))")
    }
}

private struct WindowBar: View {
    let window: UsageWindow
    let degraded: Bool
    let displayMode: DisplayPreferences.DisplayMode
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(window.name).font(.caption2).lineLimit(1)
                if window.isBlocking {
                    Text("BLOCKING").font(.caption2.weight(.bold)).foregroundStyle(.orange)
                        .accessibilityLabel("Blocking")
                }
                Spacer(minLength: 4)
                Text(window.resetAt, style: .timer).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(degraded ? Color.gray : (window.isBlocking ? .orange : .green))
                        .frame(width: max(4, geo.size.width * fraction))
                }
            }.frame(height: 6)
        }
        .accessibilityElement(children: .combine)
    }
    private var fraction: Double {
        switch displayMode {
        case .used: return window.clampedUsedFraction
        case .remaining: return 1 - window.clampedUsedFraction
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
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    if let limiting = p.limitingWindow {
                        ZStack {
                            RingView(fraction: limiting.fraction(for: entry.displayMode), status: p.status)
                                .frame(width: 56, height: 56)
                            Text("\(Int((limiting.fraction(for: entry.displayMode) * 100).rounded()))%")
                                .font(.caption.weight(.semibold)).monospacedDigit()
                        }
                    } else {
                        Image(systemName: statusSymbol(p.status)).font(.title2).foregroundStyle(statusColor(p.status))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.label).font(.caption.weight(.semibold)).lineLimit(1)
                        Text(statusCaption(p.status)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        if p.status == .blocked, let at = p.availableAt {
                            Text(timerInterval: at...Date.distantFuture, countsDown: true)
                                .font(.caption2).foregroundStyle(.secondary)
                                .accessibilityLabel("Available at \(at.formatted(date: .omitted, time: .shortened))")
                        } else if p.status == .authenticationRequired {
                            Text("Reconnect in app").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                // R1 priority: blocker context when blocked, otherwise limiting context.
                if p.status == .blocked {
                    ForEach(p.blockers.prefix(2)) { BlockerPill(blocker: $0) }
                }
                if p.status != .available && p.status != .blocked {
                    Text("Last updated \(entry.date, style: .relative) ago").font(.caption2).foregroundStyle(.secondary)
                        .accessibilityLabel("Last updated \(entry.date.formatted(date: .omitted, time: .shortened))")
                }
                Spacer(minLength: 0)
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
            VStack(alignment: .leading, spacing: 8) {
                ForEach(ordered) { p in
                    HStack(spacing: 8) {
                        Image(systemName: statusSymbol(p.status)).foregroundStyle(statusColor(p.status)).font(.caption)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.label).font(.caption.weight(.semibold)).lineLimit(1)
                            Text(statusCaption(p.status)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let limiting = p.limitingWindow {
                            ZStack {
                                RingView(fraction: limiting.fraction(for: entry.displayMode), status: p.status)
                                    .frame(width: 28, height: 28)
                                Text("\(Int((limiting.fraction(for: entry.displayMode) * 100).rounded()))%")
                                    .font(.caption2).monospacedDigit()
                            }
                        }
                        if p.status == .blocked, let at = p.availableAt {
                            Text(timerInterval: at...Date.distantFuture, countsDown: true)
                                .font(.caption2).foregroundStyle(.secondary).frame(minWidth: 44, alignment: .trailing)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(p.label), \(statusCaption(p.status))")
                }
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Button(intent: RefreshWidgetIntent(accountIDs: ordered.map { $0.slotID.rawValue })) {
                        Label("Refresh Now", systemImage: "arrow.clockwise")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.secondary)
                    .accessibilityLabel("Refresh selected accounts")
                }
            }
            .padding(12)
            .widgetURL(URL(string: "agent-usage://open"))
        }
    }
}

// MARK: - Large

struct LargeView: View {
    let entry: AgentUsageEntry
    var body: some View {
        // R4: always all six, sorted by priority, every required window when space permits without horizontal scroll.
        let ordered = WidgetOrdering.sorted(entry.presentations)
        if ordered.isEmpty {
            ContentUnavailableView("Agent Usage", systemImage: "rectangle.dashed", description: Text("Connect accounts in the app."))
                .widgetURL(URL(string: "agent-usage://open"))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Agent Usage").font(.caption.weight(.semibold))
                    Spacer()
                    Button(intent: RefreshWidgetIntent(accountIDs: ordered.map { $0.slotID.rawValue })) {
                        Label("Refresh Now", systemImage: "arrow.clockwise").font(.caption2)
                    }
                    .buttonStyle(.bordered).controlSize(.mini).tint(.secondary)
                    .accessibilityLabel("Refresh all accounts")
                }
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(ordered) { p in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Image(systemName: statusSymbol(p.status)).foregroundStyle(statusColor(p.status)).font(.caption)
                                    Text(p.label).font(.caption.weight(.semibold)).lineLimit(1)
                                    Text(statusCaption(p.status)).font(.caption2).foregroundStyle(.secondary)
                                    Spacer()
                                    if let limiting = p.limitingWindow {
                                        ZStack {
                                            RingView(fraction: limiting.fraction(for: entry.displayMode), status: p.status)
                                                .frame(width: 24, height: 24)
                                            Text("\(Int((limiting.fraction(for: entry.displayMode) * 100).rounded()))%").font(.caption2).monospacedDigit()
                                        }
                                    }
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("\(p.label), \(statusCaption(p.status))")
                                if p.status == .blocked {
                                    ForEach(p.blockers) { BlockerPill(blocker: $0) }
                                    if let at = p.availableAt {
                                        Text("Available in \(at, style: .timer)").font(.caption2).foregroundStyle(.secondary)
                                            .accessibilityLabel("Available at \(at.formatted(date: .omitted, time: .shortened))")
                                    }
                                }
                                // R4: every declared required window.
                                ForEach(p.historicalWindows, id: \.id) { w in
                                    WindowBar(window: w, degraded: p.status != .available && p.status != .blocked, displayMode: entry.displayMode)
                                }
                                if p.historicalWindows.isEmpty && p.status != .notConnected {
                                    Text("No usage data yet.").font(.caption2).foregroundStyle(.secondary)
                                }
                                if !p.diagnosticNotes.isEmpty {
                                    ForEach(p.diagnosticNotes, id: \.self) { note in
                                        Text(note).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(8)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .widgetURL(URL(string: "agent-usage://open"))
        }
    }
}
