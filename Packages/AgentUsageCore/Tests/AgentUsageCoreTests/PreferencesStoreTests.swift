import Testing
import Foundation
@testable import AgentUsageCore

/// Preference store tests: defaults, sanitization, and atomic replacement.
@Suite struct PreferencesStoreTests {

    private func makeStore() throws -> (PreferencesStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentusage-prefs-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("preferences.json")
        return (PreferencesStore(fileURL: url), url)
    }

    @Test func defaultsWhenAbsent() throws {
        let (store, _) = try makeStore()
        let prefs = store.load()
        #expect(prefs.displayMode == .remaining)
        #expect(prefs.refreshInterval == .fiveMinutes)
    }

    @Test func roundTripPreservesValues() throws {
        let (store, _) = try makeStore()
        var prefs = DisplayPreferences()
        prefs.displayMode = .used
        prefs.refreshInterval = .fiveMinutes
        try store.save(prefs)
        #expect(store.load() == prefs)
    }

    @Test func invalidStoredValuesFallBackToDefaults() throws {
        // Hand-write a file containing out-of-catalog values.
        let (store, url) = try makeStore()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = """
        {
          "version": 1,
          "preferences": {
            "displayMode": "sideways",
            "refreshInterval": 9999
          }
        }
        """
        try Data(json.utf8).write(to: url)

        let prefs = store.load()
        #expect(prefs.displayMode == .remaining)
        #expect(prefs.refreshInterval == .fiveMinutes)
    }

    @Test func corruptFileIsQuarantinedAndDefaultsApply() throws {
        let (store, url) = try makeStore()
        // First write valid data so the directory exists, then corrupt it.
        try store.save(DisplayPreferences(displayMode: .used, refreshInterval: .thirtySeconds))
        try Data("not-json-at-all".utf8).write(to: url)

        let prefs = store.load()
        #expect(prefs.displayMode == .remaining)
        #expect(prefs.refreshInterval == .fiveMinutes)

        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(leftovers.contains { $0.hasPrefix("preferences-corrupt-") })
    }
}
