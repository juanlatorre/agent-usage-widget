import Foundation

/// Persists Small/Medium selection for WidgetKit configuration.
/// Small: exactly one slot. Medium: 1–3 distinct slots.
/// Large: implicitly all six (no persisted selection). Raw IDs only, no secrets.
public struct AgentWidgetConfiguration: Codable, Sendable, Equatable {

    /// Stable suffix used to namespace files per widget configuration.
    public let identifier: String
    /// When persisted, the selected slots for this configuration.
    /// For Small, one entry; for Medium, 1–3. Empty means unconfigured.
    public let selectedSlotIDs: [AccountSlotID]

    public init(identifier: String, selectedSlotIDs: [AccountSlotID]) {
        self.identifier = identifier
        self.selectedSlotIDs = selectedSlotIDs
    }

    /// Validate for Small: exactly one connected-ish slot (unknown IDs are rejected).
    public var isValidSmall: Bool {
        selectedSlotIDs.count == 1
    }

    /// Validate for Medium: 1–3 distinct, all known.
    public var isValidMedium: Bool {
        guard (1...3).contains(selectedSlotIDs.count) else { return false }
        return Set(selectedSlotIDs).count == selectedSlotIDs.count
    }

    /// Fallback when stored config is invalid: nil so widget shows unconfigured state (R9, §6).
    public func sanitized(for family: WidgetFamily) -> AgentWidgetConfiguration? {
        switch family {
        case .small: return isValidSmall ? self : nil
        case .medium: return isValidMedium ? self : nil
        case .large: return self // large ignores selection entirely (always all six)
        }
    }
}

/// Namespace-isolated family to avoid colliding with WidgetKit.WidgetFamily.
public enum WidgetFamily: String, Codable, Sendable { case small, medium, large }
/// Deprecated alias retained for call sites that qualified with module prefix.
public typealias AgentWidgetFamily = WidgetFamily

/// Persists widget configurations alongside snapshots/preferences in the App Group (or Application Support fallback).
/// The widget extension and the app both read these; the widget never writes them.
public struct AgentWidgetConfigurationStore: Sendable {
    public let baseURL: URL
    public init(baseURL: URL) { self.baseURL = baseURL }

    public static func defaultBaseURL(appGroupID: String) -> URL? {
        let fm = FileManager.default
        if let container = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return container.appendingPathComponent("widget-configs", isDirectory: true)
        }
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return appSupport.appendingPathComponent("AgentUsageWidget", isDirectory: true).appendingPathComponent("widget-configs", isDirectory: true)
    }

    public func load(identifier: String) -> AgentWidgetConfiguration? {
        let url = fileURL(for: identifier)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(AgentWidgetConfiguration.self, from: data) else {
            return nil
        }
        return cfg
    }

    public func save(_ configuration: AgentWidgetConfiguration) throws {
        let dir = baseURL
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder().encode(configuration)
        try data.write(to: fileURL(for: configuration.identifier), options: .atomic)
    }

    public func remove(identifier: String) {
        try? FileManager.default.removeItem(at: fileURL(for: identifier))
    }

    private func fileURL(for identifier: String) -> URL {
        baseURL.appendingPathComponent("\(identifier).json")
    }
}

@available(*, deprecated, renamed: "AgentWidgetConfiguration")
public typealias WidgetConfiguration = AgentWidgetConfiguration
@available(*, deprecated, renamed: "AgentWidgetConfigurationStore")
public typealias WidgetConfigurationStore = AgentWidgetConfigurationStore
