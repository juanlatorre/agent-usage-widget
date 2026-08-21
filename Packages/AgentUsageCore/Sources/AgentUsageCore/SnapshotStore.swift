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

    /// - Parameter baseURL: directory holding one JSON file per slot.
    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    private var fileManager: FileManager { .default }

    /// Default App Group location when the group is unavailable falls back to
    /// Application Support so development builds keep working without entitlements.
    public static func defaultBaseURL(appGroupID: String) -> URL? {
        let fileManager = FileManager.default
        if let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return container.appendingPathComponent("snapshots", isDirectory: true)
        }
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("AgentUsageWidget", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
    }

    // MARK: - Read

    /// Load the valid snapshot for one slot, or nil when absent/invalid.
    ///
    /// Corrupt or unknown-schema records are quarantined and reported as nil without
    /// affecting other slots.
    @discardableResult
    public func load(slotID: AccountSlotID, now: Date = Date()) -> LoadOutcome {
        let url = recordURL(for: slotID)
        guard fileManager.fileExists(atPath: url.path) else { return .absent }

        do {
            let data = try Data(contentsOf: url)
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
    /// so an interrupted write leaves the previous record intact.
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
            throw SnapshotStoreError.writeFailed(String(describing: error))
        }
    }

    /// Remove the stored record for one slot only; other slots are unaffected.
    public func remove(slotID: AccountSlotID) {
        try? fileManager.removeItem(at: recordURL(for: slotID))
    }

    // MARK: - Plumbing

    private func recordURL(for slotID: AccountSlotID) -> URL {
        baseURL.appendingPathComponent("\(slotID.rawValue).json")
    }

    private func ensureDirectory() throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: baseURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return
        }
        do {
            try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
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
