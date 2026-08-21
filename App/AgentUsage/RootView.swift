import SwiftUI
import AgentUsageCore

/// Root layout: stable six-slot list plus an account detail pane.
struct RootView: View {
    @Environment(StatusModel.self) private var model

    @State private var selection: AccountSlotID? = .claudeLegacyA

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Accounts") {
                    ForEach(model.presentations) { presentation in
                        AccountRow(presentation: presentation,
                                   displayMode: model.preferences.displayMode)
                            .tag(presentation.slotID)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 260)
        } detail: {
            if let presentation = model.presentations.first(where: { $0.slotID == selection }) {
                AccountDetailView(presentation: presentation,
                                  displayMode: model.preferences.displayMode)
            } else {
                ContentUnavailableView("No account selected", systemImage: "rectangle.dashed")
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .navigationTitle("Agent Usage")
    }
}

/// One account row: status-first, provider-agnostic.
struct AccountRow: View {
    let presentation: AccountPresentation
    let displayMode: DisplayPreferences.DisplayMode

    var body: some View {
        HStack(spacing: 10) {
            StatusGlyph(status: presentation.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.label)
                    .font(.body)
                    .lineLimit(1)
                Text(statusCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let limiting = presentation.limitingWindow {
                UsageRing(fraction: limiting.fraction(for: displayMode),
                          status: presentation.status)
                    .frame(width: 28, height: 28)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(presentation.label), \(accessibilityStatus)")
    }

    private var statusCaption: String {
        switch presentation.status {
        case .notConnected: return "Not connected"
        case .loading: return "Loading…"
        case .available: return "Available"
        case .blocked:
            if let availableAt = presentation.availableAt {
                return "Blocked · resets \(availableAt.formatted(date: .omitted, time: .shortened))"
            }
            return "Blocked"
        case .error: return "Refresh failed"
        case .unavailable: return "Unavailable"
        }
    }

    private var accessibilityStatus: String { statusCaption }
}

/// Compact status glyph with distinct shape + color so state survives color-vision
/// differences and vibrant contexts.
struct StatusGlyph: View {
    let status: AccountStatus

    private var color: Color {
        switch status {
        case .notConnected: return .gray
        case .loading: return .blue
        case .available: return .green
        case .blocked: return .orange
        case .error, .unavailable: return .red
        }
    }

    private var symbol: String {
        switch status {
        case .notConnected: return "circle.slash"
        case .loading: return "circle.dotted"
        case .available: return "checkmark.circle.fill"
        case .blocked: return "exclamationmark.triangle.fill"
        case .error, .unavailable: return "xmark.circle.fill"
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}

/// Deterministic usage ring used in rows and detail headers.
struct UsageRing: View {
    let fraction: Double
    let status: AccountStatus

    var body: some View {
        ZStack {
            Circle()
                .stroke(lineWidth: 4)
                .foregroundStyle(.quaternary)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .foregroundStyle(ringColor)
                .rotationEffect(.degrees(-90))
        }
    }

    private var ringColor: Color {
        switch status {
        case .available: return .green
        case .blocked: return .orange
        case .error, .unavailable: return .red
        case .loading, .notConnected: return .gray
        }
    }
}
