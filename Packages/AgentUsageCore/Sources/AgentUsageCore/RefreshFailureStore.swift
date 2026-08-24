import Foundation

/// Persists per-slot refresh failure metadata atomically.
/// Failures are non-secret: category, attempt time, next retry, sanitized message.
/// Snapshots themselves remain unchanged (parent R5).
public struct RefreshFailureStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultFileURL(appGroupID: String) -> URL? {
        let fm = FileManager.default
        if let container = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return container.appendingPathComponent("refresh-failures.json")
        }
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return appSupport.appendingPathComponent("AgentUsageWidget", isDirectory: true).appendingPathComponent("refresh-failures.json")
    }

    public func load() -> [AccountSlotID: RefreshFailureRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: RefreshFailureRecord].self, from: data) else {
            return [:]
        }
        var result: [AccountSlotID: RefreshFailureRecord] = [:]
        for (raw, rec) in decoded where AccountSlotID(rawValue: raw) != nil {
            if let slot = AccountSlotID(rawValue: raw) { result[slot] = rec }
        }
        return result
    }

    public func save(_ records: [AccountSlotID: RefreshFailureRecord]) throws {
        let dir = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var encoded: [String: RefreshFailureRecord] = [:]
        for (slot, rec) in records { encoded[slot.rawValue] = rec }
        let data = try JSONEncoder().encode(encoded)
        try data.write(to: fileURL, options: .atomic)
    }

    public func remove(slotID: AccountSlotID) {
        var records = load()
        records[slotID] = nil
        try? save(records)
    }

    public func set(_ record: RefreshFailureRecord?, for slotID: AccountSlotID) {
        var records = load()
        records[slotID] = record
        try? save(records)
    }

    public func clearAll() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
