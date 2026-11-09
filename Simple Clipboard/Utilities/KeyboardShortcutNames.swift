import KeyboardShortcuts

/// Global shortcut names + defaults. Recorded in the Shortcuts tab and
/// wired to actions in `HotkeyManager`.
extension KeyboardShortcuts.Name {
    static let showClipboard = Self("showClipboard", default: .init(.v, modifiers: [.command, .shift]))
    static let showSnippets = Self("showSnippets", default: .init(.b, modifiers: [.command, .shift]))
    static let pastePrevious = Self("pastePrevious")      // no default
    static let clearHistory = Self("clearHistory")        // no default (destructive)
    static let pastePlainText = Self("pastePlainText")    // no default
}
