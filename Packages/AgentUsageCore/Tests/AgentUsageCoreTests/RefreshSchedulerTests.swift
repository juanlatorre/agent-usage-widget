import Testing
import Foundation
@testable import AgentUsageCore

@Suite struct RefreshSchedulerTests {

    private final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
        func get() -> Date { now }
    }

    private func snapshot(slotID: AccountSlotID = .claude, resetIn: TimeInterval, now: Date) -> UsageSnapshot {
        let w = UsageWindow(id: .fiveHour, name: "5 hour", isRequired: true, used: 50, limit: 100, resetAt: now.addingTimeInterval(resetIn))
        return UsageSnapshot(slotID: slotID, provider: .claude, windows: [w], capturedAt: now)
    }

    private func makeScheduler(clock: Clock, interval: DisplayPreferences.RefreshInterval = .oneMinute,
                               connected: Set<AccountSlotID> = [.claude, .openCodeGO],
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
        #expect(scheduler.beginFetch(slotID: .claude, trigger: .interval) == true)
        #expect(scheduler.beginFetch(slotID: .claude, trigger: .manualGlobal) == false)
        #expect(scheduler.beginFetch(slotID: .claude, trigger: .widget) == false)
        #expect(scheduler.hasPendingFollowUp(slotID: .claude) == true)
        let snap = snapshot(resetIn: 3600, now: clock.get())
        scheduler.finishSuccess(slotID: .claude, snapshot: snap)
        #expect(scheduler.hasPendingFollowUp(slotID: .claude) == false)
    }

    @Test func r3_independentSlotsMayRefreshConcurrently() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let scheduler = makeScheduler(clock: clock, connected: [.claude, .openCodeGO])
        scheduler.maxConcurrentFetches = 2
        #expect(scheduler.beginFetch(slotID: .claude, trigger: .manualGlobal) == true)
        #expect(scheduler.beginFetch(slotID: .openCodeGO, trigger: .manualGlobal) == true)
    }

    @Test func r5_transientFailureRecordsNextRetryAndHonorsRetryAfter() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let scheduler = RefreshScheduler(
            now: { clock.get() }, random: { 0.5 },
            preferences: { DisplayPreferences(refreshInterval: .oneMinute) },
            connectedSlots: { [.claude] },
            snapshots: { [:] },
            isAuthBlocked: { _ in false })
        scheduler.finishTransientFailure(slotID: .claude, category: .rateLimited, retryAfter: 17)
        let st = scheduler.state(for: .claude)
        #expect(st.failure?.retryAfter == 17)
        #expect(st.failure?.nextRetryAt == clock.get().addingTimeInterval(17))
        #expect(scheduler.shouldFetch(slotID: .claude, trigger: .interval) == false)
        #expect(scheduler.shouldFetch(slotID: .claude, trigger: .widget) == false)
        // A server-directed rate limit is absolute: even manual triggers wait.
        #expect(scheduler.shouldFetch(slotID: .claude, trigger: .manualGlobal) == false)
        clock.now = clock.now.addingTimeInterval(18)
        #expect(scheduler.shouldFetch(slotID: .claude, trigger: .interval) == true)
    }

    @Test func r5_transportFailureStillAllowsManualOverride() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let scheduler = RefreshScheduler(
            now: { clock.get() }, random: { 0.5 },
            preferences: { DisplayPreferences(refreshInterval: .oneMinute) },
            connectedSlots: { [.claude] },
            snapshots: { [:] },
            isAuthBlocked: { _ in false })
        // Non-rate-limit backoff (e.g. transport) stays overridable manually.
        scheduler.finishTransientFailure(slotID: .claude, category: .transport, retryAfter: nil)
        #expect(scheduler.shouldFetch(slotID: .claude, trigger: .manualGlobal) == true)
        #expect(scheduler.shouldFetch(slotID: .claude, trigger: .interval) == false)
    }

    @Test func r6_authRequiredStopsAutomaticRetries() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let scheduler = makeScheduler(clock: clock)
        scheduler.finishAuthRequired(slotID: .claude)
        #expect(scheduler.state(for: .claude).authBlockedUntilReconnect == true)
        #expect(scheduler.shouldFetch(slotID: .claude, trigger: .interval) == false)
        #expect(scheduler.shouldFetch(slotID: .claude, trigger: .manualGlobal) == false)
        #expect(scheduler.beginFetch(slotID: .claude, trigger: .manualGlobal) == false)
    }

    @Test func r7_exponentialBackoffDeterministic() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let scheduler = RefreshScheduler(
            now: { clock.get() }, random: { 1.0 },
            preferences: { DisplayPreferences(refreshInterval: .oneMinute) },
            connectedSlots: { [.claude] },
            snapshots: { [:] },
            isAuthBlocked: { _ in false })
        scheduler.backoffBase = 15; scheduler.backoffCap = 300
        // First failure: exp 15 + jitter +3 = 18, but later of backoff vs interval (60) wins.
        scheduler.finishTransientFailure(slotID: .claude, category: .transport, retryAfter: nil)
        let first = scheduler.state(for: .claude).failure!.nextRetryAt!
        #expect(first == clock.get().addingTimeInterval(60))
    }

    @Test func r7_429RetryAfterBeatsBackoff() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let scheduler = makeScheduler(clock: clock)
        scheduler.finishTransientFailure(slotID: .claude, category: .rateLimited, retryAfter: 120)
        let st = scheduler.state(for: .claude)
        #expect(st.failure?.nextRetryAt == clock.get().addingTimeInterval(120))
    }

    @Test func r8_expiredResetMarksBoundaryNeedsTrigger() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = Clock(now)
        let snap = snapshot(slotID: .claude, resetIn: -10, now: now.addingTimeInterval(-100))
        let scheduler = makeScheduler(clock: clock, connected: [.claude], snapshots: [.claude: snap])
        let affected = scheduler.resetBoundarySlots(now: now)
        #expect(affected == [.claude])
    }

    @Test func r8_noBoundaryWhenResetStillFuture() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = Clock(now)
        let snap = snapshot(resetIn: 3600, now: now)
        let scheduler = makeScheduler(clock: clock, snapshots: [.claude: snap])
        #expect(scheduler.resetBoundarySlots(now: now).isEmpty)
    }

    @Test func r12_clockJumpRecomputesDueInsteadOfReplaying() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let scheduler = RefreshScheduler(
            now: { clock.get() }, random: { 0.5 },
            preferences: { DisplayPreferences(refreshInterval: .oneMinute) },
            connectedSlots: { [.claude] },
            snapshots: { [:] },
            isAuthBlocked: { _ in false })
        let snap = snapshot(resetIn: 3600, now: clock.get())
        scheduler.finishSuccess(slotID: .claude, snapshot: snap)
        let previousNow = clock.get()
        clock.now = clock.now.addingTimeInterval(600)
        scheduler.reconcileClockJump(previousNow: previousNow, currentNow: clock.get())
        #expect(scheduler.shouldFetch(slotID: .claude, trigger: .interval) == true)
    }

    @Test func disconnectedSlotsIgnored() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let scheduler = makeScheduler(clock: clock, connected: [])
        #expect(scheduler.shouldFetch(slotID: .claude, trigger: .manualGlobal) == false)
        #expect(scheduler.dueSlots(trigger: .manualGlobal).isEmpty)
    }

    @Test func intervalGatingBlocksAutomaticBeforeDueButAllowsManual() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let scheduler = RefreshScheduler(
            now: { clock.get() }, random: { 0.5 },
            preferences: { DisplayPreferences(refreshInterval: .fiveMinutes) },
            connectedSlots: { [.claude] },
            snapshots: { [:] },
            isAuthBlocked: { _ in false })
        let snap = snapshot(resetIn: 3600, now: clock.get())
        scheduler.finishSuccess(slotID: .claude, snapshot: snap)
        #expect(scheduler.shouldFetch(slotID: .claude, trigger: .interval) == false)
        #expect(scheduler.shouldFetch(slotID: .claude, trigger: .manualPerAccount) == true)
        clock.now = clock.now.addingTimeInterval(300)
        #expect(scheduler.shouldFetch(slotID: .claude, trigger: .interval) == true)
    }
}
