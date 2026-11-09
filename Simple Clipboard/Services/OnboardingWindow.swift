import AppKit
import SwiftUI

/// Presents the first-run intro tutorial (CLAUDE.md §16) in its own AppKit-hosted window —
/// an `NSWindow` + `NSHostingView` like the floating panel, so it can be shown from
/// `AppModel.start()` without needing a scene `openWindow` action. Shown once at first
/// launch (`showIfNeeded`) and re-openable from Settings › General ("Show Again").
/// `@Observable` so it rides the same `.environment` injection as the other services.
@MainActor
@Observable
final class OnboardingWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    /// First-launch entry point. `didShowOnboarding` is recorded **as soon as** the tour is
    /// presented — not when it finishes — so quitting or closing mid-tour doesn't re-trigger
    /// it on every launch; deliberate repeats go through the Settings button.
    func showIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Pref.Key.didShowOnboarding) else { return }
        show()
    }

    /// Present (or re-present) the tutorial, always from its first page.
    func show() {
        UserDefaults.standard.set(true, forKey: Pref.Key.didShowOnboarding)
        let window = self.window ?? makeWindow()
        self.window = window
        // A fresh root view each show so a repeat run starts back at page one.
        window.contentView = NSHostingView(rootView: OnboardingView { [weak self] in
            self?.window?.close()
        })
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Fires for both the "Get Started" finish and the titlebar close button. Tear the hosted
    /// view down so the demos' animation `.task` loops stop with the window, and drop the
    /// window itself — it's cheap to rebuild on a repeat showing.
    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window?.delegate = nil
        window = nil
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Welcome to Simple Clipboard")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }
}
