import Testing
import Foundation
@testable import AgentUsageCore

@Suite struct RefreshSchedulerTests {

    private final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
        func get() -> Date { now }
    }

    private func snapshot(slotID: AccountSlotID = .claudeLegacyA, resetIn: TimeInterval, now: Date) -> UsageSnapshot {
        let w = UsageWindow(id: .fiveHour, name: "5 hour", isRequired: true, used: 50, limit: 100, resetAt: now.addingTimeInterval(resetIn))
        return UsageSnapshot(slotID: slotID, provider: .claude, windows: [w], capturedAt: now)
    }

    private func makeScheduler(clock: Clock, interval: DisplayPreferences.RefreshInterval = .oneMinute,
                               connected: Set<AccountSlotID> = [.claudeLegacyA, .openCodeGO],
                               snapshots: [AccountSlotID: UsageSnapshot] = [:]) -> RefreshScheduler {
        let prefs = DisplayPreferences(refreshInterval: interval)
        return RefreshScheduler(
            now: { clock.get() },
            random: { 0.5 },
            preferences: { prefs },
            connectedSlots: { connected },
            snapshots: { snapshots },
            isAuthBlocked: { _ in false })
    }

    @Test func ac2_onlyOneFetchInFlightAtMostOneFollowUp() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let scheduler = makeScheduler(clock: clock)
        #expect(scheduler.beginFetch(slotID: .claudeLegacyA, trigger: .interval) == true)
        #expect(scheduler.beginFetch(slotID: .claudeLegacyA, trigger: .manualGlobal) == false)
        #expect(scheduler.beginFetch(slotID: .claudeLegacyA, trigger: .widget) == false)
        #expect(scheduler.hasPendingFollowUp(slotID: .claudeLegacyA) == true)
        let snap = snapshot(resetIn: 3600, now: clock.get())
        scheduler.finishSuccess(slotID: .claudeLegacyA, snapshot: snap)
        #expect(scheduler.hasPendingFollowUp(slotID: .claudeLegacyA) == false)
    }

    @Test func r3_independentSlotsMayRefreshConcurrently() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let scheduler = makeScheduler(clock: clock, connected: [.claudeLegacyA, .openCodeGO])
        scheduler.maxConcurrentFetches = 2
        #expect(scheduler.beginFetch(slotID: .claudeLegacyA, trigger: .manualGlobal) == true)
        #expect(scheduler.beginFetch(slotID: .openCodeGO, trigger: .manualGlobal) == true)
    }

    @Test func r5_transientFailureRecordsNextRetryAndHonorsRetryAfter() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let scheduler = RefreshScheduler(
            now: { clock.get() }, random: { 0.5 },
            preferences: { DisplayPreferences(refreshInterval: .oneMinute) },
            connectedSlots: { [.claudeLegacyA] },
            snapshots: { [:] },
            isAuthBlocked: { _ in false })
        scheduler.finishTransientFailure(slotID: .claudeLegacyA, category: .rateLimited, retryAfter: 17)
        let st = scheduler.state(for: .claudeLegacyA)
        #expect(st.failure?.retryAfter == 17)
        #expect(st.failure?.nextRetryAt == clock.get().addingTimeInterval(17))
        #expect(scheduler.shouldFetch(slotID: .claudeLegacyA, trigger: .interval) == false)
        #expect(scheduler.shouldFetch(slotID: .claudeLegacyA, trigger: .manualGlobal) == true)
        clock.now = clock.now.addingTimeInterval(18)
        #expect(scheduler.shouldFetch(slotID: .claudeLegacyA, trigger: .interval) == true)
    }

    @Test func r6_authRequiredStopsAutomaticRetries() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let scheduler = makeScheduler(clock: clock)
        scheduler.finishAuthRequired(slotID: .claudeLegacyA)
        #expect(scheduler.state(for: .claudeLegacyA).authBlockedUntilReconnect == true)
        #expect(scheduler.shouldFetch(slotID: .claudeLegacyA, trigger: .interval) == false)
        #expect(scheduler.shouldFetch(slotID: .claudeLegacyA, trigger: .manualGlobal) == false)
        #expect(scheduler.beginFetch(slotID: .claudeLegacyA, trigger: .manualGlobal) == false)
    }

    @Test func r7_exponentialBackoffDeterministic() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let scheduler = RefreshScheduler(
            now: { clock.get() }, random: { 1.0 },
            preferences: { DisplayPreferences(refreshInterval: .oneMinute) },
            connectedSlots: { [.claudeLegacyA] },
            snapshots: { [:] },
            isAuthBlocked: { _ in false })
        scheduler.backoffBase = 15; scheduler.backoffCap = 300
        // First failure: exp 15 + jitter +3 = 18, but later of backoff vs interval (60) wins.
        scheduler.finishTransientFailure(slotID: .claudeLegacyA, category: .transport, retryAfter: nil)
        let first = scheduler.state(for: .claudeLegacyA).failure!.nextRetryAt!
        #expect(first == clock.get().addingTimeInterval(60))
    }

    @Test func r7_429RetryAfterBeatsBackoff() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let scheduler = makeScheduler(clock: clock)
        scheduler.finishTransientFailure(slotID: .claudeLegacyA, category: .rateLimited, retryAfter: 120)
        let st = scheduler.state(for: .claudeLegacyA)
        #expect(st.failure?.nextRetryAt == clock.get().addingTimeInterval(120))
    }

    @Test func r8_expiredResetMarksBoundaryNeedsTrigger() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = Clock(now)
        let snap = snapshot(slotID: .claudeLegacyA, resetIn: -10, now: now.addingTimeInterval(-100))
        let scheduler = makeScheduler(clock: clock, connected: [.claudeLegacyA], snapshots: [.claudeLegacyA: snap])
        let affected = scheduler.resetBoundarySlots(now: now)
        #expect(affected == [.claudeLegacyA])
    }

    @Test func r8_noBoundaryWhenResetStillFuture() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = Clock(now)
        let snap = snapshot(resetIn: 3600, now: now)
        let scheduler = makeScheduler(clock: clock, snapshots: [.claudeLegacyA: snap])
        #expect(scheduler.resetBoundarySlots(now: now).isEmpty)
    }

    @Test func r12_clockJumpRecomputesDueInsteadOfReplaying() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let scheduler = RefreshScheduler(
            now: { clock.get() }, random: { 0.5 },
            preferences: { DisplayPreferences(refreshInterval: .oneMinute) },
            connectedSlots: { [.claudeLegacyA] },
            snapshots: { [:] },
            isAuthBlocked: { _ in false })
        let snap = snapshot(resetIn: 3600, now: clock.get())
        scheduler.finishSuccess(slotID: .claudeLegacyA, snapshot: snap)
        let previousNow = clock.get()
        clock.now = clock.now.addingTimeInterval(600)
        scheduler.reconcileClockJump(previousNow: previousNow, currentNow: clock.get())
        #expect(scheduler.shouldFetch(slotID: .claudeLegacyA, trigger: .interval) == true)
    }

    @Test func disconnectedSlotsIgnored() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let scheduler = makeScheduler(clock: clock, connected: [])
        #expect(scheduler.shouldFetch(slotID: .claudeLegacyA, trigger: .manualGlobal) == false)
        #expect(scheduler.dueSlots(trigger: .manualGlobal).isEmpty)
    }

    @Test func intervalGatingBlocksAutomaticBeforeDueButAllowsManual() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let scheduler = RefreshScheduler(
            now: { clock.get() }, random: { 0.5 },
            preferences: { DisplayPreferences(refreshInterval: .fiveMinutes) },
            connectedSlots: { [.claudeLegacyA] },
            snapshots: { [:] },
            isAuthBlocked: { _ in false })
        let snap = snapshot(resetIn: 3600, now: clock.get())
        scheduler.finishSuccess(slotID: .claudeLegacyA, snapshot: snap)
        #expect(scheduler.shouldFetch(slotID: .claudeLegacyA, trigger: .interval) == false)
        #expect(scheduler.shouldFetch(slotID: .claudeLegacyA, trigger: .manualPerAccount) == true)
        clock.now = clock.now.addingTimeInterval(300)
        #expect(scheduler.shouldFetch(slotID: .claudeLegacyA, trigger: .interval) == true)
    }
}
