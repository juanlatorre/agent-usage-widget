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
        let snapshot = sampleSnapshot(.claude)
        try store.save(snapshot)
        guard case let .loaded(loaded) = store.load(slotID: .claude) else {
            Issue.record("expected loaded snapshot")
            return
        }
        #expect(loaded == snapshot)
    }

    @Test func absentSlotLoadsAsAbsent() throws {
        let (store, _) = try makeStore()
        #expect(store.load(slotID: .chatGPT) == .absent)
    }

    @Test func interruptedWritePreservesPreviousRecord() throws {
        // Atomic replacement contract: simulate by writing valid data, then verify
        // that a failed write (unencodable snapshot) leaves the file untouched.
        let (store, _) = try makeStore()
        let original = sampleSnapshot(.claude)
        try store.save(original)

        // A NaN used value is invalid domain data; JSONEncoder cannot encode it,
        // which surfaces as a thrown error before any file mutation happens.
        let corrupted = UsageSnapshot(
            slotID: .claude,
            provider: .claude,
            windows: [
                UsageWindow(
                    id: .fiveHour, name: "5 hour", isRequired: true,
                    used: .nan, limit: 100,
                    resetAt: Date().addingTimeInterval(600))
            ],
            capturedAt: Date())
        #expect(throws: (any Error).self) { try store.save(corrupted) }

        guard case let .loaded(loaded) = store.load(slotID: .claude) else {
            Issue.record("previous valid record was destroyed")
            return
        }
        #expect(loaded == original)
    }

    @Test func corruptRecordIsQuarantinedNotDeleted() throws {
        let (store, dir) = try makeStore()
        try store.save(sampleSnapshot(.claude))
        let recordURL = dir.appendingPathComponent("claude.json")

        // Overwrite with garbage, as a partial/interrupted external write would.
        try Data("{{{ not json".utf8).write(to: recordURL)

        guard case .quarantined = store.load(slotID: .claude) else {
            Issue.record("expected quarantine outcome")
            return
        }
        // The record was moved aside, not destroyed.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers.contains { $0.hasPrefix("quarantine-claude") })
        #expect(!FileManager.default.fileExists(atPath: recordURL.path))
    }

    @Test func unknownSchemaVersionIsIgnoredAndQuarantined() throws {
        let (store, dir) = try makeStore()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let recordURL = dir.appendingPathComponent("claude.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let wrapper = SnapshotStore.SnapshotFile(version: 999, snapshot: sampleSnapshot(.claude))
        try encoder.encode(wrapper).write(to: recordURL)

        guard case let .quarantined(reason) = store.load(slotID: .claude) else {
            Issue.record("expected quarantine outcome")
            return
        }
        #expect(reason == "schema version mismatch")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers.contains { $0.hasPrefix("quarantine-claude") })
    }

    @Test func corruptSlotDoesNotAffectOtherSlots() throws {
        let (store, dir) = try makeStore()
        try store.save(sampleSnapshot(.claude))
        try store.save(sampleSnapshot(.chatGPT))

        // Corrupt only the legacy profile's record.
        try Data("garbage".utf8).write(
            to: dir.appendingPathComponent("claude.json"))

        guard case .quarantined = store.load(slotID: .claude) else {
            Issue.record("expected quarantine for legacy")
            return
        }
        guard case let .loaded(gpt) = store.load(slotID: .chatGPT) else {
            Issue.record("unaffected slot must still load")
            return
        }
        #expect(gpt.slotID == .chatGPT)
    }

    @Test func removeAffectsOnlyTargetSlot() throws {
        let (store, dir) = try makeStore()
        try store.save(sampleSnapshot(.claude))
        try store.save(sampleSnapshot(.chatGPT))
        store.remove(slotID: .claude)
        #expect(store.load(slotID: .claude) == .absent)
        #expect(store.load(slotID: .chatGPT) != .absent)
        _ = dir
    }
}
