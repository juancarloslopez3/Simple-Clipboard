import KeyboardShortcuts
import SwiftUI

/// Shortcuts preferences — `KeyboardShortcuts.Recorder` for each action (CLAUDE.md §13 / §14).
struct ShortcutsSettingsView: View {
    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Show clipboard:", name: .showClipboard)
                KeyboardShortcuts.Recorder("Show snippets:", name: .showSnippets)
                KeyboardShortcuts.Recorder("Paste previous item:", name: .pastePrevious)
                KeyboardShortcuts.Recorder("Paste as plain text:", name: .pastePlainText)
                KeyboardShortcuts.Recorder("Clear history:", name: .clearHistory)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Show clipboard / show snippets open the floating panel near the cursor.")
                    Text("Paste previous item / paste as plain text paste straight into the active app — this needs Accessibility access (System Settings › Privacy & Security › Accessibility).")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
