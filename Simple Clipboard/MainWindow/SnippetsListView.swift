import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The content pane when a snippet folder is selected: a searchable,
/// multi-select list of snippet cards. The folder name is the window's toolbar title, as the
/// Clipboard pane has its title and search there; the toolbar's "New Snippet" button belongs to
/// `MainWindowView`, which keeps it before Settings.
struct SnippetsListView: View {
    @Bindable var folder: SnippetFolder
    /// Set by `MainWindowView` when its toolbar's "New Snippet" button or the snippets panel's
    /// targets this folder: opening the editor here, then clearing the flag.
    @Binding var composePending: Bool
    @Environment(PasteService.self) private var paste
    @Environment(\.modelContext) private var context
    @AppStorage(Pref.Key.alwaysPastePlainText) private var alwaysPlain = Pref.Default.alwaysPastePlainText
    @State private var editing: Snippet?
    /// The title's icon button's emoji picker popover.
    @State private var isPickingIcon = false
    /// A just-created snippet being edited, kept **out of the store** (not inserted)
    /// until the editor closes with content — so it doesn't show up in this list, the
    /// menu, or the panel while it's still being created.
    @State private var draft: Snippet?
    /// Transient copy confirmation shown after a copy (context menu or ⌘C), matching the
    /// history pane. Its label spells out the plain-text mode when it differs from the
    /// `alwaysPastePlainText` default.
    @State private var toast = CopyToast()
    /// The toolbar search: narrows the cards to those whose title or content matches, as the
    /// panel's snippet search does. It stays when the sidebar switches folders.
    @State private var search = ""
    /// Multi-select (⌘/⇧-click, ⇧-arrows, ⌘A), like the history list. Double-click or
    /// Return edits a single selected card and Space previews it; ⌘C, ⌘⌫ and the context menu act
    /// on all of them.
    @State private var selection: Set<UUID> = []
    /// The card right-clicked for the open context menu. The menu acts on it, or on the whole
    /// selection when it's selected, and those cards draw the menu ring the table no longer
    /// draws (`ContextMenuRingRemover`). Cleared when the menu closes.
    @State private var menuClickedID: UUID?
    /// `selection` in the order rows were picked, so a multi-copy pastes in that order.
    @State private var pickOrder: [UUID] = []
    /// Space-bar Quick Look for the *selected* card, like the history list's — a Bool, not
    /// an id, so the overlay follows the selection as the arrow keys move it.
    @State private var isPreviewing = false
    /// Tap-vs-hold state for Space: the key-up decides by hold duration whether the preview stays
    /// open (tap) or closes on release (hold), as in the history list and the panel.
    @State private var spaceDownTime: Date?
    @State private var spaceOpenedPreview = false
    private let holdThreshold: TimeInterval = 0.2
    /// Whether the card list has keyboard focus. With `appearsActive` it picks a selected card's
    /// fill: accent while focused in the active window, gray otherwise — the rule a native list's
    /// selection follows.
    @FocusState private var listFocused: Bool
    @Environment(\.appearsActive) private var appearsActive
    /// Snippets awaiting the delete confirmation, by id — skipped once its "Don’t ask again" turns
    /// `confirmBeforeDeletingSnippets` off (Settings › General turns it back on).
    @State private var pendingDeletion: Set<UUID>?
    @AppStorage(Pref.Key.confirmBeforeDeletingSnippets) private var confirmDeletes = Pref.Default.confirmBeforeDeletingSnippets

    var body: some View {
        let ordered = folder.orderedSnippets   // sorted once per render
        let rows = matching(ordered)
        let emphasized = listFocused && appearsActive
        Group {
            if ordered.isEmpty {
                ContentUnavailableView(
                    "No Snippets",
                    systemImage: "text.quote",
                    description: Text("Add a snippet to “\(folder.name)”.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView.search(text: search)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(rows) { snippet in
                        SnippetCard(snippet: snippet, isSelected: selection.contains(snippet.id), isEmphasized: emphasized,
                                    isMenuTarget: isMenuTarget(snippet.id)) { menuClickedID = snippet.id }
                            .tag(snippet.id)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                    }
                }
                .listStyle(.inset)
                // Keep the cards on the pane's own background rather than the list's.
                .scrollContentBackground(.hidden)
                .focused($listFocused)
                // Single click selects, double-click (or Return) edits, right-click targets the
                // clicked card or, when it's selected, the whole selection — the history list's
                // model. Never put a tap gesture on the card: it swallows the List's clicks.
                .contextMenu(forSelectionType: UUID.self) { ids in
                    let targets = snippets(for: ids)
                    if targets.count > 1 {
                        multiCardMenu(targets)
                    } else if let snippet = targets.first {
                        cardMenu(snippet)
                    }
                } primaryAction: { ids in
                    // The editor opens one snippet at a time.
                    let targets = snippets(for: ids)
                    if targets.count == 1 { editing = targets.first }
                }
                // Space: tap toggles, hold previews only while pressed — same key-up split as
                // the history list.
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
        }
        // The icon and the name are one toolbar item so they sit close together (the system leaves
        // a wide gap between a toolbar item and the title). The system title is left empty rather
        // than removed: `.toolbar(removing: .title)` makes the trailing buttons (New Snippet,
        // Settings) slide left next to the name.
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 4) {
                    // The system toolbar's Liquid Glass look, drawn by the button itself so the
                    // name stays outside the capsule. Opens the same emoji picker as the
                    // sidebar's "Change Icon".
                    Button { isPickingIcon = true } label: {
                        FolderGlyph(emoji: folder.emoji)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("Change Icon")
                    .popover(isPresented: $isPickingIcon, arrowEdge: .bottom) {
                        FolderEmojiPicker(current: folder.emoji) { value in
                            folder.emoji = value
                            try? context.save()
                            isPickingIcon = false
                        }
                    }
                    Text(folder.name)
                        .font(.headline)
                        .lineLimit(1)
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .searchable(text: $search, prompt: "Search")
        .overlay {
            // The panel's snippet preview; dismiss via Space/Esc above or by clicking the
            // backdrop. Resolving the selection against `rows` means a deleted or searched-out card
            // simply drops the overlay.
            if isPreviewing, selection.count == 1, let id = selection.first,
               let snippet = rows.first(where: { $0.id == id }) {
                SnippetPreviewOverlay(snippet: snippet) { closePreview() }
            }
        }
        .copyToast(toast)
        // ⌘C / ⌘⌫ for the selected cards, while the card list has keyboard focus.
        .background(ListKeyCommands(copy: copySelection, delete: deleteSelection))
        // Typing while the list has focus goes to the search field, as in the history pane.
        .background(TypeToSearch(placeholder: nil))
        // Confirm before deleting snippets. Attached before the editor sheet: the suppression
        // checkbox reaches every alert presented within it, and the editor's own alerts must not
        // get one.
        .alert(deletionTitle, isPresented: isPresentingDeleteConfirmation, presenting: pendingDeletion) { ids in
            Button("Delete", role: .destructive) { delete(snippets(for: ids)) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This can’t be undone.")
        }
        .dialogSuppressionToggle("Don’t ask again", isSuppressed: suppressDeleteConfirmation)
        .sheet(item: $editing, onDismiss: finishEditing) { snippet in
            // A never-committed draft (still held in `draft`) is a *new* snippet; anything
            // else is an existing one being edited — drives the editor's header title.
            SnippetEditorView(snippet: snippet, isNew: snippet === draft)
        }
        // Open the editor for a "New Snippet" request routed here by `MainWindowView`.
        // `onAppear` handles the folder having just been selected for this request (a fresh view,
        // so `onChange` wouldn't fire); `onChange` handles the folder already being on screen.
        .onAppear { if composePending { startCompose() } }
        .onChange(of: composePending) { _, pending in if pending { startCompose() } }
        // This view stays put when the sidebar switches folders; a selection belongs to the
        // folder it was made in.
        .onChange(of: folder.id) { selection = [] }
        // Space previews a single card; extending the selection closes the preview.
        .onChange(of: selection) { _, ids in
            // Keep still-selected ids in pick order; a range's new rows join in list order.
            pickOrder = pickOrder.filter(ids.contains) + shown.map(\.id).filter { ids.contains($0) && !pickOrder.contains($0) }
            if isPreviewing, ids.count != 1 { closePreview() }
        }
        // A closed context menu takes its ring with it, whether an item was picked or not.
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            menuClickedID = nil
        }
        // The editor (double-click, Return, Edit, New Snippet) replaces an open preview.
        .onChange(of: editing?.id) { _, id in
            if id != nil { closePreview() }
        }
        // Same held-Space repeat beep fix as the history list.
        .silencesSpaceRepeats(while: isPreviewing)
        .animation(.easeInOut(duration: 0.15), value: isPreviewing)
    }

    /// Space pressed: open the selected card's preview (recording the press so key-up can tell a
    /// tap from a hold), or close one already open from a prior tap.
    private func handleSpaceDown() -> KeyPress.Result {
        if isPreviewing {
            closePreview()
            return .handled
        }
        guard selection.count == 1, let id = selection.first,
              shown.contains(where: { $0.id == id }) else { return .ignored }
        isPreviewing = true
        spaceOpenedPreview = true
        spaceDownTime = Date()
        return .handled
    }

    /// Space released: if this press opened the preview, a quick tap leaves it open (toggle)
    /// while a deliberate hold closes it on release.
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

    /// Runs a copy action, then flashes the copy confirmation with `message`.
    private func copy(_ message: String = String(localized: "Copied"), _ action: () -> Void) {
        action()
        toast.flash(message)
    }

    /// Toast text for a snippet copy: spells out the plain-text mode only when it differs from
    /// the `alwaysPastePlainText` default, so an explicit plain/formatted copy names its mode
    /// while a default copy just reads "Copied". File snippets are exempt.
    private func copiedLabel(for snippet: Snippet, plainText: Bool) -> String {
        guard !snippet.isFile, plainText != alwaysPlain else { return String(localized: "Copied") }
        return plainText ? String(localized: "Copied as plain text") : String(localized: "Copied with formatting")
    }

    /// Begin the "New Snippet" flow requested from the panel: open a blank editor draft and
    /// clear the request so it fires once.
    private func startCompose() {
        composePending = false
        addSnippet()
    }

    /// New snippets start fully blank — the editor's "Title" placeholder and empty
    /// content field invite input; nothing preset to delete. The snippet is a
    /// detached draft (no folder, not inserted) until `finishEditing` commits it.
    private func addSnippet() {
        let next = (folder.snippets.map(\.sortIndex).max() ?? -1) + 1
        let snippet = Snippet(title: "", sortIndex: next)
        draft = snippet
        editing = snippet
    }

    /// Commits a non-empty draft into the folder — the new snippet only appears once
    /// it has actually been created — and sweeps contentless leftovers.
    private func finishEditing() {
        if let draft {
            if !draft.isEmpty {
                context.insert(draft)
                draft.folder = folder
                try? context.save()
                // A search left in the field could hide the new card.
                search = ""
            }
            self.draft = nil
        }
        discardEmptySnippets()
    }

    /// A snippet must have content: once the editor closes, drop any snippet
    /// left without non-whitespace content — title or not (e.g. clearing an existing
    /// snippet's title and content, then Done).
    private func discardEmptySnippets() {
        let empties = folder.snippets.filter(\.isEmpty)
        guard !empties.isEmpty else { return }
        empties.forEach(context.delete)
        try? context.save()
    }

    /// The snippets the search matches, by title or cached content preview — the same fields the
    /// panel's snippet search looks at. All of them while the field is empty.
    private func matching(_ snippets: [Snippet]) -> [Snippet] {
        guard !search.isEmpty else { return snippets }
        return snippets.filter {
            $0.title.localizedCaseInsensitiveContains(search)
            || $0.plainPreview.localizedCaseInsensitiveContains(search)
        }
    }

    /// Whether the open context menu acts on this card: the right-clicked one, or every selected card
    /// when the right-clicked one is selected — the targets `contextMenu(forSelectionType:)` passes.
    private func isMenuTarget(_ id: UUID) -> Bool {
        guard let menuClickedID else { return false }
        return id == menuClickedID || (selection.contains(menuClickedID) && selection.contains(id))
    }

    /// The cards on screen: this folder's snippets that match the search, in list order.
    private var shown: [Snippet] { matching(folder.orderedSnippets) }

    /// Resolves a selection to the cards on screen, in pick order. Selected cards the search has
    /// hidden are left alone, as in the history list.
    private func snippets(for ids: Set<UUID>) -> [Snippet] {
        let rank = Dictionary(pickOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return shown.filter { ids.contains($0.id) }
            .enumerated()
            .sorted { (rank[$0.element.id] ?? Int.max, $0.offset) < (rank[$1.element.id] ?? Int.max, $1.offset) }
            .map(\.element)
    }

    /// Toast text for a multi-snippet copy: the count, plus the mode when it differs from the default
    /// and there's something to apply it to.
    private func copiedLabel(for targets: [Snippet], plainText: Bool?) -> String {
        guard let plainText, plainText != alwaysPlain, plainText || targets.contains(where: { !$0.isFile }) else {
            return String(localized: "Copied \(targets.count) snippets")
        }
        return plainText ? String(localized: "Copied \(targets.count) snippets as plain text")
                         : String(localized: "Copied \(targets.count) snippets with formatting")
    }

    /// Copies one snippet the way the context menu's Copy does, or several at once
    /// (`PasteService.activate(_:plainText:)` for a list).
    private func copySnippets(_ targets: [Snippet], plainText: Bool? = nil) {
        if targets.count > 1 {
            copy(copiedLabel(for: targets, plainText: plainText)) { paste.activate(targets, plainText: plainText) }
        } else if let snippet = targets.first {
            copy(copiedLabel(for: snippet, plainText: plainText ?? alwaysPlain)) { paste.activate(snippet, plainText: plainText) }
        }
    }

    /// ⌘C: copies the selected snippets; false (the key goes on) when none are selected.
    private func copySelection() -> Bool {
        let targets = snippets(for: selection)
        guard !targets.isEmpty else { return false }
        copySnippets(targets)
        return true
    }

    /// ⌘⌫: deletes the selected snippets (after confirming); false (the key goes on) when none
    /// are selected.
    private func deleteSelection() -> Bool {
        let targets = snippets(for: selection)
        guard !targets.isEmpty else { return false }
        closePreview()
        requestDelete(targets)
        return true
    }

    @ViewBuilder
    private func cardMenu(_ snippet: Snippet) -> some View {
        Button("Edit") { editing = snippet }
        // "Copy" follows the pref, so it names the default mode — always "Copied".
        Button("Copy") { copy(copiedLabel(for: snippet, plainText: alwaysPlain)) { paste.activate(snippet) } }
        // File snippets are exempt from plain-text mode; they get an explicit path-copy
        // instead, like file rows.
        if snippet.isFile {
            Button(snippet.fileURLs.count > 1 ? String(localized: "Copy Paths") : String(localized: "Copy Path")) {
                copy { paste.copyPaths(of: snippet) }
            }
        } else if alwaysPlain {
            // Plain is what Copy already does with the pref on — the alternate flips to the
            // formatted form; the toast names the resolved mode.
            Button("Copy text with formatting") { copy(copiedLabel(for: snippet, plainText: false)) { paste.activate(snippet, plainText: false) } }
        } else {
            Button("Copy as plain text") { copy(copiedLabel(for: snippet, plainText: true)) { paste.activate(snippet, plainText: true) } }
        }
        Divider()
        Button("Delete", role: .destructive) { requestDelete([snippet]) }
    }

    /// The context menu for several selected cards: copy them, with the same plain/formatted
    /// alternate as a single card, or delete them all.
    @ViewBuilder
    private func multiCardMenu(_ targets: [Snippet]) -> some View {
        Button(String(localized: "Copy \(targets.count) Snippets")) { copySnippets(targets) }
        if !alwaysPlain {
            Button("Copy as plain text") { copySnippets(targets, plainText: true) }
        } else if targets.contains(where: { !$0.isFile }) {
            Button("Copy text with formatting") { copySnippets(targets, plainText: false) }
        }
        Divider()
        Button(String(localized: "Delete \(targets.count) Snippets"), role: .destructive) { requestDelete(targets) }
    }

    /// Deletes snippets once confirmed, or straight away with confirmation turned off.
    private func requestDelete(_ targets: [Snippet]) {
        guard !targets.isEmpty else { return }
        if confirmDeletes {
            pendingDeletion = Set(targets.map(\.id))
        } else {
            delete(targets)
        }
    }

    /// "Delete “Title”?" for one snippet, "Delete 3 snippets?" for several.
    private var deletionTitle: Text {
        let ids = pendingDeletion ?? []
        guard ids.count > 1 else { return Text("Delete “\(displayTitle(snippets(for: ids).first))”?") }
        return Text("Delete \(ids.count) snippets?")
    }

    private func displayTitle(_ snippet: Snippet?) -> String {
        guard let title = snippet?.title, !title.isEmpty else { return String(localized: "Untitled") }
        return title
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

    /// Deletes snippets and drops them from the selection.
    private func delete(_ targets: [Snippet]) {
        let ids = Set(targets.map(\.id))   // read before the models are deleted
        for snippet in targets {
            snippet.deleteOwnedManagedFiles()   // drop its stored file copy, if any
            context.delete(snippet)
        }
        try? context.save()
        selection.subtract(ids)
    }
}

/// A single snippet card: Title (bold) · kind and file-count tags · timestamp, then the content
/// preview. A file snippet referencing an **image** also shows a content thumbnail
/// above the text preview — the same presentation as the history rows' image thumbnails. PDF and other
/// files stay text-only, matching the history rows and the panel's snippet rows.
/// A selected card fills with the selection color, like a selected history row.
private struct SnippetCard: View {
    let snippet: Snippet
    /// Fills the whole card with the native selection color, in place of the List's own
    /// highlight, which `NativeHighlightRemover` turns off.
    let isSelected: Bool
    /// The accent fill and white text while the list has keyboard focus in the active window;
    /// the gray unemphasized fill with regular text otherwise, as a native list draws them.
    let isEmphasized: Bool
    /// The open context menu acts on this card: it gets the menu ring on its own edge, in place of
    /// the table's, which runs around the whole row and the gap around the card.
    let isMenuTarget: Bool
    /// Called when a right-click (or Control-click) on this card opens its context menu.
    let onRightClick: () -> Void
    /// Inline thumbnail for an image file snippet, generated off the referenced file
    /// (snippets store no thumbnail) via the shared `ClipboardContent.fileThumbnail`.
    /// Keyed by the file URL, not the snippet, so replacing the file in the editor
    /// regenerates it; `nil` for text/rich snippets and non-image files.
    @State private var thumbnail: NSImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let fileCount = snippet.fileURLs.count
        VStack(alignment: .leading, spacing: 6) {
            // Baseline-align the header so the tags and the caption timestamp sit on the headline
            // title's baseline instead of floating at its vertical middle.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // One line: a long title truncates rather than wrapping under its tags. "Untitled"
                // is a placeholder, so it's dimmed.
                Text(snippet.title.isEmpty ? String(localized: "Untitled") : snippet.title)
                    .font(.headline)
                    .foregroundStyle(snippet.title.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                // The file count and the kind (same order as the panel) sit together, drawn
                // alike (`RowTag`) at the same height.
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    FileCountBadge(count: snippet.fileBadgeCount)
                    if let kindLabel {
                        RowTag(kindLabel)
                    }
                }
                Spacer(minLength: 8)
                Text(snippet.createdAt.clipboardRowString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            if showsThumbnailStrip {
                FileThumbnailStrip(urls: snippet.fileURLs, placeholder: thumbnail)
            } else if let thumbnail {
                // Round the thumbnail's own corners: clip the aspect-fitted image directly,
                // with no expanding frame between the image and the clip — otherwise the
                // rounded rect spans wider than the image (its width depends on the card
                // width, not the image) and the corners read square. Left-align via the
                // HStack spacer rather than a full-width frame around the clip.
                HStack(spacing: 0) {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 64)
                        .clipShape(.rect(cornerRadius: 6))
                    Spacer(minLength: 0)
                }
            }
            if snippet.isFile {
                // Lead the file names with the glyph history file rows use: a photo when
                // they're all images, the PDF glyph when they're all PDFs, else `doc`. Several
                // files list one name per line, the first three then "…", like history rows.
                Label(previewText, systemImage: ClipboardKind.presenting(fileURLs: snippet.fileURLs).symbol)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(fileCount > 1 ? snippet.fileNamesLineLimit : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(previewText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        // On the accent fill, `.primary` / `.secondary` turn white and translucent white, the way
        // they do in a selected native row; `RowTag` follows too.
        .environment(\.backgroundProminence, isSelected && isEmphasized ? .increased : .standard)
        .background(fill, in: .rect(cornerRadius: 10))
        .overlay {
            // The border marks an unselected card's edge; a selected card's fill already does.
            if !isSelected {
                RoundedRectangle(cornerRadius: 10).strokeBorder(.separator)
            }
        }
        .overlay {
            if isMenuTarget {
                // AppKit's menu ring, 2 pt: white just inside an emphasized selection's accent fill,
                // accent elsewhere, as `NSTableView` colors it. AppKit strokes the deprecated
                // `alternateSelectedControlColor`; `selectedContentBackgroundColor` is its
                // replacement and resolves to the same color in every appearance.
                if isSelected && isEmphasized {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color(nsColor: .alternateSelectedControlTextColor), lineWidth: 2)
                        .padding(1)
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color(nsColor: .selectedContentBackgroundColor), lineWidth: 2)
                }
            }
        }
        .background(NativeHighlightRemover(onRightClick: onRightClick))
        .task(id: thumbnailURL) {
            guard let url = thumbnailURL else { thumbnail = nil; return }
            let scale = displayScale
            let data = await Task.detached(priority: .utility) {
                ClipboardContent.fileThumbnail(for: url, scale: scale)
            }.value
            thumbnail = data.flatMap(NSImage.init(data:))
        }
    }

    /// The card's background: the native list's selection colors when selected, else the
    /// control background.
    private var fill: Color {
        guard isSelected else { return Color(nsColor: .controlBackgroundColor) }
        return Color(nsColor: isEmphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor)
    }

    /// The header's kind tag: "File" / "Files" / "Images" / "PDFs" for a file snippet, "Rich Text"
    /// for rich text, none for plain text.
    private var kindLabel: String? {
        if snippet.isFile { return snippet.fileKindLabel }
        return snippet.isRichText ? String(localized: "Rich Text") : nil
    }

    /// Several files with something to preview, as history rows show them. All-PDF snippets stay
    /// text-only like single PDF ones.
    private var showsThumbnailStrip: Bool {
        let urls = snippet.fileURLs
        return urls.count > 1 && ClipboardKind.presenting(fileURLs: urls) != .pdf
            && urls.contains(where: FileThumbnailStrip.canHaveThumbnail)
    }

    /// The file a thumbnail would come from — an **image** file snippet's (single) referenced
    /// file; `nil` for PDFs and other files, which stay text-only.
    private var thumbnailURL: URL? {
        guard snippet.isFile, let url = snippet.fileURLs.first else { return nil }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .image) == true ? url : nil
    }

    private var previewText: String {
        // File snippets preview as their file *names* (one per line for several); text
        // snippets derive from the content itself — older cached previews were stored
        // newline-collapsed (menuPreview), which would defeat the 3-line preview above.
        if snippet.isFile {
            let p = snippet.fileNamesPreview
            return p.isEmpty ? String(localized: "Empty") : p
        }
        let p = snippet.plainString.multilinePreview(limit: 240)
        return p.isEmpty ? String(localized: "Empty") : p
    }
}

/// Turns off the List's own highlights for the snippet cards, which draw their own instead:
/// the selection fill, which would sit behind the opaque card as a frame around it and turn its
/// text white on white, and the right-click ring (`ContextMenuRingRemover`), which would run around
/// the whole row instead of the card. SwiftUI has no modifier for either, so this invisible view in
/// each card's background walks up to the row's `NSTableView`. It also tells the card when a
/// right-click opens its context menu. Selection itself — clicks, keys, ⌘A — is unaffected.
private struct NativeHighlightRemover: NSViewRepresentable {
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> RemovingView { RemovingView() }

    func updateNSView(_ nsView: RemovingView, context: Context) {
        nsView.onRightClick = onRightClick
        nsView.removeHighlights()
    }

    static func dismantleNSView(_ nsView: RemovingView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class RemovingView: NSView {
        var onRightClick: (() -> Void)?
        private var monitor: Any?

        /// A row's content joins the table only after it's created, so apply from here too.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeHighlights()
            if window == nil { stopMonitoring() } else { startMonitoring() }
        }

        /// Clicks go through to the row.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private var table: NSTableView? {
            var ancestor = superview
            while let current = ancestor, !(current is NSTableView) { ancestor = current.superview }
            return ancestor as? NSTableView
        }

        func removeHighlights() {
            guard let table else { return }
            if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
            ContextMenuRingRemover.install(on: table)
        }

        /// A local monitor sees the click before the table opens its menu.
        private func startMonitoring() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.noteMenuClick(event) }
                return event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// A right-click or Control-click on this card's row opens its context menu, when the click
        /// reaches the table: not one on the Space preview over it or behind the editor sheet.
        private func noteMenuClick(_ event: NSEvent) {
            guard event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                  let window, event.window === window, window.attachedSheet == nil, let table,
                  let hit = window.contentView?.superview?.hitTest(event.locationInWindow),
                  hit.isDescendant(of: table) else { return }
            let row = table.row(at: table.convert(event.locationInWindow, from: nil))
            guard row >= 0, row == table.row(for: self) else { return }
            onRightClick?()
        }
    }
}

/// AppKit outlines a right-clicked row with a 2 pt ring along the row's own highlight shape, drawn
/// by an `NSMenuHighlightView` it lays over the table, and a snippet row is the card plus the gap
/// around it. No public API turns the ring off, so the snippet table gets a subclass of its own
/// class whose `drawContextMenuHighlightForRow:` (what that view calls to draw it) draws nothing,
/// swapped in with the same per-object class change KVO uses. The card draws the ring on its own
/// edge instead. Only this table changes; the history list and the sidebar keep the native ring.
/// If AppKit drops the method, nothing is swapped and the native ring returns beside the card's.
@MainActor private enum ContextMenuRingRemover {
    private static let prefix = "SimpleClipboardNoMenuRing_"
    private static let drawSelector = NSSelectorFromString("drawContextMenuHighlightForRow:")

    static func install(on table: NSTableView) {
        guard let base = object_getClass(table) else { return }
        let baseName = String(cString: class_getName(base))
        // Already swapped, or KVO has swapped it, and stacking on KVO's class would confuse it.
        guard !baseName.hasPrefix(prefix), !baseName.hasPrefix("NSKVONotifying_"),
              let draw = class_getInstanceMethod(base, drawSelector),
              let subclass = subclass(of: base, named: prefix + baseName.filter { $0.isLetter || $0.isNumber }, draw: draw)
        else { return }
        object_setClass(table, subclass)
    }

    private static func subclass(of base: AnyClass, named name: String, draw: Method) -> AnyClass? {
        if let existing = objc_lookUpClass(name) { return existing }
        guard let subclass = objc_allocateClassPair(base, name, 0) else { return nil }
        let drawNothing: @convention(block) (NSTableView, Int) -> Void = { _, _ in }
        class_addMethod(subclass, drawSelector, imp_implementationWithBlock(drawNothing), method_getTypeEncoding(draw))
        // Report the table's own class, as KVO's subclasses do.
        let classSelector = NSSelectorFromString("class")
        if let classMethod = class_getInstanceMethod(base, classSelector) {
            let reportBase: @convention(block) (AnyObject) -> AnyClass = { _ in base }
            class_addMethod(subclass, classSelector, imp_implementationWithBlock(reportBase), method_getTypeEncoding(classMethod))
        }
        objc_registerClassPair(subclass)
        return subclass
    }
}
