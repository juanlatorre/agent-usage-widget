import Foundation

/// Errors surfaced by snapshot store operations.
public enum SnapshotStoreError: Error, Equatable, Sendable {
    case directoryCreationFailed(String)
    case writeFailed(String)
}

/// Atomic, per-slot persistence for usage snapshots in a shared non-secret container.
///
/// Contract (child spec R3/R4):
/// - writes are atomic per slot: an interrupted write cannot destroy the previous record;
/// - a corrupt or unknown-schema record is quarantined, not deleted;
/// - one slot's failure never prevents other slots from loading.
public struct SnapshotStore: Sendable {
    /// Current on-disk storage schema version. Records with a different version are ignored.
    public static let currentSchemaVersion = 1

    public let baseURL: URL
    /// Additional locations that also receive writes and are consulted on
    /// reads (newest record wins). Keeps the sandboxed widget extension in
    /// sync when the primary location is not shared with it.
    public let mirrorURLs: [URL]

    /// - Parameters:
    ///   - baseURL: directory holding one JSON file per slot.
    ///   - mirrors: extra best-effort locations mirrored on writes.
    public init(baseURL: URL, mirrors: [URL] = []) {
        self.baseURL = baseURL
        self.mirrorURLs = mirrors.filter { $0 != baseURL }
    }

    private var fileManager: FileManager { .default }

    /// Default location: the App Group container when the system resolves one,
    /// otherwise Application Support so development/Developer-ID builds keep
    /// working without a provisioned group.
    public static func defaultBaseURL(appGroupID: String) -> URL? {
        let fileManager = FileManager.default
        if let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return container.appendingPathComponent("snapshots", isDirectory: true)
        }
        return appSupportBaseURL()
    }

    /// Application Support base shared with pre-group builds and used as a
    /// write fallback when the group container exists but is not writable
    /// (Developer ID builds without a provisioning profile get EPERM there).
    public static func appSupportBaseURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("AgentUsageWidget", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
    }

    /// The App Group directory by direct path, even when `containerURL(…)`
    /// returns nil (unsandboxed main app). Used to mirror snapshots so the
    /// sandboxed widget extension keeps seeing fresh data.
    public static func groupContainerBaseURL(appGroupID: String) -> URL? {
        let fm = FileManager.default
        if let container = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return container.appendingPathComponent("snapshots", isDirectory: true)
        }
        let home = fm.homeDirectoryForCurrentUser
        let group = home
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent(appGroupID, isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
        return fm.fileExists(atPath: group.deletingLastPathComponent().path) ? group : nil
    }

    // MARK: - Read

    /// Load the valid snapshot for one slot, or nil when absent/invalid.
    ///
    /// Corrupt or unknown-schema records are quarantined and reported as nil
    /// without affecting other slots. Permission errors (sandbox denial on an
    /// unprovisioned group container) are treated as absent — never quarantined.
    /// When both the primary and the mirror hold records, the newer one wins.
    @discardableResult
    public func load(slotID: AccountSlotID, now: Date = Date()) -> LoadOutcome {
        let primary = readRecord(at: recordURL(for: slotID))
        let mirrors = mirrorURLs
            .map { readRecord(at: $0.appendingPathComponent("\(slotID.rawValue).json")) }
            .compactMap { outcome -> UsageSnapshot? in
                if case let .loaded(snapshot) = outcome { return snapshot }
                return nil
            }
        if case let .loaded(a) = primary {
            let newestMirror = mirrors.max { $0.capturedAt < $1.capturedAt }
            if let newestMirror, newestMirror.capturedAt > a.capturedAt {
                return .loaded(newestMirror)
            }
            return .loaded(a)
        }
        if let newestMirror = mirrors.max(by: { $0.capturedAt < $1.capturedAt }) {
            return .loaded(newestMirror)
        }
        if let primary { return primary }
        return .absent
    }

    /// Read one record; permission failures map to nil (absent), decode and
    /// schema failures quarantine only the record actually read.
    private func readRecord(at url: URL) -> LoadOutcome? {
        guard fileManager.fileExists(atPath: url.path) else { return .absent }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            // EPERM/EACCES/257: the sandbox denies this container — not corruption.
            return .absent
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let wrapper = try decoder.decode(SnapshotFile.self, from: data)
            return .loaded(wrapper.snapshot)
        } catch let error as StoreDecodeError where error.isSchemaVersionMismatch {
            quarantine(recordAt: url, reason: "schema version mismatch")
            return .quarantined(reason: "schema version mismatch")
        } catch {
            quarantine(recordAt: url, reason: String(describing: error))
            return .quarantined(reason: "decode failed")
        }
    }

    public enum LoadOutcome: Equatable, Sendable {
        case absent
        case loaded(UsageSnapshot)
        case quarantined(reason: String)
    }

    /// File wrapper adding storage-level schema versioning around the payload.
    struct SnapshotFile: Codable {
        let version: Int
        let snapshot: UsageSnapshot

        enum CodingKeys: String, CodingKey {
            case version, snapshot
        }

        init(version: Int, snapshot: UsageSnapshot) {
            self.version = version
            self.snapshot = snapshot
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)

            // Unknown future storage versions must not be trusted or overwritten.
            guard version == SnapshotStore.currentSchemaVersion else {
                throw StoreDecodeError.schemaVersionMismatch
            }
            snapshot = try container.decode(UsageSnapshot.self, forKey: .snapshot)
        }
    }

    // MARK: - Write

    /// Persist a snapshot atomically for one slot.
    ///
    /// Uses write-to-temp + atomic rename semantics via `Data.write(options: .atomic)`,
    /// so an interrupted write leaves the previous record intact. Falls back to
    /// the shared Application Support mirror when the primary location denies
    /// writes (unprovisioned group container), so results are never lost.
    public func save(_ snapshot: UsageSnapshot) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let wrapper = SnapshotFile(version: SnapshotStore.currentSchemaVersion, snapshot: snapshot)
        let data = try encoder.encode(wrapper)
        do {
            try data.write(to: recordURL(for: snapshot.slotID), options: .atomic)
        } catch {
            let primary = error
            if firstWritableFallback(slotID: snapshot.slotID, data: data) {
                let ns = primary as NSError
                NSLog("[AgentUsageCore] snapshot \(snapshot.slotID.rawValue) fell back after %@/%d", ns.domain, ns.code)
                return
            }
            throw SnapshotStoreError.writeFailed(String(describing: primary))
        }
        mirrorWrite(slotID: snapshot.slotID, data: data)
    }

    /// Best-effort mirror so every potential reader (app, widget extension)
    /// sees the same fresh record. Failures are ignored by design.
    private func mirrorWrite(slotID: AccountSlotID, data: Data) {
        for base in mirrorURLs {
            do {
                try ensureDirectory(at: base)
                try data.write(to: base.appendingPathComponent("\(slotID.rawValue).json"), options: .atomic)
            } catch {
                let ns = error as NSError
                NSLog("[AgentUsageCore] snapshot mirror \(slotID.rawValue) skipped after %@/%d", ns.domain, ns.code)
            }
        }
    }

    /// Write the record to the first fallback location that accepts it.
    private func firstWritableFallback(slotID: AccountSlotID, data: Data) -> Bool {
        let candidates = [Self.appSupportBaseURL(), baseURL].compactMap { $0 }.filter { $0 != baseURL }
        for base in candidates {
            do {
                try ensureDirectory(at: base)
                try data.write(to: base.appendingPathComponent("\(slotID.rawValue).json"), options: .atomic)
                return true
            } catch { continue }
        }
        return false
    }

    /// Remove the stored record for one slot only; other slots are unaffected.
    public func remove(slotID: AccountSlotID) {
        try? fileManager.removeItem(at: recordURL(for: slotID))
        for mirror in mirrorURLs {
            try? fileManager.removeItem(at: mirror.appendingPathComponent("\(slotID.rawValue).json"))
        }
    }

    // MARK: - Plumbing

    private func recordURL(for slotID: AccountSlotID) -> URL {
        baseURL.appendingPathComponent("\(slotID.rawValue).json")
    }

    private func ensureDirectory() throws {
        try ensureDirectory(at: baseURL)
    }

    private func ensureDirectory(at base: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: base.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return
        }
        do {
            try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            throw SnapshotStoreError.directoryCreationFailed(String(describing: error))
        }
    }

    /// Move an unreadable record aside instead of deleting it, then log a sanitized note.
    private func quarantine(recordAt url: URL, reason: String) {
        let stamp = Int(Date().timeIntervalSince1970)
        let target = baseURL.appendingPathComponent("quarantine-\(slotFileName(from: url))-\(stamp).json")
        _ = try? fileManager.moveItem(at: url, to: target)
        // Sanitized note only — no payload contents are logged anywhere.
        NSLog("[AgentUsageCore] quarantined %@: %@", url.lastPathComponent, reason)
    }

    private func slotFileName(from url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}
