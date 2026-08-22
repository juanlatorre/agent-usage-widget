import Foundation

/// User-visible account status derived only from snapshot data, freshness, and connection state.
///
/// The engine never fabricates availability: stale or incomplete records degrade honestly.
public enum AccountStatus: Equatable, Sendable {
    /// The slot has no connected source yet.
    case notConnected
    /// No successful snapshot exists and an initial fetch is expected.
    case loading
    /// Every required window holds remaining capacity.
    case available
    /// At least one required window is exhausted; the account cannot be used now.
    case blocked
    /// A transient refresh failure occurred; a fresh-enough historical snapshot remains visible.
    case error
    /// Required data is missing/invalid, or the last snapshot reached the freshness horizon.
    case unavailable
    /// Credentials are missing or were rejected; reconnection is required before
    /// any current claim can be made (parent R7 precedence).
    case authenticationRequired
}

/// One blocking usage window prepared for presentation.
public struct BlockingWindow: Equatable, Sendable, Identifiable {
    public let id: UsageWindowKind
    public let name: String
    public let resetAt: Date
    /// Used fraction clamped to 0...1.
    public let usedFraction: Double
}

/// The representative window supplying ring/bar percentages.
public struct LimitingWindow: Equatable, Sendable {
    public let kind: UsageWindowKind
    public let name: String
    /// Used fraction clamped to 0...1.
    public let usedFraction: Double
    /// Remaining fraction clamped to 0...1.
    public let remainingFraction: Double
    public let resetAt: Date

    /// Percentage to display under the current global display mode.
    public func fraction(for mode: DisplayPreferences.DisplayMode) -> Double {
        switch mode {
        case .used: return usedFraction
        case .remaining: return remainingFraction
        }
    }
}

/// Fully derived presentation model for one account slot. Provider-agnostic by construction.
public struct AccountPresentation: Equatable, Sendable, Identifiable {
    public let slotID: AccountSlotID
    public var id: AccountSlotID { slotID }
    public let label: String
    public let status: AccountStatus
    /// Windows that currently block use; non-empty only for `.blocked`.
    public let blockers: [BlockingWindow]
    public let limitingWindow: LimitingWindow?
    /// When every current blocker has reset. Set only for `.blocked`.
    public let availableAt: Date?
    /// Age of the underlying snapshot in seconds (zero when no snapshot exists).
    public let snapshotAge: TimeInterval
    /// Context windows shown for degraded states; never presented as current truth.
    public let historicalWindows: [UsageWindow]
    /// Non-secret diagnostics explaining degraded or notable states.
    public let diagnosticNotes: [String]

    public init(
        slotID: AccountSlotID,
        label: String,
        status: AccountStatus,
        blockers: [BlockingWindow],
        limitingWindow: LimitingWindow?,
        availableAt: Date?,
        snapshotAge: TimeInterval,
        historicalWindows: [UsageWindow],
        diagnosticNotes: [String]
    ) {
        self.slotID = slotID
        self.label = label
        self.status = status
        self.blockers = blockers
        self.limitingWindow = limitingWindow
        self.availableAt = availableAt
        self.snapshotAge = snapshotAge
        self.historicalWindows = historicalWindows
        self.diagnosticNotes = diagnosticNotes
    }
}

/// Deterministic domain rules shared by the app and future widget surfaces.
///
/// All calculations accept an injected clock and perform no I/O. No SwiftUI,
/// networking, or provider-specific logic may live here (child spec R2).
public enum AvailabilityEngine {

    /// Freshness horizon after which history can no longer support a current claim.
    public static let snapshotFreshnessHorizon: TimeInterval = 15 * 60

    // MARK: - Single account derivation

    /// Derive presentation for a slot from optional snapshot data.
    ///
    /// - Parameters:
    ///   - slot: the static catalog entry for the slot.
    ///   - snapshot: the last persisted valid snapshot, if any.
    ///   - now: injected current time.
    ///   - authenticationRequired: refresh-layer signal that credentials are
    ///     missing or were rejected. Outranks every other state (parent R7);
    ///     any snapshot remains visible only as historical context.
    public static func derive(
        slot: AccountSlot,
        snapshot: UsageSnapshot?,
        now: Date,
        authenticationRequired: Bool = false
    ) -> AccountPresentation {
        if authenticationRequired {
            let age = snapshot?.age(at: now) ?? 0
            var notes = snapshot.map(sanitizedDiagnostics(from:)) ?? []
            notes.append("Credentials are missing or were rejected; reconnect the account.")
            return AccountPresentation(
                slotID: slot.slotID, label: slot.label, status: .authenticationRequired,
                blockers: [], limitingWindow: nil, availableAt: nil,
                snapshotAge: age,
                historicalWindows: snapshot?.windows ?? [],
                diagnosticNotes: notes)
        }

        guard let snapshot else {
            if slot.isConnected {
                return AccountPresentation(
                    slotID: slot.slotID, label: slot.label, status: .loading,
                    blockers: [], limitingWindow: nil, availableAt: nil,
                    snapshotAge: 0, historicalWindows: [],
                    diagnosticNotes: ["Waiting for the first successful refresh."])
            }
            return AccountPresentation(
                slotID: slot.slotID, label: slot.label, status: .notConnected,
                blockers: [], limitingWindow: nil, availableAt: nil,
                snapshotAge: 0, historicalWindows: [],
                diagnosticNotes: [])
        }

        let age = snapshot.age(at: now)
        var notes = sanitizedDiagnostics(from: snapshot)

        // A future snapshot timestamp is treated as age zero for display, with a
        // clock-skew diagnostic recorded instead of trusting or penalizing it.
        if snapshot.capturedAt > now {
            notes.append("Snapshot timestamp is in the future; treating it as current (clock skew).")
        }

        // Expired history: too old to support any current claim.
        guard age < snapshotFreshnessHorizon else {
            notes.append("Snapshot is at least 15 minutes old.")
            return AccountPresentation(
                slotID: slot.slotID, label: slot.label, status: .unavailable,
                blockers: [], limitingWindow: nil, availableAt: nil,
                snapshotAge: age, historicalWindows: snapshot.windows,
                diagnosticNotes: notes)
        }

        // Unknown future schema: ignore for current state, retain as history.
        guard snapshot.schemaVersion == UsageSnapshot.schemaVersion else {
            notes.append("Snapshot schema version \(snapshot.schemaVersion) is not recognized.")
            return AccountPresentation(
                slotID: slot.slotID, label: slot.label, status: .unavailable,
                blockers: [], limitingWindow: nil, availableAt: nil,
                snapshotAge: age, historicalWindows: snapshot.windows,
                diagnosticNotes: notes)
        }

        return deriveCurrentWindows(
            slot: slot, snapshot: snapshot, now: now,
            age: age, notes: &notes)
    }

    /// Derive availability from validated current windows of a fresh snapshot.
    private static func deriveCurrentWindows(
        slot: AccountSlot,
        snapshot: UsageSnapshot,
        now: Date,
        age: TimeInterval,
        notes: inout [String]
    ) -> AccountPresentation {
        let windowMap = Dictionary(
            uniqueKeysWithValues: snapshot.windows.map { ($0.id, $0) }
        )
        let required = slot.requiredWindows.compactMap { windowMap[$0] }
        let missing = slot.requiredWindows.filter { windowMap[$0] == nil }
        let invalid = required.filter {
            !$0.isIndividuallyValid || $0.resetAt <= snapshot.capturedAt
        }
        // Cached reset times that have passed suspend every availability claim
        // until a successful post-reset snapshot verifies current windows
        // (parent R9, ADR-0005).
        let completeValid = required.filter {
            $0.isIndividuallyValid && $0.resetAt > snapshot.capturedAt
        }
        let expiredByNow = completeValid.filter { $0.resetAt <= now }
        if !expiredByNow.isEmpty {
            notes.append("Cached reset time has passed; waiting for verification after reset.")
            return degradedPresentation(
                slot: slot, status: .unavailable, age: age,
                history: completeValid, notes: notes)
        }

        // Incomplete or invalid required data: UNAVAILABLE; complete windows stay
        // visible as partial context only. Never fabricate zero usage.
        if !missing.isEmpty || !invalid.isEmpty {
            if !missing.isEmpty {
                notes.append("Missing required windows: " + names(of: missing) + ".")
            }
            if !invalid.isEmpty {
                notes.append("Invalid required windows: " + names(of: invalid.map(\.id)) + ".")
            }
            return degradedPresentation(
                slot: slot, status: .unavailable, age: age,
                history: completeValid, notes: notes)
        }

        let blockers = completeValid.filter(\.isBlocking)

        if blockers.isEmpty {
            return AccountPresentation(
                slotID: slot.slotID, label: slot.label, status: .available,
                blockers: [], limitingWindow: representativeWindow(of: completeValid),
                availableAt: nil,
                snapshotAge: age, historicalWindows: completeValid,
                diagnosticNotes: notes)
        }

        let blockingPresentation = blockers.map { window in
            BlockingWindow(
                id: window.id,
                name: window.name,
                resetAt: window.resetAt,
                usedFraction: window.clampedUsedFraction)
        }
        return AccountPresentation(
            slotID: slot.slotID, label: slot.label, status: .blocked,
            blockers: blockingPresentation,
            limitingWindow: representativeWindow(of: completeValid),
            availableAt: blockers.map(\.resetAt).max(),
            snapshotAge: age, historicalWindows: completeValid,
            diagnosticNotes: notes)
    }

    /// Presentation for slots without any snapshot; LOADING only when connected.
    private static func missingPresentation(slot: AccountSlot) -> AccountPresentation {
        if slot.isConnected {
            return AccountPresentation(
                slotID: slot.slotID, label: slot.label, status: .loading,
                blockers: [], limitingWindow: nil, availableAt: nil,
                snapshotAge: 0, historicalWindows: [],
                diagnosticNotes: ["Waiting for the first successful refresh."])
        }
        return AccountPresentation(
            slotID: slot.slotID, label: slot.label, status: .notConnected,
            blockers: [], limitingWindow: nil, availableAt: nil,
            snapshotAge: 0, historicalWindows: [],
            diagnosticNotes: [])
    }

    /// Presentation for degraded states that cannot claim current availability.
    private static func degradedPresentation(
        slot: AccountSlot,
        status: AccountStatus,
        age: TimeInterval,
        history: [UsageWindow],
        notes: [String]
    ) -> AccountPresentation {
        AccountPresentation(
            slotID: slot.slotID, label: slot.label, status: status,
            blockers: [], limitingWindow: nil, availableAt: nil,
            snapshotAge: age, historicalWindows: history,
            diagnosticNotes: notes)
    }

    // MARK: - Multi account derivation

    /// Derive presentation for every slot in stable catalog order.
    ///
    /// Ordering is deterministic; Large-widget priority sorting is deferred to its child.
    public static func deriveAll(
        slots: [AccountSlot],
        snapshots: [AccountSlotID: UsageSnapshot],
        now: Date,
        authenticationRequired: Set<AccountSlotID> = []
    ) -> [AccountPresentation] {
        slots.map { derive(
            slot: $0,
            snapshot: snapshots[$0.slotID],
            now: now,
            authenticationRequired: authenticationRequired.contains($0.slotID))
        }
    }

    // MARK: - Helpers

    /// The limiting window: maximum used fraction, equivalently minimum remaining.
    private static func representativeWindow(
        of windows: [UsageWindow]
    ) -> LimitingWindow? {
        guard let window = windows.max(by: {
            $0.clampedUsedFraction < $1.clampedUsedFraction
        }) else { return nil }
        return LimitingWindow(
            kind: window.id,
            name: window.name,
            usedFraction: window.clampedUsedFraction,
            remainingFraction: min(max(window.remaining / window.limit, 0), 1),
            resetAt: window.resetAt)
    }

    private static func names(of kinds: [UsageWindowKind]) -> String {
        kinds.map(\.displayName).sorted().joined(separator: ", ")
    }

    /// Flatten sanitized provenance notes; never include payloads or secrets.
    private static func sanitizedDiagnostics(from snapshot: UsageSnapshot) -> [String] {
        var notes = snapshot.provenance.notes
        for window in snapshot.windows {
            notes.append(contentsOf: window.sourceDiagnostics.notes)
        }
        return notes
    }
}
