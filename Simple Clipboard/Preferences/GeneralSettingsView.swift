import SwiftUI
import AppKit

/// General preferences. Values persist via `@AppStorage`; side effects
/// (login item, pruning, appearance) fire on change.
struct GeneralSettingsView: View {
    @Environment(HistoryStore.self) private var history
    @Environment(OnboardingWindow.self) private var onboarding

    @AppStorage(Pref.Key.openAtLogin) private var openAtLogin = Pref.Default.openAtLogin
    @AppStorage(Pref.Key.historySize) private var historySize = Pref.Default.historySize
    @AppStorage(Pref.Key.inlineItemCount) private var inlineItemCount = Pref.Default.inlineItemCount
    @AppStorage(Pref.Key.folderSize) private var folderSize = Pref.Default.folderSize
    @AppStorage(Pref.Key.ignoreLargerThanMB) private var ignoreLargerThanMB = Pref.Default.ignoreLargerThanMB
    @AppStorage(Pref.Key.ignoreLargerThanUnit) private var ignoreSizeUnit = Pref.Default.ignoreLargerThanUnit
    @AppStorage(Pref.Key.saveHistoryOnQuit) private var saveHistoryOnQuit = Pref.Default.saveHistoryOnQuit
    @AppStorage(Pref.Key.confirmBeforeDeletingItems) private var confirmBeforeDeletingItems = Pref.Default.confirmBeforeDeletingItems
    @AppStorage(Pref.Key.confirmBeforeDeletingSnippets) private var confirmBeforeDeletingSnippets = Pref.Default.confirmBeforeDeletingSnippets
    @AppStorage(Pref.Key.confirmBeforeDeletingFolders) private var confirmBeforeDeletingFolders = Pref.Default.confirmBeforeDeletingFolders
    @AppStorage(Pref.Key.confirmBeforeClearingHistory) private var confirmBeforeClearingHistory = Pref.Default.confirmBeforeClearingHistory
    @AppStorage(Pref.Key.alwaysPastePlainText) private var alwaysPastePlainText = Pref.Default.alwaysPastePlainText
    @AppStorage(Pref.Key.trimWhitespacePreview) private var trimWhitespacePreview = Pref.Default.trimWhitespacePreview
    @AppStorage(Pref.Key.playSoundOnCopy) private var playSoundOnCopy = Pref.Default.playSoundOnCopy
    @AppStorage(Pref.Key.showMenuBarIcon) private var showMenuBarIcon = Pref.Default.showMenuBarIcon
    @AppStorage(Pref.Key.appearance) private var appearance = Pref.Default.appearance
    @AppStorage(Pref.Key.appLanguage) private var appLanguage = Pref.Default.appLanguage

    // Focus for the editable numeric fields, lifted here so a click on blank space
    // (the Form's `onTapGesture`) can resign whichever field is editing.
    @FocusState private var historyFieldFocused: Bool
    @FocusState private var ignoreFieldFocused: Bool

    /// Edits the size limit in MB, clamped to 1…100 GB. The canonical store is MB.
    private var ignoreSizeMBBinding: Binding<Int> {
        Binding {
            ignoreLargerThanMB
        } set: { newValue in
            ignoreLargerThanMB = min(max(newValue, 1), Pref.maxIgnoreSizeMB)
        }
    }

    /// Edits the MB limit in whole GB (1 GB = 1024 MB), clamped to 1…100 GB.
    private var ignoreSizeGBBinding: Binding<Int> {
        Binding {
            gbValue(ignoreLargerThanMB)
        } set: { newValue in
            ignoreLargerThanMB = min(max(newValue, 1), 100) * SizeUnit.mbPerGB
        }
    }

    /// The MB limit expressed in whole GB (1 GB = 1024 MB), rounded, min 1 GB.
    private func gbValue(_ mb: Int) -> Int {
        max(1, Int((Double(mb) / Double(SizeUnit.mbPerGB)).rounded()))
    }
    private func gbDisplayString(_ mb: Int) -> String { String(gbValue(mb)) }

    /// A language change takes effect on relaunch (the bundle language is chosen at launch),
    /// so offer to restart now.
    private func promptRelaunch() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Language Changed")
        alert.informativeText = String(localized: "Relaunch Simple Clipboard to apply the new language.")
        alert.addButton(withTitle: String(localized: "Relaunch Now"))
        alert.addButton(withTitle: String(localized: "Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            LanguageSupport.relaunch()
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, newValue in LaunchAtLogin.set(newValue) }
                Toggle("Show menu-bar icon", isOn: $showMenuBarIcon)
            }

            Section("History") {
                LabeledContent("Clipboard history size") {
                    HStack(spacing: 8) {
                        EditableNumberField(display: String(historySize), focused: $historyFieldFocused) { entered in
                            guard let n = Int(entered) else {
                                return String(historySize)   // empty/invalid → revert
                            }
                            historySize = min(max(n, 10), 1000)
                            return String(historySize)
                        }
                        Stepper("", value: $historySize, in: 10...1000, step: 10)
                            .labelsHidden()
                    }
                }
                .onChange(of: historySize) { _, _ in history.prune() }

                Stepper("Items shown inline: \(inlineItemCount)", value: $inlineItemCount, in: 1...10)
                Stepper("Folder size: \(folderSize)", value: $folderSize, in: 1...20)

                LabeledContent("Ignore items larger than") {
                    HStack(spacing: 8) {
                        if ignoreSizeUnit == SizeUnit.gb.rawValue {
                            EditableNumberField(display: gbDisplayString(ignoreLargerThanMB), focused: $ignoreFieldFocused) { entered in
                                guard let gb = Int(entered) else {
                                    return gbDisplayString(ignoreLargerThanMB)   // empty/invalid → revert
                                }
                                ignoreLargerThanMB = min(max(gb, 1), 100) * SizeUnit.mbPerGB
                                return gbDisplayString(ignoreLargerThanMB)
                            }
                            Stepper("", value: ignoreSizeGBBinding, in: 1...100)
                                .labelsHidden()
                        } else {
                            EditableNumberField(display: String(ignoreLargerThanMB), focused: $ignoreFieldFocused) { entered in
                                guard let n = Int(entered) else {
                                    return String(ignoreLargerThanMB)   // empty/invalid → revert
                                }
                                ignoreLargerThanMB = min(max(n, 1), Pref.maxIgnoreSizeMB)
                                return String(ignoreLargerThanMB)
                            }
                            Stepper("", value: ignoreSizeMBBinding, in: 1...Pref.maxIgnoreSizeMB)
                                .labelsHidden()
                        }
                        Picker("", selection: $ignoreSizeUnit) {
                            ForEach(SizeUnit.allCases) { Text($0.label).tag($0.rawValue) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }
                .onChange(of: ignoreSizeUnit) { _, newUnit in
                    // Re-express the same byte limit in the newly selected unit (whole GB).
                    if newUnit == SizeUnit.gb.rawValue {
                        ignoreLargerThanMB = gbValue(ignoreLargerThanMB) * SizeUnit.mbPerGB
                    } else {
                        ignoreLargerThanMB = min(max(ignoreLargerThanMB, 1), Pref.maxIgnoreSizeMB)
                    }
                }

                Toggle("Save clipboard history on quit", isOn: $saveHistoryOnQuit)
            }

            Section("Pasting") {
                Toggle("Always paste plain text", isOn: $alwaysPastePlainText)
                Toggle("Trim whitespace from preview", isOn: $trimWhitespacePreview)
                Toggle("Play sound on copy", isOn: $playSoundOnCopy)
            }

            // Each is turned off by its alert's "Don’t ask again"; these are the way back.
            Section("Confirmations") {
                Toggle("Ask before deleting clipboard items", isOn: $confirmBeforeDeletingItems)
                Toggle("Ask before deleting snippets", isOn: $confirmBeforeDeletingSnippets)
                Toggle("Ask before deleting snippet folders", isOn: $confirmBeforeDeletingFolders)
                Toggle("Ask before clearing history", isOn: $confirmBeforeClearingHistory)
            }

            Section("Other") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .onChange(of: appearance) { _, _ in AppModel.applyAppearance() }

                Picker("Language", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .onChange(of: appLanguage) { _, newValue in
                    LanguageSupport.applyOverride(AppLanguage(rawValue: newValue) ?? .system)
                    promptRelaunch()
                }

                LabeledContent("Intro tutorial") {
                    Button("Show Again") { onboarding.show() }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        // Clicking blank space resigns whichever numeric field is editing (which
        // commits + clamps it via the field's focus-change handler).
        .contentShape(Rectangle())
        .onTapGesture {
            historyFieldFocused = false
            ignoreFieldFocused = false
        }
        // Don't open Settings with a text field already focused: the window otherwise
        // makes the first field its first responder. Rather than resigning the field after
        // the fact (`makeFirstResponder(nil)` tears down the field editor's input context,
        // a synchronous wait on a lower-QoS text-input thread → priority-inversion warning),
        // claim the window's initial first responder so the field is never focused at all.
        .background { InitialFocusSink().frame(width: 0, height: 0) }
    }
}

/// An invisible view that registers itself as its window's `initialFirstResponder`, so
/// the window starts with nothing visibly focused instead of picking the first text field.
/// It's excluded from the Tab loop (`canBecomeKeyView`), so keyboard navigation is unchanged.
private struct InitialFocusSink: NSViewRepresentable {
    final class SinkView: NSView {
        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { false }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.initialFirstResponder = self
        }
    }
    func makeNSView(context: Context) -> SinkView { SinkView() }
    func updateNSView(_ nsView: SinkView, context: Context) {}
}

/// A digits-only text field you can edit freely — including clearing it entirely — that
/// only normalizes its value when editing ends (focus loss or Return), so typing a
/// replacement is never fought mid-keystroke. Non-digit characters (letters, `.`, `,`)
/// are rejected as typed. `display` is the canonical string for the current value;
/// `commit` parses the entered text, clamps + persists it, and returns the string to
/// show afterwards (reverting on empty/invalid input). `focused` is owned by the parent
/// so a click on blank space can resign it.
private struct EditableNumberField: View {
    let display: String
    @FocusState.Binding var focused: Bool
    let commit: (String) -> String

    @State private var text = ""

    var body: some View {
        TextField("", text: $text)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onAppear { text = display }
            .onChange(of: text) { _, newValue in
                let digits = newValue.filter { $0.isASCII && $0.isNumber }
                if digits != newValue { text = digits }   // strip non-digits
            }
            .onChange(of: display) { _, newValue in
                if !focused { text = newValue }   // reflect external changes (stepper, unit switch)
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { text = commit(text) }   // normalize/clamp when leaving the field
            }
            .onSubmit { text = commit(text) }
    }
}
