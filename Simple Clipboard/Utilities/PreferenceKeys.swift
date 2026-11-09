import Foundation

/// Single source of truth for every `@AppStorage` preference key and its default
/// value. Never scatter raw `UserDefaults` string keys elsewhere.
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
        // Delete / Clear History confirmations; each alert's "Don’t ask again" turns its own off.
        static let confirmBeforeDeletingItems = "confirmBeforeDeletingItems"
        static let confirmBeforeDeletingSnippets = "confirmBeforeDeletingSnippets"
        static let confirmBeforeDeletingFolders = "confirmBeforeDeletingFolders"
        static let confirmBeforeClearingHistory = "confirmBeforeClearingHistory"
        // Rich snippet editor: the ruler's last shown/hidden state (TextEdit's `ShowRuler`).
        static let showsSnippetRuler = "showsSnippetRuler"

        // General — suggested additions
        static let pasteOnSelect = "pasteOnSelect"      // reserved (copy-only this build)
        static let playSoundOnCopy = "playSoundOnCopy"
        static let appearance = "appearance"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let appLanguage = "appLanguage"          // in-app language override

        // Privacy
        static let ignoredAppBundleIDs = "ignoredAppBundleIDs"
        static let suppressFullDiskAccessPrompt = "suppressFullDiskAccessPrompt"   // iPhone-copy alert (`FullDiskAccess`)

        // Storage
        static let keepCopiedFiles = "keepCopiedFiles"   // file cache (`HistoryFileCache`)
        static let didKeepEarlierCopiedFiles = "didKeepEarlierCopiedFiles"   // one-time keep of items from before it

        // Folder icon picker (`FolderEmojiPicker`)
        static let folderEmojiSkinTones = "folderEmojiSkinTones"    // default-tone emoji → tone last picked
        static let folderCustomEmoji = "folderCustomEmoji"          // [String], the Custom section, newest first

        // Onboarding
        static let didShowOnboarding = "didShowOnboarding"
        static let relaunchDestination = "relaunchDestination"   // Full Disk Access relaunch (`RelaunchDestination`)

        // Updates (`UpdateChecker`)
        static let lastUpdateCheck = "lastUpdateCheck"   // Date of the last successful release check
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
        static let confirmBeforeDeletingItems = true
        static let confirmBeforeDeletingSnippets = true
        static let confirmBeforeDeletingFolders = true
        static let confirmBeforeClearingHistory = true
        static let showsSnippetRuler = true   // TextEdit registers `ShowRuler` = YES

        static let pasteOnSelect = false   // synthetic-paste path deferred; copy-only
        static let playSoundOnCopy = false
        static let appearance = AppAppearance.system.rawValue
        static let showMenuBarIcon = true
        static let appLanguage = AppLanguage.system.rawValue

        static let ignoredAppBundleIDs: [String] = []
        static let suppressFullDiskAccessPrompt = false

        static let keepCopiedFiles = true
        static let didKeepEarlierCopiedFiles = false

        static let didShowOnboarding = false
        static let relaunchDestination = RelaunchDestination.none.rawValue
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
            Key.confirmBeforeDeletingItems: Default.confirmBeforeDeletingItems,
            Key.confirmBeforeDeletingSnippets: Default.confirmBeforeDeletingSnippets,
            Key.confirmBeforeDeletingFolders: Default.confirmBeforeDeletingFolders,
            Key.confirmBeforeClearingHistory: Default.confirmBeforeClearingHistory,
            Key.showsSnippetRuler: Default.showsSnippetRuler,
            Key.pasteOnSelect: Default.pasteOnSelect,
            Key.playSoundOnCopy: Default.playSoundOnCopy,
            Key.appearance: Default.appearance,
            Key.showMenuBarIcon: Default.showMenuBarIcon,
            Key.appLanguage: Default.appLanguage,
            Key.ignoredAppBundleIDs: Default.ignoredAppBundleIDs,
            Key.suppressFullDiskAccessPrompt: Default.suppressFullDiskAccessPrompt,
            Key.keepCopiedFiles: Default.keepCopiedFiles,
            Key.didKeepEarlierCopiedFiles: Default.didKeepEarlierCopiedFiles,
            Key.didShowOnboarding: Default.didShowOnboarding,
            Key.relaunchDestination: Default.relaunchDestination,
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
    static var keepCopiedFiles: Bool { UserDefaults.standard.bool(forKey: Key.keepCopiedFiles) }

    static var didKeepEarlierCopiedFiles: Bool {
        get { UserDefaults.standard.bool(forKey: Key.didKeepEarlierCopiedFiles) }
        set { UserDefaults.standard.set(newValue, forKey: Key.didKeepEarlierCopiedFiles) }
    }

    static var ignoredAppBundleIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: Key.ignoredAppBundleIDs) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Key.ignoredAppBundleIDs) }
    }

    static var confirmBeforeClearingHistory: Bool {
        get { UserDefaults.standard.bool(forKey: Key.confirmBeforeClearingHistory) }
        set { UserDefaults.standard.set(newValue, forKey: Key.confirmBeforeClearingHistory) }
    }

    static var suppressFullDiskAccessPrompt: Bool {
        get { UserDefaults.standard.bool(forKey: Key.suppressFullDiskAccessPrompt) }
        set { UserDefaults.standard.set(newValue, forKey: Key.suppressFullDiskAccessPrompt) }
    }

    /// No default: `nil` means no check has run yet (fresh install).
    static var lastUpdateCheck: Date? {
        get { UserDefaults.standard.object(forKey: Key.lastUpdateCheck) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Key.lastUpdateCheck) }
    }

    static var relaunchDestination: RelaunchDestination {
        get { RelaunchDestination(rawValue: UserDefaults.standard.string(forKey: Key.relaunchDestination) ?? "") ?? .none }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.relaunchDestination) }
    }
}

/// Where to pick up after granting Full Disk Access, which makes System Settings quit and reopen
/// the app: the window whose Allow button started it (`PermissionRow`). `AppModel.start` honors it
/// only if access actually came through.
enum RelaunchDestination: String, Sendable {
    case none = ""
    case onboarding
    case privacySettings
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

/// In-app interface language (General tab). `system` follows the OS language (no
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
