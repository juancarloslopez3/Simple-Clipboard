import SwiftData
import SwiftUI

/// Filter bar (on a Liquid Glass slab, §3) + searchable history list (CLAUDE.md §10).
/// Rows are standard content — no glass.
struct ClipboardListView: View {
    @Environment(PasteService.self) private var paste
    @Environment(HistoryStore.self) private var history
    @Environment(\.modelContext) private var context

    @Query(sort: \ClipboardItem.createdAt, order: .reverse) private var items: [ClipboardItem]
    @Query(sort: \SnippetFolder.sortIndex) private var folders: [SnippetFolder]

    @State private var filter: ClipboardFilter = .all
    @State private var search = ""
    @State private var selection: UUID?
    /// Space-bar Quick Look for the *selected* row (§10) — a Bool, not an id, so the
    /// overlay follows the selection (arrow keys re-preview like Finder's Quick Look).
    @State private var isPreviewing = false
    /// Tap-vs-hold state for Space, mirroring the panel (§9): the key-up decides by hold
    /// duration whether the preview stays open (tap) or closes on release (hold).
    @State private var spaceDownTime: Date?
    @State private var spaceOpenedPreview = false
    private let holdThreshold: TimeInterval = 0.2
    /// Transient copy confirmation shown after a copy (double-click / context menu, §10).
    /// Its label spells out the plain-text mode when it differs from the
    /// `alwaysPastePlainText` default (§12) — shared with the snippets pane.
    @State private var toast = CopyToast()
    /// "Save as Snippet" first asks for a title (§10). Hold the pending item/folder and
    /// the editable title while the prompt is up; commit on Save, drop on Cancel.
    @State private var pendingSnippetItem: ClipboardItem?
    @State private var pendingSnippetFolder: SnippetFolder?
    @State private var snippetTitle = ""
    @State private var showTitlePrompt = false
    /// ⌘S "Save as Snippet" for the *selected* row (§10) — drives the panel's shared
    /// title+folder form (`PanelSaveSnippetHost`, §9), overlaid on this pane. Same state
    /// class as the panel so Esc can peel the inline folder-name field before the form.
    @State private var saveState = PanelSnippetSaveState()
    /// Live ⌥ state feeding the copy-mode hint strip (`PanelOptionHint`, §12) — set by a
    /// local `.flagsChanged` monitor installed while this pane is on screen (local needs
    /// no Accessibility, like the panel's).
    @State private var modifier = PanelModifierState()
    @State private var flagsMonitor: Any?
    @Environment(\.appearsActive) private var appearsActive
    @AppStorage(Pref.Key.alwaysPastePlainText) private var alwaysPlain = Pref.Default.alwaysPastePlainText
    /// The ⌘S form's AppKit title field steals first responder; restoring list focus when
    /// the form closes keeps Space/arrow keys alive without a click.
    @FocusState private var listFocused: Bool

    private var selectedItem: ClipboardItem? {
        guard let id = selection else { return nil }
        return filtered.first { $0.id == id }
    }

    private var filtered: [ClipboardItem] {
        items.filter { item in
            if !filter.matches(item) { return false }
            if !search.isEmpty {
                let inPreview = item.plainPreview.localizedCaseInsensitiveContains(search)
                let inApp = item.sourceAppName?.localizedCaseInsensitiveContains(search) ?? false
                if !inPreview && !inApp { return false }
            }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Filter", selection: $filter) {
                ForEach(ClipboardFilter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .rect(cornerRadius: 10))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if filtered.isEmpty {
                ContentUnavailableView(
                    items.isEmpty ? String(localized: "No Clipboard History") : String(localized: "No Matches"),
                    systemImage: "doc.on.clipboard",
                    description: Text(items.isEmpty ? String(localized: "Copy something and it'll appear here.") : String(localized: "Try a different filter or search."))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(filtered) { item in
                        ClipboardRowView(item: item)
                            .tag(item.id)
                    }
                }
                .listStyle(.inset)
                .focused($listFocused)
                // Single click selects natively anywhere on the row, double-click is the
                // primary action, right-click targets the clicked row. Never put a tap
                // gesture on the row itself — it swallows single clicks over the content,
                // so rows only selected from their padding (§10).
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let item = item(for: ids) { rowMenu(item) }
                } primaryAction: { ids in
                    if let item = item(for: ids) {
                        // Resolve Option-invert once so the toast names the same mode the
                        // write lands in (mirrors `activateFromClick`, §12).
                        let plain = clickPlainText()
                        copy(copiedLabel(for: item, plainText: plain)) {
                            paste.activate(item, plainText: plain)
                        }
                    }
                }
                // Space: tap toggles, hold previews only while pressed — same key-up split
                // as the panel (§9).
                .onKeyPress(.space, phases: [.down, .repeat, .up]) { press in
                    switch press.phase {
                    case .down: handleSpaceDown()
                    case .up: handleSpaceUp()
                    // Auto-repeat while held: the initial press already opened the preview —
                    // swallow repeats so one doesn't read as a second tap and close it.
                    default: isPreviewing ? .handled : .ignored
                    }
                }
                .onKeyPress(.escape) {
                    guard isPreviewing else { return .ignored }
                    closePreview()
                    return .handled
                }
            }

            // Holding ⌥ spells out the inverted copy mode before a double-click — the same
            // strip the panel shows above its footer (§12).
            PanelOptionHint()
        }
        .navigationTitle("Clipboard")
        .searchable(text: $search, prompt: "Search")
        .overlay {
            // Same overlay as the panel's Space preview (§9); dismiss via Space/Esc
            // above or by clicking the backdrop. Resolving through `selectedItem` means
            // a deleted/filtered-out row simply drops the overlay.
            if isPreviewing, let item = selectedItem {
                ClipboardPreviewOverlay(item: item) { closePreview() }
            }
        }
        .copyToast(toast)
        // ⌘S "Save as Snippet" form over this pane — the same title + destination-folder
        // card the panel's ⌘S shows (§9/§10), resolving `saveState.pendingItemID` against
        // its own `@Query`.
        .overlay { PanelSaveSnippetHost() }
        .background {
            // ⌘S — save the *selected* row as a snippet via the shared panel form (§9/§10).
            // A hidden key-equivalent button so it fires wherever focus sits (list or search).
            Button("Save as Snippet", action: beginSaveShortcut)
                .keyboardShortcut("s", modifiers: .command)
                .hidden()
            // While the form is up its AppKit title field holds focus, so the list's
            // `.onKeyPress` never sees Esc — a `.cancelAction` equivalent peels one layer
            // (the inline folder-name field first), mirroring the panel's Esc chain (§9).
            if saveState.pendingItemID != nil {
                Button("Cancel", action: dismissSaveFormLayer)
                    .keyboardShortcut(.cancelAction)
                    .hidden()
            }
        }
        // Ask for a snippet title before saving (§10). The field is prefilled with the
        // item's derived preview so accepting is one keystroke; Cancel drops the pending
        // target.
        .alert("Save as Snippet", isPresented: $showTitlePrompt) {
            TextField("Title", text: $snippetTitle)
            Button("Save") { commitSnippet() }
            Button("Cancel", role: .cancel) { clearPendingSnippet() }
        } message: {
            Text("Enter a title for this snippet.")
        }
        // Track ⌥ while this pane is on screen so the hint strip appears/disappears live
        // (§12) — the same local-monitor pattern as the panel. Reset whenever the window
        // deactivates, so a release we never saw (e.g. ⌥ still down during ⌘Tab) can't
        // leave the strip stuck.
        .onAppear {
            guard flagsMonitor == nil else { return }
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
                let option = event.modifierFlags.contains(.option)
                MainActor.assumeIsolated { modifier.optionHeld = option }
                return event
            }
        }
        .onDisappear {
            if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
            flagsMonitor = nil
            modifier.optionHeld = false
        }
        .onChange(of: appearsActive) { _, active in
            if !active { modifier.optionHeld = false }
        }
        // Hand keyboard focus back to the list once the ⌘S form closes — its AppKit title
        // field stole first responder, and without this Space/arrows go dead until a click.
        .onChange(of: saveState.pendingItemID) { _, id in
            if id == nil { listFocused = true }
        }
        .environment(saveState)
        .environment(modifier)
        // Same held-Space repeat beep as the editor's file preview (§10/§11) — the
        // repeats escape the List's `.onKeyPress` to the responder chain and beep.
        .silencesSpaceRepeats(while: isPreviewing)
        .animation(.easeInOut(duration: 0.15), value: isPreviewing)
        .animation(.easeInOut(duration: 0.12), value: modifier.optionHeld)
    }

    /// Runs a copy action, then flashes the copy confirmation with `message` (§10).
    private func copy(_ message: String = String(localized: "Copied"), _ action: () -> Void) {
        action()
        toast.flash(message)
    }

    /// The plain-text mode a plain click/double-click resolves to (mirrors
    /// `PasteService.activateFromClick`, §12): the `alwaysPastePlainText` default, inverted
    /// while **Option** is held.
    private func clickPlainText() -> Bool {
        NSEvent.modifierFlags.contains(.option) ? !alwaysPlain : alwaysPlain
    }

    /// Toast text for a copy: spells out the plain-text mode only when it differs from the
    /// `alwaysPastePlainText` default, so the *inverted*/explicit copy (Option-click or the
    /// context-menu plain/formatted action) names its mode while a default copy just reads
    /// "Copied" (§10/§12). Exempt kinds (image/pdf/file) have no such distinction.
    private func copiedLabel(for item: ClipboardItem, plainText: Bool) -> String {
        guard !item.kind.isPlainTextExempt, plainText != alwaysPlain else { return String(localized: "Copied") }
        return plainText ? String(localized: "Copied as plain text") : String(localized: "Copied with formatting")
    }

    /// Resolves the context-menu / primary-action selection (single-select, so 0…1 ids).
    private func item(for ids: Set<UUID>) -> ClipboardItem? {
        guard let id = ids.first else { return nil }
        return filtered.first { $0.id == id }
    }

    /// Space pressed: open the selected row's preview (recording the press so key-up can
    /// tell a tap from a hold), or close one already open from a prior tap (§9/§10).
    private func handleSpaceDown() -> KeyPress.Result {
        if isPreviewing {
            closePreview()
            return .handled
        }
        guard selectedItem != nil else { return .ignored }
        isPreviewing = true
        spaceOpenedPreview = true
        spaceDownTime = Date()
        return .handled
    }

    /// Space released: if this press opened the preview, a quick tap leaves it open
    /// (toggle) while a deliberate hold closes it on release.
    private func handleSpaceUp() -> KeyPress.Result {
        guard spaceOpenedPreview else { return .ignored }
        let held = spaceDownTime.map { Date().timeIntervalSince($0) } ?? 0
        spaceOpenedPreview = false
        spaceDownTime = nil
        if held >= holdThreshold { isPreviewing = false }
        return .handled
    }

    private func closePreview() {
        isPreviewing = false
        spaceOpenedPreview = false
        spaceDownTime = nil
    }

    @ViewBuilder
    private func rowMenu(_ item: ClipboardItem) -> some View {
        // "Copy" follows the pref, so it names the default mode — always "Copied" (§10).
        Button("Copy") { copy(copiedLabel(for: item, plainText: alwaysPlain)) { paste.activate(item) } }
        // Images, PDFs and files are exempt from plain-text mode (CLAUDE.md §12); files get
        // an explicit path-copy instead.
        if item.kind == .file {
            Button(item.fileURLs.count > 1 ? String(localized: "Copy Paths") : String(localized: "Copy Path")) { copy { paste.copyPaths(of: item) } }
        } else if !item.kind.isPlainTextExempt {
            // With "Always paste plain text" on, plain *is* what Copy does — the alternate
            // action flips to the formatted/original form, mirroring the ⌥ hint labels (§12).
            // The toast names the resolved mode ("Copied with formatting" / "as plain text").
            if alwaysPlain {
                Button("Copy text with formatting") { copy(copiedLabel(for: item, plainText: false)) { paste.activate(item, plainText: false) } }
            } else {
                Button("Copy as plain text") { copy(copiedLabel(for: item, plainText: true)) { paste.activate(item, plainText: true) } }
            }
        }
        if !folders.isEmpty {
            Menu("Save as Snippet") {
                ForEach(folders) { folder in
                    Button(folder.name) { promptForSnippet(item, to: folder) }
                }
            }
        }
        Divider()
        Button("Delete", role: .destructive) { history.delete(item) }
    }

    /// ⌘S: open the shared Save as Snippet form (title + destination folder, §9) for the
    /// selected row — replacing an open Space preview, like the panel's shortcut.
    private func beginSaveShortcut() {
        guard saveState.pendingItemID == nil, !showTitlePrompt, let item = selectedItem else { return }
        closePreview()
        saveState.namingFolder = false
        saveState.pendingItemID = item.id
    }

    /// Esc while the ⌘S form is up peels one layer: the inline folder-name field first,
    /// then the form itself — mirroring the panel's Esc chain (§9).
    private func dismissSaveFormLayer() {
        if saveState.namingFolder {
            saveState.namingFolder = false
        } else {
            saveState.pendingItemID = nil
        }
    }

    /// Opens the title prompt for "Save as Snippet"; the actual insert happens in
    /// `commitSnippet()` once the user confirms (§10).
    private func promptForSnippet(_ item: ClipboardItem, to folder: SnippetFolder) {
        pendingSnippetItem = item
        pendingSnippetFolder = folder
        snippetTitle = Snippet.defaultTitle(for: item)
        showTitlePrompt = true
    }

    private func clearPendingSnippet() {
        pendingSnippetItem = nil
        pendingSnippetFolder = nil
    }

    private func commitSnippet() {
        guard let item = pendingSnippetItem, let folder = pendingSnippetFolder else { return }
        defer { clearPendingSnippet() }
        // A cleared field leaves the title empty — it renders as "Untitled" everywhere,
        // matching a snippet created without a title (§11).
        let title = snippetTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        context.insert(Snippet.from(item, title: title, folder: folder))
        try? context.save()
    }
}
