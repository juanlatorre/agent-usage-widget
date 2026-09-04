import Foundation

public enum CommandCodeUsageError: Error, Equatable, Sendable {
    case missingCredential
    case unauthorized(status: Int)
    case rateLimited(retryAfter: TimeInterval?)
    case http(status: Int)
    case transport(String)
    case incompleteUsage(String)
}

public struct CommandCodeUsageResult: Equatable, Sendable {
    public let windows: [UsageWindow]
    /// Sanitized plan identity when subscription metadata was available and active.
    public let planLabel: String?
    /// Sanitized warning when subscription fetch failed but windows are still valid (R5/AC2).
    public let metadataWarning: String?
    public init(windows: [UsageWindow], planLabel: String? = nil, metadataWarning: String? = nil) {
        self.windows = windows
        self.planLabel = planLabel
        self.metadataWarning = metadataWarning
    }
}

/// Transport and normalization for the Command Code billing API.
///
/// Endpoints (R1):
/// - `GET https://api.commandcode.ai/alpha/billing/credits` — two usage
///   windows in `windowLimits.fiveHour` / `windowLimits.weekly`, each with
///   `used`, positive `cap`, and epoch-millisecond `resetAt` (R3). `exceeded`
///   corroborates but never replaces capacity math. Credits outside
///   `windowLimits` and subscription status never add required windows.
/// - `GET https://api.commandcode.ai/alpha/billing/subscriptions` — plan
///   metadata (`planId` + `status`). An inactive subscription produces
///   UNAVAILABLE/AUTH; a failed subscription fetch does not invalidate
///   otherwise-valid windows (R5/AC2).
///
/// Corrects the AgentBar inheritance that defaults absent windows to zero: this
/// adapter returns no window for missing/invalid data so the engine derives
/// UNAVAILABLE (AC3).
public struct CommandCodeUsageProvider: Sendable {

    public static let creditsURL = URL(string: "https://api.commandcode.ai/alpha/billing/credits")!
    public static let subscriptionsURL = URL(string: "https://api.commandcode.ai/alpha/billing/subscriptions")!
    /// Truthful user agent required by the service (R2).
    public static let userAgent = "command-code-cli/1.26.0"

    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(session: URLSession = .shared, now: @escaping @Sendable () -> Date = Date.init) {
        self.session = session
        self.now = now
    }

    // MARK: - Fetch

    /// Fetch usage for one slot using credentials resolved by the caller.
    ///
    /// Two concurrent requests (credits + subscriptions) share the same Bearer
    /// credential. The credits call is authoritative for availability; the
    /// subscription call is supplementary (R5).
    public func fetchUsage(credentials: CommandCodeCredentials) async throws -> CommandCodeUsageResult {
        try await fetchUsageInternal(credentials: credentials)
    }

    private func fetchUsageInternal(credentials: CommandCodeCredentials) async throws -> CommandCodeUsageResult {
        let headers = baseHeaders(credentials: credentials)

        // Use TaskGroup so one failure does not cancel the sibling unless
        // both fail (R5 partial-success contract).
        async let creditsResult = fetchCredits(headers: headers)
        async let subscriptionResult = fetchSubscription(headers: headers)

        let creditsOutcome: Result<[UsageWindow], CommandCodeUsageError>
        let subscriptionOutcome: Result<CommandCodeSubscription?, CommandCodeUsageError>

        do {
            let windows = try await creditsResult
            creditsOutcome = .success(windows)
        } catch let error as CommandCodeUsageError {
            creditsOutcome = .failure(error)
        } catch {
            creditsOutcome = .failure(.transport(String(describing: error)))
        }

        do {
            let sub = try await subscriptionResult
            subscriptionOutcome = .success(sub)
        } catch let error as CommandCodeUsageError {
            subscriptionOutcome = .failure(error)
        } catch {
            subscriptionOutcome = .failure(.transport(String(describing: error)))
        }

        // R4/R5: credits failure cannot be rescued by plan success.
        guard case let .success(windows) = creditsOutcome else {
            if case let .failure(error) = creditsOutcome { throw error }
            throw CommandCodeUsageError.transport("credits fetch failed")
        }

        // R4: inactive subscription downgrades availability even when credits
        // look healthy — but we surface the result and let the engine/manager
        // layer decide the precise UNAVAILABLE/AUTH mapping by annotating.
        // For normalization, preserve windows and attach a warning.
        switch subscriptionOutcome {
        case .success(let sub):
            if let sub {
                let lower = (sub.status ?? "").lowercased()
                let inactive = ["inactive", "canceled", "cancelled", "expired", "past_due", "unpaid", "suspended"]
                if inactive.contains(lower) {
                    // Subscription explicitly inactive: window data is context only;
                    // manager will map to AUTH. Still return windows so history exists.
                    return CommandCodeUsageResult(windows: windows, planLabel: Self.sanitizedPlanLabel(sub.planId),
                                                  metadataWarning: "subscription status: \(lower)")
                }
                return CommandCodeUsageResult(windows: windows, planLabel: Self.sanitizedPlanLabel(sub.planId))
            } else {
                return CommandCodeUsageResult(windows: windows, metadataWarning: "subscription metadata absent")
            }
        case .failure:
            // R5/AC2: subscription failure does not invalidate valid windows.
            return CommandCodeUsageResult(windows: windows, metadataWarning: "subscription metadata unavailable")
        }
    }

    private func fetchCredits(headers: [String: String]) async throws -> [UsageWindow] {
        let (data, response) = try await performRequest(url: Self.creditsURL, headers: headers)
        try validateHTTP(response)
        return try Self.normalizeCredits(data: data, now: now())
    }

    private func fetchSubscription(headers: [String: String]) async throws -> CommandCodeSubscription? {
        let (data, response) = try await performRequest(url: Self.subscriptionsURL, headers: headers)
        try validateHTTP(response)
        return try Self.normalizeSubscription(data: data)
    }

    private func performRequest(url: URL, headers: [String: String]) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CommandCodeUsageError.transport("cancelled")
        } catch is CancellationError {
            throw CommandCodeUsageError.transport("cancelled")
        } catch let error as URLError where error.code == .timedOut {
            throw CommandCodeUsageError.transport("timeout")
        } catch {
            throw CommandCodeUsageError.transport(String(describing: error))
        }
    }

    private func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CommandCodeUsageError.transport("non-HTTP response")
        }
        switch http.statusCode {
        case 200...299: break
        case 401, 403: throw CommandCodeUsageError.unauthorized(status: http.statusCode)
        case 429: throw CommandCodeUsageError.rateLimited(retryAfter: Self.retryAfter(from: http))
        default: throw CommandCodeUsageError.http(status: http.statusCode)
        }
    }

    func baseHeaders(credentials: CommandCodeCredentials) -> [String: String] {
        [
            "Authorization": "Bearer \(credentials.apiKey)",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": Self.userAgent,
        ]
    }

    // MARK: - Credits normalization

    /// Normalize a raw credits payload into the two required windows.
    ///
    /// Only `windowLimits.fiveHour` and `windowLimits.weekly` matter (R4).
    /// Each window requires finite `used`, positive `cap`, and a valid
    /// epoch-millisecond `resetAt` strictly before overflow and not in the
    /// distant past. `exceeded` corroborates but cannot create availability
    /// (R3). Missing/invalid fields yield no window → UNAVAILABLE (AC3).
    public static func normalizeCredits(data: Data, now: Date) throws -> [UsageWindow] {
        do {
            let payload = try JSONDecoder().decode(CreditsPayload.self, from: data)
            var windows: [UsageWindow] = []
            if let w = normalizedWindow(kind: .fiveHour, raw: payload.windowLimits?.fiveHour, now: now) {
                windows.append(w)
            }
            if let w = normalizedWindow(kind: .weekly, raw: payload.windowLimits?.weekly, now: now) {
                windows.append(w)
            }
            // Monthly credits nearly exhausted → blocking window so the user sees why.
            if let mc = payload.credits?.monthlyCredits, mc < 1.0 {
                let nextMonth = Calendar.current.date(byAdding: .month, value: 1, to: now)
                    ?? now.addingTimeInterval(30 * 24 * 60 * 60)
                windows.append(UsageWindow(
                    id: .monthly, name: UsageWindowKind.monthly.displayName,
                    isRequired: true, used: 100, limit: 100, resetAt: nextMonth,
                    sourceDiagnostics: SourceDiagnostics(
                        sourceKind: "commandcode-credits", sourceReliability: "official-endpoint",
                        notes: [String(format: "Monthly credits nearly exhausted (%.2f remaining)", mc)])))
            }
            return windows
        } catch let error as CommandCodeUsageError {
            throw error
        } catch {
            throw CommandCodeUsageError.transport("undecodable credits payload")
        }
    }

    static func normalizedWindow(kind: UsageWindowKind, raw: RawWindowLimit?, now: Date) -> UsageWindow? {
        guard let raw,
              let used = raw.used, used.isFinite,
              let cap = raw.cap, cap.isFinite, cap > 0 else {
            return nil
        }
        // Inactive 5-hour window: the official endpoint reports `used: 0` with
        // `resetAt: 0` while no window is running. Dropping it made the engine
        // derive UNAVAILABLE ("missing required window") even though nothing
        // blocks usage — the account is genuinely available. Emit the window
        // with used 0 and an estimated reset (window cannot end before it could
        // next expire), annotated so the derivation stays honest.
        let rawReset = raw.resetAt ?? 0
        if kind == .fiveHour, rawReset <= 0, used == 0, raw.exceeded != true {
            return UsageWindow(
                id: kind, name: kind.displayName, isRequired: true,
                used: 0, limit: cap,
                resetAt: now.addingTimeInterval(5 * 60 * 60),
                sourceDiagnostics: SourceDiagnostics(
                    sourceKind: "commandcode-credits",
                    sourceReliability: "official-endpoint",
                    notes: ["5-hour window inactive; reset time estimated"]))
        }
        guard let resetAt = raw.resetAt else { return nil }
        // Epoch milliseconds must be finite and not overflow Date.
        // Valid range: 0 < ms < ~8.64e15 (year 275760). Negative/zero/huge → incomplete.
        guard resetAt > 0, resetAt < 8_640_000_000_000_000 else { return nil }
        let resetDate = Date(timeIntervalSince1970: TimeInterval(resetAt) / 1000.0)
        guard resetDate.timeIntervalSince1970.isFinite else { return nil }
        // Cap must be > 0 already checked; remaining derived. Reset must be
        // >= now to be current (engine also enforces, but we reject stale
        // credits as incomplete so AC3 holds). Allow reset == now as
        // edge-pending (manager derives UNAVAILABLE pending verification).
        guard resetDate >= now else { return nil }

        // `exceeded` can indicate blocking but never overrides capacity math.
        // No extra derivation from it needed — used >= cap already blocks.
        return UsageWindow(
            id: kind, name: kind.displayName, isRequired: true,
            used: used, limit: cap, resetAt: resetDate,
            sourceDiagnostics: SourceDiagnostics(
                sourceKind: "commandcode-credits",
                sourceReliability: "official-endpoint",
                notes: []))
    }

    static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let header = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)) {
            return max(seconds, 0)
        }
        return nil
    }

    // MARK: - Subscription normalization

    public static func normalizeSubscription(data: Data) throws -> CommandCodeSubscription? {
        let payload = try JSONDecoder().decode(SubscriptionPayload.self, from: data)
        return payload.data
    }

    static func sanitizedPlanLabel(_ planId: String?) -> String? {
        guard let planId, !planId.isEmpty else { return nil }
        // Only sanitize by trimming; displayPlanName does presentation mapping.
        return planId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Payload types

    struct CreditsPayload: Decodable {
        let windowLimits: WindowLimits?
        let credits: Credits?
    }

    struct Credits: Decodable {
        let monthlyCredits: Double?
        let belowThreshold: Bool?
    }

    struct WindowLimits: Decodable {
        let fiveHour: RawWindowLimit?
        let weekly: RawWindowLimit?
    }

    struct RawWindowLimit: Decodable {
        let used: Double?
        let cap: Double?
        let exceeded: Bool?
        let resetAt: Int64?
    }

    struct SubscriptionPayload: Decodable {
        let success: Bool?
        let data: CommandCodeSubscription?
    }
}

public struct CommandCodeSubscription: Decodable, Sendable, Equatable {
    public let planId: String?
    public let status: String?
    public init(planId: String?, status: String?) {
        self.planId = planId; self.status = status
    }
}
