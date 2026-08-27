import Foundation

public enum ZaiUsageError: Error, Equatable, Sendable {
    case missingCredential
    case unauthorized(status: Int)
    case rateLimited(retryAfter: TimeInterval?)
    case http(status: Int)
    case transport(String)
    case incompleteUsage(String)
}

public struct ZaiUsageResult: Equatable, Sendable {
    public let windows: [UsageWindow]
    public init(windows: [UsageWindow]) { self.windows = windows }
}

/// Transport and normalization for `GET https://api.z.ai/api/monitor/usage/quota/limit`.
///
/// Only `TOKENS_LIMIT` defines the required 5-hour window (R3/NO1). The
/// response is an envelope `{code, success, data:{limits:[{type, percentage, nextResetTime}]}}`.
/// Required: `TOKENS_LIMIT.percentage` in 0...100 and epoch-millisecond
/// `nextResetTime`. Duplicate TOKENS_LIMIT entries → incomplete unless
/// deterministically resolvable to one valid entry (R4, §6).
///
/// Auth compatibility (R2): Bearer first, single raw-token retry only after
/// an unauthorized Bearer response. Missing TOKENS_LIMIT/percentage/reset or
/// an unsuccessful envelope → UNAVAILABLE (empty windows, R4).
public struct ZaiUsageProvider: Sendable {

    public static let usageURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!

    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(session: URLSession = .shared, now: @escaping @Sendable () -> Date = Date.init) {
        self.session = session; self.now = now
    }

    // MARK: - Fetch

    public func fetchUsage(credentials: ZaiCredentials) async throws -> ZaiUsageResult {
        let now = now()
        let data = try await fetchWithAuthRetry(credentials: credentials)
        return ZaiUsageResult(windows: try Self.normalize(data: data, now: now))
    }

    private func fetchWithAuthRetry(credentials: ZaiCredentials) async throws -> Data {
        // Attempt 1: Bearer
        let bearerHeaders = baseHeaders(token: "Bearer \(credentials.apiKey)")
        do {
            let (data, response) = try await performRequest(url: Self.usageURL, headers: bearerHeaders)
            try validateHTTP(response)
            return data
        } catch ZaiUsageError.unauthorized {
            // R2: single raw-token retry only after Bearer got 401/403.
            let rawHeaders = baseHeaders(token: credentials.apiKey)
            let (data, response) = try await performRequest(url: Self.usageURL, headers: rawHeaders)
            try validateHTTP(response)
            return data
        }
    }

    private func performRequest(url: URL, headers: [String: String]) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
     throw ZaiUsageError.transport("cancelled")
 } catch is CancellationError {
     throw ZaiUsageError.transport("cancelled")
 } catch let error as URLError where error.code == .timedOut {
     throw ZaiUsageError.transport("timeout")
 } catch {
     throw ZaiUsageError.transport(String(describing: error))
 }
    }

    private func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ZaiUsageError.transport("non-HTTP response") }
        switch http.statusCode {
        case 200...299: break
        case 401, 403: throw ZaiUsageError.unauthorized(status: http.statusCode)
        case 429: throw ZaiUsageError.rateLimited(retryAfter: Self.retryAfter(from: http))
        default: throw ZaiUsageError.http(status: http.statusCode)
        }
    }

    func baseHeaders(token: String) -> [String: String] {
        [
            "Authorization": token,
            "Accept": "application/json",
            "Accept-Language": "en-US,en",
        ]
    }

    // MARK: - Normalization

    /// Normalize a raw quota response into the single required 5-hour window.
    ///
    /// Unsuccessful envelope (`code != 0` or `success == false`) → empty.
    /// Duplicate TOKENS_LIMIT entries → empty (invalid unless deterministic).
    /// Missing percentage/reset or out-of-bounds → empty (AC3).
    public static func normalize(data: Data, now: Date) throws -> [UsageWindow] {
        do {
            let payload = try JSONDecoder().decode(QuotaResponse.self, from: data)

            // Envelope must be successful. The real API returns code 200 (HTTP-like)
            // with success true, while fixtures use code 0. Treat any 2xx code as success.
            if let code = payload.code, code != 0, !(200...299).contains(code) { return [] }
            if payload.success == false { return [] }

            guard let limits = payload.data?.limits, !limits.isEmpty else { return [] }

            let tokensEntries = limits.filter { $0.type == "TOKENS_LIMIT" }
            // Duplicate required entries are invalid — no deterministic choice.
            if tokensEntries.count != 1 { return [] }

            guard let entry = tokensEntries.first else { return [] }

            // Percentage 0 with no nextResetTime is valid for exhausted/zero usage (e.g. capped plan at cap).
            // For percentage == 0, tolerate missing reset and synthesize a far-future reset so the
            // window can still be stored; the engine will derive availability from used==0 as AVAILABLE.
            // For percentage > 0, nextResetTime is required (R3).
            if entry.percentage == nil { return [] }
            guard let percentage = entry.percentage, percentage.isFinite,
                  percentage >= 0, percentage <= 100 else { return [] }

            let resetAt: Date
            if let nextResetMs = entry.nextResetTime, nextResetMs.isFinite, nextResetMs > 0, nextResetMs < 8_640_000_000_000_000 {
                let parsed = Date(timeIntervalSince1970: nextResetMs / 1000)
                guard parsed.timeIntervalSince1970.isFinite else { return [] }
                // For non-zero usage, stale reset is invalid; for 0% allow past reset (quota just refilled).
                if percentage > 0, parsed < now { return [] }
                resetAt = parsed < now ? now.addingTimeInterval(3600) : parsed
            } else if percentage == 0 {
                // Synthesize a 1-hour future reset for the zero-usage edge case.
                resetAt = now.addingTimeInterval(3600)
            } else {
                return []
            }

            let window = UsageWindow(
                id: .fiveHour, name: UsageWindowKind.fiveHour.displayName, isRequired: true,
                used: percentage, limit: 100, resetAt: resetAt,
                sourceDiagnostics: SourceDiagnostics(sourceKind: "zai-quota", sourceReliability: "official-endpoint", notes: []))
            return [window]
        } catch let error as ZaiUsageError {
            throw error
        } catch {
            throw ZaiUsageError.transport("undecodable quota payload")
        }
    }

    static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let header = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)) { return max(seconds, 0) }
        return nil
    }

    // MARK: - Payload

    struct QuotaResponse: Decodable {
        let code: Int?
        let success: Bool?
        let data: QuotaData?
    }

    struct QuotaData: Decodable {
        let limits: [Limit]?
        let level: String?
    }

    struct Limit: Decodable {
        let type: String
        let percentage: Double?
        let nextResetTime: Double?
        let usage: Double?
        let currentValue: Double?
    }
}
