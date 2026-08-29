import SwiftUI
import AgentUsageCore

/// The menu bar icon: a gauge glyph rendered as a template, so macOS tints it
/// exactly like the other menu bar icons (white in dark mode, black in light).
struct MenuBarIconView: View {
    var body: some View {
        Image(systemName: "gauge.with.needle")
            .renderingMode(.template)
    }
}
