import Foundation

/// Shared dual-location persistence helpers.
///
/// Developer ID builds without a provisioning profile get a Group Container
/// the sandbox denies (EPERM/513) or `containerURL(…)` cannot resolve at all.
/// The stable strategy is: canonical Application Support (always writable by
/// the app) plus best-effort mirrors — crucially the Group Container by direct
/// path — so the sandboxed widget extension observes the same state.
public enum SharedStoreLocations {

    /// App Group identifier (iOS-style). Developer ID builds resolve no
    /// blessed container for it — sharing happens via the widget-extension
    /// container mirror below plus this group's direct path.
    public static let canonicalAppGroupID = "group.com.juanlatorre.agent-usage"

    /// `~/Library/Application Support/AgentUsageWidget` — the app-writable
    /// canonical location shared with pre-group builds.
    public static func appSupportDirectory() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport.appendingPathComponent("AgentUsageWidget", isDirectory: true)
    }

    /// The widget extension's own sandbox container — the one location a
    /// sandboxed widget can always read. The unsandboxed main app mirrors
    /// shared state here by direct path (no provisioning profile needed).
    public static let widgetBundleID = "com.juanlatorre.AgentUsage.widget"

    public static func widgetContainerDirectory() -> URL? {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(widgetBundleID, isDirectory: true)
            .appendingPathComponent("Data/Library/Application Support/AgentUsageWidget", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    /// The App Group container: the system-resolved URL when available,
    /// otherwise the well-known direct path when the directory exists
    /// (usable by an unsandboxed main app for mirroring). Tries the canonical
    /// Team-prefixed group first, then the legacy one.
    public static func groupContainer(appGroupID: String) -> URL? {
        let fm = FileManager.default
        if let container = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return container
        }
        let direct = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent(appGroupID, isDirectory: true)
        return fm.fileExists(atPath: direct.path) ? direct : nil
    }

    /// Best canonical group container across both group identifiers.
    public static func anyGroupContainer() -> URL? {
        groupContainer(appGroupID: canonicalAppGroupID)
    }

    /// The canonical group container, created when missing. Only the
    /// unsandboxed main app may call this.
    public static func ensureCanonicalGroupContainer() -> URL? {
        let fm = FileManager.default
        if let resolved = fm.containerURL(forSecurityApplicationGroupIdentifier: canonicalAppGroupID) {
            return resolved
        }
        let direct = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent(canonicalAppGroupID, isDirectory: true)
        do {
            try fm.createDirectory(at: direct, withIntermediateDirectories: true)
            return direct
        } catch {
            NSLog("[AgentUsageCore] could not create canonical group container: %@", String(describing: error))
            return nil
        }
    }

    /// Standard mirror set for a file named `fileName`: the Application
    /// Support directory and the App Group container, deduplicated against
    /// (and excluding) the primary URL.
    ///
    /// Mirrors only participate for canonical storage locations — arbitrary
    /// primaries (unit-test temp directories) stay fully isolated.
    public static func mirrorURLs(forFileName fileName: String, primary: URL?, appGroupID: String = SharedStoreLocations.canonicalAppGroupID) -> [URL] {
        if let primary, !isCanonicalLocation(primary, appGroupID: appGroupID) {
            return []
        }
        var urls: [URL] = []
        if let appSupport = appSupportDirectory() {
            urls.append(appSupport.appendingPathComponent(fileName, isDirectory: false))
        }
        // The widget-extension container is the one place a sandboxed widget
        // can read without a provisioned app group — always mirror there.
        if let widgetContainer = widgetContainerDirectory() {
            urls.append(widgetContainer.appendingPathComponent(fileName, isDirectory: false))
        }
        if let group = groupContainer(appGroupID: appGroupID) {
            urls.append(group.appendingPathComponent(fileName, isDirectory: false))
        }
        if let primary {
            urls = urls.filter { $0 != primary }
        }
        return urls
    }

    /// True when `url` lives inside one of the app's canonical storage roots.
    private static func isCanonicalLocation(_ url: URL, appGroupID: String) -> Bool {
        let path = url.path
        if let group = groupContainer(appGroupID: appGroupID)?.path, path.hasPrefix(group) { return true }
        if let appSupport = appSupportDirectory()?.path, path.hasPrefix(appSupport) { return true }
        if let widgetContainer = widgetContainerDirectory()?.path, path.hasPrefix(widgetContainer) { return true }
        return false
    }

    /// Write `data` to every location that accepts it (primary first).
    /// Throws only when no location accepted the write, surfacing the
    /// primary location's error.
    public static func writeMirrored(_ data: Data, primary: URL, mirrors: [URL]) throws {
        var primaryError: Error?
        var wroteAny = false
        for url in [primary] + mirrors {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                wroteAny = true
            } catch {
                if url == primary { primaryError = error }
                let ns = error as NSError
                NSLog("[AgentUsageCore] mirror write skipped %@ after %@/%d", url.lastPathComponent, ns.domain, ns.code)
            }
        }
        if !wroteAny {
            throw primaryError ?? CocoaError(.fileWriteUnknown)
        }
    }
}
