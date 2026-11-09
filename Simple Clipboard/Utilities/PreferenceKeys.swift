import Foundation

/// Single source of truth for every `@AppStorage` preference key and its default
/// value (CLAUDE.md §13 / §16). Never scatter raw `UserDefaults` string keys elsewhere.
enum Pref {

    /// Stable `UserDefaults` key strings.
    enum Key {
        // General
        static let openAtLogin = "openAtLogin"
        static let historySize = "historySize"
        static let inlineItemCount = "inlineItemCount"
        static let folderSize = "folderSize"
        static let ignoreLargerThanMB = "ignoreLargerThanMB"
        static let ignoreLargerThanUnit = "ignoreLargerThanUnit"   // display/entry unit for ignoreLargerThanMB
        static let saveHistoryOnQuit = "saveHistoryOnQuit"
        static let alwaysPastePlainText = "alwaysPastePlainText"
        static let trimWhitespacePreview = "trimWhitespacePreview"

        // General — suggested additions
        static let pasteOnSelect = "pasteOnSelect"      // reserved (copy-only this build, §12)
        static let playSoundOnCopy = "playSoundOnCopy"
        static let appearance = "appearance"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let appLanguage = "appLanguage"          // in-app language override (§17)

        // Privacy
        static let ignoredAppBundleIDs = "ignoredAppBundleIDs"

        // Onboarding (§16)
        static let didShowOnboarding = "didShowOnboarding"
    }

    /// Default values, mirrored into `registerDefaults()`.
    enum Default {
        static let openAtLogin = true
        static let historySize = 50
        static let inlineItemCount = 5
        static let folderSize = 5
        static let ignoreLargerThanMB = 20
        static let ignoreLargerThanUnit = SizeUnit.mb.rawValue
        static let saveHistoryOnQuit = true
        static let alwaysPastePlainText = false
        static let trimWhitespacePreview = true

        static let pasteOnSelect = false   // synthetic-paste path deferred; copy-only
        static let playSoundOnCopy = false
        static let appearance = AppAppearance.system.rawValue
        static let showMenuBarIcon = true
        static let appLanguage = AppLanguage.system.rawValue

        static let ignoredAppBundleIDs: [String] = []

        static let didShowOnboarding = false
    }

    /// Register defaults once at launch so first reads return the intended values.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.openAtLogin: Default.openAtLogin,
            Key.historySize: Default.historySize,
            Key.inlineItemCount: Default.inlineItemCount,
            Key.folderSize: Default.folderSize,
            Key.ignoreLargerThanMB: Default.ignoreLargerThanMB,
            Key.ignoreLargerThanUnit: Default.ignoreLargerThanUnit,
            Key.saveHistoryOnQuit: Default.saveHistoryOnQuit,
            Key.alwaysPastePlainText: Default.alwaysPastePlainText,
            Key.trimWhitespacePreview: Default.trimWhitespacePreview,
            Key.pasteOnSelect: Default.pasteOnSelect,
            Key.playSoundOnCopy: Default.playSoundOnCopy,
            Key.appearance: Default.appearance,
            Key.showMenuBarIcon: Default.showMenuBarIcon,
            Key.appLanguage: Default.appLanguage,
            Key.ignoredAppBundleIDs: Default.ignoredAppBundleIDs,
            Key.didShowOnboarding: Default.didShowOnboarding,
        ])
    }

    /// Upper bound for the "ignore items larger than" limit, in MB (= 100 GB).
    static let maxIgnoreSizeMB = 102_400

    // MARK: Convenience accessors for non-`@AppStorage` reads (services).

    static var historySize: Int { UserDefaults.standard.integer(forKey: Key.historySize) }
    static var inlineItemCount: Int { UserDefaults.standard.integer(forKey: Key.inlineItemCount) }
    static var folderSize: Int { max(1, UserDefaults.standard.integer(forKey: Key.folderSize)) }
    static var ignoreLargerThanBytes: Int { UserDefaults.standard.integer(forKey: Key.ignoreLargerThanMB) * 1_048_576 }
    static var saveHistoryOnQuit: Bool { UserDefaults.standard.bool(forKey: Key.saveHistoryOnQuit) }
    static var alwaysPastePlainText: Bool { UserDefaults.standard.bool(forKey: Key.alwaysPastePlainText) }
    static var trimWhitespacePreview: Bool { UserDefaults.standard.bool(forKey: Key.trimWhitespacePreview) }
    static var playSoundOnCopy: Bool { UserDefaults.standard.bool(forKey: Key.playSoundOnCopy) }

    static var ignoredAppBundleIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: Key.ignoredAppBundleIDs) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Key.ignoredAppBundleIDs) }
    }
}

/// Unit for the "ignore items larger than" size limit (General tab). The limit is
/// always stored canonically in MB (`ignoreLargerThanMB`); this only selects how it
/// is displayed and entered. 1 GB = 1024 MB.
enum SizeUnit: String, CaseIterable, Identifiable, Sendable {
    case mb = "MB"
    case gb = "GB"
    var id: String { rawValue }
    var label: String { rawValue }
    static let mbPerGB = 1024
}

/// Appearance options for the General tab.
enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }
}

/// In-app interface language (General tab, §17). `system` follows the OS language (no
/// override — Spanish or English are matched, anything else falls back to English, the
/// development region); `english`/`spanish` force that language via a per-app
/// `AppleLanguages` override, applied on next launch (`LanguageSupport`).
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, english, spanish
    var id: String { rawValue }

    /// The bundle language code for an explicit choice, or `nil` for `system` (no override).
    var languageCode: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .spanish: "es"
        }
    }

    /// Picker label. Language names are shown as their own endonym (`English`, `Español`);
    /// only "Automatic" is itself localized.
    var label: String {
        switch self {
        case .system: String(localized: "Automatic")
        case .english: "English"
        case .spanish: "Español"
        }
    }
}
