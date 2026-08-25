import Testing
import Foundation
@testable import AgentUsageCore

@Suite struct RefreshServiceTests {

    private final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private func snapshot(slotID: AccountSlotID = .claude, now: Date) -> UsageSnapshot {
        let w = UsageWindow(id: .fiveHour, name: "5 hour", isRequired: true, used: 20, limit: 100, resetAt: now.addingTimeInterval(3600))
        return UsageSnapshot(slotID: slotID, provider: .claude, windows: [w], capturedAt: now)
    }

    @Test func triggerPersistsSnapshotAndClearsFailure() async {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rs-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let snapshotStore = SnapshotStore(baseURL: base.appendingPathComponent("snapshots", isDirectory: true))
        let failureStore = RefreshFailureStore(fileURL: base.appendingPathComponent("failures.json"))
        let scheduler = RefreshScheduler(
            now: { clock.now }, random: { 0.5 },
            preferences: { DisplayPreferences(refreshInterval: .oneMinute) },
            connectedSlots: { [.claude] },
            snapshots: { [:] },
            isAuthBlocked: { _ in false })
        let snap = snapshot(now: clock.now)
        let service = RefreshService(
            scheduler: scheduler,
            snapshotStore: snapshotStore,
            failureStore: failureStore,
            fetcher: { _ in .success(snap) },
            now: { clock.now })

        await service.trigger(slotID: .claude, trigger: .manualPerAccount)

        if case .loaded(let stored) = snapshotStore.load(slotID: .claude) {
            #expect(stored.windows.first?.used == 20)
        } else { Issue.record("snapshot not persisted") }
        #expect(scheduler.state(for: .claude).failure == nil)
    }

    @Test func transientFailureDoesNotOverwriteSnapshotPreservesHistory() async {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rs-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let snapshotStore = SnapshotStore(baseURL: base.appendingPathComponent("snapshots", isDirectory: true))
        // Seed a valid snapshot.
        let initial = snapshot(now: clock.now)
        try? snapshotStore.save(initial)
        let scheduler = RefreshScheduler(
            now: { clock.now }, random: { 0.5 },
            preferences: { DisplayPreferences(refreshInterval: .oneMinute) },
            connectedSlots: { [.claude] },
            snapshots: { [.claude: initial] },
            isAuthBlocked: { _ in false })
        // Pre-seed scheduler state as if prior success happened.
        scheduler.finishSuccess(slotID: .claude, snapshot: initial)
        clock.now = clock.now.addingTimeInterval(61) // past interval
        let service = RefreshService(
            scheduler: scheduler,
            snapshotStore: snapshotStore,
            fetcher: { _ in .failure(.transport("offline")) },
            now: { clock.now })

        await service.trigger(slotID: .claude, trigger: .manualGlobal)

        // Snapshot unchanged.
        if case .loaded(let stored) = snapshotStore.load(slotID: .claude) {
            #expect(stored.capturedAt == initial.capturedAt)
        } else { Issue.record("expected historical snapshot preserved") }
        #expect(scheduler.state(for: .claude).failure != nil)
    }

    @Test func boundedConcurrencyDoesNotBlockOtherSlots() async {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rs-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let snapshotStore = SnapshotStore(baseURL: base.appendingPathComponent("sn", isDirectory: true))
        let scheduler = RefreshScheduler(
            now: { clock.now }, random: { 0.5 },
            preferences: { DisplayPreferences(refreshInterval: .oneMinute) },
            connectedSlots: { [.claude, .openCodeGO] },
            snapshots: { [:] },
            isAuthBlocked: { _ in false })
        scheduler.maxConcurrentFetches = 1
        var calls: [AccountSlotID] = []
        let service = RefreshService(
            scheduler: scheduler,
            snapshotStore: snapshotStore,
            fetcher: { slotID in
                // One slot hangs briefly; the other should still complete promptly.
                if slotID == .claude { try? await Task.sleep(nanoseconds: 80_000_000) }
                calls.append(slotID)
                return .success(UsageSnapshot(slotID: slotID, provider: .claude,
                    windows: [UsageWindow(id: .fiveHour, name: "5h", isRequired: true, used: 10, limit: 100, resetAt: clock.now.addingTimeInterval(3600))],
                    capturedAt: clock.now))
            },
            now: { clock.now })

        await service.triggerGlobal(trigger: .manualGlobal)
        #expect(calls.contains(.claude))
        #expect(calls.contains(.openCodeGO))
    }

    @Test func handleResetBoundariesTriggersExpiredWindows() async {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rs-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let snapshotStore = SnapshotStore(baseURL: base.appendingPathComponent("sn", isDirectory: true))
        let expiredSnap = snapshot(slotID: .claude, now: clock.now.addingTimeInterval(-3600))
        let scheduler = RefreshScheduler(
            now: { clock.now }, random: { 0.5 },
            preferences: { DisplayPreferences(refreshInterval: .oneMinute) },
            connectedSlots: { [.claude] },
            snapshots: { [.claude: expiredSnap] },
            isAuthBlocked: { _ in false })
        var fetched: [AccountSlotID] = []
        let service = RefreshService(
            scheduler: scheduler,
            snapshotStore: snapshotStore,
            fetcher: { slotID in fetched.append(slotID); return .success(self.snapshot(now: clock.now)) },
            now: { clock.now })
        await service.handleResetBoundaries()
        #expect(fetched == [.claude])
    }
}
