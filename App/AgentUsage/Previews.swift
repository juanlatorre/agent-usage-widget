import SwiftUI
import AgentUsageCore

/// Canvas previews exercising the AC3 state matrix with fixed clocks.
/// Fixture data mirrors `FixtureProvider` scenarios and is demo infrastructure.
enum PreviewFixtures {
    static let now = Date(timeIntervalSince1970: 1_760_000_000)

    private static func slot(_ id: AccountSlotID, label: String,
                             windows: [UsageWindowKind], connected: Bool = true) -> AccountSlot {
        AccountSlot(slotID: id, label: label, provider: .claude,
                    requiredWindows: windows, isConnected: connected)
    }

    private static func window(_ kind: UsageWindowKind, used: Double, limit: Double,
                               resetIn: TimeInterval) -> UsageWindow {
        UsageWindow(id: kind, name: kind.displayName, isRequired: true,
                    used: used, limit: limit, resetAt: now.addingTimeInterval(resetIn))
    }

    static func presentation(
        status: AccountStatus
    ) -> AccountPresentation {
        let openCode = slot(.openCodeGO, label: "OpenCode · GO",
                           windows: [.fiveHour, .weekly, .monthly])
        switch status {
        case .available:
            return AvailabilityEngine.derive(
                slot: openCode,
                snapshot: UsageSnapshot(
                    slotID: .openCodeGO, provider: .opencode,
                    windows: [
                        window(.fiveHour, used: 42, limit: 100, resetIn: 1800),
                        window(.weekly, used: 10, limit: 100, resetIn: 86_400),
                        window(.monthly, used: 5, limit: 200, resetIn: 400_000)
                    ],
                    capturedAt: now),
                now: now)
        case .blocked:
            return AvailabilityEngine.derive(
                slot: openCode,
                snapshot: UsageSnapshot(
                    slotID: .openCodeGO, provider: .opencode,
                    windows: [
                        window(.fiveHour, used: 100, limit: 100, resetIn: 3600),
                        window(.weekly, used: 100, limit: 100, resetIn: 3 * 86_400),
                        window(.monthly, used: 39, limit: 100, resetIn: 12 * 86_400)
                    ],
                    capturedAt: now),
                now: now)
        case .unavailable:
            // Expired history variant.
            return AvailabilityEngine.derive(
                slot: openCode,
                snapshot: UsageSnapshot(
                    slotID: .openCodeGO, provider: .opencode,
                    windows: [window(.fiveHour, used: 65, limit: 100, resetIn: 600)],
                    capturedAt: now.addingTimeInterval(-16 * 60)),
                now: now)
        case .loading:
            return AvailabilityEngine.derive(
                slot: openCode, snapshot: nil, now: now)
        case .error:
            let base = AvailabilityEngine.derive(
                slot: openCode,
                snapshot: UsageSnapshot(
                    slotID: .openCodeGO, provider: .opencode,
                    windows: [window(.fiveHour, used: 55, limit: 100, resetIn: 1200)],
                    capturedAt: now.addingTimeInterval(-120)),
                now: now)
            // ERROR presentation pairs a fresh historical snapshot with failure copy;
            // the refresh layer sets this status in later children.
            return AccountPresentation(
                slotID: base.slotID, label: base.label, status: .error,
                blockers: [], limitingWindow: nil, availableAt: nil,
                snapshotAge: base.snapshotAge,
                historicalWindows: base.historicalWindows,
                diagnosticNotes: ["Last refresh failed."])
        case .notConnected:
            return AvailabilityEngine.derive(
                slot: self.slot(.claudeLegacyA, label: "Claude (legacy A)",
                           windows: [.fiveHour, .weekly], connected: false),
                snapshot: nil, now: now)
        case .authenticationRequired:
            return AvailabilityEngine.derive(
                slot: self.slot(.claudeLegacyA, label: "Claude (legacy A)",
                           windows: [.fiveHour, .weekly]),
                snapshot: UsageSnapshot(
                    slotID: .claudeLegacyA, provider: .claude,
                    windows: [window(.fiveHour, used: 48, limit: 100, resetIn: 1500),
                              window(.weekly, used: 22, limit: 100, resetIn: 3 * 86_400)],
                    capturedAt: now.addingTimeInterval(-3 * 60)),
                now: now,
                authenticationRequired: true)
        }
    }
}

#Preview("Available") {
    AccountDetailView(presentation: PreviewFixtures.presentation(status: .available),
                      displayMode: .used)
}

#Preview("Blocked · multiple") {
    AccountDetailView(presentation: PreviewFixtures.presentation(status: .blocked),
                      displayMode: .remaining)
}

#Preview("Unavailable · stale") {
    AccountDetailView(presentation: PreviewFixtures.presentation(status: .unavailable),
                      displayMode: .remaining)
}

#Preview("Loading") {
    AccountDetailView(presentation: PreviewFixtures.presentation(status: .loading),
                      displayMode: .remaining)
}

#Preview("Not connected") {
    AccountDetailView(presentation: PreviewFixtures.presentation(status: .notConnected),
                      displayMode: .remaining)
}

#Preview("Reconnection required") {
    AccountDetailView(presentation: PreviewFixtures.presentation(status: .authenticationRequired),
                      displayMode: .remaining)
}
