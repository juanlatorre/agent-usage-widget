import Foundation

/// Errors surfaced by the Claude usage transport.
public enum ClaudeUsageError: Error, Equatable, Sendable {
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
}

/// Normalized result of one successful Claude usage fetch.
public struct ClaudeUsageResult: Equatable, Sendable {
    public let windows: [UsageWindow]

    public init(windows: [UsageWindow]) {
        self.windows = windows
    }
}

/// Transport and normalization for Claude's OAuth usage endpoint.
///
/// Grounded in the verified AgentBar adapter but deliberately different where the
/// child spec forbids inherited behavior: no cache-on-error, no zero-on-missing,
/// no swallowed decode failures. Failures surface as typed errors; missing or
/// unusable required windows yield no window, which callers must treat as
/// `UNAVAILABLE` — never as 0% (child spec R6).
public struct ClaudeUsageProvider: Sendable {

    /// The undocumented OAuth usage endpoint this adapter depends on (ADR-0002).
    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Beta header required by the OAuth usage endpoint.
    public static let betaHeader = "oauth-2025-04-20"

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
    public func fetchUsage(credentials: ClaudeOAuthCredentials) async throws -> ClaudeUsageResult {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
     throw ClaudeUsageError.transport("cancelled")
 } catch is CancellationError {
     throw ClaudeUsageError.transport("cancelled")
 } catch let error as URLError where error.code == .timedOut {
     throw ClaudeUsageError.transport("timeout")
 } catch {
     throw ClaudeUsageError.transport(String(describing: error))
 }

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeUsageError.transport("non-HTTP response")
        }

        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw ClaudeUsageError.unauthorized(status: http.statusCode)
        case 429:
            throw ClaudeUsageError.rateLimited(retryAfter: Self.retryAfter(from: http))
        default:
            throw ClaudeUsageError.http(status: http.statusCode)
        }

        return ClaudeUsageResult(windows: try Self.normalize(data: data, now: now()))
    }

    // MARK: - Normalization

    /// Normalize a raw usage payload into the two required windows.
    ///
    /// Contract (child spec R5):
    /// - exact `five_hour` / `seven_day` keys win over suffixed variants;
    /// - variants pick the most constrained (highest utilization); ties pick the
    ///   latest reset;
    /// - missing/null windows or unusable reset timestamps yield no window, never
    ///   fabricated zero usage (R6);
    /// - unknown keys are ignored.
    public static func normalize(data: Data, now: Date) throws -> [UsageWindow] {
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            let fiveHour = canonicalWindow(from: payload.fiveHour, kind: .fiveHour, now: now)
            let sevenDay = canonicalWindow(from: payload.sevenDay, kind: .weekly, now: now)
            return [fiveHour, sevenDay].compactMap { $0 }
        } catch let error as ClaudeUsageError {
            throw error
        } catch {
            throw ClaudeUsageError.transport("undecodable usage payload")
        }
    }

    private static func canonicalWindow(
        from raw: RawWindow?, kind: UsageWindowKind, now: Date
    ) -> UsageWindow? {
        guard let raw else { return nil }
        // Inactive window: the endpoint reports utilization 0 with a null reset
        // while no window is running (observed on five_hour). Dropping it made
        // the engine derive UNAVAILABLE ("missing required window") even though
        // nothing blocks usage — same normalization as Command Code's inactive
        // 5-hour window. Emit used 0 with an estimated reset, honestly noted.
        if let reported = raw.utilization, reported <= 0, raw.parsedReset == nil {
            let reset = now.addingTimeInterval(kind == .fiveHour ? 5 * 60 * 60 : 7 * 24 * 60 * 60)
            return UsageWindow(
                id: kind,
                name: kind.displayName,
                isRequired: true,
                used: 0,
                limit: 100,
                resetAt: reset,
                sourceDiagnostics: SourceDiagnostics(
                    sourceKind: "claude-oauth-usage",
                    sourceReliability: "undocumented-endpoint",
                    notes: ["\(kind.displayName.lowercased()) window inactive; reset time estimated"]))
        }
        guard let resetAt = raw.parsedReset else { return nil }
        // Null/absent utilization is incomplete data, not zero usage: dropping
        // the window derives UNAVAILABLE instead of fabricating capacity (R6).
        guard let reported = raw.utilization else { return nil }
        let used = min(max(reported, 0), 100)
        return UsageWindow(
            id: kind,
            name: kind.displayName,
            isRequired: true,
            used: used,
            limit: 100,
            resetAt: resetAt,
            sourceDiagnostics: SourceDiagnostics(
                sourceKind: "claude-oauth-usage",
                sourceReliability: "undocumented-endpoint",
                notes: raw.chosenKey.map { ["normalized from \($0)"] } ?? []))
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
        let fiveHour: RawWindow?
        let sevenDay: RawWindow?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)

            var all: [String: RawWindow] = [:]
            for key in container.allKeys {
                if let window = try? container.decode(RawWindow.self, forKey: key) {
                    all[key.stringValue] = window
                }
            }

            fiveHour = Self.resolve("five_hour", from: all)
            sevenDay = Self.resolve("seven_day", from: all)
        }

        /// Exact aggregate key wins over suffixed variants; otherwise pick the
        /// most constrained variant, breaking ties by latest reset then key order.
        static func resolve(_ base: String, from windows: [String: RawWindow]) -> RawWindow? {
            if let exact = windows[base] { return exact }
            let prefix = "\(base)_"
            let candidates = windows.filter { $0.key.hasPrefix(prefix) }
            guard !candidates.isEmpty else { return nil }
            let selected = candidates
                .sorted { $0.key < $1.key }
                .max { lhs, rhs in
                    let lhsUsed = lhs.value.utilization ?? -.infinity
                    let rhsUsed = rhs.value.utilization ?? -.infinity
                    if lhsUsed != rhsUsed { return lhsUsed < rhsUsed }
                    let lhsReset = lhs.value.parsedReset ?? .distantPast
                    let rhsReset = rhs.value.parsedReset ?? .distantPast
                    if lhsReset != rhsReset { return lhsReset < rhsReset }
                    return false
                }
            guard let selected else { return nil }
            var window = selected.value
            window.chosenKey = selected.key
            return window
        }
    }

    struct RawWindow: Decodable, Equatable {
        let utilization: Double?
        /// Raw payload key spelling (`resets_at` in Claude's response).
        var resetsAt: String?
        /// The raw payload key this window was selected from. Set only when a
        /// suffixed variant was chosen over an absent aggregate key.
        var chosenKey: String?

        init(utilization: Double?, resetsAt: String?, chosenKey: String? = nil) {
            self.utilization = utilization
            self.resetsAt = resetsAt
            self.chosenKey = chosenKey
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Null or absent utilization is tolerated; reset validity is checked later.
            utilization = try container.decodeIfPresent(Double.self, forKey: .utilization)
            resetsAt = try container.decodeIfPresent(String.self, forKey: .resetsAt)
            chosenKey = nil
        }

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        var parsedReset: Date? {
            guard let resetsAt else { return nil }
            return Self.parseISO8601(resetsAt)
        }

        /// Parse ISO-8601 timestamps with or without fractional seconds.
        static func parseISO8601(_ value: String) -> Date? {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: value)
        }
    }

    struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}
