import Foundation

/// Sanitized failure category persisted per slot. No payloads or secrets.
public enum RefreshFailureCategory: String, Codable, Sendable {
    case rateLimited = "rateLimited"
    case transport = "transport"
    case http = "http"
    case incomplete = "incomplete"
    case unknown = "unknown"
}

/// One failed attempt, preserved as history while the valid snapshot remains unchanged (parent R5).
public struct RefreshFailureRecord: Codable, Sendable, Equatable {
    public let category: RefreshFailureCategory
    public let attemptAt: Date
    /// When the scheduler may retry. Nil means immediate retry is allowed (manual override may still run).
    public let nextRetryAt: Date?
    /// Sanitized retry hint, e.g. Retry-After seconds when known.
    public let retryAfter: TimeInterval?
    public let sanitizedMessage: String

    public init(category: RefreshFailureCategory, attemptAt: Date, nextRetryAt: Date?, retryAfter: TimeInterval? = nil, sanitizedMessage: String = "") {
        self.category = category; self.attemptAt = attemptAt; self.nextRetryAt = nextRetryAt; self.retryAfter = retryAfter; self.sanitizedMessage = sanitizedMessage
    }
}

/// Trigger kinds for refresh requests (R2, R9). Only safe manual overrides may bypass a retry deadline.
public enum RefreshTrigger: Sendable, Equatable {
    case interval
    case appActivation
    case manualGlobal
    case manualPerAccount
    case widget
    case resetBoundary
    case sourceChange

    public var isSafeManualOverride: Bool {
        switch self {
        case .manualGlobal, .manualPerAccount, .widget: return true
        default: return false
        }
    }

    public var isAutomatic: Bool {
        switch self {
        case .interval, .resetBoundary: return true
        default: return false
        }
    }
}

/// Unified fetch error surfaced by the per-slot fetch closure to the scheduler.
/// Preserves Retry-After for R7 without leaking payloads.
public enum RefreshFetchError: Error, Sendable, Equatable {
    case unauthorized(status: Int)
    case sourceIdentityChanged
    case rateLimited(retryAfter: TimeInterval?)
    case http(status: Int)
    case transport(String)
    case incomplete(String)
}
