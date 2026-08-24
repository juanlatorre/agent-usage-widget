import Foundation

/// Orchestrates refreshes for all connected slots through a single scheduler.
/// Handles R2 single-flight (via scheduler), R3 bounded concurrency, R4 success,
/// R5 failure-aging, R6 auth, R7 backoff, R8 reset boundary, R9 triggers, R12 clock.
/// Injectable transports, clock, and random for deterministic tests. No WidgetKit.
public final class RefreshService: @unchecked Sendable {

    public let scheduler: RefreshScheduler
    private let snapshotStore: SnapshotStore
    private let failureStore: RefreshFailureStore?
    private let fetcher: (AccountSlotID) async -> Result<UsageSnapshot, RefreshFetchError>
    private let now: () -> Date
    private let onSnapshotPublished: ((UsageSnapshot) -> Void)?

    /// Optional hook invoked after any slot's state changes so callers can recompute
    /// AvailabilityEngine derivations (e.g. StatusModel).
    public var onStateChange: (() -> Void)?

    public init(scheduler: RefreshScheduler,
                snapshotStore: SnapshotStore,
                failureStore: RefreshFailureStore? = nil,
                fetcher: @escaping (AccountSlotID) async -> Result<UsageSnapshot, RefreshFetchError>,
                now: @escaping () -> Date = Date.init,
                onSnapshotPublished: ((UsageSnapshot) -> Void)? = nil) {
        self.scheduler = scheduler
        self.snapshotStore = snapshotStore
        self.failureStore = failureStore
        self.fetcher = fetcher
        self.now = now
        self.onSnapshotPublished = onSnapshotPublished
    }

    // MARK: - Public triggers

    /// Trigger refresh for one slot. Honors R2 coalescing.
    public func trigger(slotID: AccountSlotID, trigger: RefreshTrigger) async {
        guard scheduler.beginFetch(slotID: slotID, trigger: trigger) else { return }
        await performFetch(slotID: slotID)
        // R2: at most one pending follow-up.
        if scheduler.hasPendingFollowUp(slotID: slotID) {
            // Clear pending and run one safe follow-up if still allowed.
            // We clear the flag via finish logic; re-enter once.
            if scheduler.beginFetch(slotID: slotID, trigger: trigger) {
                await performFetch(slotID: slotID)
            }
        }
    }

    /// Global refresh targeting all connected slots (R9). Runs independent slots concurrently under bounded limit.
    public func triggerGlobal(trigger: RefreshTrigger) async {
        let due = scheduler.dueSlots(trigger: trigger)
        await withTaskGroup(of: Void.self) { group in
            let semaphore = AsyncSemaphore(value: scheduler.maxConcurrentFetches)
            for slotID in due {
                await semaphore.wait()
                group.addTask {
                    await self.trigger(slotID: slotID, trigger: trigger)
                    await semaphore.signal()
                }
            }
        }
    }

    /// Explicit IDs only (widget, per-account): target is authoritative, still honors coalescing/auth.
    public func triggerSlots(_ slotIDs: [AccountSlotID], trigger: RefreshTrigger) async {
        for slotID in slotIDs {
            await self.trigger(slotID: slotID, trigger: trigger)
        }
    }

    // MARK: - Reset boundary

    /// Scan stored snapshots for expired resets and trigger immediate refresh (R8).
    public func handleResetBoundaries() async {
        let affected = scheduler.resetBoundarySlots(now: now())
        for slotID in affected {
            await trigger(slotID: slotID, trigger: .resetBoundary)
        }
    }

    // MARK: - Core fetch

    private func performFetch(slotID: AccountSlotID) async {
        let result = await fetcher(slotID)
        switch result {
        case .success(let snapshot):
            do { try snapshotStore.save(snapshot) } catch { NSLog("[AgentUsage] snapshot save failed: \(error)") }
            scheduler.finishSuccess(slotID: slotID, snapshot: snapshot)
            if let fs = failureStore { fs.remove(slotID: slotID) }
            onSnapshotPublished?(snapshot)
            // Best-effort widget timeline reload is requested by the caller (app/helper) after this.
            onStateChange?()
        case .failure(let error):
            handleFetchError(slotID: slotID, error: error)
        }
    }

    private func handleFetchError(slotID: AccountSlotID, error: RefreshFetchError) {
        switch error {
        case .unauthorized:
            scheduler.finishAuthRequired(slotID: slotID)
            failureStore?.set(RefreshFailureRecord(category: .unknown, attemptAt: now(), nextRetryAt: nil, sanitizedMessage: "unauthorized"), for: slotID)
        case .sourceIdentityChanged:
            scheduler.finishSourceIdentityChanged(slotID: slotID)
            failureStore?.set(RefreshFailureRecord(category: .unknown, attemptAt: now(), nextRetryAt: nil, sanitizedMessage: "identity changed"), for: slotID)
        case .rateLimited(let retryAfter):
            scheduler.finishTransientFailure(slotID: slotID, category: .rateLimited, retryAfter: retryAfter, sanitizedMessage: "rate limited")
            if let rec = scheduler.state(for: slotID).failure { failureStore?.set(rec, for: slotID) }
        case .http(let status):
            scheduler.finishTransientFailure(slotID: slotID, category: .http, retryAfter: nil, sanitizedMessage: "http \(status)")
            if let rec = scheduler.state(for: slotID).failure { failureStore?.set(rec, for: slotID) }
        case .transport(let msg):
            scheduler.finishTransientFailure(slotID: slotID, category: .transport, retryAfter: nil, sanitizedMessage: msg)
            if let rec = scheduler.state(for: slotID).failure { failureStore?.set(rec, for: slotID) }
        case .incomplete(let msg):
            scheduler.finishTransientFailure(slotID: slotID, category: .incomplete, retryAfter: nil, sanitizedMessage: msg)
            if let rec = scheduler.state(for: slotID).failure { failureStore?.set(rec, for: slotID) }
        }
        onStateChange?()
    }
}

/// Minimal async semaphore for bounded concurrency (R3 isolation: one hung provider must not block others).
private actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(value: Int) { self.value = value }
    func wait() async {
        if value > 0 { value -= 1; return }
        await withCheckedContinuation { c in waiters.append(c) }
    }
    func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst(); waiter.resume()
        } else { value += 1 }
    }
}
