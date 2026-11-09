import AppKit
import Foundation

/// In-app language switching (CLAUDE.md §17). macOS chooses a bundle's localization from the
/// per-app `AppleLanguages` override (the same key System Settings › General › Language & Region
/// writes for an app), read once at launch — so switching language means writing that key and
/// relaunching. `system` removes the override so the OS decides: Spanish or English are matched
/// against the app's localizations, anything else falls back to the development region (English).
enum LanguageSupport {
    private static let appleLanguagesKey = "AppleLanguages"

    /// The user's stored language choice (defaults to `.system`).
    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: Pref.Key.appLanguage) ?? "") ?? .system
    }

    /// Reconcile the per-app `AppleLanguages` override with `language`. Called at launch (so the
    /// override always matches the stored pref) and whenever the picker changes. It takes effect on
    /// the **next** launch — `Bundle.main` resolves its localization before `main()`, so the running
    /// process keeps its current language until relaunched (`relaunch()`).
    static func applyOverride(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        if let code = language.languageCode {
            defaults.set([code], forKey: appleLanguagesKey)
        } else {
            // Back to system: drop the app-domain override so the global language order applies.
            defaults.removeObject(forKey: appleLanguagesKey)
        }
    }

    /// Relaunch the app so the new language is picked up. Launches a fresh instance, then quits this
    /// one; the agent (`LSUIElement`) has no documents to lose and its data is persisted in SwiftData.
    @MainActor
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
