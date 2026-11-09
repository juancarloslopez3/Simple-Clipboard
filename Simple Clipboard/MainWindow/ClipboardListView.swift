import SwiftData
import SwiftUI

/// Filter bar (a Liquid Glass capsule) + searchable history list.
/// Rows are standard content — no glass.
struct ClipboardListView: View {
    @Environment(PasteService.self) private var paste
    @Environment(HistoryStore.self) private var history
    @Environment(\.modelContext) private var context

    @Query(sort: \ClipboardItem.createdAt, order: .reverse) private var items: [ClipboardItem]
    @Query(sort: \SnippetFolder.sortIndex) private var folders: [SnippetFolder]

    @State private var filter: ClipboardFilter = .all
    @State private var search = ""
    /// Multi-select (⌘/⇧-click, ⇧-arrows, ⌘A). Space acts on a single selected row; ⌘S, ⌘C,
    /// ⌘⌫ and the context menu act on all of them.
    @State private var selection: Set<UUID> = []
    /// `selection` in the order rows were picked, so a multi-copy pastes in that order.
    @State private var pickOrder: [UUID] = []
    /// Space-bar Quick Look for the *selected* row — a Bool, not an id, so the
    /// overlay follows the selection (arrow keys re-preview like Finder's Quick Look).
    @State private var isPreviewing = false
    /// Tap-vs-hold state for Space, mirroring the panel: the key-up decides by hold
    /// duration whether the preview stays open (tap) or closes on release (hold).
    @State private var spaceDownTime: Date?
    @State private var spaceOpenedPreview = false
    private let holdThreshold: TimeInterval = 0.2
    /// Transient copy confirmation shown after a copy (double-click / context menu).
    /// Its label spells out the plain-text mode when it differs from the
    /// `alwaysPastePlainText` default — shared with the snippets pane.
    @State private var toast = CopyToast()
    /// "Save as Snippet" first asks for a title. Hold the pending item/folder and
    /// the editable title while the prompt is up; commit on Save, drop on Cancel.
    @State private var pendingSnippetItem: ClipboardItem?
    @State private var pendingSnippetFolder: SnippetFolder?
    @State private var snippetTitle = ""
    @State private var showTitlePrompt = false
    /// ⌘S "Save as Snippet" for the *selected* rows — drives the panel's shared
    /// title+folder form (`PanelSaveSnippetHost`), or its batch form for several rows,
    /// overlaid on this pane. Same state class as the panel so Esc can peel the inline
    /// folder-name field before the form.
    @State private var saveState = PanelSnippetSaveState()
    /// Live ⌥ state feeding the copy-mode hint strip (`PanelOptionHint`) — set by a
    /// local `.flagsChanged` monitor installed while this pane is on screen (local needs
    /// no Accessibility, like the panel's).
    @State private var modifier = PanelModifierState()
    @State private var flagsMonitor: Any?
    @Environment(\.appearsActive) private var appearsActive
    @AppStorage(Pref.Key.alwaysPastePlainText) private var alwaysPlain = Pref.Default.alwaysPastePlainText
    /// Rows awaiting the delete confirmation, by id — a row pruned while the alert is up just
    /// drops out. Skipped once its "Don’t ask again" turns `confirmBeforeDeletingItems` off
    /// (Settings › General turns it back on).
    @State private var pendingDeletion: Set<UUID>?
    @AppStorage(Pref.Key.confirmBeforeDeletingItems) private var confirmDeletes = Pref.Default.confirmBeforeDeletingItems
    /// The ⌘S form's AppKit title field steals first responder; restoring list focus when
    /// the form closes keeps Space/arrow keys alive without a click.
    @FocusState private var listFocused: Bool

    /// The selected row when exactly one is selected — what Space previews.
    private var selectedItem: ClipboardItem? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return filtered.first { $0.id == id }
    }

    private var filtered: [ClipboardItem] {
        items.filter { item in
            if !filter.matches(item) { return false }
            // Search matches content only, not the source app name: "text" used to pull in
            // every image copied from TextEdit, whose only text is a "PNG · 522×630" label.
            if !search.isEmpty && !item.plainPreview.localizedCaseInsensitiveContains(search) {
                return false
            }
            return true
        }
    }

    var body: some View {
        // Filtered once per render — the list, the empty state and the preview all read it, and
        // each pass is a localized search over every item's preview.
        let rows = filtered
        VStack(spacing: 0) {
            FilterBar(selection: $filter)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            // The blank space around the filter bar deselects, like clicking empty space in the
            // list below it (Finder-style). Full width so the margins beside the bar count too;
            // clicks on the segments themselves still go to the picker.
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
            .onTapGesture(perform: deselect)

            if rows.isEmpty {
                ContentUnavailableView(
                    items.isEmpty ? String(localized: "No Clipboard History") : String(localized: "No Matches"),
                    systemImage: "doc.on.clipboard",
                    description: Text(items.isEmpty ? String(localized: "Copy something and it'll appear here.") : String(localized: "Try a different filter or search."))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(rows) { item in
                        ClipboardRowView(item: item)
                            .tag(item.id)
                    }
                }
                .listStyle(.inset)
                .focused($listFocused)
                // Single click selects natively anywhere on the row, double-click is the
                // primary action, right-click targets the clicked row. Never put a tap
                // gesture on the row itself — it swallows single clicks over the content,
                // so rows only selected from their padding.
                .contextMenu(forSelectionType: UUID.self) { ids in
                    let targets = items(for: ids)
                    if targets.count > 1 {
                        multiRowMenu(targets)
                    } else if let item = targets.first {
                        rowMenu(item)
                    }
                } primaryAction: { ids in
                    let targets = items(for: ids)
                    if targets.count > 1 {
                        // Option inverts the default for this copy, as for a single row.
                        copyItems(targets, plainText: NSEvent.modifierFlags.contains(.option) ? !alwaysPlain : nil)
                    } else if let item = targets.first {
                        // Resolve Option-invert once so the toast names the same mode the
                        // write lands in (mirrors `activateFromClick`).
                        let plain = clickPlainText()
                        copy(copiedLabel(for: item, plainText: plain)) {
                            paste.activate(item, plainText: plain)
                        }
                    }
                }
                // Space: tap toggles, hold previews only while pressed — same key-up split
                // as the panel.
                .onKeyPress(.space, phases: [.down, .repeat, .up]) { press in
                    switch press.phase {
                    case .down: handleSpaceDown()
                    case .up: handleSpaceUp()
                    // Auto-repeat while held: the initial press already opened the preview —
                    // swallow repeats so one doesn't read as a second tap and close it.
                    default: isPreviewing ? .handled : .ignored
                    }
                }
                // Esc peels one layer: an open preview first, then the selection (Finder-style).
                .onKeyPress(.escape) {
                    if isPreviewing {
                        closePreview()
                        return .handled
                    }
                    guard !selection.isEmpty else { return .ignored }
                    selection = []
                    return .handled
                }
            }

            // Holding ⌥ spells out the inverted copy mode before a double-click — the same
            // strip the panel shows above its footer.
            PanelOptionHint(count: selection.count)
        }
        .navigationTitle("Clipboard")
        .searchable(text: $search, prompt: "Search")
        .overlay {
            // Same overlay as the panel's Space preview; dismiss via Space/Esc
            // above or by clicking the backdrop. Resolving the selection against `rows` means
            // a deleted/filtered-out row simply drops the overlay.
            if isPreviewing, selection.count == 1, let id = selection.first, let item = rows.first(where: { $0.id == id }) {
                ClipboardPreviewOverlay(item: item) { closePreview() }
            }
        }
        .copyToast(toast)
        // ⌘S "Save as Snippet" form over this pane — the same title + destination-folder
        // card the panel's ⌘S shows, or the batch form for several rows.
        .overlay { PanelSaveSnippetHost() }
        // ⌘C / ⌘⌫ for the selected rows, while the history list has keyboard focus.
        .background(ListKeyCommands(copy: copySelection, delete: deleteSelection))
        .background(TypeToSearch(placeholder: nil))
        .background {
            // ⌘S — save the *selected* rows as snippets via the shared panel form.
            // A hidden key-equivalent button so it fires wherever focus sits (list or search).
            Button("Save as Snippet", action: beginSaveShortcut)
                .keyboardShortcut("s", modifiers: .command)
                .hidden()
            // While the form is up its AppKit title field holds focus, so the list's
            // `.onKeyPress` never sees Esc — a `.cancelAction` equivalent peels one layer
            // (the inline folder-name field first), mirroring the panel's Esc chain.
            if saveState.isOpen {
                Button("Cancel", action: dismissSaveFormLayer)
                    .keyboardShortcut(.cancelAction)
                    .hidden()
            }
        }
        // Confirm before deleting history rows. The suppression checkbox only reaches alerts
        // attached above it, so the snippet-title alert below stays without one.
        .alert(deletionTitle, isPresented: isPresentingDeleteConfirmation, presenting: pendingDeletion) { ids in
            Button("Delete", role: .destructive) { delete(items(for: ids)) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This can’t be undone.")
        }
        .dialogSuppressionToggle("Don’t ask again", isSuppressed: suppressDeleteConfirmation)
        // Ask for a snippet title before saving. The field is prefilled with the
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
        // — the same local-monitor pattern as the panel. Reset whenever the window
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
        .onChange(of: saveState.isOpen) { _, open in
            if !open { listFocused = true }
        }
        // Space previews a single row; extending the selection closes the preview.
        .onChange(of: selection) { _, ids in
            // Keep still-selected ids in pick order; a range's new rows join in list order.
            pickOrder = pickOrder.filter(ids.contains) + filtered.map(\.id).filter { ids.contains($0) && !pickOrder.contains($0) }
            if isPreviewing, ids.count != 1 { closePreview() }
        }
        .environment(saveState)
        .environment(modifier)
        // Same held-Space repeat beep as the editor's file preview — the
        // repeats escape the List's `.onKeyPress` to the responder chain and beep.
        .silencesSpaceRepeats(while: isPreviewing)
        .animation(.easeInOut(duration: 0.15), value: isPreviewing)
        .animation(.easeInOut(duration: 0.12), value: modifier.optionHeld)
    }

    /// Runs a copy action, then flashes the copy confirmation with `message`.
    private func copy(_ message: String = String(localized: "Copied"), _ action: () -> Void) {
        action()
        toast.flash(message)
    }

    /// The plain-text mode a plain click/double-click resolves to (mirrors
    /// `PasteService.activateFromClick`): the `alwaysPastePlainText` default, inverted
    /// while **Option** is held.
    private func clickPlainText() -> Bool {
        NSEvent.modifierFlags.contains(.option) ? !alwaysPlain : alwaysPlain
    }

    /// Toast text for a copy: spells out the plain-text mode only when it differs from the
    /// `alwaysPastePlainText` default, so the *inverted*/explicit copy (Option-click or the
    /// context-menu plain/formatted action) names its mode while a default copy just reads
    /// "Copied". Exempt kinds (image/pdf/file) have no such distinction.
    private func copiedLabel(for item: ClipboardItem, plainText: Bool) -> String {
        guard !item.kind.isPlainTextExempt, plainText != alwaysPlain else { return String(localized: "Copied") }
        return plainText ? String(localized: "Copied as plain text") : String(localized: "Copied with formatting")
    }

    /// Resolves a selection to its rows still shown under the current filter and search, in list
    /// order. Selected rows the search has hidden are left alone.
    private func items(for ids: Set<UUID>) -> [ClipboardItem] {
        let rank = Dictionary(pickOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return filtered.filter { ids.contains($0.id) }
            .enumerated()
            .sorted { (rank[$0.element.id] ?? Int.max, $0.offset) < (rank[$1.element.id] ?? Int.max, $1.offset) }
            .map(\.element)
    }

    /// Toast text for a multi-row copy: the count, plus the mode when it differs from the default
    /// and any of the rows has a textual form to apply it to.
    private func copiedLabel(for targets: [ClipboardItem], plainText: Bool?) -> String {
        guard let plainText, plainText != alwaysPlain, targets.contains(where: \.kind.hasTextForm) else {
            return String(localized: "Copied \(targets.count) items")
        }
        return plainText ? String(localized: "Copied \(targets.count) items as plain text")
                         : String(localized: "Copied \(targets.count) items with formatting")
    }

    /// Copies one row the way the context menu's Copy does, or several at once
    /// (`PasteService.activate(_:plainText:)` for a list).
    private func copyItems(_ targets: [ClipboardItem], plainText: Bool? = nil) {
        if targets.count > 1 {
            copy(copiedLabel(for: targets, plainText: plainText)) { paste.activate(targets, plainText: plainText) }
        } else if let item = targets.first {
            copy(copiedLabel(for: item, plainText: plainText ?? alwaysPlain)) { paste.activate(item, plainText: plainText) }
        }
    }

    /// Deletes rows once confirmed, or straight away with confirmation turned off.
    private func requestDelete(_ targets: [ClipboardItem]) {
        guard !targets.isEmpty else { return }
        if confirmDeletes {
            pendingDeletion = Set(targets.map(\.id))
        } else {
            delete(targets)
        }
    }

    private var deletionTitle: Text {
        let count = pendingDeletion?.count ?? 0
        return Text(count > 1 ? String(localized: "Delete \(count) items?") : String(localized: "Delete this item?"))
    }

    /// Bridges `pendingDeletion` to the alert's `isPresented`; dismissing clears it.
    private var isPresentingDeleteConfirmation: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    /// The alert's "Don’t ask again" — recorded only when the user goes on to Delete.
    private var suppressDeleteConfirmation: Binding<Bool> {
        Binding(
            get: { !confirmDeletes },
            set: { confirmDeletes = !$0 }
        )
    }

    /// Deletes rows from history and drops them from the selection.
    private func delete(_ targets: [ClipboardItem]) {
        let ids = Set(targets.map(\.id))   // read before the models are deleted
        history.delete(targets)
        selection.subtract(ids)
    }

    /// ⌘C: copies the selected rows; false (the key goes on) when none are shown.
    private func copySelection() -> Bool {
        let targets = items(for: selection)
        guard !targets.isEmpty else { return false }
        copyItems(targets)
        return true
    }

    /// ⌘⌫: deletes the selected rows (after confirming); false (the key goes on) when none are shown.
    private func deleteSelection() -> Bool {
        let targets = items(for: selection)
        guard !targets.isEmpty else { return false }
        closePreview()
        requestDelete(targets)
        return true
    }

    /// Space pressed: open the selected row's preview (recording the press so key-up can
    /// tell a tap from a hold), or close one already open from a prior tap.
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

    /// Clears the selection and keeps keyboard focus in the history list, as a click on its own
    /// empty space does — so the sidebar's selection reads as inactive (gray).
    private func deselect() {
        selection = []
        listFocused = true
    }

    @ViewBuilder
    private func rowMenu(_ item: ClipboardItem) -> some View {
        // "Copy" follows the pref, so it names the default mode — always "Copied".
        Button("Copy") { copy(copiedLabel(for: item, plainText: alwaysPlain)) { paste.activate(item) } }
        // Images, PDFs and files are exempt from plain-text mode; files get
        // an explicit path-copy instead.
        if item.kind == .file {
            Button(item.fileURLs.count > 1 ? String(localized: "Copy Paths") : String(localized: "Copy Path")) { copy { paste.copyPaths(of: item) } }
        } else if !item.kind.isPlainTextExempt {
            // With "Always paste plain text" on, plain *is* what Copy does — the alternate
            // action flips to the formatted/original form, mirroring the ⌥ hint labels.
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
                    Button(folder.displayName) { promptForSnippet(item, to: folder) }
                }
            }
        }
        Divider()
        Button("Delete", role: .destructive) { requestDelete([item]) }
    }

    /// The context menu for several selected rows: copy them, with the same plain/formatted
    /// alternate as a single row, save them as snippets (the ⌘S batch form), or delete them all.
    @ViewBuilder
    private func multiRowMenu(_ targets: [ClipboardItem]) -> some View {
        Button(String(localized: "Copy \(targets.count) Items")) { copyItems(targets) }
        if alwaysPlain {
            if targets.contains(where: { !$0.kind.isPlainTextExempt }) {
                Button("Copy text with formatting") { copyItems(targets, plainText: false) }
            }
        } else if targets.contains(where: \.kind.hasTextForm) {
            Button("Copy as plain text") { copyItems(targets, plainText: true) }
        }
        Button(String(localized: "Save \(targets.count) Items as Snippets")) { beginSave(targets) }
        Divider()
        Button(String(localized: "Delete \(targets.count) Items"), role: .destructive) { requestDelete(targets) }
    }

    /// ⌘S: open the shared Save as Snippet form for the selected rows — a title and
    /// destination folder for one, a folder plus a title per row for several — replacing an
    /// open Space preview, like the panel's shortcut.
    private func beginSaveShortcut() {
        beginSave(items(for: selection))
    }

    /// Opens the Save as Snippet form for `targets` — ⌘S's selection, or the rows a context
    /// menu was opened on.
    private func beginSave(_ targets: [ClipboardItem]) {
        guard !saveState.isOpen, !showTitlePrompt, !targets.isEmpty else { return }
        closePreview()
        saveState.namingFolder = false
        saveState.pendingItemIDs = targets.map(\.id)
    }

    /// Esc while the ⌘S form is up peels one layer: the inline folder-name field first,
    /// then the form itself — mirroring the panel's Esc chain.
    private func dismissSaveFormLayer() {
        if saveState.namingFolder {
            saveState.namingFolder = false
        } else {
            saveState.pendingItemIDs = []
        }
    }

    /// Opens the title prompt for "Save as Snippet"; the actual insert happens in
    /// `commitSnippet()` once the user confirms.
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
        // matching a snippet created without a title.
        let title = snippetTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        context.insert(Snippet.from(item, title: title, folder: folder))
        try? context.save()
    }
}

/// ⌘C / ⌘⌫ for the selected rows of the history list and the snippet list. A local
/// key-down monitor, like the panel's ⌘S: these are menu key equivalents, which never reach
/// the List's `.onKeyPress`. It acts only while that list itself is first responder, so the search
/// field, the ⌘S form and the preview's text keep their own copy / delete-to-line-start, and only
/// when a handler returns true — otherwise the key goes on as usual. The handlers are refreshed on
/// every update, so they always act on the current rows and selection.
struct ListKeyCommands: NSViewRepresentable {
    let copy: () -> Bool
    let delete: () -> Bool

    @MainActor final class Coordinator {
        var monitor: Any?
        var commands: ListKeyCommands

        init(commands: ListKeyCommands) {
            self.commands = commands
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(commands: self) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view, weak coordinator] event in
            // Exactly Command; ⌘C matched by character so it survives non-QWERTY layouts.
            guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command else { return event }
            let isCopy = event.charactersIgnoringModifiers?.lowercased() == "c"
            let isDelete = event.keyCode == 51   // 51 = Delete (⌫)
            guard isCopy || isDelete else { return event }
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let view, let coordinator, let window = view.window, event.window === window,
                      let table = window.firstResponder as? NSTableView, !table.isInSidebar else { return false }
                return isCopy ? coordinator.commands.copy() : coordinator.commands.delete()
            }
            return consumed ? nil : event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.commands = self
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }
}

/// The history filter bar: every `ClipboardFilter` in declaration order.
private struct FilterBar: View {
    @Binding var selection: ClipboardFilter

    var body: some View {
        GlassSegmentedPicker(ClipboardFilter.allCases.map { ($0, $0.label) },
                             selection: $selection, accessibilityLabel: Text("Filter"))
    }
}

/// A segmented control drawn as one Liquid Glass capsule, styled like a macOS 26 toolbar
/// segmented control: each segment is sized to its label and the selection is a pill that
/// slides between them. The history filter bar and the snippet editor's type switch both use
/// it, so the two read as one control. It replaces a native segmented `Picker`: on a glass
/// slab that put glass on glass and stretched every segment to the widest one, and outside a
/// toolbar (the editor sheet) it fills the selected segment with the accent color. Labels
/// truncate when the bar gets too little room (long Spanish labels at the minimum window width).
struct GlassSegmentedPicker<Value: Hashable>: View {
    private struct Segment: Identifiable {
        let value: Value
        let label: String
        var id: Value { value }
    }

    private let segments: [Segment]
    @Binding private var selection: Value
    private let accessibilityLabel: Text
    /// The segment the pill sits under. Kept apart from `selection` so only the pill animates:
    /// the history list takes the new filter unanimated — an animated List diff of every row
    /// made the slide hitch.
    @State private var pillValue: Value
    @State private var hovered: Value?
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `segments` pairs each value with its (already localized) label, in display order.
    init(_ segments: [(Value, String)], selection: Binding<Value>, accessibilityLabel: Text) {
        self.segments = segments.map { Segment(value: $0.0, label: $0.1) }
        _selection = selection
        self.accessibilityLabel = accessibilityLabel
        _pillValue = State(initialValue: selection.wrappedValue)
    }

    var body: some View {
        // Metrics and colors measured off a native `NSSegmentedControl` in a macOS 26 toolbar
        // (light and dark): a 28 pt pill inset 4 pt in the track, 8 pt label padding, 5 pt
        // between pills. The gaps belong to the segments' hit areas (see `segment`), so a click
        // between two labels still picks one rather than falling through to the deselect tap.
        HStack(spacing: 0) {
            ForEach(segments) { segment($0) }
        }
        .background {
            // One persistent pill that follows the selected segment's frame, so it glides
            // instead of cross-fading between per-segment copies. A plain fill, not glass: it
            // already sits on the glass track. `.quaternary` is the native selection's exact
            // tone in both appearances; `.fill` came out about twice as dark.
            Capsule()
                .fill(.quaternary)
                .matchedGeometryEffect(id: pillValue, in: pill, isSource: false)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
        .glassEffect(.regular, in: .capsule)
        // A selection changed from outside (not by a click here) moves the pill without a slide.
        // After a click this sets the value the click already animated to, so it does nothing.
        .onChange(of: selection) { _, value in pillValue = value }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func segment(_ segment: Segment) -> some View {
        let value = segment.value
        return Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) { pillValue = value }
            selection = value
        } label: {
            Text(segment.label)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background {
                    // Half the selection's tone, so a hovered segment never reads as chosen.
                    // Not `.quinary`: in dark mode that drew exactly as strong as `.quaternary`.
                    if hovered == value && value != pillValue {
                        Capsule().fill(.quaternary.opacity(0.5))
                    }
                }
                .matchedGeometryEffect(id: value, in: pill)
                // Half the 5 pt gap on each side, inside the button: the pill stays label-sized
                // but the gaps still hit a segment.
                .padding(.horizontal, 2.5)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hovered = value
            } else if hovered == value {
                hovered = nil
            }
        }
        .accessibilityAddTraits(value == selection ? .isSelected : [])
    }
}

/// Type-to-search: while a list (or nothing text-like) has keyboard focus, a printable key moves
/// focus to the window's search field and then goes on to it, so the first character isn't lost.
/// Works for the main window's `.searchable` field (an `NSSearchField`) and the panel's plain
/// `TextField` (found by its placeholder). Space, Esc, Return, arrows and anything with ⌘/⌃ are
/// left alone — those drive previews, selection and shortcuts.
struct TypeToSearch: NSViewRepresentable {
    /// Placeholder of the panel's search field; nil targets the window's `NSSearchField`.
    var placeholder: String?

    @MainActor final class Coordinator {
        var monitor: Any?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let placeholder = placeholder
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let chars = event.characters, let scalar = chars.unicodeScalars.first,
                  chars.unicodeScalars.count == 1,
                  scalar.value > 0x20, scalar.value != 0x7F,            // printable, not Space/Delete
                  !(0xF700...0xF8FF).contains(scalar.value) else { return event }   // arrows, F-keys
            MainActor.assumeIsolated {
                guard let view, let window = view.window, window.isKeyWindow, event.window === window,
                      !(window.firstResponder is NSText),             // already typing somewhere
                      window.attachedSheet == nil else { return }
                if let field = Self.findField(in: window.contentView, placeholder: placeholder) {
                    window.makeFirstResponder(field)
                }
            }
            return event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }

    @MainActor private static func findField(in root: NSView?, placeholder: String?) -> NSTextField? {
        guard let root else { return nil }
        if let field = root as? NSTextField, field.isEditable, !field.isHiddenOrHasHiddenAncestor {
            if let placeholder {
                if field.placeholderString == placeholder || field.placeholderAttributedString?.string == placeholder { return field }
            }
            else if field is NSSearchField { return field }
        }
        for sub in root.subviews {
            if let found = findField(in: sub, placeholder: placeholder) { return found }
        }
        return nil
    }
}
