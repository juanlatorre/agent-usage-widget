import SwiftUI
import AgentUsageCore

/// The menu bar icon: the app icon, nothing else. Usage lives in the popover.
struct MenuBarIconView: View {
    var body: some View {
        Image(nsImage: MenuBarIconRenderer.appIconImage())
            .renderingMode(.original)
    }
}

@MainActor
enum MenuBarIconRenderer {
    /// Renders the AppIcon at 18×18pt (36px @2x) once and caches it — the
    /// asset catalog only ships 16/32/128/256/512 sizes, so 32px is scaled down.
    private static var cached: NSImage?

    static func appIconImage() -> NSImage {
        if let cached { return cached }
        let icon = NSApp.applicationIconImage.copy() as? NSImage
            ?? NSImage(named: "AppIcon")
            ?? NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: nil)!
        icon.size = NSSize(width: 18, height: 18)
        cached = icon
        return icon
    }
}
