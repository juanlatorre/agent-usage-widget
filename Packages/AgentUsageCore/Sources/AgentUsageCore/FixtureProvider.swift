import Foundation

/// Injectable fixture snapshots for the six predefined slots.
///
/// Fixture providers are test/demo infrastructure, not a user-selectable production
/// provider. They let every UI state be exercised before live credentials exist.
public enum FixtureProvider {

    /// Build a complete valid snapshot with one window.
    public static func snapshot(
        slotID: AccountSlotID,
        provider: ProviderFamily,
        windows: [UsageWindow],
        capturedAt: Date
    ) -> UsageSnapshot {
        UsageSnapshot(
            slotID: slotID,
            provider: provider,
            windows: windows,
            capturedAt: capturedAt,
            provenance: SourceDiagnostics(
                sourceKind: "fixture",
                sourceReliability: "test-fixture",
                notes: []))
    }

    /// A generic window for provider-agnostic UI verification (AC5).
    public static func window(
        _ kind: UsageWindowKind,
        used: Double,
        limit: Double,
        resetAt: Date
    ) -> UsageWindow {
        UsageWindow(
            id: kind,
            name: kind.displayName,
            isRequired: true,
            used: used,
            limit: limit,
            resetAt: resetAt)
    }

    // MARK: - Canonical scenario fixtures

    /// AC1: two exhausted windows plus one partially used window.
    public static func multipleBlockers(slotID: AccountSlotID, provider: ProviderFamily, now: Date) -> UsageSnapshot {
        snapshot(
            slotID: slotID,
            provider: provider,
            windows: [
                window(.fiveHour, used: 100, limit: 100, resetAt: now.addingTimeInterval(3600)),
                window(.weekly, used: 100, limit: 100, resetAt: now.addingTimeInterval(3 * 24 * 3600)),
                window(.monthly, used: 39, limit: 100, resetAt: now.addingTimeInterval(12 * 24 * 3600))
            ],
            capturedAt: now)
    }

    /// AC2-style limiting window at 42% used / 58% remaining.
    public static func partialUsage(slotID: AccountSlotID, provider: ProviderFamily, now: Date) -> UsageSnapshot {
        snapshot(
            slotID: slotID,
            provider: provider,
            windows: [
                window(.fiveHour, used: 42, limit: 100, resetAt: now.addingTimeInterval(1800))
            ],
            capturedAt: now)
    }
}
