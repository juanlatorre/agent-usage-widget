import Foundation

/// Errors surfaced by the OpenCode usage transport.
public enum OpenCodeUsageError: Error, Equatable, Sendable {
    case missingCredential
    case unauthorized(status: Int)
    case rateLimited(retryAfter: TimeInterval?)
    case http(status: Int)
    case transport(String)
    case incompleteUsage(String)
}

/// Normalized result of one successful OpenCode usage fetch.
public struct OpenCodeUsageResult: Equatable, Sendable {
    public let windows: [UsageWindow]
    public init(windows: [UsageWindow]) { self.windows = windows }
}

/// Transport and normalization for `GET https://opencode.ai/zen/go/v1/usage`.
///
/// Two payload shapes are supported (child spec R2):
/// - Shape A — top-level `rollingUsage` / `weeklyUsage` / `monthlyUsage`
///   each carrying `usagePercent` (or `usage_percent`) and `resetInSec`
///   (or `reset_in_sec`), a nonnegative integer relative to fetch time;
/// - Shape B — nested `usage.{rolling,weekly,monthly}` each carrying
///   `percent` and `resetsAt` (ISO-8601 string; may also appear inside the
///   top-level shape for resilience).
///
/// Rolling maps to the 5-hour required window. All three required windows must
/// be present with a finite percent in 0...100 and a future-or-current reset;
/// any gap yields no window for that period — never fabricated zero usage
/// (R3/R4). `useBalance` and unknown members are ignored (R5).
public struct OpenCodeUsageProvider: Sendable {

    public static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    public static let userAgent = "agent-usage-widget/0.1"

    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(session: URLSession = .shared, now: @escaping @Sendable () -> Date = Date.init) {
        self.session = session
        self.now = now
    }

    // MARK: - Fetch

    public func fetchUsage(credentials: OpenCodeCredentials) async throws -> OpenCodeUsageResult {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
     throw OpenCodeUsageError.transport("cancelled")
 } catch is CancellationError {
     throw OpenCodeUsageError.transport("cancelled")
 } catch let error as URLError where error.code == .timedOut {
     throw OpenCodeUsageError.transport("timeout")
 } catch {
     throw OpenCodeUsageError.transport(String(describing: error))
 }

        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeUsageError.transport("non-HTTP response")
        }

        switch http.statusCode {
        case 200...299: break
        case 401, 403: throw OpenCodeUsageError.unauthorized(status: http.statusCode)
        case 429: throw OpenCodeUsageError.rateLimited(retryAfter: Self.retryAfter(from: http))
        default: throw OpenCodeUsageError.http(status: http.statusCode)
        }

        return OpenCodeUsageResult(windows: try Self.normalize(data: data, now: now()))
    }

    // MARK: - Normalization

    /// Normalize a raw payload into the three required windows.
    ///
    /// - A provider `status` that indicates failure makes the whole response
    ///   incomplete even if windows look present (R4).
    /// - Missing window, percent, or reset produces no window for that period
    ///   (caller derives UNAVAILABLE, AC3). Never fabricate zero.
    public static func normalize(data: Data, now: Date) throws -> [UsageWindow] {
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)

            if let status = payload.status?.trimmingCharacters(in: .whitespacesAndNewlines),
               !status.isEmpty,
               !isSuccessStatus(status) {
                return []
            }

            var windows: [UsageWindow] = []
            if let w = normalizedWindow(kind: .fiveHour, from: payload, now: now) { windows.append(w) }
            if let w = normalizedWindow(kind: .weekly, from: payload, now: now) { windows.append(w) }
            if let w = normalizedWindow(kind: .monthly, from: payload, now: now) { windows.append(w) }
            return windows
        } catch let error as OpenCodeUsageError {
            throw error
        } catch {
            throw OpenCodeUsageError.transport("undecodable usage payload")
        }
    }

    static func isSuccessStatus(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return ["ok", "success", "active", "ready"].contains(lower)
    }

    static func normalizedWindow(kind: UsageWindowKind, from payload: Payload, now: Date) -> UsageWindow? {
        let raw: RawUsage?
        switch kind {
        case .fiveHour:
            raw = payload.rollingUsage ?? payload.usage?.rolling
        case .weekly:
            raw = payload.weeklyUsage ?? payload.usage?.weekly
        case .monthly:
            raw = payload.monthlyUsage ?? payload.usage?.monthly
        }

        guard let raw else { return nil }

        guard let percent = raw.effectivePercent,
              percent.isFinite, percent >= 0, percent <= 100 else { return nil }

        let resetAt: Date?
        if let iso = raw.effectiveResetsAt, !iso.isEmpty {
            guard let parsed = parseISO8601(iso) else { return nil }
            resetAt = parsed
        } else if let seconds = raw.effectiveResetInSec {
            guard seconds >= 0 else { return nil }
            resetAt = now.addingTimeInterval(TimeInterval(seconds))
        } else {
            return nil
        }

        guard let resolved = resetAt, resolved >= now else { return nil }

        var notes: [String] = []
        if raw.effectiveResetsAt == nil, raw.effectiveResetInSec != nil {
            notes.append("reset derived from resetInSec")
        }

        return UsageWindow(
            id: kind, name: kind.displayName, isRequired: true,
            used: percent, limit: 100, resetAt: resolved,
            sourceDiagnostics: SourceDiagnostics(
                sourceKind: "opencode-go-usage",
                sourceReliability: "official-endpoint",
                notes: notes))
    }

    static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let header = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)) {
            return max(seconds, 0)
        }
        return nil
    }

    // MARK: - Payload

    struct Payload: Decodable {
        let rollingUsage: RawUsage?
        let weeklyUsage: RawUsage?
        let monthlyUsage: RawUsage?
        let usage: UsageContainer?
        let status: String?
    }

    struct UsageContainer: Decodable {
        let rolling: RawUsage?
        let weekly: RawUsage?
        let monthly: RawUsage?
    }

    struct RawUsage: Decodable, Equatable {
        let usagePercent: Double?
        let resetInSec: Int?
        let percent: Double?
        let resetsAt: String?
        let usage_percent: Double?
        let reset_in_sec: Int?
        let resets_at: String?

        enum CodingKeys: String, CodingKey {
            case usagePercent, resetInSec, percent, resetsAt
            case usage_percent, reset_in_sec, resets_at
        }

        init(usagePercent: Double? = nil, resetInSec: Int? = nil,
             percent: Double? = nil, resetsAt: String? = nil,
             usage_percent: Double? = nil, reset_in_sec: Int? = nil,
             resets_at: String? = nil) {
            self.usagePercent = usagePercent
            self.resetInSec = resetInSec
            self.percent = percent
            self.resetsAt = resetsAt
            self.usage_percent = usage_percent
            self.reset_in_sec = reset_in_sec
            self.resets_at = resets_at
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func double(_ key: CodingKeys) -> Double? {
                (try? c.decodeIfPresent(Double.self, forKey: key))
                    ?? (try? c.decodeIfPresent(Int.self, forKey: key)).map(Double.init)
            }
            usagePercent = double(.usagePercent)
            percent = double(.percent)
            usage_percent = double(.usage_percent)
            resetInSec = try c.decodeIfPresent(Int.self, forKey: .resetInSec)
            reset_in_sec = try c.decodeIfPresent(Int.self, forKey: .reset_in_sec)
            resetsAt = try c.decodeIfPresent(String.self, forKey: .resetsAt)
            resets_at = try c.decodeIfPresent(String.self, forKey: .resets_at)
        }

        var effectivePercent: Double? { usagePercent ?? percent ?? usage_percent }
        var effectiveResetInSec: Int? { resetInSec ?? reset_in_sec }
        var effectiveResetsAt: String? { resetsAt ?? resets_at }
    }
}
