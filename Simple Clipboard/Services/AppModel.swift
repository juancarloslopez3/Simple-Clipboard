import AppKit
import SwiftData
import SwiftUI

/// Root container that builds the SwiftData stack and wires the services together
/// (CLAUDE.md §6). Owned by `AppDelegate` — created exactly once, never as App `@State`
/// (see `SimpleClipboardApp`) — and injected into every scene.
@MainActor
@Observable
final class AppModel {
    let container: ModelContainer
    let history: HistoryStore
    let monitor: ClipboardMonitor
    let paste: PasteService
    let hotkeys: HotkeyManager

    /// Cross-scene signal for the snippets panel's "New Snippet" button (CLAUDE.md §9/§11): a
    /// detached panel can't host the sheet-based `SnippetEditorView`, so it raises a request the
    /// main window consumes (selects a folder + opens the editor). Injected into the main-window
    /// scene via `.environment`.
    let composer = SnippetComposer()

    /// Presents the first-run intro tutorial (CLAUDE.md §16); shown once from `start()` and
    /// re-openable from Settings › General (injected into the Settings scene).
    let onboarding = OnboardingWindow()

    private var didStart = false

    /// Captured from the scene graph (see `OpenMainWindowCapture`) so AppKit-side surfaces
    /// like the floating panel can open the SwiftUI `Window("main")` — a detached panel's
    /// hosting view has no working scene `openWindow` action of its own.
    var openMainWindow: (() -> Void)?

    /// Pure construction only — build the SwiftData stack and wire the services. **No global
    /// side effects** (no `NSApplication`, monitor, or hotkey registration): this runs inside the
    /// `App`'s property initialization, which SwiftUI may evaluate more than once and before
    /// AppKit is ready. Those effects belong in `start()`, called once after launch.
    init() {
        Pref.registerDefaults()
        // Keep the per-app AppleLanguages override in sync with the stored language pref (§17).
        // Effective on the next launch; the running process keeps the language it started with.
        LanguageSupport.applyOverride(LanguageSupport.current)

        self.container = Self.makeContainer()
        let container = self.container

        // One shared copy-feedback sound for both the capture path (external ⌘C → history)
        // and the internal-selection path (`PasteService`), so both play the same sound (§8a/§13).
        let copySound = CopySound()
        let history = HistoryStore(context: container.mainContext, copySound: copySound)
        let monitor = ClipboardMonitor(history: history)
        let paste = PasteService(history: history, monitor: monitor, copySound: copySound)
        self.history = history
        self.monitor = monitor
        self.paste = paste
        self.hotkeys = HotkeyManager(history: history, paste: paste, container: container)
    }

    /// Run the one-time launch side effects. Called from `AppDelegate.applicationDidFinishLaunching`
    /// so `NSApplication` is fully initialized and this happens exactly once.
    func start() {
        guard !didStart else { return }
        didStart = true

        Self.applyAppearance()
        LaunchAtLogin.syncFromSystem()
        monitor.start()
        hotkeys.register()
        hotkeys.onOpenMainWindow = { [weak self] in self?.presentMainWindow() }
        hotkeys.onNewSnippet = { [weak self] folderID in self?.composeNewSnippet(folderID: folderID) }
        observeTermination()
        onboarding.showIfNeeded()
    }

    /// Handle the snippets panel's "New Snippet" button (CLAUDE.md §9/§11): bring the main window
    /// forward and raise a compose request the main window consumes, targeting the folder the panel's
    /// picker chose (`folderID`, `nil` to fall back to the current/first/new folder). `pendingRequest`
    /// is durable state (not a fire-and-forget edge), so a request made while the window is closed is
    /// still honored once it opens.
    func composeNewSnippet(folderID: UUID?) {
        presentMainWindow()
        composer.requestNewSnippet(folderID: folderID)
    }

    /// Bring the main window forward (CLAUDE.md §10), activating the app first. Falls back to
    /// fronting an already-open main window if the scene action hasn't been captured yet.
    func presentMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let openMainWindow {
            openMainWindow()
        } else if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            existing.makeKeyAndOrderFront(nil)
        }
    }

    /// Build the SwiftData container at a dedicated, app-specific store URL so it never
    /// collides with the shared `default.store` used by other SwiftData apps. If the store
    /// can't be opened (an incompatible schema during development), reset it once.
    private static func makeContainer() -> ModelContainer {
        let schema = Schema([ClipboardItem.self, SnippetFolder.self, Snippet.self])
        let directory = URL.applicationSupportDirectory.appending(path: "SimpleClipboard", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appending(path: "ClipboardData.store")
        let config = ModelConfiguration(schema: schema, url: storeURL)

        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            NSLog("SwiftData store failed to open (\(error)); resetting \(storeURL.lastPathComponent).")
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
            }
            do {
                return try ModelContainer(for: schema, configurations: config)
            } catch {
                fatalError("Unable to create the SwiftData container: \(error)")
            }
        }
    }

    /// Apply the stored appearance preference globally (CLAUDE.md §13 additions).
    static func applyAppearance() {
        let raw = UserDefaults.standard.string(forKey: Pref.Key.appearance) ?? AppAppearance.system.rawValue
        switch AppAppearance(rawValue: raw) ?? .system {
        case .system: NSApplication.shared.appearance = nil
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Honor "Save clipboard history on quit" (CLAUDE.md §8d).
    private func observeTermination() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak history] _ in
            MainActor.assumeIsolated {
                if !Pref.saveHistoryOnQuit { history?.clear() }
            }
        }
    }
}

/// Cross-scene compose signal for the snippets panel's "New Snippet" button (CLAUDE.md §9/§11).
/// The floating panel is detached and can't present the sheet-based `SnippetEditorView`, so it
/// raises `pendingRequest`; `MainWindowView` consumes it (selects/creates a folder + opens the
/// editor) and clears it. It's durable state rather than a fire-once token so a request raised
/// while the main window is closed survives until the window appears and picks it up. Injected via
/// `.environment`, mirroring the panel's other shared `@Observable`s.
@MainActor
@Observable
final class SnippetComposer {
    /// True from when "New Snippet" is pressed until `MainWindowView` opens the editor.
    var pendingRequest = false
    /// The folder the pending New Snippet should target — chosen in the snippets panel's folder
    /// picker (CLAUDE.md §9/§11). `nil` falls back to the current/first/new folder logic.
    /// Consumed (and cleared) alongside `pendingRequest` by `MainWindowView.beginCompose`.
    var folderID: UUID?

    func requestNewSnippet(folderID: UUID? = nil) {
        self.folderID = folderID
        pendingRequest = true
    }
}
