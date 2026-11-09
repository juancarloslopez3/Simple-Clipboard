import AppKit
import SwiftUI

@main
@MainActor
struct SimpleClipboardApp: App {
    // The model is owned by the app delegate, not a `@State`: an `App`'s property initializers
    // can be re-evaluated by SwiftUI on UI events, so a side-effectful `AppModel()` there would
    // be reconstructed repeatedly (and crash touching AppKit too early). The delegate is created
    // exactly once and starts the model after launch.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(Pref.Key.showMenuBarIcon) private var showMenuBarIcon = Pref.Default.showMenuBarIcon

    private var model: AppModel { appDelegate.model }

    var body: some Scene {
        // 1a. Menu-bar dropdown — native menu, Liquid Glass automatically (CLAUDE.md §9).
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarView()
                .modelContainer(model.container)
                .environment(model.paste)
                .environment(model.history)
        } label: {
            // The label renders at launch, so it's a reliable point to hand the scene's real
            // `openWindow` action to the model for the floating panel's "Main Window" button.
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.menu)

        // 1b. Main window — two-pane browser (CLAUDE.md §10).
        Window("Simple Clipboard", id: "main") {
            MainWindowView()
                .modelContainer(model.container)
                .environment(model.paste)
                .environment(model.history)
                .environment(model.composer)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 920, height: 620)

        // Preferences (CLAUDE.md §13).
        Settings {
            SettingsView()
                .modelContainer(model.container)
                .environment(model.history)
                .environment(model.onboarding)
        }
    }
}

/// The menu-bar status item. Besides drawing the icon, it captures the scene-level
/// `openWindow` action into the model so the detached floating panel can open `Window("main")`.
private struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "doc.on.clipboard")
            .accessibilityLabel("Simple Clipboard")
            .onAppear { model.openMainWindow = { openWindow(id: "main") } }
    }
}

/// Owns the single `AppModel` and runs its launch side effects once, after AppKit is ready
/// (CLAUDE.md Architecture). Using a delegate keeps `AppModel` from being reconstructed when
/// SwiftUI re-evaluates the `App`'s properties on UI events.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    /// This is a menu-bar **agent** (`LSUIElement`): closing the floating `ClipboardPanel` or the
    /// main window must never quit the app — the `MenuBarExtra` keeps it alive, and the user quits
    /// explicitly via the menu. Because we supply a custom delegate, AppKit would otherwise
    /// terminate the process when the last window closes. (Explicit `terminate(_:)`/⌘Q still quits.)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
