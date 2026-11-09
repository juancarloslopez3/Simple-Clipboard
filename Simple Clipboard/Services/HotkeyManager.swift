import Foundation
import KeyboardShortcuts
import SwiftData

/// Wires `KeyboardShortcuts.Name`s to actions once at launch. The
/// show-clipboard / show-snippets shortcuts open the floating `ClipboardPanel` — the
/// MenuBarExtra menu cannot be opened programmatically.
@MainActor
final class HotkeyManager {
    private let paste: PasteService
    private let panel: ClipboardPanel

    init(history: HistoryStore, paste: PasteService, container: ModelContainer) {
        self.paste = paste
        self.panel = ClipboardPanel(container: container, paste: paste, history: history)
    }

    /// Forwarded to the floating panel's "Main Window" button.
    var onOpenMainWindow: (() -> Void)? {
        get { panel.onOpenMainWindow }
        set { panel.onOpenMainWindow = newValue }
    }

    /// Forwarded to the snippets panel's "New Snippet" button; the argument is
    /// the destination folder chosen in the panel's picker (`nil` to fall back).
    var onNewSnippet: ((UUID?) -> Void)? {
        get { panel.onNewSnippet }
        set { panel.onNewSnippet = newValue }
    }

    func register() {
        KeyboardShortcuts.onKeyUp(for: .showClipboard) { [weak self] in
            self?.panel.toggle(.history)
        }
        KeyboardShortcuts.onKeyUp(for: .showSnippets) { [weak self] in
            self?.panel.toggle(.snippets)
        }
        // Through the panel, which closes itself if open before the confirmation shows.
        KeyboardShortcuts.onKeyUp(for: .clearHistory) { [weak self] in
            self?.panel.confirmClearHistory()
        }
        KeyboardShortcuts.onKeyUp(for: .pastePrevious) { [weak self] in
            self?.paste.pastePrevious()
        }
        KeyboardShortcuts.onKeyUp(for: .pastePlainText) { [weak self] in
            self?.paste.pasteTop(plainText: true)
        }
    }
}
