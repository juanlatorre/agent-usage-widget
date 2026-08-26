import Foundation

/// Errors surfaced by preference store operations.
public enum PreferencesStoreError: Error, Equatable {
    case directoryCreationFailed(String)
    case writeFailed(String)
}

/// Non-secret shared preferences: global display mode and refresh interval.
///
/// Invalid stored values fall back to `.remaining` and `.oneMinute` (child spec R5).
public struct PreferencesStore: Sendable {
    public static let currentSchemaVersion = 1

    public let fileURL: URL
    /// Best-effort mirror locations (App Group container) receiving the same
    /// writes so the sandboxed widget extension sees the same preferences.
    public let mirrorURLs: [URL]

    /// - Parameters:
    ///   - fileURL: full path of the preferences JSON file.
    ///   - mirrors: extra best-effort locations mirrored on writes.
    public init(fileURL: URL, mirrors: [URL] = []) {
        self.fileURL = fileURL
        self.mirrorURLs = mirrors.filter { $0 != fileURL }
    }

    private var fileManager: FileManager { .default }

    /// Default App Group location, with an Application Support fallback for
    /// development builds that lack the entitlement.
    public static func defaultFileURL(appGroupID: String) -> URL? {
        let fileManager = FileManager.default
        if let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return container.appendingPathComponent("preferences.json", isDirectory: false)
        }
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("AgentUsageWidget", isDirectory: true)
            .appendingPathComponent("preferences.json", isDirectory: false)
    }

    // MARK: - Read

    /// Load stored preferences; invalid or absent data yields defaults.
    ///
    /// A corrupt primary record is renamed aside (quarantined) so a future
    /// healthy write can occur; mirror records are consulted when the primary
    /// is absent or unreadable (permission-denied group container).
    public func load() -> DisplayPreferences {
        if let loaded = decodeRecord(at: fileURL, quarantineOnCorrupt: true) {
            return loaded
        }
        for mirror in mirrorURLs {
            if let loaded = decodeRecord(at: mirror, quarantineOnCorrupt: false) {
                return loaded
            }
        }
        return DisplayPreferences()
    }

    private func decodeRecord(at url: URL, quarantineOnCorrupt: Bool) -> DisplayPreferences? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let wrapper = try decoder.decode(PreferencesFile.self, from: data)
            return wrapper.preferences.sanitized()
        } catch {
            if quarantineOnCorrupt { quarantineCorruptRecord() }
            return nil
        }
    }

    // MARK: - Write

    /// Persist preferences atomically. A failed write leaves the previous file intact;
    /// in-memory state remains valid regardless. Mirrors are best-effort.
    public func save(_ preferences: DisplayPreferences) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let wrapper = PreferencesFile(version: Self.currentSchemaVersion, preferences: preferences)
        let data: Data
        do {
            data = try encoder.encode(wrapper)
        } catch {
            throw PreferencesStoreError.writeFailed(String(describing: error))
        }
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            let primary = error
            // Fall back to the first mirror that accepts the write.
            for mirror in mirrorURLs {
                if (try? writeMirror(data, to: mirror)) != nil { return }
            }
            throw PreferencesStoreError.writeFailed(String(describing: primary))
        }
        for mirror in mirrorURLs {
            _ = try? writeMirror(data, to: mirror)
        }
    }

    private func writeMirror(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Plumbing

    struct PreferencesFile: Codable {
        let version: Int
        let preferences: DisplayPreferences
    }

    private func quarantineCorruptRecord() {
        let stamp = Int(Date().timeIntervalSince1970)
        let target = fileURL.deletingLastPathComponent()
            .appendingPathComponent("preferences-corrupt-\(stamp).json")
        _ = try? fileManager.moveItem(at: fileURL, to: target)
        NSLog("[AgentUsageCore] quarantined corrupt preferences file")
    }
}

extension DisplayPreferences {
    /// Coerce out-of-range or unknown values to safe defaults.
    func sanitized() -> DisplayPreferences {
        var copy = self
        if !DisplayPreferences.DisplayMode.allCases.contains(copy.displayMode) {
            copy.displayMode = .remaining
        }
        if !DisplayPreferences.RefreshInterval.allCases.contains(copy.refreshInterval) {
            copy.refreshInterval = .oneMinute
        }
        return copy
    }
}
