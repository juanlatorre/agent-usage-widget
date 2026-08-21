import Testing
import Foundation
@testable import AgentUsageCore

/// Fixed-clock tests for availability derivation (AC1, AC2, AC3) and edge cases.
@Suite struct AvailabilityEngineTests {

    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func slot(
        _ id: AccountSlotID,
        windows: [UsageWindowKind],
        connected: Bool = true
    ) -> AccountSlot {
        AccountSlot(
            slotID: id,
            label: "Test Slot",
            provider: .claude,
            requiredWindows: windows,
            isConnected: connected)
    }

    private func window(
        _ kind: UsageWindowKind,
        used: Double,
        limit: Double,
        resetIn: TimeInterval
    ) -> UsageWindow {
        UsageWindow(
            id: kind,
            name: kind.displayName,
            isRequired: true,
            used: used,
            limit: limit,
            resetAt: now.addingTimeInterval(resetIn))
    }

    // MARK: AC1 — multiple blockers

    @Test func ac1_multipleBlockers_availableAtIsLaterReset() {
        let fiveHour = window(.fiveHour, used: 100, limit: 100, resetIn: 3600)
        let weekly = window(.weekly, used: 100, limit: 100, resetIn: 3 * 24 * 3600)
        let monthly = window(.monthly, used: 39, limit: 100, resetIn: 12 * 24 * 3600)
        let snapshot = UsageSnapshot(
            slotID: .openCodeGO, provider: .opencode,
            windows: [fiveHour, weekly, monthly], capturedAt: now)

        let presentation = AvailabilityEngine.derive(
            slot: slot(.openCodeGO, windows: [.fiveHour, .weekly, .monthly]),
            snapshot: snapshot, now: now)

        #expect(presentation.status == .blocked)
        #expect(presentation.blockers.map(\.id) == [.fiveHour, .weekly])
        #expect(presentation.availableAt == weekly.resetAt)
    }

    // MARK: AC2 — display mode

    @Test func ac2_displayModeChangesRepresentationOnly() {
        let snapshot = FixtureProvider.partialUsage(
            slotID: .gptPersonal, provider: .gpt, now: now)
        let slot = self.slot(.gptPersonal, windows: [.fiveHour])

        let presentation = AvailabilityEngine.derive(slot: slot, snapshot: snapshot, now: now)

        guard let limiting = presentation.limitingWindow else {
            Issue.record("limiting window missing")
            return
        }
        #expect(limiting.usedFraction == 0.42)
        #expect(limiting.remainingFraction == 0.58)
        #expect(abs(limiting.fraction(for: .used) - 0.42) < 0.0001)
        #expect(abs(limiting.fraction(for: .remaining) - 0.58) < 0.0001)
        // State is unchanged by display mode.
        #expect(presentation.status == .available)
        #expect(presentation.blockers.isEmpty)
    }

    // MARK: AC3 — state matrix

    @Test func ac3_noSnapshotNotConnected() {
        let presentation = AvailabilityEngine.derive(
            slot: slot(.claudeLegacyA, windows: [.fiveHour], connected: false),
            snapshot: nil, now: now)
        #expect(presentation.status == .notConnected)
    }

    @Test func ac3_connectedWithoutSnapshotLoads() {
        let presentation = AvailabilityEngine.derive(
            slot: slot(.claudeLegacyA, windows: [.fiveHour]),
            snapshot: nil, now: now)
        #expect(presentation.status == .loading)
    }

    @Test func ac3_completeSnapshotAvailable() {
        let snapshot = UsageSnapshot(
            slotID: .claudeLegacyA, provider: .claude,
            windows: [window(.fiveHour, used: 10, limit: 100, resetIn: 600)],
            capturedAt: now)
        let presentation = AvailabilityEngine.derive(
            slot: slot(.claudeLegacyA, windows: [.fiveHour]),
            snapshot: snapshot, now: now)
        #expect(presentation.status == .available)
        #expect(presentation.limitingWindow?.usedFraction == 0.10)
    }

    @Test func ac3_incompleteSnapshotUnavailableWithPartialContext() {
        // Weekly required but only 5-hour present.
        let snapshot = UsageSnapshot(
            slotID: .claudeLegacyA, provider: .claude,
            windows: [window(.fiveHour, used: 30, limit: 100, resetIn: 600)],
            capturedAt: now)
        let presentation = AvailabilityEngine.derive(
            slot: slot(.claudeLegacyA, windows: [.fiveHour, .weekly]),
            snapshot: snapshot, now: now)
        #expect(presentation.status == .unavailable)
        // Complete window remains visible as partial context, never fabricated to zero.
        #expect(presentation.historicalWindows.count == 1)
        #expect(presentation.historicalWindows.first?.clampedUsedFraction == 0.30)
        #expect(!presentation.diagnosticNotes.isEmpty)
    }

    @Test func ac3_expiredHistoryUnavailable() {
        let captured = now.addingTimeInterval(-16 * 60)
        let snapshot = UsageSnapshot(
            slotID: .zaiCodingPlan, provider: .zai,
            windows: [UsageWindow(id: .fiveHour, name: "5 hour", isRequired: true,
                                  used: 10, limit: 100, resetAt: captured.addingTimeInterval(3600))],
            capturedAt: captured)
        let presentation = AvailabilityEngine.derive(
            slot: slot(.zaiCodingPlan, windows: [.fiveHour]),
            snapshot: snapshot, now: now)
        #expect(presentation.status == .unavailable)
        #expect(presentation.snapshotAge >= AvailabilityEngine.snapshotFreshnessHorizon)
        #expect(presentation.historicalWindows.count == 1)
    }

    @Test func ac3_postResetPendingVerification() {
        // Cached reset already passed: UNAVAILABLE pending verification (ADR-0005).
        let captured = now.addingTimeInterval(-5 * 60)
        let snapshot = UsageSnapshot(
            slotID: .commandCodeGOAT, provider: .commandCode,
            windows: [window(.fiveHour, used: 100, limit: 100, resetIn: -60)],
            capturedAt: captured)
        let presentation = AvailabilityEngine.derive(
            slot: slot(.commandCodeGOAT, windows: [.fiveHour]),
            snapshot: snapshot, now: now)
        #expect(presentation.status == .unavailable)
        #expect(presentation.historicalWindows.count == 1)
        #expect(presentation.blockers.isEmpty)
        #expect(presentation.availableAt == nil)
    }

    @Test func ac3_errorStateCarriesFreshHistoricalSnapshot() {
        // The ERROR status itself is set by the refresh layer; the engine's contract
        // is that a fresh snapshot remains presentable as historical context.
        let captured = now.addingTimeInterval(-2 * 60)
        let snapshot = UsageSnapshot(
            slotID: .openCodeGO, provider: .opencode,
            windows: [window(.fiveHour, used: 55, limit: 100, resetIn: 1200)],
            capturedAt: captured)
        let presentation = AvailabilityEngine.derive(
            slot: slot(.openCodeGO, windows: [.fiveHour]),
            snapshot: snapshot, now: now)
        // Fresh valid data still derives normally; historical context is available
        // for the UI to pair with an error banner from the refresh layer.
        #expect(presentation.status == .available)
        #expect(presentation.snapshotAge == 120)
    }

    // MARK: Limiting window

    @Test func limitingWindowIsMaxUsedFraction() {
        let snapshot = UsageSnapshot(
            slotID: .openCodeGO, provider: .opencode,
            windows: [
                window(.fiveHour, used: 20, limit: 100, resetIn: 600),
                window(.weekly, used: 70, limit: 100, resetIn: 86_400),
                window(.monthly, used: 50, limit: 200, resetIn: 1_000_000)
            ],
            capturedAt: now)
        let presentation = AvailabilityEngine.derive(
            slot: slot(.openCodeGO, windows: [.fiveHour, .weekly, .monthly]),
            snapshot: snapshot, now: now)
        #expect(presentation.limitingWindow?.kind == .weekly)
        #expect(presentation.limitingWindow?.usedFraction == 0.70)
    }

    // MARK: Edge cases

    @Test func nonFiniteAndNegativeLimitsAreInvalid() {
        let cases: [(used: Double, limit: Double)] = [
            (.nan, 100), (.infinity, 100), (-1, 100),
            (10, .nan), (10, 0), (10, -5)
        ]
        for values in cases {
            let bad = window(.fiveHour, used: values.used, limit: values.limit, resetIn: 600)
            let snapshot = UsageSnapshot(
                slotID: .zaiCodingPlan, provider: .zai,
                windows: [bad], capturedAt: now)
            let presentation = AvailabilityEngine.derive(
                slot: slot(.zaiCodingPlan, windows: [.fiveHour]),
                snapshot: snapshot, now: now)
            #expect(presentation.status == .unavailable,
                    "used=\(values.used) limit=\(values.limit)")
        }
    }

    @Test func negativeUsedIsInvalidNotFreeCapacity() {
        let bad = window(.fiveHour, used: -5, limit: 100, resetIn: 600)
        #expect(bad.isIndividuallyValid == false)
    }

    @Test func usedAboveLimitClampsButRemainsBlocking() {
        let over = window(.fiveHour, used: 130, limit: 100, resetIn: 900)
        #expect(over.isBlocking)
        #expect(over.clampedUsedFraction == 1.0)
        let snapshot = UsageSnapshot(
            slotID: .gptPersonal, provider: .gpt,
            windows: [over], capturedAt: now)
        let presentation = AvailabilityEngine.derive(
            slot: slot(.gptPersonal, windows: [.fiveHour]),
            snapshot: snapshot, now: now)
        #expect(presentation.status == .blocked)
        #expect(presentation.limitingWindow?.usedFraction == 1.0)
        #expect(presentation.limitingWindow?.remainingFraction == 0.0)
    }

    @Test func pastResetIsInvalidPendingVerification() {
        let expired = window(.fiveHour, used: 0, limit: 100, resetIn: -120)
        let snapshot = UsageSnapshot(
            slotID: .gptPersonal, provider: .gpt,
            windows: [expired], capturedAt: now.addingTimeInterval(-30))
        let presentation = AvailabilityEngine.derive(
            slot: slot(.gptPersonal, windows: [.fiveHour]),
            snapshot: snapshot, now: now)
        // A fully-used expired window would be blocking anyway; assert it never
        // presents as AVAILABLE without post-reset verification.
        #expect(presentation.status != .available)
    }

    @Test func futureSnapshotTimestampTreatedAsAgeZero() {
        let captured = now.addingTimeInterval(+10 * 60) // 10 minutes in the future
        let snapshot = UsageSnapshot(
            slotID: .claudethe team, provider: .claude,
            windows: [window(.fiveHour, used: 25, limit: 100,
                             resetIn: 3600 + 600)],
            capturedAt: captured)
        let presentation = AvailabilityEngine.derive(
            slot: slot(.claudethe team, windows: [.fiveHour]),
            snapshot: snapshot, now: now)
        #expect(presentation.snapshotAge == 0)
        #expect(presentation.status == .available)
        #expect(presentation.diagnosticNotes.contains {
            $0.lowercased().contains("future")
        })
    }

    @Test func deriveAllPreservesCatalogOrder() {
        let slots = AccountCatalog.slots
        let presentations = AvailabilityEngine.deriveAll(
            slots: slots, snapshots: [:], now: now)
        #expect(presentations.map(\.slotID) == slots.map(\.slotID))
        #expect(presentations.allSatisfy { $0.status == .notConnected })
    }
}
