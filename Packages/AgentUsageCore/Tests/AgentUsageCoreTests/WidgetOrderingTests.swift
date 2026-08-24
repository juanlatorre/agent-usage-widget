import Testing
import Foundation
@testable import AgentUsageCore

@Suite struct WidgetOrderingTests {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func presentation(slotID: AccountSlotID, status: AccountStatus) -> AccountPresentation {
        AccountPresentation(slotID: slotID, label: slotID.rawValue, status: status,
                           blockers: [], limitingWindow: nil, availableAt: nil,
                           snapshotAge: 0, historicalWindows: [], diagnosticNotes: [])
    }

    @Test func largeSortsBlockedBeforeAvailableDeterministically() {
        let input: [AccountPresentation] = [
            presentation(slotID: .zaiCodingPlan, status: .available),
            presentation(slotID: .claudeLegacyA, status: .blocked),
            presentation(slotID: .openCodeGO, status: .error),
            presentation(slotID: .gptPersonal, status: .available),
        ]
        let sorted = WidgetOrdering.sorted(input)
        #expect(sorted.map(\.slotID) == [.claudeLegacyA, .openCodeGO, .gptPersonal, .zaiCodingPlan])
        // Available preserves catalog order.
        #expect(sorted.filter { $0.status == .available }.map(\.slotID) == [.gptPersonal, .zaiCodingPlan])
    }

    @Test func usedRemainingComplementsWithoutChangingAvailability() {
        // gptPersonal requires only .weekly, so use that kind.
        let window = UsageWindow(id: .weekly, name: "Weekly", isRequired: true, used: 42, limit: 100, resetAt: now.addingTimeInterval(3600))
        let snap = UsageSnapshot(slotID: .gptPersonal, provider: .gpt, windows: [window], capturedAt: now)
        let slot = AccountCatalog.slot(for: .gptPersonal)!
        let p = AvailabilityEngine.derive(slot: slot, snapshot: snap, now: now)
        #expect(p.status == .available)
        guard let limiting = p.limitingWindow else { Issue.record("missing limiting"); return }
        #expect(abs(limiting.fraction(for: .used) + limiting.fraction(for: .remaining) - 1) < 0.0001)
        #expect(abs(window.clampedUsedFraction - 0.42) < 0.0001)
    }

    @Test func configurationValidation() {
        let small = AgentWidgetConfiguration(identifier: "a", selectedSlotIDs: [.claudeLegacyA])
        #expect(small.isValidSmall)
        #expect(small.sanitized(for: .small) != nil)
        #expect(AgentWidgetConfiguration(identifier: "b", selectedSlotIDs: []).sanitized(for: .small) == nil)
        #expect(AgentWidgetConfiguration(identifier: "c", selectedSlotIDs: [.claudeLegacyA, .gptPersonal]).sanitized(for: .small) == nil)

        let medium = AgentWidgetConfiguration(identifier: "m", selectedSlotIDs: [.claudeLegacyA, .gptPersonal, .openCodeGO])
        #expect(medium.isValidMedium)
        #expect(AgentWidgetConfiguration(identifier: "n", selectedSlotIDs: []).sanitized(for: .medium) == nil)
        #expect(AgentWidgetConfiguration(identifier: "o", selectedSlotIDs: [.claudeLegacyA, .claudeLegacyA]).sanitized(for: .medium) == nil)
    }
}
