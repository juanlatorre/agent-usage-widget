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

    /// - Parameter fileURL: full path of the preferences JSON file.
    public init(fileURL: URL) {
        self.fileURL = fileURL
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
    /// A corrupt record is renamed aside (quarantined) so a future healthy write can occur.
    public func load() -> DisplayPreferences {
        guard fileManager.fileExists(atPath: fileURL.path) else { return DisplayPreferences() }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            let wrapper = try decoder.decode(PreferencesFile.self, from: data)
            return wrapper.preferences.sanitized()
        } catch {
            quarantineCorruptRecord()
            return DisplayPreferences()
        }
    }

    // MARK: - Write

    /// Persist preferences atomically. A failed write leaves the previous file intact;
    /// in-memory state remains valid regardless.
    public func save(_ preferences: DisplayPreferences) throws {
        let directory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw PreferencesStoreError.directoryCreationFailed(String(describing: error))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let wrapper = PreferencesFile(version: Self.currentSchemaVersion, preferences: preferences)
        do {
            let data = try encoder.encode(wrapper)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw PreferencesStoreError.writeFailed(String(describing: error))
        }
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
