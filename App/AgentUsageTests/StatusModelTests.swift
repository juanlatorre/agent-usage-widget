import Testing
import Foundation
@testable import AgentUsage
import AgentUsageCore

/// App-model tests: display-mode semantics, fixture matrix, and persistence safety.
@MainActor
struct StatusModelTests {

    /// Test context bundling the model with its store locations.
    private struct Context {
        let model: StatusModel
        let snapshotsDir: URL
        let preferencesFile: URL
    }

    private func makeModel() throws -> Context {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentusage-app-\(UUID().uuidString)")
        let snapshots = root.appendingPathComponent("snapshots")
        let prefsURL = root.appendingPathComponent("preferences.json")
        let fixedNow = Date(timeIntervalSince1970: 1_760_000_000)
        let model = StatusModel(
            snapshotStore: SnapshotStore(baseURL: snapshots),
            preferencesStore: PreferencesStore(fileURL: prefsURL),
            now: { fixedNow })
        return Context(model: model, snapshotsDir: snapshots, preferencesFile: prefsURL)
    }

    @Test func allSixSlotsPresentInStableOrder() throws {
        let context = try makeModel()
        let model = context.model
        #expect(model.presentations.map(\.slotID) == AccountCatalog.slots.map(\.slotID))
        #expect(model.presentations.count == 6)
        #expect(model.presentations.allSatisfy { $0.status == .notConnected })
    }

    @Test func ac2_displayModeChangesPercentagesNotAvailability() throws {
        let context = try makeModel()
        let model = context.model
        model.applyFixture(.availablePartial, to: .gptPersonal)

        try model.setDisplayMode(.remaining)
        let remainingPresentation = model.presentations.first { $0.slotID == .gptPersonal }
        #expect(remainingPresentation?.status == .available)
        #expect(remainingPresentation?.limitingWindow?.fraction(for: .remaining) == 0.58)

        try model.setDisplayMode(.used)
        let usedPresentation = model.presentations.first { $0.slotID == .gptPersonal }
        #expect(usedPresentation?.status == .available)
        #expect(usedPresentation?.limitingWindow?.fraction(for: .used) == 0.42)
    }

    @Test func ac3_fixtureStateMatrix() throws {
        let context = try makeModel()
        let model = context.model

        model.applyFixture(.availablePartial, to: .claudeLegacyA)
        #expect(model.presentations.first { $0.slotID == .claudeLegacyA }?.status == .available)

        model.applyFixture(.multipleBlockers, to: .openCodeGO)
        let blocked = model.presentations.first { $0.slotID == .openCodeGO }
        #expect(blocked?.status == .blocked)
        #expect(blocked?.blockers.count == 2)
        // availableAt is the later reset of the two blockers.
        let fixedNow = Date(timeIntervalSince1970: 1_760_000_000)
        #expect(blocked?.availableAt == fixedNow.addingTimeInterval(3 * 24 * 3600))

        model.applyFixture(.incomplete, to: .commandCodeGOAT)
        #expect(model.presentations.first { $0.slotID == .commandCodeGOAT }?.status == .unavailable)

        model.applyFixture(.staleHistory, to: .zaiCodingPlan)
        #expect(model.presentations.first { $0.slotID == .zaiCodingPlan }?.status == .unavailable)

        model.applyFixture(.postResetPending, to: .claudethe team)
        #expect(model.presentations.first { $0.slotID == .claudethe team }?.status == .unavailable)

        model.applyFixture(.none, to: .gptPersonal)
        #expect(model.presentations.first { $0.slotID == .gptPersonal }?.status == .loading)
    }

    @Test func ac4_failedSnapshotWritePreservesPreviousRecord() throws {
        let context = try makeModel()
        let model = context.model
        let snapshotsDir = context.snapshotsDir
        let good = FixtureProvider.partialUsage(
            slotID: .gptPersonal, provider: .gpt,
            now: Date(timeIntervalSince1970: 1_760_000_000))
        model.storeSnapshot(good)
        #expect(FileManager.default.fileExists(
            atPath: snapshotsDir.appendingPathComponent("gpt-personal.json").path))

        // A NaN window is unencodable; the store must throw before touching the file.
        let bad = UsageSnapshot(
            slotID: .gptPersonal, provider: .gpt,
            windows: [UsageWindow(
                id: .weekly, name: "Weekly", isRequired: true,
                used: .nan, limit: 100,
                resetAt: Date(timeIntervalSince1970: 1_760_100_000))],
            capturedAt: Date(timeIntervalSince1970: 1_760_050_000))
        #expect(throws: (any Error).self) {
            try SnapshotStore(baseURL: snapshotsDir).save(bad)
        }

        // The original valid record survives and still loads.
        let outcome = SnapshotStore(baseURL: snapshotsDir).load(slotID: .gptPersonal)
        guard case let .loaded(snapshot) = outcome else {
            Issue.record("valid record was destroyed")
            return
        }
        #expect(snapshot == good)
    }

    @Test func clearSlotReturnsToDisconnectedEmptyState() throws {
        let context = try makeModel()
        let model = context.model
        model.applyFixture(.availablePartial, to: .zaiCodingPlan)
        #expect(model.presentations.first { $0.slotID == .zaiCodingPlan }?.status == .available)
        model.clearSlot(.zaiCodingPlan)
        #expect(model.presentations.first { $0.slotID == .zaiCodingPlan }?.status == .notConnected)
    }

    @Test func preferencesRoundTripThroughDisk() throws {
        let context = try makeModel()
        let modelA = context.model
        let prefsURL = context.preferencesFile
        try modelA.setDisplayMode(.used)
        try modelA.setRefreshInterval(.fiveMinutes)

        // A fresh model over the same files reads persisted values.
        let fixedNow = Date(timeIntervalSince1970: 1_760_000_000)
        let modelB = StatusModel(
            snapshotStore: nil,
            preferencesStore: PreferencesStore(fileURL: prefsURL),
            now: { fixedNow })
        #expect(modelB.preferences.displayMode == .used)
        #expect(modelB.preferences.refreshInterval == .fiveMinutes)
    }
}
