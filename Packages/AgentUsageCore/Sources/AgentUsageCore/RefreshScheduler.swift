import Foundation

/// In-memory per-slot scheduler state. Pure logic, no I/O, injectable clock/random.
/// Child 07 R1–R12: interval, coalescing, failure aging, adaptive limits, reset boundaries.
public final class RefreshScheduler: @unchecked Sendable {

    public struct SlotState: Sendable {
        public var lastSuccessAt: Date?
        public var nextDueAt: Date?
        public var failure: RefreshFailureRecord?
        public var authBlockedUntilReconnect: Bool
        public var inFlight: Bool
        public var pendingFollowUp: Bool
        public var consecutiveFailures: Int
        public var snapshot: UsageSnapshot?
    }

    private let lock = NSLock()
    private var states: [AccountSlotID: SlotState] = [:]
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double  // 0..<1 for jitter
    private var preferences: () -> DisplayPreferences
    private var connectedSlots: () -> Set<AccountSlotID>
    private var snapshots: () -> [AccountSlotID: UsageSnapshot]
    private var isAuthBlocked: (AccountSlotID) -> Bool

    // Bounded concurrency for global refresh (R3).
    public var maxConcurrentFetches: Int = 2

    // Capped exponential backoff base (seconds) before jitter.
    public var backoffBase: TimeInterval = 15
    public var backoffCap: TimeInterval = 300
    private let jitterFraction: Double = 0.2

    public init(now: @escaping @Sendable () -> Date = Date.init,
                random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
                preferences: @escaping () -> DisplayPreferences = { DisplayPreferences() },
                connectedSlots: @escaping () -> Set<AccountSlotID> = { [] },
                snapshots: @escaping () -> [AccountSlotID: UsageSnapshot] = { [:] },
                isAuthBlocked: @escaping (AccountSlotID) -> Bool = { _ in false }) {
        self.now = now
        self.random = random
        self.preferences = preferences
        self.connectedSlots = connectedSlots
        self.snapshots = snapshots
        self.isAuthBlocked = isAuthBlocked
    }

    // MARK: - Slot state access

    public func state(for slotID: AccountSlotID) -> SlotState {
        lock.lock(); defer { lock.unlock() }
        return states[slotID] ?? SlotState(authBlockedUntilReconnect: false, inFlight: false, pendingFollowUp: false, consecutiveFailures: 0)
    }

    public func setState(_ state: SlotState, for slotID: AccountSlotID) {
        lock.lock(); defer { lock.unlock() }
        states[slotID] = state
    }

    public func removeState(for slotID: AccountSlotID) {
        lock.lock(); defer { lock.unlock() }
        states.removeValue(forKey: slotID)
    }

    // MARK: - Query: should we fetch?

    /// Whether a fetch may start now for the slot given the trigger.
    /// Returns false when: disconnected, auth-blocked, in-flight, before retry deadline (unless safe manual override).
    public func shouldFetch(slotID: AccountSlotID, trigger: RefreshTrigger) -> Bool {
        if !connectedSlots().contains(slotID) { return false }
        let st = state(for: slotID)
        if st.authBlockedUntilReconnect { return false }
        if st.inFlight { return false }
        let current = now()
        // Retry deadline: R7 — later of Retry-After/backoff vs target interval. A stored nextRetryAt wins.
        // A server-directed rate-limit deadline is absolute: no trigger (not even
        // manual) may bypass it, because the provider will keep answering 429 and
        // each request can extend the window.
        if let failure = st.failure, let nextRetry = failure.nextRetryAt, current < nextRetry {
            if failure.category == .rateLimited || !trigger.isSafeManualOverride {
                return false
            }
        }
        // Interval gating: don't refetch before nextDueAt for automatic triggers.
        if trigger.isAutomatic, let due = st.nextDueAt, current < due, !trigger.isSafeManualOverride {
            return false
        }
        return true
    }

    // MARK: - Trigger entry points

    /// Register that a fetch is starting. Returns false if coalesced (already in-flight or before retry).
    @discardableResult
    public func beginFetch(slotID: AccountSlotID, trigger: RefreshTrigger) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !connectedSlots().contains(slotID) { return false }
        var st = states[slotID] ?? SlotState(authBlockedUntilReconnect: false, inFlight: false, pendingFollowUp: false, consecutiveFailures: 0)
        if st.inFlight {
            st.pendingFollowUp = true
            states[slotID] = st
            return false
        }
        if st.authBlockedUntilReconnect { return false }
        let current = now()
        if let failure = st.failure, let nextRetry = failure.nextRetryAt, current < nextRetry {
            if failure.category == .rateLimited || !trigger.isSafeManualOverride {
                return false
            }
        }
        if trigger.isAutomatic, let due = st.nextDueAt, current < due, !trigger.isSafeManualOverride {
            return false
        }
        st.inFlight = true
        states[slotID] = st
        return true
    }

    /// Mark fetch as finished successfully.
    public func finishSuccess(slotID: AccountSlotID, snapshot: UsageSnapshot) {
        lock.lock(); defer { lock.unlock() }
        var st = states[slotID] ?? SlotState(authBlockedUntilReconnect: false, inFlight: false, pendingFollowUp: false, consecutiveFailures: 0)
        st.inFlight = false
        st.lastSuccessAt = now()
        st.snapshot = snapshot
        st.failure = nil
        st.authBlockedUntilReconnect = false
        st.consecutiveFailures = 0
        let interval = TimeInterval(preferences().refreshInterval.rawValue)
        st.nextDueAt = now().addingTimeInterval(interval)
        // Follow-up coalescing (R2): if a trigger arrived during fetch, run one safe follow-up.
        if st.pendingFollowUp {
            st.pendingFollowUp = false
            // Next fetch will be allowed because we clear inFlight; recompute due as immediate for follow-up.
            st.nextDueAt = now()
        }
        states[slotID] = st
    }

    /// Mark fetch as authentication-required (R6). Stops automatic retries.
    public func finishAuthRequired(slotID: AccountSlotID) {
        lock.lock(); defer { lock.unlock() }
        var st = states[slotID] ?? SlotState(authBlockedUntilReconnect: false, inFlight: false, pendingFollowUp: false, consecutiveFailures: 0)
        st.inFlight = false
        st.authBlockedUntilReconnect = true
        st.failure = RefreshFailureRecord(category: .unknown, attemptAt: now(), nextRetryAt: nil, sanitizedMessage: "authentication required")
        // Never schedule automatic retry.
        st.nextDueAt = nil
        st.consecutiveFailures = 0
        states[slotID] = st
    }

    /// Record source identity mismatch (R6) — same as auth, requires reconnect.
    public func finishSourceIdentityChanged(slotID: AccountSlotID) {
        finishAuthRequired(slotID: slotID)
    }

    /// Record transient failure with adaptive retry (R7).
    public func finishTransientFailure(slotID: AccountSlotID, category: RefreshFailureCategory, retryAfter: TimeInterval?, sanitizedMessage: String = "") {
        lock.lock(); defer { lock.unlock() }
        var st = states[slotID] ?? SlotState(authBlockedUntilReconnect: false, inFlight: false, pendingFollowUp: false, consecutiveFailures: 0)
        st.inFlight = false
        st.consecutiveFailures += 1
        let current = now()
        let nextRetry: Date
        if let retryAfter {
            // 429 Retry-After wins (R7).
            nextRetry = current.addingTimeInterval(max(retryAfter, 0))
        } else {
            let exp = min(backoffBase * pow(2.0, Double(max(st.consecutiveFailures - 1, 0))), backoffCap)
            let jitter = exp * jitterFraction * (random() * 2 - 1)  // ±20%
            let interval = TimeInterval(preferences().refreshInterval.rawValue)
            // The later of backoffWithJitter and target interval wins (R7: "a later configured interval wins").
            let withJitter = exp + jitter
            nextRetry = current.addingTimeInterval(max(withJitter, interval))
        }
        st.failure = RefreshFailureRecord(category: category, attemptAt: current, nextRetryAt: nextRetry, retryAfter: retryAfter, sanitizedMessage: sanitizedMessage)
        st.nextDueAt = nextRetry
        states[slotID] = st
    }

    /// Teardown (app terminating, fetch cancelled mid-flight): clear inFlight
    /// without recording a failure — a quit must not poison the persisted
    /// failure store for the next launch.
    public func finishTeardown(slotID: AccountSlotID) {
        lock.lock(); defer { lock.unlock() }
        guard var st = states[slotID] else { return }
        st.inFlight = false
        states[slotID] = st
    }

    /// Whether a follow-up was requested during the last fetch (R2).
    public func hasPendingFollowUp(slotID: AccountSlotID) -> Bool {
        state(for: slotID).pendingFollowUp
    }

    /// Clear auth block (called after successful reconnect).
    public func clearAuthBlock(slotID: AccountSlotID) {
        lock.lock(); defer { lock.unlock() }
        var st = states[slotID] ?? SlotState(authBlockedUntilReconnect: false, inFlight: false, pendingFollowUp: false, consecutiveFailures: 0)
        st.authBlockedUntilReconnect = false
        st.failure = nil
        states[slotID] = st
    }

    /// Compute due slots for a trigger (R9, R12). Recomputes instead of replaying missed intervals.
    public func dueSlots(trigger: RefreshTrigger) -> [AccountSlotID] {
        let connected = connectedSlots()
        return connected.filter { shouldFetch(slotID: $0, trigger: trigger) }.sorted { $0.rawValue < $1.rawValue }
    }

    /// Mark a reset boundary (R8): if any required window reset has passed, suspend availability as UNAVAILABLE and trigger.
    /// Returns the affected slot IDs that need an immediate refresh.
    public func resetBoundarySlots(now current: Date) -> [AccountSlotID] {
        let snaps = snapshots()
        var affected: [AccountSlotID] = []
        for (slotID, snapshot) in snaps {
            guard connectedSlots().contains(slotID) else { continue }
            for window in snapshot.windows where window.resetAt <= current {
                affected.append(slotID)
                break
            }
        }
        return affected.sorted { $0.rawValue < $1.rawValue }
    }

    /// Remaining delay until a slot is due (for timer scheduling). Negative means overdue.
    public func delayUntilDue(slotID: AccountSlotID) -> TimeInterval? {
        guard let due = state(for: slotID).nextDueAt else { return nil }
        return due.timeIntervalSince(now())
    }

    /// Hydrate from persisted failures (crash/upgrade recovery, §7).
    public func hydrateFailures(_ records: [AccountSlotID: RefreshFailureRecord]) {
        for (slotID, rec) in records {
            var st = state(for: slotID)
            st.failure = rec
            st.nextDueAt = rec.nextRetryAt
            setState(st, for: slotID)
        }
    }

    /// Apply clock jump (sleep/wake, rollback/forward, R12): recompute due times.
    public func reconcileClockJump(previousNow: Date, currentNow: Date) {
        // Simply recompute nextDueAt as lastSuccessAt + interval when the stored nextDueAt would have been stale.
        // We do not replay every missed interval (R12).
        let interval = TimeInterval(preferences().refreshInterval.rawValue)
        lock.lock(); defer { lock.unlock() }
        for slotID in states.keys {
            guard var st = states[slotID] else { continue }
            if let last = st.lastSuccessAt {
                let expected = last.addingTimeInterval(interval)
                if currentNow >= expected {
                    st.nextDueAt = currentNow  // due immediately, not n * interval
                    states[slotID] = st
                }
            } else if let due = st.nextDueAt, currentNow >= due {
                st.nextDueAt = currentNow
                states[slotID] = st
            }
        }
    }
}
