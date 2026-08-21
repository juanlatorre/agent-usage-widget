import Foundation

/// The reset period of a usage window (re-exported alias for readability in store code).
public typealias WindowKind = UsageWindowKind

/// One provider-reported capacity limit over a reset period.
public struct UsageWindow: Codable, Sendable, Hashable {
    /// Stable window identity within a snapshot: the reset-period kind.
    public let id: UsageWindowKind
    public let name: String
    /// Required windows gate availability; only required windows are stored in v1.
    public let isRequired: Bool
    /// Units consumed in the current period. Must be finite and non-negative for validity.
    public let used: Double
    /// Total capacity for the period. Must be finite and positive for validity.
    public let limit: Double
    /// When the window resets. Validity requires `resetAt > capturedAt`.
    public let resetAt: Date
    /// Diagnostics about the raw source values, excluding payload contents and secrets.
    public let sourceDiagnostics: SourceDiagnostics

    public init(id: UsageWindowKind, name: String, isRequired: Bool,
                used: Double, limit: Double, resetAt: Date,
                sourceDiagnostics: SourceDiagnostics = SourceDiagnostics()) {
        self.id = id
        self.name = name
        self.isRequired = isRequired
        self.used = used
        self.limit = limit
        self.resetAt = resetAt
        self.sourceDiagnostics = sourceDiagnostics
    }
}

extension UsageWindow {
    /// Remaining capacity clamped to zero.
    public var remaining: Double { max(limit - used, 0) }

    /// Used fraction clamped to 0...1 for presentation only.
    public var clampedUsedFraction: Double { min(max(used / limit, 0), 1) }

    /// True when this required window has no remaining capacity.
    public var isBlocking: Bool { remaining <= 0 }

    /// The window's own validity independent of snapshot-level checks.
    public var isIndividuallyValid: Bool {
        used.isFinite && used >= 0 && limit.isFinite && limit > 0
    }
}

/// Sanitized provenance about where window values came from. Never contains payload data.
public struct SourceDiagnostics: Codable, Sendable, Hashable {
    /// Coarse shape of the source record, e.g. "claude-oauth-profile".
    public var sourceKind: String?
    /// Whether values came from an official API, an undocumented endpoint, or a local import.
    public var sourceReliability: String?
    public var notes: [String]

    public init(sourceKind: String? = nil, sourceReliability: String? = nil, notes: [String] = []) {
        self.sourceKind = sourceKind
        self.sourceReliability = sourceReliability
        self.notes = notes
    }
}

/// The normalized usage state for one account slot at a recorded point in time.
///
/// Snapshots are non-secret by contract: they never carry credentials or raw payloads.
public struct UsageSnapshot: Codable, Sendable, Hashable {
    public static let schemaVersion = 1

    /// Storage schema version, used to ignore unknown future records safely.
    public var schemaVersion: Int
    public let slotID: AccountSlotID
    public let provider: ProviderFamily
    /// Every required window declared for the slot. Complete snapshots contain all of them.
    public let windows: [UsageWindow]
    /// When the provider data was captured.
    public let capturedAt: Date
    public let provenance: SourceDiagnostics

    public init(schemaVersion: Int = UsageSnapshot.schemaVersion,
                slotID: AccountSlotID,
                provider: ProviderFamily,
                windows: [UsageWindow],
                capturedAt: Date,
                provenance: SourceDiagnostics = SourceDiagnostics()) {
        self.schemaVersion = schemaVersion
        self.slotID = slotID
        self.provider = provider
        self.windows = windows
        self.capturedAt = capturedAt
        self.provenance = provenance
    }
}

extension UsageSnapshot {
    /// A snapshot is complete when every declared required window is present.
    public func isComplete(for slot: AccountSlot) -> Bool {
        Set(windows.map(\.id)) == Set(slot.requiredWindows)
    }

    /// True when every window is individually valid and reset lies after capture.
    public var isIndividuallyValid: Bool {
        windows.allSatisfy { $0.isIndividuallyValid && $0.resetAt > capturedAt }
    }

    /// Snapshot age in seconds relative to a reference time; never negative for display.
    public func age(at now: Date) -> TimeInterval {
        max(now.timeIntervalSince(capturedAt), 0)
    }
}

/// Global, non-secret display and refresh preferences.
public struct DisplayPreferences: Codable, Sendable, Hashable {
    /// Whether rings, bars, and labels present used or remaining capacity.
    public var displayMode: DisplayMode
    /// Target automatic refresh interval.
    public var refreshInterval: RefreshInterval

    public init(displayMode: DisplayMode = .remaining,
                refreshInterval: RefreshInterval = .oneMinute) {
        self.displayMode = displayMode
        self.refreshInterval = refreshInterval
    }

    public enum DisplayMode: String, Codable, Sendable, CaseIterable {
        case used
        case remaining
    }

    public enum RefreshInterval: Int, Codable, Sendable, CaseIterable {
        case thirtySeconds = 30
        case oneMinute = 60
        case fiveMinutes = 300

        public var displayName: String {
            switch self {
            case .thirtySeconds: return "30 seconds"
            case .oneMinute: return "1 minute"
            case .fiveMinutes: return "5 minutes"
            }
        }
    }
}
