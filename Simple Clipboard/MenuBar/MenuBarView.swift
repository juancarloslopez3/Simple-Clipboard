import AppKit
import SwiftUI

/// The menu-bar dropdown content (CLAUDE.md §1a / §9). Renders as a native menu, so
/// Liquid Glass is applied automatically — no `.glassEffect` here. History and snippets
/// live in the floating panel (⌘⇧V / ⌘⇧B) and the main window; this dropdown is just a
/// compact action menu.
struct MenuBarView: View {
    @Environment(HistoryStore.self) private var history
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Link(destination: URL(string: "https://github.com/juancarloslopez3/simple-clipboard")!) {
            Label("Star on GitHub", systemImage: "star")
        }
        Button {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Label("Main Window", systemImage: "macwindow")
        }
        Button {
            history.clear()
        } label: {
            Label("Clear History", systemImage: "trash")
        }
        SettingsLink {
            Label("Preferences…", systemImage: "gearshape")
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Label("Quit", systemImage: "power")
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
