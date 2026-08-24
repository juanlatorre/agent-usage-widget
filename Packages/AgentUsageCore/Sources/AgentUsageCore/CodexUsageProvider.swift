import Foundation

/// Errors surfaced by the Codex usage transport.
public enum CodexUsageError: Error, Equatable, Sendable {
    /// No usable credential exists in the slot's Keychain entry.
    case missingCredential
    /// The provider rejected the credential.
    case unauthorized(status: Int)
    /// The provider asked to slow down; `retryAfter` is honored when present.
    case rateLimited(retryAfter: TimeInterval?)
    /// Any other non-2xx transport outcome.
    case http(status: Int)
    /// The request timed out or failed at the connection/payload layer.
    case transport(String)
    /// A 200 response arrived but its weekly window was incomplete/unusable.
    ///
    /// Distinct from `.transport` so callers can distinguish "endpoint gone or
    /// reshaped" from transient network trouble while still deriving UNAVAILABLE.
    case incompleteUsage(String)
}

/// Normalized result of one successful Codex usage fetch.
public struct CodexUsageResult: Equatable, Sendable {
    public let windows: [UsageWindow]

    public init(windows: [UsageWindow]) {
        self.windows = windows
    }
}

/// Transport and normalization for the ChatGPT Codex usage endpoint.
///
/// Contract grounded in the verified AgentBar adapter (child spec R1/R2) but
/// deliberately different where this spec forbids inherited behavior: no cache,
/// no zero-on-missing (`used_percent ?? 0` is exactly the AC4 fabrication this
/// adapter must not repeat), no synthetic 100M token limit, no plan metadata.
///
/// Only `primary_window` defines the required Weekly window. `secondary_window`,
/// `additional_rate_limits`, credits, and spend control are ignored (R6).
public struct CodexUsageProvider: Sendable {

    /// The undocumented OAuth usage endpoint this adapter depends on (ADR-0002).
    public static let usageURL = URL(string: "https://chatgpt.com/backend-api/codex/usage?limit_id=codex")!

    /// Truthful client user agent required by the endpoint (R1).
    public static let userAgent = "agent-usage-widget/0.1"

    private let session: URLSession
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - session: injectable transport for tests.
    ///   - now: injected clock for deterministic behavior.
    public init(session: URLSession = .shared, now: @escaping @Sendable () -> Date = Date.init) {
        self.session = session
        self.now = now
    }

    // MARK: - Fetch

    /// Fetch usage for one slot using credentials resolved by the caller.
    public func fetchUsage(credentials: CodexOAuthCredentials) async throws -> CodexUsageResult {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw CodexUsageError.transport("timeout")
        } catch {
            throw CodexUsageError.transport(String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw CodexUsageError.transport("non-HTTP response")
        }

        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw CodexUsageError.unauthorized(status: http.statusCode)
        case 429:
            throw CodexUsageError.rateLimited(retryAfter: Self.retryAfter(from: http))
        default:
            throw CodexUsageError.http(status: http.statusCode)
        }

        return CodexUsageResult(windows: try Self.normalize(data: data, now: now()))
    }

    // MARK: - Normalization

    /// Normalize a raw usage payload into the one required Weekly window.
    ///
    /// Contract (child spec R2/R3):
    /// - a complete window needs both a finite percentage in 0...100 AND a
    ///   future reset (absolute epoch, else nonnegative `reset_after_seconds`
    ///   relative to fetch time); anything less yields NO window — never zero
    ///   usage presented as current (AC4);
    /// - `limit_reached`/`allowed` corroborate blocking only when the complete
    ///   window already exists (R3);
    /// - unknown extra fields are ignored (R6).
    public static func normalize(data: Data, now: Date) throws -> [UsageWindow] {
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            if let primary = payload.rateLimit?.primaryWindow,
               let window = normalizedWindow(from: primary, now: now) {
                return [window]
            }
            // Transport succeeded but the required Weekly window is incomplete.
            // Return no window so the caller can persist an UNAVAILABLE snapshot
            // rather than treating this as a transient failure (child spec R4,
            // parent R1/R7 precedence). Never fabricate zero usage.
            return []
        } catch let error as CodexUsageError {
            throw error
        } catch {
            throw CodexUsageError.transport("undecodable usage payload")
        }
    }

    /// Build the Weekly window from raw primary-window values, or nil when the
    /// pair is incomplete. Percentage must be finite within 0...100; reset must
    /// be an absolute epoch strictly after `now`, or relative seconds >= 0.
    static func normalizedWindow(from primary: RawWindow, now: Date) -> UsageWindow? {
        guard let usedPercent = primary.usedPercent,
              usedPercent.isFinite,
              usedPercent >= 0, usedPercent <= 100 else {
            return nil
        }
        guard let resetAt = parsedReset(from: primary, now: now),
              resetAt >= now else {
            return nil
        }
        var notes: [String] = []
        if primary.resetAt == nil {
            notes.append("reset derived from reset_after_seconds")
        }
        return UsageWindow(
            id: .weekly,
            name: UsageWindowKind.weekly.displayName,
            isRequired: true,
            used: usedPercent,
            limit: 100,
            resetAt: resetAt,
            sourceDiagnostics: SourceDiagnostics(
                sourceKind: "codex-oauth-usage",
                sourceReliability: "undocumented-endpoint",
                notes: notes))
    }

    /// Absolute `reset_at` wins; otherwise nonnegative `reset_after_seconds`
    /// resolved against the fetch time. Both absent yields nil (incomplete).
    static func parsedReset(from primary: RawWindow, now: Date) -> Date? {
        if let epoch = primary.resetAt, epoch > 0 {
            return Date(timeIntervalSince1970: TimeInterval(epoch))
        }
        if let seconds = primary.resetAfterSeconds, seconds >= 0 {
            return now.addingTimeInterval(TimeInterval(seconds))
        }
        return nil
    }

    /// Extract `Retry-After` seconds when present and numeric.
    static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let header = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)) {
            return max(seconds, 0)
        }
        // HTTP-date form falls back to scheduler backoff per the parent contract.
        return nil
    }

    // MARK: - Payload decoding

    struct Payload: Decodable {
        let rateLimit: RateLimit?

        enum CodingKeys: String, CodingKey {
            case rateLimit = "rate_limit"
        }
    }

    struct RateLimit: Decodable {
        let allowed: Bool?
        let limitReached: Bool?
        let primaryWindow: RawWindow?

        enum CodingKeys: String, CodingKey {
            case allowed
            case limitReached = "limit_reached"
            case primaryWindow = "primary_window"
        }
    }

    struct RawWindow: Decodable, Equatable {
        let usedPercent: Double?
        let limitWindowSeconds: Int?
        let resetAfterSeconds: Int?
        let resetAt: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAfterSeconds = "reset_after_seconds"
            case resetAt = "reset_at"
        }
    }
}
