import Testing
import Foundation
@testable import AgentUsageCore

/// Store tests: schema versioning, atomic replacement, corruption, and slot isolation (AC4).
@Suite struct SnapshotStoreTests {

    private func makeStore() throws -> (SnapshotStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentusage-tests-\(UUID().uuidString)")
        return (SnapshotStore(baseURL: dir), dir)
    }

    private func sampleSnapshot(
        _ slot: AccountSlotID,
        capturedAt: Date = Date(timeIntervalSince1970: 1_760_000_000)
    ) -> UsageSnapshot {
        UsageSnapshot(
            slotID: slot,
            provider: .claude,
            windows: [
                UsageWindow(
                    id: .fiveHour, name: "5 hour", isRequired: true,
                    used: 42, limit: 100,
                    resetAt: capturedAt.addingTimeInterval(1800))
            ],
            capturedAt: capturedAt)
    }

    @Test func saveAndLoadRoundTrip() throws {
        let (store, _) = try makeStore()
        let snapshot = sampleSnapshot(.claudeLegacyA)
        try store.save(snapshot)
        guard case let .loaded(loaded) = store.load(slotID: .claudeLegacyA) else {
            Issue.record("expected loaded snapshot")
            return
        }
        #expect(loaded == snapshot)
    }

    @Test func absentSlotLoadsAsAbsent() throws {
        let (store, _) = try makeStore()
        #expect(store.load(slotID: .gptPersonal) == .absent)
    }

    @Test func interruptedWritePreservesPreviousRecord() throws {
        // Atomic replacement contract: simulate by writing valid data, then verify
        // that a failed write (unencodable snapshot) leaves the file untouched.
        let (store, _) = try makeStore()
        let original = sampleSnapshot(.claudeLegacyA)
        try store.save(original)

        // A NaN used value is invalid domain data; JSONEncoder cannot encode it,
        // which surfaces as a thrown error before any file mutation happens.
        let corrupted = UsageSnapshot(
            slotID: .claudeLegacyA,
            provider: .claude,
            windows: [
                UsageWindow(
                    id: .fiveHour, name: "5 hour", isRequired: true,
                    used: .nan, limit: 100,
                    resetAt: Date().addingTimeInterval(600))
            ],
            capturedAt: Date())
        #expect(throws: (any Error).self) { try store.save(corrupted) }

        guard case let .loaded(loaded) = store.load(slotID: .claudeLegacyA) else {
            Issue.record("previous valid record was destroyed")
            return
        }
        #expect(loaded == original)
    }

    @Test func corruptRecordIsQuarantinedNotDeleted() throws {
        let (store, dir) = try makeStore()
        try store.save(sampleSnapshot(.claudeLegacyA))
        let recordURL = dir.appendingPathComponent("claude-legacy-1.json")

        // Overwrite with garbage, as a partial/interrupted external write would.
        try Data("{{{ not json".utf8).write(to: recordURL)

        guard case .quarantined = store.load(slotID: .claudeLegacyA) else {
            Issue.record("expected quarantine outcome")
            return
        }
        // The record was moved aside, not destroyed.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers.contains { $0.hasPrefix("quarantine-claude-legacy-1") })
        #expect(!FileManager.default.fileExists(atPath: recordURL.path))
    }

    @Test func unknownSchemaVersionIsIgnoredAndQuarantined() throws {
        let (store, dir) = try makeStore()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let recordURL = dir.appendingPathComponent("claude-legacy-1.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let wrapper = SnapshotStore.SnapshotFile(version: 999, snapshot: sampleSnapshot(.claudeLegacyA))
        try encoder.encode(wrapper).write(to: recordURL)

        guard case let .quarantined(reason) = store.load(slotID: .claudeLegacyA) else {
            Issue.record("expected quarantine outcome")
            return
        }
        #expect(reason == "schema version mismatch")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers.contains { $0.hasPrefix("quarantine-claude-legacy-1") })
    }

    @Test func corruptSlotDoesNotAffectOtherSlots() throws {
        let (store, dir) = try makeStore()
        try store.save(sampleSnapshot(.claudeLegacyA))
        try store.save(sampleSnapshot(.gptPersonal))

        // Corrupt only the legacy profile's record.
        try Data("garbage".utf8).write(
            to: dir.appendingPathComponent("claude-legacy-1.json"))

        guard case .quarantined = store.load(slotID: .claudeLegacyA) else {
            Issue.record("expected quarantine for legacy")
            return
        }
        guard case let .loaded(gpt) = store.load(slotID: .gptPersonal) else {
            Issue.record("unaffected slot must still load")
            return
        }
        #expect(gpt.slotID == .gptPersonal)
    }

    @Test func removeAffectsOnlyTargetSlot() throws {
        let (store, dir) = try makeStore()
        try store.save(sampleSnapshot(.claudeLegacyA))
        try store.save(sampleSnapshot(.claudethe team))
        store.remove(slotID: .claudeLegacyA)
        #expect(store.load(slotID: .claudeLegacyA) == .absent)
        #expect(store.load(slotID: .claudethe team) != .absent)
        _ = dir
    }
}
