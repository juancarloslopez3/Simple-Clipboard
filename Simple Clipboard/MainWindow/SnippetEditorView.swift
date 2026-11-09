import AppKit
import CoreText
import SwiftData
import SwiftUI

/// Edits a snippet's title + content. The header type control depends on
/// whether the snippet is new: a **new** draft gets the full **Plain/Rich/File** toggle
/// (so a file snippet can be created from New Snippet), but an **existing** snippet is
/// locked to its category — a text snippet toggles only Plain↔Rich (File isn't offered),
/// and a file snippet shows a fixed "File" label. Plain stores UTF-8; rich stores RTF,
/// edited via an `NSTextView` wrapper; File holds **one or more** files (`FileSnippetList`),
/// added by dragging them from Finder onto the area, clicking the empty drop zone, or
/// **Add Files…**, and removed individually or as a selection. Switching between Text and
/// File (new drafts only) stashes the other mode's payload for the session, so an accidental
/// flip doesn't destroy content. **Cancel** discards every change made in the session
/// (restoring the snapshot taken on open), after asking when there are any; **Done** saves.
struct SnippetEditorView: View {
    @Bindable var snippet: Snippet
    /// `true` when editing a just-created draft (not yet committed) — the header reads
    /// "New Snippet" instead of "Edit Snippet".
    var isNew: Bool = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var showingEmptyContentAlert = false
    /// Cancel's "Discard changes?" confirmation, shown only when the session changed something.
    @State private var showingDiscardAlert = false
    /// Space / double-click Quick Look of the snippet's files in File mode — the same
    /// `SnippetPreviewOverlay` the panel's snippet Space preview uses, overlaid on the sheet.
    @State private var isPreviewingFile = false
    /// The file the preview shows: the selected one when it opens, then whichever it pages to,
    /// so the file grid's selection follows the preview.
    @State private var previewedFile: URL?
    /// The payload of the mode the editor switched *away* from (text kept with its
    /// plain/rich form, file list as raw payload). Session-only — dies with the sheet.
    @State private var stashedText: StashedText?
    @State private var stashedFiles: Data?
    /// The RTF a Rich→Plain switch flattened, with the plain text it produced. Switching back
    /// to Rich while the text is still exactly that restores the formatting instead of
    /// rebuilding unstyled RTF — the session-level stand-in for TextEdit's undoable
    /// "Make Plain Text". Session-only, like the other stashes.
    @State private var richBeforePlain: RichStash?
    /// The live text view of whichever text editor is showing, so the sheet's Esc / Return
    /// can defer to its find bar (see `FindBarHost`).
    @State private var findBar = FindBarHost()
    /// The snippet's fields when the editor opened, captured so **Cancel** can revert every
    /// in-editor change. SwiftData autosaves the live model as it's edited, so discarding
    /// means restoring these values — not just skipping `save()`. Captured once on appear.
    @State private var original: Snapshot?

    private enum SnippetMode: Hashable { case plain, rich, file }
    /// The corner radius of the title-and-content card, which the file area's drop highlight
    /// follows.
    static let cardRadius: CGFloat = 10
    private struct StashedText { var isRich: Bool; var data: Data }
    private struct RichStash { var rtf: Data; var plain: String }
    private struct Snapshot {
        var title: String
        var isRichText: Bool
        var isFile: Bool
        var payload: Data
        var plainPreview: String

        init(_ s: Snippet) {
            title = s.title
            isRichText = s.isRichText
            isFile = s.isFile
            payload = s.payload
            plainPreview = s.plainPreview
        }

        /// The file URLs the snippet referenced on open (the previously-stored copies, if any),
        /// so replacing the file on save can clean up the ones it superseded.
        var fileURLs: [URL] {
            isFile ? ClipboardItem.fileURLs(fromPayload: payload) : []
        }

        /// Whether `s` differs from the snapshot in anything Cancel would put back: its title,
        /// its type or its content. Editing something and then putting it back is no change.
        func differs(from s: Snippet) -> Bool {
            guard s.title == title, s.isFile == isFile, s.isRichText == isRichText else { return true }
            if s.payload == payload { return false }
            return !(isRichText && !isFile && Self.sameRichText(s.payload, payload))
        }

        /// Whether two RTF payloads hold the same text and formatting. The rich editor writes
        /// the RTF anew on every edit, so after typing and deleting a character the bytes
        /// differ from RTF another app wrote while the text is just as it was. So both sides
        /// are compared as AppKit writes them: read, given the attribute fixing the text view
        /// applies (fonts for characters the chosen one lacks, such as emoji), and written
        /// again. Comparing the read strings instead fails: AppKit's writer adds explicit
        /// paragraph styles and changes color spaces, and two reads of one list never match
        /// (`NSTextList` compares by identity).
        private static func sameRichText(_ a: Data, _ b: Data) -> Bool {
            func rewritten(_ rtf: Data) -> Data? {
                guard let parsed = NSAttributedString(rtf: rtf, documentAttributes: nil) else { return nil }
                let fixed = NSMutableAttributedString(attributedString: parsed)
                let all = NSRange(location: 0, length: fixed.length)
                fixed.fixAttributes(in: all)
                return fixed.rtf(from: all, documentAttributes: [:])
            }
            guard let lhs = rewritten(a) else { return false }
            return lhs == rewritten(b)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Title 2 bold, so the heading outranks the 15 pt semibold title field below it.
            // Baseline-aligned with the picker's labels rather than centered on its capsule.
            HStack(alignment: .firstTextBaseline) {
                Text(isNew ? String(localized: "New Snippet") : String(localized: "Edit Snippet"))
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                Spacer()
                modeControl
            }

            // Title and content share one frame, the way Mail's compose window puts the subject
            // above the body: a borderless title row, a hairline, then the content (under the
            // rich editor's format bar, like Mail's).
            VStack(spacing: 0) {
                TextField("Title", text: $snippet.title)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    // 11 pt in, the body text's left margin in both text editors (see
                    // `PlainTextView` and `RichTextView`), so the title starts where the text does.
                    .padding(.horizontal, 11)
                    .padding(.vertical, 10)
                Divider()
                Group {
                    if snippet.isFile {
                        FileSnippetList(urls: snippet.fileURLs, isPreviewing: $isPreviewingFile,
                                        previewedFile: $previewedFile,
                                        onAdd: addFiles, onRemove: removeFiles)
                    } else if snippet.isRichText {
                        RichTextEditor(rtfData: rtfBinding, findBar: findBar)
                    } else {
                        PlainTextView(text: plainBinding, findBar: findBar)
                    }
                }
                .frame(minHeight: 300)
            }
            .background(Color(nsColor: .textBackgroundColor))
            // The text views paint square backgrounds, which showed past the rounded corners
            // wherever the sheet's background differs from the text background.
            .clipShape(.rect(cornerRadius: Self.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Self.cardRadius).strokeBorder(.separator))

            HStack {
                Spacer()
                // Discard the session's changes (Esc): asks first if there are any, then
                // reverts to the on-open snapshot, bypassing the empty-content prompt
                // entirely. While the file preview is up, Esc peels just it. Esc from
                // anywhere in the sheet reaches this .cancelAction equivalent only because
                // of `.interactiveDismissDisabled()` below.
                Button("Cancel", role: .cancel) {
                    if isPreviewingFile {
                        isPreviewingFile = false
                    } else if isKeyPress, findBar.handleEscape() {
                        // Esc with the find bar up closes it, never the sheet (a click on
                        // Cancel still cancels).
                    } else {
                        cancel()
                    }
                }
                .keyboardShortcut(.cancelAction)
                Button("Done") {
                    // Return while the file preview is up closes it, never the sheet.
                    guard !isPreviewingFile else {
                        isPreviewingFile = false
                        return
                    }
                    // Return typed in the find bar's fields is theirs (find next / replace).
                    if isKeyPress, findBar.handleReturn() { return }
                    // A titled snippet with no content can't be saved: offer to
                    // discard it or save the title text as the content. (Fully blank
                    // snippets just close — the list's onDismiss never commits a blank
                    // draft and sweeps stored ones.)
                    if hasTitleButNoContent {
                        showingEmptyContentAlert = true
                    } else {
                        finalizeFileStorage()
                        syncPreview()
                        try? context.save()
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        // The system's 20 pt dialog margins.
        .padding(20)
        // 748 pt inside the margins: wide enough for the format bar's full TextEdit set,
        // Highlight included (see `RichTextEditor.toolbar`); the main window's minimum width
        // keeps room for it.
        .frame(width: 788, height: 560)
        // Esc must act as Cancel. Esc typed in the text or the title becomes `cancelOperation:`,
        // which climbs to SwiftUI's sheet window, and that window closes the sheet itself
        // (`SheetPresentationWindow.cancelOperation:` calls its `onDismiss` while its
        // `handleEscapeKey` is set): no "Discard changes?" and no revert, so the edits stayed
        // saved. `handleEscapeKey` is `!interactiveDismissDisabled`
        // (`SheetBridge.hostingView(_:didChangePreferences:)`). Disabled, the window passes Esc
        // to `NSWindow`, whose `_cancelKey:` sends it as a key equivalent, which is Cancel's.
        // Closing from Cancel, Done or an alert uses `dismiss()`, which this doesn't block.
        .interactiveDismissDisabled()
        // Quick Look of the snippet's files (Space tap/hold or double-click on a file) —
        // the panel's snippet preview card, dimming the whole sheet behind it. It opens on the
        // selected file and pages through all of them.
        .overlay {
            if isPreviewingFile, snippet.isFile, !snippet.fileURLs.isEmpty {
                SnippetPreviewOverlay(snippet: snippet,
                                      onClose: { isPreviewingFile = false },
                                      startingAt: previewedFile,
                                      onPageChange: { previewedFile = $0 })
            }
        }
        // Holding Space (hold-to-preview) auto-repeats, and the repeats escaping to the
        // responder chain beeped on every one — consumed while the preview is open.
        .silencesSpaceRepeats(while: isPreviewingFile)
        .animation(.easeInOut(duration: 0.15), value: isPreviewingFile)
        // Snapshot the original content once, before any edits, so Cancel can restore it.
        .onAppear { if original == nil { original = Snapshot(snippet) } }
        .alert("You can't leave the content empty", isPresented: $showingEmptyContentAlert) {
            // Move to Content only makes sense for text — a title can't become a file;
            // in File mode the fix is adding a file, so offer to keep editing instead.
            if snippet.isFile {
                Button("Keep Editing", role: .cancel) {}
            } else {
                Button("Move to content") { moveTitleToContent() }
                    .keyboardShortcut(.defaultAction)
            }
            Button("Discard", role: .destructive) { discardSnippet() }
        } message: {
            Text(snippet.isFile
                ? String(localized: "A snippet must have a file. Add a file, or discard the snippet.")
                : String(localized: "A snippet must have content. Move the title to the content, or discard the snippet."))
        }
        // Cancel with edits made. Return discards, like the confirmation it answers;
        // Esc goes back to the editor with everything still there.
        .alert("Discard changes?", isPresented: $showingDiscardAlert) {
            Button("Discard Changes", role: .destructive) { discardChanges() }
                .keyboardShortcut(.defaultAction)
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your changes to this snippet will be lost.")
        }
        // Prewarm the font-family cache while the editor is still in Plain mode, so the
        // Rich toggle (and the toolbar's font picker) has the list ready instantly.
        .task { _ = await FontCatalog.families() }
    }

    // MARK: Mode control

    /// The type control in the header. A **new** draft can still pick any of the three
    /// types (so a file snippet can be created from New Snippet); an **existing**
    /// snippet is locked to its category — a text snippet toggles only Plain↔Rich (File is
    /// not offered), and a file snippet shows a fixed "File" label with no toggle at all.
    /// It's the history filter bar's glass capsule (`GlassSegmentedPicker`) rather than a
    /// native segmented `Picker`, which in a sheet fills the selection with the accent color.
    @ViewBuilder private var modeControl: some View {
        if snippet.isFile && !isNew {
            // A file snippet can't become text — it stays a file.
            Label("File", systemImage: "doc")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        } else {
            let text: [(SnippetMode, String)] = [(.plain, String(localized: "Plain Text")),
                                                 (.rich, String(localized: "Rich Text"))]
            GlassSegmentedPicker(isNew ? text + [(.file, String(localized: "File"))] : text,
                                 selection: modeBinding,
                                 accessibilityLabel: Text("Snippet Type"))
                .fixedSize()
        }
    }

    // MARK: Bindings

    private var plainBinding: Binding<String> {
        Binding(
            get: { String(data: snippet.payload, encoding: .utf8) ?? "" },
            set: { snippet.payload = Data($0.utf8) }
        )
    }

    private var rtfBinding: Binding<Data> {
        Binding(
            get: { snippet.payload },
            set: { snippet.payload = $0 }
        )
    }

    /// The Plain/Rich/File segment. Plain↔rich converts the payload; switches to/from
    /// File swap payloads through the session stashes (`stashedText`/`stashedFiles`) so
    /// neither the typed text nor the file list is lost until the sheet closes.
    private var modeBinding: Binding<SnippetMode> {
        Binding(
            get: { snippet.isFile ? .file : (snippet.isRichText ? .rich : .plain) },
            set: { switchMode(to: $0) }
        )
    }

    private func switchMode(to mode: SnippetMode) {
        let current: SnippetMode = snippet.isFile ? .file : (snippet.isRichText ? .rich : .plain)
        guard mode != current else { return }
        switch (current, mode) {
        case (.plain, .rich):
            let text = String(data: snippet.payload, encoding: .utf8) ?? snippet.plainPreview
            snippet.payload = richPayload(forPlain: text)
            snippet.isRichText = true
        case (.rich, .plain):
            let text = snippet.plainString
            richBeforePlain = RichStash(rtf: snippet.payload, plain: text)
            snippet.payload = Data(text.utf8)
            snippet.isRichText = false
        case (_, .file):
            stashedText = StashedText(isRich: snippet.isRichText, data: snippet.payload)
            snippet.isFile = true
            snippet.payload = stashedFiles ?? Data()
        case (.file, _):
            stashedFiles = snippet.payload
            snippet.isFile = false
            snippet.isRichText = mode == .rich
            snippet.payload = restoredTextPayload(rich: mode == .rich)
        default:
            break
        }
        syncPreview()
    }

    /// The stashed text payload converted to the target form (empty if nothing stashed).
    private func restoredTextPayload(rich: Bool) -> Data {
        guard let stash = stashedText else {
            return rich ? (NSAttributedString(string: "").rtf() ?? Data()) : Data()
        }
        if stash.isRich == rich { return stash.data }
        if rich {
            return richPayload(forPlain: String(data: stash.data, encoding: .utf8) ?? "")
        }
        // Lists keep their markers ("\t•\tItem"), which are part of the text, as in TextEdit.
        let text = NSAttributedString.withListMarkers(rtf: stash.data)?.string ?? ""
        return Data(text.utf8)
    }

    /// RTF for plain `text` going rich: the formatting a Rich→Plain switch flattened this
    /// session when the text is still exactly what that switch produced, else unstyled RTF.
    private func richPayload(forPlain text: String) -> Data {
        if let stash = richBeforePlain, stash.plain == text { return stash.rtf }
        return NSAttributedString(string: text).rtf() ?? Data()
    }

    /// Whether the button action running now came from the keyboard (its Esc / Return
    /// equivalent) rather than a click — only key presses defer to the find bar.
    private var isKeyPress: Bool { NSApp.currentEvent?.type == .keyDown }

    // MARK: File mode

    /// Appends the files among `urls` (a drop or the open panel) to the snippet's files, in the
    /// order given. A folder is added whole, as the folder itself, as Save as Snippet does with a
    /// copied folder. Non-file URLs and files the snippet already has are skipped, so
    /// dropping the same file twice doesn't paste it twice.
    private func addFiles(_ urls: [URL]) {
        var files = snippet.fileURLs
        var paths = Set(files.map { $0.standardizedFileURL.path(percentEncoded: false) })
        for url in urls.filter(isExistingFileURL) {
            let file = url.standardizedFileURL
            if paths.insert(file.path(percentEncoded: false)).inserted { files.append(file) }
        }
        guard files.count != snippet.fileURLs.count else { return }
        setFileURLs(files)
    }

    /// Drops `removed` from the snippet's files. Any stored copy among them is deleted on Done
    /// (`finalizeFileStorage`), not here, so Cancel can still bring it back.
    private func removeFiles(_ removed: Set<URL>) {
        setFileURLs(snippet.fileURLs.filter { !removed.contains($0) })
    }

    private func setFileURLs(_ urls: [URL]) {
        snippet.payload = Snippet.filePayload(urls)
        syncPreview()
    }

    /// On save, store the referenced originals in the managed store so moving or
    /// deleting the user's original no longer breaks the snippet, and reference the stored files.
    /// During editing the snippet references the picked file directly (so its real path shows and
    /// Quick Look/Missing work against it) — storing is deferred to here, so picking a file then
    /// Cancelling never writes to disk. Any copy this edit superseded (the file was replaced, or
    /// removed) is deleted so it doesn't orphan; an unchanged existing snippet already points at
    /// its copies, so neither step changes anything.
    private func finalizeFileStorage() {
        if snippet.isFile {
            let urls = snippet.fileURLs
            let stored = urls.map(Snippet.storedOrOriginal)
            if stored != urls { setFileURLs(stored) }
        }
        for previous in original?.fileURLs ?? [] where !snippet.fileURLs.contains(previous) {
            Snippet.deleteManagedFileCopy(previous)
        }
    }

    private func syncPreview() {
        // A file snippet previews as its file *names* (matching the `.file` item preview),
        // not the full paths `plainString` yields.
        if snippet.isFile {
            snippet.plainPreview = Snippet.fileNames(snippet.fileURLs)
        } else {
            // Keep line breaks — the snippet card shows up to 3 lines; single-line
            // surfaces (menu, panel row) collapse via menuPreview at display time.
            // Stored with its tabs, like a history item's; the previews take them out.
            snippet.plainPreview = snippet.plainString.multilinePreview(limit: 240, keepingTabs: true)
        }
    }

    private var hasTitleButNoContent: Bool {
        snippet.isEmpty && !snippet.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Cancel: closes at once when nothing changed, else asks before throwing the edits away.
    private func cancel() {
        if hasUnsavedChanges {
            showingDiscardAlert = true
        } else {
            discardChanges()
        }
    }

    /// Whether Cancel would lose anything. A new draft only has something to lose once it has
    /// a title or content (closing a blank one saves nothing either way); an existing snippet,
    /// once it differs from the on-open snapshot.
    private var hasUnsavedChanges: Bool {
        guard let original else { return false }
        if isNew {
            return !snippet.isEmpty || !snippet.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return original.differs(from: snippet)
    }

    /// Discard every change made this session and close. SwiftData autosaves the
    /// live model as it's edited, so reverting the fields to the on-open snapshot — not
    /// skipping `save()` — is what actually discards. A reverted new draft is left empty,
    /// so `finishEditing` never inserts it; an existing snippet keeps its original
    /// content. No empty-content prompt: Cancel already means "throw it away".
    private func discardChanges() {
        if let original {
            snippet.title = original.title
            snippet.isRichText = original.isRichText
            snippet.isFile = original.isFile
            snippet.payload = original.payload
            snippet.plainPreview = original.plainPreview
            try? context.save()
        }
        dismiss()
    }

    /// Discard from the empty-content alert: a new-snippet draft was never inserted
    /// — just close; only a stored snippet needs deleting. Also drop any managed file
    /// copy the snippet had stored, so discarding an emptied file snippet doesn't orphan it.
    private func discardSnippet() {
        snippet.deleteOwnedManagedFiles()
        original?.fileURLs.forEach(Snippet.deleteManagedFileCopy)
        if snippet.modelContext != nil {
            context.delete(snippet)
            try? context.save()
        }
        dismiss()
    }

    /// "Move to Content": the typed title becomes the snippet's content (UTF-8 plain,
    /// RTF when the editor is in rich mode), the title is left empty, and the snippet
    /// saves and closes.
    private func moveTitleToContent() {
        if snippet.isRichText {
            snippet.payload = NSAttributedString(string: snippet.title).rtf() ?? Data()
        } else {
            snippet.payload = Data(snippet.title.utf8)
        }
        snippet.title = ""
        syncPreview()
        try? context.save()
        dismiss()
    }
}

/// Whether a drop or the open panel carried a file or folder that's there — not a web URL. A
/// folder then adds its contents (`addFiles`).
private func isExistingFileURL(_ url: URL) -> Bool {
    url.isFileURL && FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
}

/// The File-mode content area: the snippet's files as a Finder-style icon grid.
/// Files are added by **dragging them from Finder** onto the area (empty or not), by
/// **clicking** the empty drop zone, or with **Add Files…**; dropping or picking several adds
/// them all, in order. The grid selects like Finder's icon view: click selects, ⌘-click
/// toggles, ⇧-click extends, the arrow keys move, and ⌫ / **Remove** removes the selection.
/// **Space / double-click** opens the Quick Look preview on the selected file, paging through
/// all of them, with the panel's tap-vs-hold Space split; the selection follows the
/// preview's page. Selection is keyboard focus: focus moving anywhere else clears it, so the
/// highlight always means Space works. A file that no longer exists at its path can't be
/// pasted, so its tile is dimmed and flagged as missing.
private struct FileSnippetList: View {
    let urls: [URL]
    @Binding var isPreviewing: Bool
    /// The file the preview shows: set here when it opens, then by the preview as it pages.
    @Binding var previewedFile: URL?
    let onAdd: ([URL]) -> Void
    let onRemove: (Set<URL>) -> Void

    @State private var isDropTargeted = false
    @State private var selection: Set<URL> = []
    /// The file last clicked or moved to: where ⇧-click ranges, arrow keys and Space start.
    @State private var anchor: URL?
    @FocusState private var isFocused: Bool
    /// The grid's visible size: sets the column count and vertically centres a short grid.
    @State private var gridSize: CGSize = .zero
    /// Tap-vs-hold state for Space, mirroring the panel / history pane.
    @State private var spaceDownTime: Date?
    @State private var spaceOpenedPreview = false
    private let holdThreshold: TimeInterval = 0.2

    private let tileWidth: CGFloat = 132
    private let tileSpacing: CGFloat = 12
    private let gridPadding: CGFloat = 20

    var body: some View {
        Group {
            if urls.isEmpty {
                emptyState
            } else {
                filledState
            }
        }
        // Fill the whole square with a soft tint while a drag hovers, so it reads
        // unmistakably as the drop target (works in both the empty and filled states).
        .background(
            dropShape
                .fill(.tint.opacity(isDropTargeted ? 0.12 : 0))
        )
        .dropDestination(for: URL.self) { dropped, _ in
            // Files and folders (which add their contents) — a drop of nothing but web URLs is
            // rejected, so it shows the "no" cursor rather than silently doing nothing.
            let files = dropped.filter(isExistingFileURL)
            guard !files.isEmpty else { return false }
            onAdd(files)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay(
            // A bold dashed border on drag-over — the classic "drop here" affordance.
            dropShape
                .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2.5, dash: [7, 5]))
                .opacity(isDropTargeted ? 1 : 0)
        )
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        // A removed file leaves the selection.
        .onChange(of: urls) { _, now in
            selection.formIntersection(now)
            if let anchor, !now.contains(anchor) { self.anchor = nil }
        }
        // Paging the preview moves the selection along, as Quick Look does in Finder. A page
        // that's already part of a multi-selection keeps that selection.
        .onChange(of: previewedFile) { _, file in
            guard isPreviewing, let file, urls.contains(file) else { return }
            if !selection.contains(file) { selection = [file] }
            anchor = file
        }
    }

    /// The drop highlight's outline: the lower part of the editor's card, below the title row's
    /// hairline, so only its bottom corners round, with the card's radius.
    private var dropShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(bottomLeadingRadius: SnippetEditorView.cardRadius,
                               bottomTrailingRadius: SnippetEditorView.cardRadius)
    }

    /// The empty state is itself the add control: clicking anywhere in it opens the file
    /// picker (drop still works). While a drag hovers, the prompt flips to a "release" cue.
    private var emptyState: some View {
        Button(action: chooseFiles) {
            ContentUnavailableView {
                Label(isDropTargeted ? String(localized: "Drop to Add") : String(localized: "No Files"),
                      systemImage: isDropTargeted ? "arrow.down.doc.fill" : "doc.badge.plus")
                    .foregroundStyle(isDropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            } description: {
                Text(isDropTargeted ? String(localized: "Release to add files.") : String(localized: "Drag files or folders here, or click to browse."))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var filledState: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(urls, id: \.self) { url in
                            FileSnippetTile(url: url, isSelected: selection.contains(url),
                                            onClick: { click(url) },
                                            onPreview: {
                                                select(only: url)
                                                startPreview(at: url)
                                            })
                                .id(url)
                                .contextMenu {
                                    Button("Quick Look") {
                                        select(only: url)
                                        startPreview(at: url)
                                    }
                                    Divider()
                                    Button("Remove", role: .destructive) {
                                        onRemove(selection.contains(url) ? selection : [url])
                                    }
                                }
                        }
                    }
                    .padding(gridPadding)
                    // At least as tall as the area, so a short grid (one file) sits centred.
                    .frame(maxWidth: .infinity, minHeight: gridSize.height)
                    // Clicks on the blank space around and between the tiles deselect.
                    .background {
                        Color.clear
                            .contentShape(.rect)
                            .onTapGesture { selection = [] }
                    }
                }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { gridSize = $0 }
                .onChange(of: anchor) { _, url in
                    if let url { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(url) } }
                }
            }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()   // the tiles draw their own selection highlight
            // Space: tap toggles, hold previews only while pressed — same key-up split as the
            // panel. Only fires while the grid holds focus, so typing a space into the
            // title field is untouched.
            .onKeyPress(.space, phases: [.down, .repeat, .up]) { press in
                switch press.phase {
                case .down: return handleSpaceDown()
                case .up: return handleSpaceUp()
                // Auto-repeat while held: swallow so it doesn't read as a second tap.
                default: return isPreviewing ? .handled : .ignored
                }
            }
            // While the preview is up with several files, its pager catches ←/→ first.
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat]) { press in
                move(press.key)
            }
            .onKeyPress(phases: .down) { press in
                // ⌫ arrives as DEL (U+007F) on macOS; ⌦ as `.deleteForward`.
                let isDelete = press.key == .delete || press.key == .deleteForward || press.characters == "\u{7F}"
                guard isDelete, press.modifiers.isEmpty, !isPreviewing, !selection.isEmpty else { return .ignored }
                onRemove(selection)
                return .handled
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { selection = [] }
            }

            Divider()
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Add Files…", systemImage: "plus", action: chooseFiles)
            Button("Remove", systemImage: "minus", role: .destructive) { onRemove(selection) }
                .disabled(selection.isEmpty)
            Spacer()
            if urls.count > 1 {
                Text("\(urls.count) files")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    /// As many fixed-width columns as fit, but no more than there are files, so a grid of a
    /// few files stays centred rather than hugging the leading edge.
    private var columnCount: Int {
        let usable = gridSize.width - 2 * gridPadding + tileSpacing
        return max(1, min(urls.count, Int(usable / (tileWidth + tileSpacing))))
    }

    /// Top-aligned, so icons line up across a row whatever the height of each tile's name and
    /// missing flag.
    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(tileWidth), spacing: tileSpacing, alignment: .top), count: columnCount)
    }

    // MARK: Selection

    private func select(only url: URL) {
        selection = [url]
        anchor = url
        isFocused = true
    }

    /// Finder's icon-view clicks: plain selects just this file, ⌘ toggles it, ⇧ selects the
    /// range from the anchor.
    private func click(_ url: URL) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
            anchor = url
            isFocused = true
        } else if flags.contains(.shift), let anchor,
                  let from = urls.firstIndex(of: anchor), let to = urls.firstIndex(of: url) {
            selection = Set(urls[min(from, to)...max(from, to)])
            isFocused = true
        } else {
            select(only: url)
        }
    }

    /// Arrow keys move a single selection through the grid: ←/→ by one file, ↑/↓ by a row.
    /// ↓ from the row above a shorter last row lands on the last file, as in Finder.
    private func move(_ key: KeyEquivalent) -> KeyPress.Result {
        guard !urls.isEmpty else { return .ignored }
        guard let current = anchor.flatMap(urls.firstIndex(of:)) else {
            select(only: urls[0])
            return .handled
        }
        let columns = columnCount
        var target: Int
        switch key {
        case .leftArrow: target = current - 1
        case .rightArrow: target = current + 1
        case .upArrow: target = current - columns
        default:
            target = current + columns
            if current / columns < (urls.count - 1) / columns { target = min(target, urls.count - 1) }
        }
        if urls.indices.contains(target) { select(only: urls[target]) }
        return .handled
    }

    // MARK: Preview

    /// The file Space opens the preview on: the anchor while it's selected, else the first
    /// selected file, else the first file.
    private var previewStart: URL? {
        if let anchor, selection.contains(anchor) { return anchor }
        return urls.first(where: selection.contains) ?? urls.first
    }

    private func startPreview(at url: URL) {
        previewedFile = url
        isPreviewing = true
    }

    /// Space pressed: open the preview (recording the press so key-up can tell tap from
    /// hold), or close it if it's already up (a tap toggles).
    private func handleSpaceDown() -> KeyPress.Result {
        if isPreviewing {
            isPreviewing = false
            return .handled
        }
        guard let start = previewStart else { return .ignored }
        startPreview(at: start)
        spaceOpenedPreview = true
        spaceDownTime = Date()
        return .handled
    }

    /// Space released: if this press opened the preview, a quick tap leaves it open and a
    /// long hold closes it on release — the panel's split.
    private func handleSpaceUp() -> KeyPress.Result {
        guard spaceOpenedPreview else { return .ignored }
        let held = spaceDownTime.map { Date().timeIntervalSince($0) } ?? 0
        spaceOpenedPreview = false
        spaceDownTime = nil
        if held >= holdThreshold { isPreviewing = false }
        return .handled
    }

    /// Files and folders, several at once. A folder is added whole (`addFiles`).
    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        if panel.runModal() == .OK { onAdd(panel.urls) }
    }
}

/// One file in the File-mode grid: its large file-type icon — never a content
/// thumbnail; the content preview is on demand via Space / double-click — over its name, and a
/// missing-file flag when it no longer exists at its path. `isSelected` paints **Finder-style
/// icon selection**: a soft rounded backdrop behind the icon and an accent pill behind the name.
/// Only the icon and the name take clicks — one click selects, double-click previews — so a
/// click on the space around them reaches the grid and deselects.
private struct FileSnippetTile: View {
    let url: URL
    let isSelected: Bool
    let onClick: () -> Void
    let onPreview: () -> Void

    var body: some View {
        let path = url.path(percentEncoded: false)
        let name = url.lastPathComponent.isEmpty ? path : url.lastPathComponent
        let missing = !FileManager.default.fileExists(atPath: path)
        VStack(spacing: 6) {
            // The OS supplies hi-res icon reps. Only the file identity dims when missing —
            // the flag below stays fully legible. The selection backdrop's padding is
            // reserved always, so selecting never shifts layout.
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                .opacity(missing ? 0.5 : 1)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.separator)
                        .opacity(isSelected ? 1 : 0)
                )
                .contentShape(.rect)
                // Simultaneous select so the first click of a double-click already selects,
                // with no disambiguation delay on a plain single click.
                .onTapGesture(count: 2, perform: onPreview)
                .simultaneousGesture(TapGesture().onEnded(onClick))

            Text(name)
                .font(.callout)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isSelected ? Color.accentColor : Color.clear)
                )
                .opacity(missing ? 0.5 : 1)
                .contentShape(.rect)
                .onTapGesture(count: 2, perform: onPreview)
                .simultaneousGesture(TapGesture().onEnded(onClick))

            if missing {
                Label("File is missing", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: 132, alignment: .top)
        .help(name)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Quick Look", onPreview)
    }
}

/// Process-wide cache of the installed font-family list for the format bar's font
/// picker. The first font-registry enumeration is expensive (tens to hundreds of ms
/// cold) and used to run synchronously inside the toolbar's first render, stalling the
/// editor sheet as it opened — so it must never run during a body render. Families are
/// enumerated off the main thread via CoreText (thread-safe, unlike `NSFontManager`),
/// hidden "."-prefixed system families dropped, and the result kept for the process's
/// lifetime; every open after the first is served from the cache synchronously.
@MainActor
private enum FontCatalog {
    private static var cached: [String]?

    static func families() async -> [String] {
        if let cached { return cached }
        let names = await Task.detached(priority: .userInitiated) {
            ((CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? [])
                .filter { !$0.hasPrefix(".") }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }.value
        cached = names
        return names
    }
}

/// RTF editor styled after macOS TextEdit's format bar: B·I·U·S,
/// text + highlight color, font family/size, paragraph alignment, lists and line
/// spacing, over an `EditorTextView` with TextEdit's ruler (indents and tab stops, see
/// `EditorRulerView`). The app is an agent (`LSUIElement`)
/// with no system Format menu, so all formatting is driven by this bar / its
/// ⌘B·⌘I·⌘U shortcuts, plus the TextEdit menu equivalents `EditorTextView` handles itself
/// (⌘+/⌘− size, ⌘{ ⌘| ⌘} alignment, ⌥⌘C/⌥⌘V style, ⌥⇧⌘V paste and match style, ⌘R ruler,
/// ⌃⌘C/⌃⌘V copy/paste ruler, the find bar).
private struct RichTextEditor: View {
    @Binding var rtfData: Data
    let findBar: FindBarHost
    @State private var controller = RichTextController()
    @State private var showingCustomMarker = false
    @State private var customMarker = ""
    // Loaded async from FontCatalog; empty only for the first instants of the very
    // first open (the picker shows the system font + caret family until it lands).
    @State private var installedFamilies: [String] = []

    private typealias ListKind = RichTextController.ListKind

    private let fontSizes: [CGFloat] = [9, 10, 11, 12, 13, 14, 18, 24, 36, 48, 64, 72]
    // Mirrors the native macOS line-spacing menu: 0.5…1.5 in 0.1 steps, then 2.0.
    private let lineSpacings: [(label: String, value: CGFloat)] =
        [("0.5", 0.5), ("0.6", 0.6), ("0.7", 0.7), ("0.8", 0.8), ("0.9", 0.9),
         ("1.0", 1.0), ("1.1", 1.1), ("1.2", 1.2), ("1.3", 1.3), ("1.4", 1.4),
         ("1.5", 1.5), ("2.0", 2.0)]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            RichTextView(rtfData: $rtfData, controller: controller, findBar: findBar)
        }
        .task { installedFamilies = await FontCatalog.families() }
    }

    // MARK: Toolbar

    // Single non-scrolling row: the groups are sized to fit the fixed-width editor
    // window, so there's no horizontal scroll bar. At minimum gaps the
    // groups + this row's padding (743pt with the ruler button, measured November 3, 2026)
    // must stay under ~748pt (the 788pt sheet minus its
    // 20pt margins): a wider row doesn't clip — it overflows the proposed width and drags the
    // content card's right edge past the header's, breaking the sheet's right
    // padding. The dividers' flexible gaps absorb any width left over, spreading the
    // groups across the full row so the trailing inset stays equal to the leading one.
    private var toolbar: some View {
        HStack(spacing: 0) {
            styleGroup
            barDivider
            colorGroup
            barDivider
            fontGroup
            barDivider
            alignmentGroup
            barDivider
            paragraphGroup
            barDivider
            highlightGroup
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 40)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var styleGroup: some View {
        HStack(spacing: 2) {
            styleButton("bold", active: controller.isBold, shortcut: "b", help: String(localized: "Bold (⌘B)")) {
                controller.toggleBold()
            }
            styleButton("italic", active: controller.isItalic, shortcut: "i", help: String(localized: "Italic (⌘I)")) {
                controller.toggleItalic()
            }
            styleButton("underline", active: controller.isUnderline, shortcut: "u", help: String(localized: "Underline (⌘U)")) {
                controller.toggleUnderline()
            }
            styleButton("strikethrough", active: controller.isStrikethrough, shortcut: "x",
                        modifiers: [.command, .shift], help: String(localized: "Strikethrough (⌘⇧X)")) {
                controller.toggleStrikethrough()
            }
        }
    }

    private var colorGroup: some View {
        HStack(spacing: 5) {
            FormatBarColorWellView(kind: .text, color: controller.textColor,
                                   help: String(localized: "Text color")) { controller.applyColor($0) }
                .frame(width: 20, height: 20)
            FormatBarColorWellView(kind: .background, color: controller.backgroundColor,
                                   help: String(localized: "Text background color")) { controller.applyBackgroundColor($0) }
                .frame(width: 20, height: 20)
        }
    }

    private var fontGroup: some View {
        HStack(spacing: 6) {
            // Menu + inline Picker rather than a .menu Picker: SwiftUI builds a .menu
            // Picker's ~250 family items eagerly on every toolbar render (~170 ms
            // release, worse in debug) — it was the dominant cost of opening the rich
            // editor and re-ran on each caret move. Menu content is only built when
            // clicked, so the closed control renders just its label; the inline Picker
            // still checkmarks the active family. Sized to fit a typical family name;
            // longer names truncate with "…" so the control stays compact.
            Menu {
                Picker("Font", selection: fontFamilyBinding) {
                    ForEach(fontFamilies, id: \.self) { Text(fontDisplayName($0)).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(fontDisplayName(controller.fontFamily))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 92)
            .help("Font")

            // Editable combo box: type a size with the keyboard or pick a preset.
            FontSizeField(size: fontSizeBinding, presets: fontSizes) { controller.focusText() }
                .frame(width: 56)
                .help("Size")
        }
    }

    private var alignmentGroup: some View {
        HStack(spacing: 2) {
            alignButton(.left, "text.alignleft", help: String(localized: "Align Left"))
            alignButton(.center, "text.aligncenter", help: String(localized: "Center"))
            alignButton(.right, "text.alignright", help: String(localized: "Align Right"))
            alignButton(.justified, "text.justify", help: String(localized: "Justify"))
        }
    }

    private var paragraphGroup: some View {
        HStack(spacing: 6) {
            // TextEdit's Lists popup, style for style (the one AppKit builds for its ruler,
            // `-[_NSTextViewRulerHelper _rulerAccViewSetUpLists]`): None, the bullets, then the
            // numbered styles, each making TextEdit's own list (`ListKind.markerFormat`). An
            // inline Picker bound to the detected list kind gives each style a native checkmark
            // when active; default menu style (not .borderlessButton) gives the same gray
            // pop-up box as the font picker.
            Menu {
                Picker("List style", selection: listBinding) {
                    Text("None").tag(ListKind.none)
                    Text("⁃   Dash").tag(ListKind.dash)
                    Text("•   Bullet").tag(ListKind.bullet)
                    Text("▪   Square").tag(ListKind.square)
                    Text("✓   Check").tag(ListKind.check)
                    Text("1.   2.   3.").tag(ListKind.decimalDot)
                    Text("1)   2)   3)").tag(ListKind.decimalParen)
                    Text("A.   B.   C.").tag(ListKind.upperAlphaDot)
                    Text("a.   b.   c.").tag(ListKind.lowerAlphaDot)
                    Text("a)   b)   c)").tag(ListKind.lowerAlphaParen)
                    Text("I.   II.   III.").tag(ListKind.upperRomanDot)
                    Text("i.   ii.   iii.").tag(ListKind.lowerRomanDot)
                    // Surface the active custom marker, or a TextEdit list in a style this
                    // menu doesn't offer, as a checked row, so detection has a tag to match
                    // (and to show what's applied).
                    switch controller.currentList {
                    case .custom(let marker):
                        Text("Custom (\(marker))").tag(ListKind.custom(marker))
                    case .otherTextList(let format):
                        Text(verbatim: ListKind.title(ofMarkerFormat: format)).tag(ListKind.otherTextList(format))
                    default:
                        EmptyView()
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                Button("Other…") {
                    customMarker = ""
                    showingCustomMarker = true
                }
            } label: {
                Image(systemName: "list.bullet")
            }
            .fixedSize()
            .help("Lists")
            .alert("Custom List Marker", isPresented: $showingCustomMarker) {
                TextField("Marker", text: $customMarker)
                Button("Cancel", role: .cancel) {}
                Button("Apply") {
                    let trimmed = customMarker.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { controller.setList(.custom(trimmed)) }
                }
            } message: {
                Text("Enter the character(s) to use as the marker for each list line, e.g. ★, →, or §.")
            }

            Picker("", selection: lineSpacingBinding) {
                ForEach(lineSpacings, id: \.value) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 64)
            .help("Line spacing")

            // TextEdit's Format › Text › Show/Hide Ruler, which this agent app has no menu for.
            BarIconButton(symbol: "ruler", active: controller.isRulerVisible,
                          help: controller.isRulerVisible
                              ? String(localized: "Hide Ruler (⌘R)")
                              : String(localized: "Show Ruler (⌘R)")) {
                controller.toggleRuler()
            }
        }
    }

    /// TextEdit's Highlight control (the last group of its macOS 26 format bar): the
    /// highlighter toggles a highlight on the selection, the circle beside it picks the
    /// highlight color from TextEdit's menu (Accent, then Purple…Blue) and shows, live with the
    /// caret, the highlight's color — a blank dotted circle on unhighlighted text. Highlights are the
    /// system's `textHighlightStyle` / `textHighlightColorScheme` attributes, which RTF keeps
    /// (`\AppleHighlight`), so they survive in the snippet; apps that don't know them paste
    /// the text unhighlighted.
    private var highlightGroup: some View {
        HStack(spacing: 2) {
            BarIconButton(symbol: "highlighter", active: controller.isHighlighted,
                          help: String(localized: "Highlight")) {
                controller.toggleHighlight()
            }
            HighlightColorButton(shownScheme: controller.isHighlighted ? controller.highlightScheme : nil,
                                 checkedScheme: controller.highlightScheme) { controller.setHighlightScheme($0) }
        }
    }

    // MARK: Buttons

    private func styleButton(
        _ symbol: String, active: Bool, shortcut: KeyEquivalent,
        modifiers: EventModifiers = .command, help: String, action: @escaping () -> Void
    ) -> some View {
        BarIconButton(symbol: symbol, active: active, help: help, action: action)
            .keyboardShortcut(shortcut, modifiers: modifiers)
    }

    private func alignButton(_ alignment: NSTextAlignment, _ symbol: String, help: String) -> some View {
        BarIconButton(symbol: symbol, active: controller.alignment == alignment, help: help) {
            controller.setAlignment(alignment)
        }
    }

    /// Thin separator between the format bar's groups (shorter than the row, so it reads
    /// as a group break rather than a boxed segment edge). The flexible gaps on both
    /// sides share the row's leftover width equally, so the groups spread edge-to-edge
    /// and the row's right inset matches its left padding instead of pooling the slack
    /// after the last group.
    private var barDivider: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 6)
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1, height: 16)
            Spacer(minLength: 6)
        }
    }

    // MARK: Picker data

    /// The macOS system UI font reports a private family name (".AppleSystemUIFont")
    /// that the installed-families list never contains, so RTF authored in the system
    /// font would leave the family Picker with a selection that has no matching tag
    /// (SwiftUI's "selection … is invalid and does not have an associated tag" warning).
    /// Always surface it as a stable, friendly first entry so the selection's tag is
    /// present in every render.
    private static let systemFontFamily =
        NSFont.systemFont(ofSize: NSFont.systemFontSize).familyName ?? ".AppleSystemUIFont"

    private var fontFamilies: [String] {
        var all = installedFamilies
        all.insert(Self.systemFontFamily, at: 0)
        // Whatever the caret currently uses must be selectable, even an unlisted font.
        if !all.contains(controller.fontFamily) { all.insert(controller.fontFamily, at: 1) }
        return all
    }

    private func fontDisplayName(_ family: String) -> String {
        family == Self.systemFontFamily ? String(localized: "System Font") : family
    }

    // MARK: Bindings — custom getters read controller state without re-applying, so
    // refreshState() can update a control's displayed value without looping.

    private var fontFamilyBinding: Binding<String> {
        Binding(get: { controller.fontFamily }, set: { controller.setFontFamily($0) })
    }
    private var fontSizeBinding: Binding<CGFloat> {
        Binding(get: { controller.fontSize }, set: { controller.setFontSize($0) })
    }
    private var lineSpacingBinding: Binding<CGFloat> {
        Binding(get: { controller.lineHeightMultiple }, set: { controller.setLineHeightMultiple($0) })
    }
    private var listBinding: Binding<ListKind> {
        Binding(get: { controller.currentList }, set: { controller.setList($0) })
    }
}

/// Flat format-bar icon button — the single visual language for the style (B·I·U·S) and
/// alignment groups: a rounded hover highlight, an accent-tinted active state (background
/// + glyph), and a slight dim while pressed. Replaces the old boxed segments so the bar
/// matches the flat toolbars of modern macOS apps.
private struct BarIconButton: View {
    let symbol: String
    var active: Bool
    var help: String
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : .primary)
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(active
                            ? Color.accentColor.opacity(0.18)
                            : isHovered ? Color.primary.opacity(0.08) : .clear)
                )
                .contentShape(.rect)
        }
        .buttonStyle(PressDimButtonStyle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: active)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// `.plain`-like button style that dims the label while pressed, so flat icon buttons
/// still give click feedback.
private struct PressDimButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.55 : 1)
    }
}

/// Editable font-size control: an `NSComboBox` so the user can type a
/// size with the keyboard or pick one of the presets from the dropdown. Input is
/// validated on commit (whole positive points) — no `NSFormatter`, which would grey out
/// the string list items. Return confirms the typed size and Esc drops it; either way the
/// field hands focus back through `onFinish`, and neither reaches the sheet's Done / Cancel.
private struct FontSizeField: NSViewRepresentable {
    @Binding var size: CGFloat
    let presets: [CGFloat]
    /// Leaves the field (the format bar puts the caret back in the text).
    var onFinish: () -> Void = {}

    func makeNSView(context: Context) -> NSComboBox {
        let combo = NSComboBox()
        combo.controlSize = .small
        combo.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        combo.delegate = context.coordinator
        combo.completes = false
        combo.hasVerticalScroller = true
        combo.numberOfVisibleItems = presets.count
        combo.addItems(withObjectValues: presets.map { String(Int($0)) })
        combo.stringValue = String(Int(size))
        return combo
    }

    func updateNSView(_ nsView: NSComboBox, context: Context) {
        // Don't clobber the field while the user is typing in it.
        guard nsView.currentEditor() == nil else { return }
        let current = String(Int(size))
        if nsView.stringValue != current { nsView.stringValue = current }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        let parent: FontSizeField
        init(_ parent: FontSizeField) { self.parent = parent }

        // Picking from the dropdown. AppKit doesn't reliably commit the chosen row into
        // the field here, so set the displayed value ourselves; defer the binding write
        // since mutating it synchronously mid-selection gets dropped.
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let combo = notification.object as? NSComboBox else { return }
            let index = combo.indexOfSelectedItem
            guard parent.presets.indices.contains(index) else { return }
            let value = parent.presets[index]
            combo.stringValue = String(Int(value))
            DispatchQueue.main.async { [parent] in parent.size = value }
        }

        /// Return and Esc, taken before the field acts on them. Left to AppKit, Return ends the
        /// editing and — the field having no action of its own to send — `-[NSTextField
        /// textDidEndEditing:]` then offers the key to the window as a key equivalent, which
        /// pressed the sheet's Done and closed the editor; Esc travels up the responder chain
        /// to the sheet's Cancel, discarding the whole edit.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                // Leaving the field ends its editing, which applies the size
                // (`controlTextDidEndEditing`).
                parent.onFinish()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                // Drop what was typed: the field shows the size in use again and nothing is
                // applied, so a selection of mixed sizes keeps them.
                control.abortEditing()
                control.stringValue = String(Int(parent.size))
                parent.onFinish()
                return true
            default:
                return false
            }
        }

        // Keyboard entry committed via Return / focus loss; revert anything non-numeric.
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let combo = notification.object as? NSComboBox else { return }
            if let value = Int(combo.stringValue), value > 0 {
                parent.size = CGFloat(value)
            } else {
                combo.stringValue = String(Int(parent.size))
            }
        }
    }
}

/// Bridges the format bar to the live `NSTextView`: applies traits/attributes/paragraph
/// styles to the selection (and typing attributes, so continued typing keeps the format)
/// and publishes the formatting at the caret back to the bar.
@MainActor
@Observable
private final class RichTextController {
    /// The marker styles offered by the Lists popup. All but `custom` are TextEdit's lists: an
    /// `NSTextList` in TextEdit's marker format (`markerFormat`), set up as TextEdit sets it up
    /// (`NSTextView.setTextEditList`), so a list copied from one app pastes into the other as
    /// that list. `custom` carries an arbitrary marker string entered via "Other…", which is
    /// typed into the text instead (`setCustomList`).
    enum ListKind: Hashable {
        case none
        case dash, bullet, square, check
        case decimalDot, decimalParen
        case upperAlphaDot, lowerAlphaDot, lowerAlphaParen
        case upperRomanDot, lowerRomanDot
        /// A TextEdit list in a style the popup doesn't offer (TextEdit's Bullets and Numbering
        /// panel has more), by its marker format, so the popup can show and check it.
        case otherTextList(String)
        case custom(String)

        /// The marker format of each style TextEdit's Lists popup offers: its items'
        /// represented objects, in its order (the options are always 0).
        private static let textEditFormats: [(kind: ListKind, format: String)] = [
            (.dash, "{hyphen}"), (.bullet, "{disc}"), (.square, "{square}"), (.check, "{check}"),
            (.decimalDot, "{decimal}."), (.decimalParen, "{decimal})"),
            (.upperAlphaDot, "{upper-alpha}."), (.lowerAlphaDot, "{lower-alpha}."),
            (.lowerAlphaParen, "{lower-alpha})"), (.upperRomanDot, "{upper-roman}."),
            (.lowerRomanDot, "{lower-roman}."),
        ]

        /// The style of a TextEdit list in `format`.
        init(markerFormat format: NSTextList.MarkerFormat) {
            self = Self.textEditFormats.first { $0.format == format.rawValue }?.kind
                ?? .otherTextList(format.rawValue)
        }

        /// The `NSTextList` marker format of the list this style makes; nil for None and custom.
        var markerFormat: NSTextList.MarkerFormat? {
            if case .otherTextList(let format) = self { return NSTextList.MarkerFormat(rawValue: format) }
            return Self.textEditFormats.first { $0.kind == self }.map { NSTextList.MarkerFormat(rawValue: $0.format) }
        }

        /// The popup's row for a list in `format`: its marker, or its first three for a
        /// numbered list, like the popup's own numbered rows.
        static func title(ofMarkerFormat format: String) -> String {
            let list = NSTextList(markerFormat: NSTextList.MarkerFormat(rawValue: format), options: 0)
            guard list.isOrdered else { return list.marker(forItemNumber: 1) }
            return (1...3).map { list.marker(forItemNumber: $0) }.joined(separator: "   ")
        }
    }

    /// The list style detected at the caret (drives the Lists popup checkmark).
    var currentList: ListKind = .none

    weak var textView: NSTextView?

    // Published toolbar state (updated by refreshState()).
    var isBold = false
    var isItalic = false
    var isUnderline = false
    var isStrikethrough = false
    var fontFamily = "Helvetica"
    var fontSize: CGFloat = 12
    var alignment: NSTextAlignment = .left
    var lineHeightMultiple: CGFloat = 1.0
    /// The selection's text color — `.textColor` where the text has no color of its own.
    var textColor: NSColor = .textColor
    /// The selection's background color; nil where it has none.
    var backgroundColor: NSColor?
    var isHighlighted = false
    /// The highlight color the Highlight control checks in its menu: the selection's, on
    /// highlighted text (the button shows it then), else the one last picked — which the next
    /// highlight uses. nil until one is picked (nothing checked, as in TextEdit).
    var highlightScheme: NSAttributedString.TextHighlightColorScheme?
    private var chosenHighlightScheme: NSAttributedString.TextHighlightColorScheme?
    /// Whether the ruler is showing (the ruler button's state).
    var isRulerVisible = false

    /// Puts keyboard focus back in the text, as after confirming or cancelling the size field.
    func focusText() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }

    // MARK: Ruler

    /// Show / Hide Ruler (⌘R): AppKit's own `toggleRuler(_:)`, as in TextEdit. The choice
    /// is remembered for the next rich snippet opened.
    func toggleRuler() {
        guard let tv = textView else { return }
        tv.toggleRuler(nil)
        isRulerVisible = tv.isRulerVisible
        UserDefaults.standard.set(isRulerVisible, forKey: Pref.Key.showsSnippetRuler)
        (tv as? EditorTextView)?.refreshRuler()
    }

    // MARK: Character formatting

    func toggleBold() { toggleTrait(mask: .boldFontMask, symbolic: .bold) }
    func toggleItalic() { toggleTrait(mask: .italicFontMask, symbolic: .italic) }
    func toggleUnderline() { toggleAttribute(.underlineStyle) }
    func toggleStrikethrough() { toggleAttribute(.strikethroughStyle) }

    func setFontFamily(_ family: String) {
        let fm = NSFontManager.shared
        applyFont { fm.convert($0, toFamily: family) }
    }

    func setFontSize(_ size: CGFloat) {
        let fm = NSFontManager.shared
        applyFont { fm.convert($0, toSize: size) }
    }

    /// TextEdit's Format › Font › Bigger / Smaller (⌘+ / ⌘−): steps each run's own size by
    /// `delta` points, so mixed sizes in the selection keep their proportions.
    func stepFontSize(by delta: CGFloat) {
        let fm = NSFontManager.shared
        applyFont { fm.convert($0, toSize: max(1, $0.pointSize + delta)) }
    }

    /// Sets the selected text's color; the popover's "no color" returns it to the default
    /// text color.
    func applyColor(_ color: NSColor) {
        apply(color, as: .foregroundColor)
    }

    /// Sets the selected text's background color; the popover's "no color" removes it.
    func applyBackgroundColor(_ color: NSColor) {
        apply(color, as: .backgroundColor)
    }

    /// A color well's pick: a fully transparent color is its "no color" cell, which clears
    /// the attribute rather than painting it invisible.
    private func apply(_ color: NSColor, as key: NSAttributedString.Key) {
        guard let tv = textView else { return }
        if Self.isClear(color) {
            removeAttribute(key, from: tv)
        } else {
            setAttribute(key, value: color, to: tv)
        }
        refreshState()
    }

    private static func isClear(_ color: NSColor) -> Bool {
        (color.usingColorSpace(.sRGB) ?? color).alphaComponent == 0
    }

    // MARK: Highlight

    /// The highlighter: removes the highlight from highlighted text, else highlights the
    /// selection (or what's typed next, at a caret) in the chosen color.
    func toggleHighlight() {
        guard let tv = textView else { return }
        if isHighlighted {
            removeAttributes([.textHighlightStyle, .textHighlightColorScheme], from: tv)
        } else {
            highlight(in: chosenHighlightScheme ?? .default, tv)
        }
        refreshState()
    }

    /// Picks the highlight color for the next highlight, and recolors the selection — or the
    /// highlight being typed — right away, as TextEdit's Highlight color menu does.
    func setHighlightScheme(_ scheme: NSAttributedString.TextHighlightColorScheme) {
        chosenHighlightScheme = scheme
        guard let tv = textView else { return }
        if tv.selectedRange().length > 0 || isHighlighted { highlight(in: scheme, tv) }
        refreshState()
    }

    private func highlight(in scheme: NSAttributedString.TextHighlightColorScheme, _ tv: NSTextView) {
        setAttributes([.textHighlightStyle: NSAttributedString.TextHighlightStyle.default,
                       .textHighlightColorScheme: scheme], to: tv)
    }

    // MARK: Paragraph formatting

    func setAlignment(_ alignment: NSTextAlignment) {
        applyParagraphStyle { $0.alignment = alignment }
    }

    func setLineHeightMultiple(_ value: CGFloat) {
        applyParagraphStyle { $0.lineHeightMultiple = value }
    }

    /// The Lists popup's choice, made on the selected paragraphs as TextEdit makes it: a style
    /// or None goes through TextEdit's own list code (`setTextEditList`), "Other…"'s marker is
    /// typed into the lines (`setCustomList`).
    func setList(_ kind: ListKind) {
        guard let tv = textView else { return }
        if case .custom(let marker) = kind {
            setCustomList(marker, in: tv)
        } else {
            tv.setTextEditList(kind.markerFormat)
        }
        refreshState()
    }

    /// "Other…": `marker` and a tab typed at the start of each selected line with text, after
    /// any marker the line had. A line in a TextEdit list leaves it (only the selected lines),
    /// as None would leave it, so the line doesn't end up with two markers.
    private func setCustomList(_ marker: String, in tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let ns = storage.mutableString
        var paraRange = ns.paragraphRange(for: tv.selectedRange())
        paraRange.length -= tv.removeTextLists(in: paraRange)

        // Last line first, so each insertion leaves the lines before it where they were.
        var lines: [NSRange] = []
        ns.enumerateSubstrings(in: paraRange, options: [.byLines, .substringNotRequired]) { _, _, enclosing, _ in
            lines.append(enclosing)
        }
        for line in lines.reversed() {
            let text = ns.substring(with: line)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let attrs = line.location < storage.length
                ? storage.attributes(at: line.location, effectiveRange: nil)
                : tv.typingAttributes
            let start = NSRange(location: line.location, length: 0)
            let typed = marker + "\t"
            guard tv.shouldChangeText(in: start, replacementString: typed) else { continue }
            storage.beginEditing()
            storage.replaceCharacters(in: start, with: NSAttributedString(string: typed, attributes: attrs))
            storage.endEditing()
            tv.didChangeText()
        }
    }

    /// Return on a line with a typed marker ("Other…"'s, or any style from before lists were
    /// TextEdit's), the way TextEdit's lists behave: the new line gets the next marker
    /// (numbered styles count on, renumbering the items below), and Return on an item with no
    /// text ends the list by removing its marker. Returns `false` — leaving Return to the text
    /// view — off such a line, with the caret inside the marker, or with a selection. In a
    /// TextEdit list the text view does all that itself (`insertNewline:`), as in TextEdit.
    func continueList() -> Bool {
        guard let tv = textView, let storage = tv.textStorage else { return false }
        let selection = tv.selectedRange()
        guard selection.length == 0 else { return false }
        let ns = storage.string as NSString
        let line = ns.lineRange(for: NSRange(location: selection.location, length: 0))
        if line.location < storage.length,
           let style = storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle,
           !style.textLists.isEmpty { return false }
        let markerLength = Self.listMarkerLength(ns.substring(with: line))
        guard markerLength > 0, selection.location >= line.location + markerLength else { return false }
        let kind = detectListKind()
        guard kind != .none else { return false }

        var contentsEnd = 0
        ns.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: line)
        let itemStart = line.location + markerLength
        let itemText = ns.substring(with: NSRange(location: itemStart, length: max(0, contentsEnd - itemStart)))
        let markerBody = Self.markerBody(in: ns, line: line) ?? ""
        let ordinal = Self.ordinal(of: markerBody, kind: kind)
        if itemText.trimmingCharacters(in: .whitespaces).isEmpty {
            // An empty item: leave the list, as TextEdit does. Numbered items below it move
            // up into the number it gave up.
            let marker = NSRange(location: line.location, length: markerLength)
            if tv.shouldChangeText(in: marker, replacementString: "") {
                storage.replaceCharacters(in: marker, with: "")
                tv.didChangeText()
                if let ordinal { renumberList(kind, after: line.location, from: ordinal) }
            }
            refreshState()
            return true
        }

        let next = (ordinal ?? 0) + 1
        let insertion = "\n" + Self.listMarker(kind, number: next)
        // A plain undoable replacement, not `insertText`: typing's undo coalescing would
        // split the new line and the renumbering into separate undo steps. Breaking
        // coalescing first keeps the item's typed text its own step, as a Return is.
        tv.breakUndoCoalescing()
        guard tv.shouldChangeText(in: selection, replacementString: insertion) else { return true }
        storage.replaceCharacters(in: selection, with: NSAttributedString(string: insertion, attributes: tv.typingAttributes))
        tv.didChangeText()
        let caret = selection.location + (insertion as NSString).length
        tv.setSelectedRange(NSRange(location: caret, length: 0))
        renumberList(kind, after: caret, from: next + 1)
        tv.scrollRangeToVisible(tv.selectedRange())
        refreshState()
        return true
    }

    /// Re-marks the contiguous list lines after the caret's line `start + 0, +1, …`, so a
    /// numbered item inserted mid-list pushes the ones below it down. Static markers
    /// (bullets, custom) don't count, so they're left alone.
    private func renumberList(_ kind: ListKind, after location: Int, from start: Int) {
        switch kind {
        case .decimalDot, .decimalParen, .upperAlphaDot, .lowerAlphaDot, .lowerAlphaParen,
             .upperRomanDot, .lowerRomanDot: break
        default: return
        }
        guard let tv = textView, let storage = tv.textStorage else { return }
        let ns = storage.string as NSString
        var lineStart = NSMaxRange(ns.lineRange(for: NSRange(location: location, length: 0)))
        var edits: [(range: NSRange, marker: String)] = []
        var number = start
        // The "." / ")" this style's markers end in — a line ending its marker otherwise, or
        // not numbered in this style at all, ends the list (e.g. a bullet list right below).
        let suffix = Self.listMarker(kind, number: 1).dropLast().last
        while lineStart < ns.length {
            let line = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            let length = Self.listMarkerLength(ns.substring(with: line))
            guard length > 0, let body = Self.markerBody(in: ns, line: line), body.last == suffix,
                  Self.ordinal(of: body, kind: kind) != nil else { break }
            let marker = Self.listMarker(kind, number: number)
            let range = NSRange(location: line.location, length: length)
            if ns.substring(with: range) != marker { edits.append((range, marker)) }
            number += 1
            lineStart = NSMaxRange(line)
        }
        guard !edits.isEmpty else { return }
        let span = NSRange(location: edits[0].range.location,
                           length: NSMaxRange(edits[edits.count - 1].range) - edits[0].range.location)
        let replacement = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: span))
        // Back to front, so earlier ranges stay valid as marker widths change (9. → 10.).
        for edit in edits.reversed() {
            let local = NSRange(location: edit.range.location - span.location, length: edit.range.length)
            let attrs = replacement.attributes(at: local.location, effectiveRange: nil)
            replacement.replaceCharacters(in: local, with: NSAttributedString(string: edit.marker, attributes: attrs))
        }
        // The real replacement string — `nil` would register an attributes-only undo.
        guard tv.shouldChangeText(in: span, replacementString: replacement.string) else { return }
        storage.replaceCharacters(in: span, with: replacement)
        tv.didChangeText()
    }

    /// The item number a marker body (sans tab) stands for in `kind`'s numbering — the
    /// inverse of `listMarker` — or nil for the static styles.
    private static func ordinal(of body: String, kind: ListKind) -> Int? {
        let core = String(body.dropLast())   // drop the "." / ")"
        switch kind {
        case .decimalDot, .decimalParen:
            return Int(core)
        case .upperAlphaDot, .lowerAlphaDot, .lowerAlphaParen:
            var value = 0
            for scalar in core.uppercased().unicodeScalars {
                guard (65...90).contains(scalar.value) else { return nil }
                value = value * 26 + Int(scalar.value - 64)
            }
            return value
        case .upperRomanDot, .lowerRomanDot:
            let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000]
            let digits = core.uppercased().compactMap { values[$0] }
            guard digits.count == core.count, !digits.isEmpty else { return nil }
            var total = 0
            for (i, digit) in digits.enumerated() {
                total += i + 1 < digits.count && digit < digits[i + 1] ? -digit : digit
            }
            return total
        default:
            return nil
        }
    }

    /// Reflects the formatting at the caret/selection onto the toolbar. Runs on every caret move,
    /// so it writes only values that changed (`update`): each write notifies observers, and
    /// unconditional writes re-rendered the whole format bar on every keystroke.
    func refreshState() {
        let font = activeFont
        let symbolic = font.fontDescriptor.symbolicTraits
        update(\.isBold, symbolic.contains(.bold))
        update(\.isItalic, symbolic.contains(.italic))
        update(\.isUnderline, attributeActive(.underlineStyle))
        update(\.isStrikethrough, attributeActive(.strikethroughStyle))
        update(\.fontFamily, font.familyName ?? font.fontName)
        update(\.fontSize, font.pointSize)
        let para = activeParagraphStyle
        let resolved = para?.alignment ?? .left
        update(\.alignment, resolved == .natural ? .left : resolved)
        let lhm = para?.lineHeightMultiple ?? 0
        update(\.lineHeightMultiple, lhm == 0 ? 1.0 : lhm)
        update(\.textColor, activeColor)
        let background = activeAttribute(.backgroundColor) as? NSColor
        update(\.backgroundColor, background.flatMap { Self.isClear($0) ? nil : $0 })
        update(\.currentList, detectListKind())
        let highlightValue = activeAttribute(.textHighlightStyle)
        update(\.isHighlighted, highlightValue != nil)
        update(\.highlightScheme, highlightValue == nil
            ? chosenHighlightScheme
            : Self.highlightScheme(activeAttribute(.textHighlightColorScheme)))
    }

    /// An attribute value as stored: the bridged `NSString` read back from RTF / storage, or
    /// the Swift value set in-process. Absent means the default (Accent) color.
    private static func highlightScheme(_ value: Any?) -> NSAttributedString.TextHighlightColorScheme {
        if let scheme = value as? NSAttributedString.TextHighlightColorScheme { return scheme }
        if let raw = value as? String { return .init(rawValue: raw) }
        return .default
    }

    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<RichTextController, Value>,
                                          _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    // MARK: Apply helpers

    private func toggleTrait(mask: NSFontTraitMask, symbolic: NSFontDescriptor.SymbolicTraits) {
        let enabling = !activeFont.fontDescriptor.symbolicTraits.contains(symbolic)
        let fm = NSFontManager.shared
        applyFont { enabling ? fm.convert($0, toHaveTrait: mask) : fm.convert($0, toNotHaveTrait: mask) }
    }

    private func applyFont(_ transform: (NSFont) -> NSFont) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let fallback = tv.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let range = tv.selectedRange()
        if range.length > 0, tv.shouldChangeText(in: range, replacementString: nil) {
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: range, options: []) { value, sub, _ in
                storage.addAttribute(.font, value: transform((value as? NSFont) ?? fallback), range: sub)
            }
            storage.endEditing()
            tv.didChangeText()
        }
        tv.typingAttributes[.font] = transform((tv.typingAttributes[.font] as? NSFont) ?? fallback)
        refreshState()
    }

    private func toggleAttribute(_ key: NSAttributedString.Key) {
        guard let tv = textView else { return }
        let value = attributeActive(key) ? 0 : NSUnderlineStyle.single.rawValue
        setAttribute(key, value: value, to: tv)
        refreshState()
    }

    private func setAttribute(_ key: NSAttributedString.Key, value: Any, to tv: NSTextView) {
        setAttributes([key: value], to: tv)
    }

    /// Sets several attributes on the selection as one change (one undo step, one
    /// `didChangeText`), and in the typing attributes.
    private func setAttributes(_ attributes: [NSAttributedString.Key: Any], to tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        if range.length > 0, tv.shouldChangeText(in: range, replacementString: nil) {
            storage.beginEditing()
            storage.addAttributes(attributes, range: range)
            storage.endEditing()
            tv.didChangeText()
        }
        tv.typingAttributes.merge(attributes) { _, new in new }
    }

    private func removeAttribute(_ key: NSAttributedString.Key, from tv: NSTextView) {
        removeAttributes([key], from: tv)
    }

    private func removeAttributes(_ keys: [NSAttributedString.Key], from tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        if range.length > 0, tv.shouldChangeText(in: range, replacementString: nil) {
            storage.beginEditing()
            keys.forEach { storage.removeAttribute($0, range: range) }
            storage.endEditing()
            tv.didChangeText()
        }
        keys.forEach { tv.typingAttributes.removeValue(forKey: $0) }
    }

    private func applyParagraphStyle(_ mutate: (NSMutableParagraphStyle) -> Void) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = (storage.string as NSString).paragraphRange(for: tv.selectedRange())
        if tv.shouldChangeText(in: range, replacementString: nil) {
            storage.beginEditing()
            if range.length > 0 {
                storage.enumerateAttribute(.paragraphStyle, in: range, options: []) { value, sub, _ in
                    let style = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
                        ?? NSMutableParagraphStyle()
                    mutate(style)
                    storage.addAttribute(.paragraphStyle, value: style, range: sub)
                }
            }
            storage.endEditing()
            tv.didChangeText()
        }
        let typing = ((tv.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy()
            as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        mutate(typing)
        tv.typingAttributes[.paragraphStyle] = typing
        refreshState()
    }

    private static func listMarkerLength(_ line: String) -> Int {
        TypedListMarker.length(in: line)
    }

    /// The typed marker text (glyph/number + tab) for `kind` on the `number`-th line, as
    /// Return continues a typed list. Static styles ignore `number`.
    private static func listMarker(_ kind: ListKind, number n: Int) -> String {
        switch kind {
        case .none, .otherTextList: return ""
        case .dash: return "–\t"
        case .bullet: return "•\t"
        case .square: return "▪\t"
        case .check: return "✓\t"
        case .decimalDot: return "\(n).\t"
        case .decimalParen: return "\(n))\t"
        case .upperAlphaDot: return "\(alpha(n, upper: true)).\t"
        case .lowerAlphaDot: return "\(alpha(n, upper: false)).\t"
        case .lowerAlphaParen: return "\(alpha(n, upper: false)))\t"
        case .upperRomanDot: return "\(roman(n, upper: true)).\t"
        case .lowerRomanDot: return "\(roman(n, upper: false)).\t"
        case .custom(let marker): return "\(marker)\t"
        }
    }

    /// Spreadsheet-style alphabetic marker: 1→A, 26→Z, 27→AA.
    private static func alpha(_ n: Int, upper: Bool) -> String {
        guard n > 0 else { return "" }
        var value = n
        var result = ""
        let base = UInt8(upper ? 65 : 97)
        while value > 0 {
            let rem = UInt8((value - 1) % 26)
            result = String(Character(UnicodeScalar(base + rem))) + result
            value = (value - 1) / 26
        }
        return result
    }

    /// Roman-numeral marker (1→I, 4→IV, 9→IX…); falls back to the integer above the table.
    private static func roman(_ n: Int, upper: Bool) -> String {
        guard n > 0 else { return "\(n)" }
        let table: [(Int, String)] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
            (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
        ]
        var value = n
        var result = ""
        for (v, sym) in table where value > 0 {
            while value >= v { result += sym; value -= v }
        }
        return upper ? result : result.lowercased()
    }

    // MARK: List detection

    /// Classifies the list at the caret so the Lists popup can check the active style: a
    /// TextEdit list by its innermost list's marker format (the item's own level), else a
    /// typed marker on the caret's line. Typed lists always renumber from item 1, so the
    /// contiguous lettered block's first marker disambiguates alphabetic vs roman
    /// (whose single-letter markers — I, V, X… — otherwise overlap).
    private func detectListKind() -> ListKind {
        if let list = activeParagraphStyle?.textLists.last { return ListKind(markerFormat: list.markerFormat) }
        guard let tv = textView, let storage = tv.textStorage, storage.length > 0 else { return .none }
        let ns = storage.string as NSString
        let loc = min(tv.selectedRange().location, ns.length)
        let caretLine = ns.lineRange(for: NSRange(location: loc, length: 0))
        guard let body = Self.markerBody(in: ns, line: caretLine) else { return .none }

        switch body {
        case "–": return .dash
        case "•": return .bullet
        case "▪": return .square
        case "✓": return .check
        default: break
        }
        guard let suffix = body.last, suffix == "." || suffix == ")" else { return .custom(body) }
        let core = String(body.dropLast())
        if !core.isEmpty, core.allSatisfy(\.isNumber) {
            return suffix == "." ? .decimalDot : .decimalParen
        }
        if !core.isEmpty, core.allSatisfy(\.isLetter) {
            let upper = core.first?.isUppercase ?? false
            if isRomanList(in: ns, caretLine: caretLine, core: core) {
                return upper ? .upperRomanDot : .lowerRomanDot
            }
            return suffix == ")" ? .lowerAlphaParen : (upper ? .upperAlphaDot : .lowerAlphaDot)
        }
        return .custom(body)
    }

    /// The marker text (sans trailing tab) at the start of `line`, or nil if none.
    private static func markerBody(in ns: NSString, line: NSRange) -> String? {
        let text = ns.substring(with: line)
        let len = listMarkerLength(text)
        guard len > 0 else { return nil }
        return String((text as NSString).substring(to: len).dropLast())   // drop the tab
    }

    /// Whether a lettered marker belongs to a roman (vs alphabetic) list. Multi-letter
    /// roman numerals are unambiguous; a lone roman-valued letter is decided by the first
    /// marker of the contiguous lettered block above the caret (item 1 = "A"/"a" vs "I"/"i").
    private func isRomanList(in ns: NSString, caretLine: NSRange, core: String) -> Bool {
        if core.count > 1 { return Self.isRomanNumeral(core) }
        var top = caretLine
        while top.location > 0 {
            let prev = ns.lineRange(for: NSRange(location: top.location - 1, length: 0))
            guard let pbody = Self.markerBody(in: ns, line: prev), pbody.count >= 2,
                  let psuffix = pbody.last, psuffix == "." || psuffix == ")",
                  String(pbody.dropLast()).allSatisfy(\.isLetter) else { break }
            top = prev
        }
        guard let firstBody = Self.markerBody(in: ns, line: top) else { return false }
        return String(firstBody.dropLast()).uppercased() == "I"
    }

    private static func isRomanNumeral(_ s: String) -> Bool {
        let upper = s.uppercased()
        return !upper.isEmpty && upper.allSatisfy { "IVXLCDM".contains($0) }
    }

    // MARK: State probes

    private var activeFont: NSFont {
        let fallback = textView?.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        guard let tv = textView else { return fallback }
        let range = tv.selectedRange()
        if range.length > 0, let storage = tv.textStorage, range.location < storage.length,
           let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont {
            return font
        }
        return (tv.typingAttributes[.font] as? NSFont) ?? fallback
    }

    private var activeParagraphStyle: NSParagraphStyle? {
        guard let tv = textView else { return nil }
        let range = tv.selectedRange()
        if range.length > 0, let storage = tv.textStorage, range.location < storage.length {
            return storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
        }
        return tv.typingAttributes[.paragraphStyle] as? NSParagraphStyle
    }

    /// The text color at the selection's first character, or the caret's typing color. Text
    /// with no color of its own draws in the default text color — never `tv.textColor`, which
    /// reports the color of the document's *first character*: selecting uncolored text showed
    /// whatever color the snippet began with, so the swatch looked stuck on an old color.
    private var activeColor: NSColor {
        (activeAttribute(.foregroundColor) as? NSColor) ?? .textColor
    }

    /// The value of `key` at the selection's first character, or in the typing attributes at
    /// a caret.
    private func activeAttribute(_ key: NSAttributedString.Key) -> Any? {
        guard let tv = textView else { return nil }
        let range = tv.selectedRange()
        if range.length > 0, let storage = tv.textStorage, range.location < storage.length {
            return storage.attribute(key, at: range.location, effectiveRange: nil)
        }
        return tv.typingAttributes[key]
    }

    private func attributeActive(_ key: NSAttributedString.Key) -> Bool {
        guard let tv = textView else { return false }
        let range = tv.selectedRange()
        if range.length > 0, let storage = tv.textStorage, range.location < storage.length {
            return ((storage.attribute(key, at: range.location, effectiveRange: nil) as? Int) ?? 0) != 0
        }
        return ((tv.typingAttributes[key] as? Int) ?? 0) != 0
    }
}

// MARK: - TextEdit lists

/// A list marker typed into the text (a short marker and a tab at the start of the line), as
/// "Other…" makes them and as every list style was made before lists became TextEdit's.
private enum TypedListMarker {
    /// The length of the typed marker `line` starts with, 0 if none: an alphanumeric run
    /// (decimal / alpha / roman) ending in `.`/`)` + tab, or a short run of symbol characters +
    /// tab (glyphs and "Other…" markers). The symbol branch excludes word/space chars so
    /// ordinary tab-indented prose isn't mistaken for a marker, and TextEdit's markers, which
    /// start with a tab, never match.
    static func length(in line: String) -> Int {
        guard let pattern else { return 0 }
        return pattern.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))?.range.length ?? 0
    }

    /// Compiled once — list detection runs on every caret move (`refreshState`).
    private static let pattern = try? NSRegularExpression(pattern: "^([0-9A-Za-z]+[.)]\\t|[^\\w\\s]{1,3}\\t)")
}

/// TextEdit's lists, made exactly as TextEdit makes them, so they paste between the two apps
/// as lists. TextEdit's format bar hands its Lists choice to AppKit
/// (`-[NSTextViewSharedData _doUserSetListMarkerFormat:options:]`), which runs
/// `-[_NSTextViewRulerHelper _doUserSetListMarkerFormat:options:startingItemNumber:inRange:level:]`
/// for each list and `_doUserRemoveMarkerFormatInRange:` for None. This is that code, read off
/// AppKit's disassembly on macOS 27.2 and written with public API. A list is an `NSTextList` in
/// each item's paragraph style, with the item indented and tabbed for its marker, which sits in
/// the text as tab, marker, tab while `includesTextListMarkers` is on, as in TextEdit.
/// AppKit's text view does the rest itself, as in TextEdit: Return adds the next item and ends
/// the list on an empty one, and Tab / ⇧Tab at an item's start nest it and bring it back out.
private extension NSTextView {
    /// The Lists popup: lists in `format` on the selected paragraphs, or None (nil).
    ///
    /// A style goes onto whole lists: a selected paragraph in a list brings in the rest of its
    /// innermost list (None takes every level of it), and a list keeps its starting number.
    /// Paragraphs in no list become one list per run. A caret on the empty last line first gets
    /// a line break, so there's a paragraph to list. Unlike AppKit, which goes from the first
    /// range to the last and so writes markers off by the ones it already added when a multiple
    /// selection takes in more than one run, the ranges go last to first here.
    ///
    /// Lines with a marker typed the old way lose it: a style replaces it with the list's
    /// marker, None removes it.
    func setTextEditList(_ format: NSTextList.MarkerFormat?) {
        guard let storage = textStorage else { return }
        var ranges = rangesForUserParagraphAttributeChange?.map(\.rangeValue)
        let userRange = rangeForUserParagraphAttributeChange
        var addedLine = false
        if format != nil, userRange.location != NSNotFound, userRange.length == 0 {
            guard shouldChangeText(in: userRange, replacementString: "\n") else { return }
            storage.beginEditing()
            storage.replaceCharacters(in: userRange, with: "\n")
            storage.endEditing()
            didChangeText()
            addedLine = true
            ranges = [NSRange(location: userRange.location, length: 1)]
            if userRange.location + 1 == storage.length {
                setSelectedRange(NSRange(location: userRange.location, length: 0))
            }
        }
        guard let ranges, userRange.location != NSNotFound, userRange.length > 0 || addedLine else { return }

        var targets = IndexSet()
        for range in ranges {
            var location = range.location
            while location < NSMaxRange(range) {
                var run = NSRange()
                let style = storage.attribute(.paragraphStyle, at: location, longestEffectiveRange: &run,
                                              in: range) as? NSParagraphStyle
                if let lists = style?.textLists, let innermost = lists.last {
                    run = storage.range(of: innermost, at: location)
                    if format == nil {
                        run.length = NSMaxRange(storage.range(of: lists[0], at: location)) - run.location
                    }
                }
                targets.insert(integersIn: run.location..<NSMaxRange(run))
                location = NSMaxRange(run)
            }
        }
        for target in targets.rangeView.reversed() {
            let range = NSRange(target)
            if let format {
                let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
                setTextList(format, startingAt: style?.textLists.last?.startingItemNumber ?? 1,
                            in: range, level: textListLevel(in: range))
            } else {
                removeTextLists(in: range)
            }
        }
    }

    /// None on `range` alone (`_doUserRemoveMarkerFormatInRange:`): its paragraphs leave their
    /// lists, back at no indent with the default tab stops the list's replaced, and lose their
    /// markers, TextEdit's or typed ones. Returns how many characters that removed, all from
    /// the starts of paragraphs in `range`.
    @discardableResult
    func removeTextLists(in range: NSRange) -> Int {
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: nil) else { return 0 }
        let defaultStyle = defaultParagraphStyle ?? .default
        var listed = IndexSet()
        storage.beginEditing()
        var location = range.location
        while location < NSMaxRange(range) {
            var run = NSRange()
            let style = storage.attribute(.paragraphStyle, at: location, longestEffectiveRange: &run,
                                          in: range) as? NSParagraphStyle ?? defaultStyle
            if !style.textLists.isEmpty {
                listed.insert(integersIn: run.location..<NSMaxRange(run))
                let paragraph = style.mutableCopy() as! NSMutableParagraphStyle
                paragraph.textLists = []
                paragraph.firstLineHeadIndent = 0
                paragraph.headIndent = 0
                for tab in paragraph.tabStops where tab.location <= style.headIndent {
                    paragraph.removeTabStop(tab)
                }
                for tab in defaultStyle.tabStops where tab.location <= style.headIndent {
                    paragraph.addTabStop(tab.copy() as! NSTextTab)
                }
                storage.addAttribute(.paragraphStyle, value: paragraph, range: run)
            }
            location = NSMaxRange(run)
        }
        storage.endEditing()
        didChangeText()

        // The markers, last paragraph first, so each removal leaves the ones before it in place.
        let text = storage.mutableString
        var paragraphs: [NSRange] = []
        text.enumerateSubstrings(in: range, options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
            paragraphs.append(enclosing)
        }
        var removed = 0
        for paragraph in paragraphs.reversed() {
            let length = listed.intersects(integersIn: paragraph.location..<NSMaxRange(paragraph))
                ? textEditMarkerLength(in: paragraph, closedOnly: true)
                : TypedListMarker.length(in: text.substring(with: paragraph))
            let marker = NSRange(location: paragraph.location, length: length)
            guard length > 0, shouldChangeText(in: marker, replacementString: "") else { continue }
            storage.beginEditing()
            storage.replaceCharacters(in: marker, with: "")
            storage.endEditing()
            didChangeText()
            removed += length
        }
        return removed
    }

    /// The attributes a new marker keeps from its item's first character, the rest (underline,
    /// links, highlights…) left off it (`+[NSTextList _standardMarkerAttributesForAttributes:]`).
    private static let markerAttributeKeys: Set<NSAttributedString.Key> = [.font, .foregroundColor, .backgroundColor, .paragraphStyle]

    /// One list in `format` on `range`, numbered from `start`, at `level` (0 the outermost).
    /// A paragraph already that deep gets this list in place of its list at that level; one
    /// that isn't goes a level in: 36 pt deeper, with no first-line indent, the tab stops up to
    /// there replaced by the marker's at 25 pt before it and the item's own. Then each item at
    /// `level` gets its marker, replacing one it already had.
    private func setTextList(_ format: NSTextList.MarkerFormat, startingAt start: Int, in range: NSRange, level: Int) {
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: nil) else { return }
        let list = NSTextList(markerFormat: format, options: 0)
        list.startingItemNumber = start
        storage.beginEditing()
        var location = range.location
        while location < NSMaxRange(range) {
            var run = NSRange()
            let style = storage.attribute(.paragraphStyle, at: location, longestEffectiveRange: &run,
                                          in: range) as? NSParagraphStyle ?? defaultParagraphStyle ?? .default
            let paragraph = style.mutableCopy() as! NSMutableParagraphStyle
            var lists = style.textLists
            if level < lists.count {
                lists[level] = list
            } else {
                let indent = CGFloat(lists.count + 1) * 36
                lists.append(list)
                paragraph.firstLineHeadIndent = 0
                paragraph.headIndent = indent
                for tab in paragraph.tabStops where tab.location <= indent { paragraph.removeTabStop(tab) }
                paragraph.addTabStop(NSTextTab(textAlignment: .left, location: indent - 25))
                paragraph.addTabStop(NSTextTab(textAlignment: .natural, location: indent))
            }
            paragraph.textLists = lists
            storage.addAttribute(.paragraphStyle, value: paragraph, range: run)
            location = NSMaxRange(run)
        }
        storage.endEditing()
        didChangeText()

        var length = range.length
        if textContentStorage?.includesTextListMarkers ?? true {
            let text = storage.mutableString
            var item = start
            var location = range.location
            while location < range.location + length {
                var paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
                var run = NSRange()
                let style = storage.attribute(.paragraphStyle, at: location, longestEffectiveRange: &run,
                                              in: NSRange(location: range.location, length: length)) as? NSParagraphStyle
                guard style?.textLists.count == level + 1 else {
                    location = NSMaxRange(run)
                    continue
                }
                var old = textEditMarkerLength(in: paragraph, closedOnly: false)
                if old == 0 { old = TypedListMarker.length(in: text.substring(with: paragraph)) }
                let marker = "\t" + list.marker(forItemNumber: item) + "\t"
                var attributes = storage.attributes(at: paragraph.location, effectiveRange: nil)
                if old <= 1 { attributes = attributes.filter { Self.markerAttributeKeys.contains($0.key) } }
                let replaced = NSRange(location: paragraph.location, length: old)
                if shouldChangeText(in: replaced, replacementString: marker) {
                    storage.beginEditing()
                    storage.replaceCharacters(in: replaced, with: NSAttributedString(string: marker, attributes: attributes))
                    storage.endEditing()
                    didChangeText()
                    let added = (marker as NSString).length - old
                    length += added
                    paragraph.length += added
                }
                item += 1
                location = NSMaxRange(paragraph)
            }
        }

        // What's typed at a caret in the list goes on in it (TextEdit's text views, which use
        // the inspector bar, get this; AppKit skips it for others).
        let selection = selectedRange()
        let end = range.location + length
        if selection.length == 0, storage.length > 0,
           (range.location..<end).contains(selection.location) || (selection.location == storage.length && selection.location == end),
           let style = storage.attribute(.paragraphStyle, at: max(selection.location - 1, 0), effectiveRange: nil) {
            typingAttributes[.paragraphStyle] = style
        }
    }

    /// How deep the shallowest paragraph in `range` sits: 0 in no list or the outermost one,
    /// 1 in a list nested once, and so on (`_markerLevelForRange:`).
    private func textListLevel(in range: NSRange) -> Int {
        guard let storage = textStorage else { return 0 }
        var level: Int?
        var location = range.location
        while location < NSMaxRange(range) {
            var run = NSRange()
            let lists = (storage.attribute(.paragraphStyle, at: location, longestEffectiveRange: &run,
                                           in: range) as? NSParagraphStyle)?.textLists ?? []
            level = min(level ?? .max, max(lists.count - 1, 0))
            location = NSMaxRange(run)
        }
        return level ?? 0
    }

    /// The length of the TextEdit marker `paragraph` starts with: a tab, the marker and the
    /// tab after it. With `closedOnly` false, a lone leading tab counts too (1), which a new
    /// marker replaces; 0 if the paragraph has neither, or is under two characters long.
    private func textEditMarkerLength(in paragraph: NSRange, closedOnly: Bool) -> Int {
        guard let text = textStorage?.mutableString, paragraph.length >= 2,
              text.character(at: paragraph.location) == 9 else { return 0 }
        var length = 1
        var character: unichar
        repeat {
            character = text.character(at: paragraph.location + length)
            length += 1
        } while character != 9 && length < paragraph.length
        if character == 9 { return length }
        return closedOnly ? 0 : 1
    }
}

/// The text and background color controls: TextEdit's format-bar color wells.
/// A real `NSColorWell` in `.minimal` style, so a click opens the system's color popover — the
/// same `NSColorPopoverController` TextEdit's wells open: the row of standard colors, the color
/// matrix, and Show Colors…, which hands the system color panel to this well. `supportsAlpha`
/// keeps the matrix's "no color" cell enabled (AppKit greys it out without it); picking it
/// clears the text's color or background. The closed well is drawn by `FormatBarColorWell`.
private struct FormatBarColorWellView: NSViewRepresentable {
    let kind: FormatBarColorWell.Kind
    /// The selection's color; nil where it has none of its own.
    var color: NSColor?
    var help: String
    var onPick: (NSColor) -> Void

    func makeNSView(context: Context) -> FormatBarColorWell {
        // `init(frame:)` + style, not `init(style:)`: that factory returns a plain
        // `NSColorWell` even when called on a subclass.
        let well = FormatBarColorWell(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        well.colorWellStyle = .minimal
        well.supportsAlpha = true
        well.kind = kind
        well.refusesFirstResponder = true   // the caret stays in the text
        well.target = context.coordinator
        well.action = #selector(Coordinator.picked(_:))
        well.toolTip = help
        well.setAccessibilityLabel(help)
        return well
    }

    func updateNSView(_ well: FormatBarColorWell, context: Context) {
        context.coordinator.onPick = onPick
        well.swatch = color
        // The popover and color panel start from the well's color: keep it on the selection's.
        // Setting `color` doesn't send the action; the flag guards against an echo anyway, so
        // moving the caret can never recolor the text.
        let wellColor = color ?? (kind == .text ? NSColor.textColor : .clear)
        if well.color != wellColor {
            context.coordinator.isSyncing = true
            well.color = wellColor
            context.coordinator.isSyncing = false
        }
    }

    static func dismantleNSView(_ well: FormatBarColorWell, coordinator: Coordinator) {
        // Show Colors… leaves the color panel attached to the well: detach it with the sheet.
        if well.isActive { well.deactivate() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    @MainActor
    final class Coordinator: NSObject {
        var onPick: (NSColor) -> Void
        var isSyncing = false

        init(onPick: @escaping (NSColor) -> Void) { self.onPick = onPick }

        @objc func picked(_ sender: NSColorWell) {
            guard !isSyncing else { return }
            onPick(sender.color)
        }
    }
}

/// The closed well, drawn as TextEdit draws its format-bar wells (AppKit's
/// `_NSTextFormattingColorComponentView`, measured from a live inspector bar): a 20pt rounded
/// square filled with the color under a hairline separator border; with no background color,
/// the text background with a gray "A" struck through in red. A `draw(_:)` override replaces
/// AppKit's own (circular) minimal swatch while keeping its click → popover behavior.
private final class FormatBarColorWell: NSColorWell {
    enum Kind { case text, background }

    var kind: Kind = .text
    /// The color the face shows; nil draws "none" (the default text color, or the struck-through
    /// "A" for the background).
    var swatch: NSColor? {
        didSet { if swatch != oldValue { needsDisplay = true } }
    }
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    private var hoverArea: NSTrackingArea?

    override var intrinsicContentSize: NSSize { NSSize(width: 20, height: 20) }

    override func draw(_ dirtyRect: NSRect) {
        let face = NSRect(x: (bounds.width - 20) / 2, y: (bounds.height - 20) / 2, width: 20, height: 20)
        let shape = NSBezierPath(roundedRect: face, xRadius: 6, yRadius: 6)
        (swatch ?? (kind == .text ? .textColor : .textBackgroundColor)).setFill()
        shape.fill()
        if swatch == nil, kind == .background { drawNoColorMark(in: face) }
        let lineWidth: CGFloat = isHovered ? 1 : 0.5
        let border = NSBezierPath(roundedRect: face.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
                                  xRadius: 6 - lineWidth / 2, yRadius: 6 - lineWidth / 2)
        border.lineWidth = lineWidth
        (isHovered ? NSColor.tertiaryLabelColor : .separatorColor).setStroke()
        border.stroke()
    }

    /// TextEdit's "no background color": a gray "A" (~33% ink: #ababab on light, #676767 on
    /// dark) struck through in red, corner to corner.
    private func drawNoColorMark(in face: NSRect) {
        let glyph = NSAttributedString(string: "A", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.33),
        ])
        let size = glyph.size()
        glyph.draw(at: NSPoint(x: face.midX - size.width / 2, y: face.midY - size.height / 2))
        let slash = NSBezierPath()
        slash.move(to: NSPoint(x: face.minX + 4, y: face.minY + 4))
        slash.line(to: NSPoint(x: face.maxX - 4, y: face.maxY - 4))
        slash.lineWidth = 1.25
        slash.lineCapStyle = .round
        NSColor.systemRed.setStroke()
        slash.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true   // the face's system colors are per-appearance
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    // AppKit's own tracking areas (the pull-down's) still go to `super`.
    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea === hoverArea { isHovered = true } else { super.mouseEntered(with: event) }
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea === hoverArea { isHovered = false } else { super.mouseExited(with: event) }
    }
}

/// The Highlight group's color button: TextEdit's Highlight color menu (recovered from AppKit's
/// `_NSTextFormattingHighlightPickerComponentView`): Accent, a separator, then Purple, Pink,
/// Orange, Mint and Blue, each with its preview — a color wheel for Accent, a color dot for the
/// rest, as AppKit's 15pt menu images — and the color in use checked. The button follows the
/// caret live: the highlight's preview on highlighted text, a blank dotted circle elsewhere.
/// A real `NSMenu`, so it reads exactly like TextEdit's.
private struct HighlightColorButton: View {
    /// The highlight under the caret / selection, shown on the button; nil off highlighted text.
    var shownScheme: NSAttributedString.TextHighlightColorScheme?
    /// The color checked in the menu: the highlight's, or else the one the next highlight uses
    /// (nil until one is picked).
    var checkedScheme: NSAttributedString.TextHighlightColorScheme?
    var choose: (NSAttributedString.TextHighlightColorScheme) -> Void

    @State private var isHovered = false
    @State private var anchor = MenuAnchor()

    /// TextEdit's menu, in its order; nil marks the separator. Dot colors are AppKit's: its
    /// menu images sample to exactly these system colors.
    private static let entries: [(scheme: NSAttributedString.TextHighlightColorScheme, name: String, color: NSColor?)?] = [
        (.default, String(localized: "Accent"), nil),
        nil,
        (.purple, String(localized: "Purple"), .systemPurple),
        (.pink, String(localized: "Pink"), .systemPink),
        (.orange, String(localized: "Orange"), .systemOrange),
        (.mint, String(localized: "Mint"), .systemMint),
        (.blue, String(localized: "Blue"), .systemBlue),
    ]

    var body: some View {
        Button(action: showMenu) {
            icon
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
                )
                .contentShape(.rect)
        }
        .buttonStyle(PressDimButtonStyle())
        .background(MenuAnchorView(anchor: anchor))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(String(localized: "Highlight color"))
        .accessibilityLabel(String(localized: "Highlight color"))
    }

    @ViewBuilder private var icon: some View {
        if let shownScheme {
            Image(nsImage: Self.preview(for: shownScheme, size: 15))
        } else {
            Image(systemName: "circle.dotted")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
    }

    private func showMenu() {
        guard let view = anchor.view else { return }
        let menu = NSMenu()
        for entry in Self.entries {
            guard let entry else { menu.addItem(.separator()); continue }
            let item = ClosureMenuItem(title: entry.name) { choose(entry.scheme) }
            item.state = entry.scheme == checkedScheme ? .on : .off
            item.image = Self.preview(for: entry.scheme, size: 15)
            // macOS 27 hides menu item images unless asked (TextEdit's menu shows them).
            if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    /// A scheme's preview, as AppKit draws its menu images: a circle 2pt smaller than the
    /// square canvas — the color wheel for Accent, the scheme's dot otherwise. Not a template,
    /// so menus keep its colors.
    static func preview(for scheme: NSAttributedString.TextHighlightColorScheme, size: CGFloat) -> NSImage {
        let color = entries.compactMap { $0 }.first { $0.scheme == scheme }?.color
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let circle = rect.insetBy(dx: 1, dy: 1)
            if let color {
                color.setFill()
                NSBezierPath(ovalIn: circle).fill()
            } else if let context = NSGraphicsContext.current?.cgContext {
                drawColorWheel(in: circle, context: context)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Accent's color wheel: a conic gradient starting red at 3 o'clock and turning
    /// counterclockwise through pink, purple (12 o'clock), blue, cyan, green, yellow
    /// (6 o'clock) and orange — stops sampled every 30° from AppKit's own menu image.
    private static func drawColorWheel(in circle: NSRect, context: CGContext) {
        let stops: [UInt32] = [0xFE1F4A, 0xF93496, 0xC334C1, 0x9937DC, 0x664BE3, 0x425CE8,
                               0x2288E0, 0x03B6D7, 0x3CB98D, 0x9BB819, 0xFCB204, 0xFD6E08, 0xFE1F4A]
        let colors = stops.map {
            CGColor(srgbRed: CGFloat($0 >> 16 & 0xFF) / 255, green: CGFloat($0 >> 8 & 0xFF) / 255,
                    blue: CGFloat($0 & 0xFF) / 255, alpha: 1)
        }
        let locations = (0..<stops.count).map { CGFloat($0) / CGFloat(stops.count - 1) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)
        else { return }
        context.saveGState()
        context.addEllipse(in: circle)
        context.clip()
        // Angle 0 is +x and grows toward +y — counterclockwise in this unflipped image.
        // (CoreGraphics names no Swift member for it, so it's the C function.)
        CGContextDrawConicGradient(context, gradient, CGPoint(x: circle.midX, y: circle.midY), 0)
        context.restoreGState()
    }
}

/// A menu item that runs a closure — targets itself, which the menu keeps alive.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }
}

/// Where AppKit pops a menu for a SwiftUI control: `NSMenu.popUp(positioning:at:in:)` needs an
/// `NSView`, so `MenuAnchorView` sits invisibly behind the control and records itself here — a
/// plain reference, so there's no state write while SwiftUI builds the view.
@MainActor
private final class MenuAnchor {
    weak var view: NSView?
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// `EditorTextView` wrapper with TextEdit's ruler (`EditorRulerView`). Edits flow out as RTF
/// via the delegate; the `controller` (set here) lets the format bar
/// reach the text view. Configured after TextEdit's rich-text view
/// (`-[DocumentWindowController setupInitialTextViewSharedStateForTextView:]`): find bar
/// with incremental search, spell checking while typing, the system's smart quotes / dashes
/// / text replacement, and adaptive dark-mode color mapping.
private struct RichTextView: NSViewRepresentable {
    @Binding var rtfData: Data
    var controller: RichTextController
    let findBar: FindBarHost

    /// Where lines wrap, which is where the ruler's right indent marker sits by default:
    /// 22.79 cm (646pt) on the scale at every zoom. It fits the 788pt sheet at actual size,
    /// where the editor shows about 25.6 cm. It only shapes the editor. The RTF stores no
    /// width, so where the snippet is pasted, the text wraps to that app's own width.
    static let textWidth: CGFloat = 22.79 / 2.54 * 72

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = EditorTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? EditorTextView else { return scrollView }
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFontPanel = false
        textView.configureFindAndSpelling()
        // Like TextEdit: document colors keep their light-mode meaning (black text stays
        // black in the RTF that gets pasted) and are remapped only on screen in Dark Mode.
        // Without it, uncolored or black text — e.g. a snippet just switched from Plain —
        // drew black on the dark background.
        textView.usesAdaptiveColorMappingForDarkAppearance = true
        textView.onFontSizeStep = { [weak controller] in controller?.stepFontSize(by: $0) }
        textView.onAlign = { [weak controller] in controller?.setAlignment($0) }
        textView.onToggleRuler = { [weak controller] in controller?.toggleRuler() }
        // TextEdit's ruler: `-[DocumentWindowController updateForRichTextAndRulerState:]`
        // turns on `usesRuler` for rich text and `showRuler:` shows it when the `ShowRuler`
        // default is on. It's AppKit's own text ruler, so the indent markers, tab stops and
        // units behave exactly as in TextEdit (see `EditorRulerView`). The ruler view is set
        // before it's made visible, or the scroll view would build a stock one.
        textView.usesRuler = true
        scrollView.horizontalRulerView = EditorRulerView(scrollView: scrollView, orientation: .horizontalRuler)
        scrollView.hasHorizontalRuler = true
        textView.isRulerVisible = UserDefaults.standard.bool(forKey: Pref.Key.showsSnippetRuler)
        controller.isRulerVisible = textView.isRulerVisible
        // The ruler's divider under the scale is a scroll-pocket line that macOS 26 runs to
        // the window's edges (and the scale overhangs its right end by the text inset), so
        // unclipped it crossed the editor box out to the sheet's sides.
        scrollView.clipsToBounds = true
        textView.configureZoom()
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        // The same 11pt left margin as the plain editor's 6pt inset + 5pt padding, all of it
        // padding so the ruler's right indent marker lines up with the text (see
        // `wrapToFixedWidth`).
        textView.textContainerInset = NSSize(width: 0, height: 8)
        textView.textContainer?.lineFragmentPadding = 11
        textView.font = NSFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12)
        textView.isHorizontallyResizable = false
        textView.wrapToFixedWidth(Self.textWidth)
        // Lists keep their markers in the text ("\t•\tItem"), as TextEdit's do: its text storage
        // (`-[DocumentWindowController init]`) and its reads (`-[Document readFromURL:…]`) follow
        // its `IncludesTextListMarkersInsideDocuments` default, which is on. TextKit 2 otherwise
        // leaves them out and draws them from the `NSTextList` alone. So the list code and the
        // text view's own (pastes, Return, Tab) work on the same text as in TextEdit, and copies
        // carry the markers in their plain text too.
        textView.textContentStorage?.includesTextListMarkers = true
        if let attr = NSAttributedString.withListMarkers(rtf: rtfData) {
            textView.textStorage?.setAttributedString(attr)
        }
        textView.placeCaretAtEndOfFirstLine()
        controller.textView = textView
        findBar.textView = textView
        DispatchQueue.main.async {
            controller.refreshState()
            textView.refreshRuler()
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // Edits flow out via the delegate; avoid clobbering the field while typing.
    }

    func makeCoordinator() -> Coordinator { Coordinator(rtfData: $rtfData, controller: controller) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var rtfData: Data
        let controller: RichTextController
        weak var textView: NSTextView?

        init(rtfData: Binding<Data>, controller: RichTextController) {
            _rtfData = rtfData
            self.controller = controller
            super.init()
            // Undoing or redoing a ruler edit (a tab stop or indent marker moved, added or
            // removed) changes the paragraph style without `textDidChange`, which would leave
            // the snippet's RTF on the edit that was undone.
            for name in [NSNotification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                NotificationCenter.default.addObserver(self, selector: #selector(undoManagerDidUndoOrRedo(_:)),
                                                       name: name, object: nil)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            sync(textView)
        }

        @MainActor @objc private func undoManagerDidUndoOrRedo(_ notification: Notification) {
            guard let textView, let undoManager = notification.object as? UndoManager,
                  undoManager === textView.undoManager else { return }
            sync(textView)
        }

        /// Publishes the text as RTF and brings the bar and the ruler up to date with it.
        @MainActor private func sync(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            rtfData = storage.rtf() ?? Data()
            // Changes that leave the selection alone (⌥⌘V Paste Style, undo of a format
            // change) still have to reach the bar.
            controller.refreshState()
            // AppKit moves the ruler's markers on selection changes and its own ruler edits,
            // but not on redo or for paragraph styles set in code.
            (textView as? EditorTextView)?.refreshRuler()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            controller.refreshState()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            selector == #selector(NSResponder.insertNewline(_:)) && controller.continueList()
        }
    }
}

/// The text view under both snippet editors. This agent app has no Edit /
/// Format / Find menus to carry TextEdit's editing key equivalents, so the view answers them
/// itself while it has focus — same keys and actions as TextEdit's menus (recovered from its
/// `Edit.nib`): the find bar (⌘F, ⌥⌘F, ⌘G, ⇧⌘G, ⌘E, ⌘J), Zoom In / Out / Actual Size
/// (⌘⇧. / ⌘⇧, / ⌘0), and in rich text Paste and Match
/// Style (⌥⇧⌘V), Copy / Paste Style (⌥⌘C / ⌥⌘V), Show Ruler (⌘R), Copy / Paste Ruler
/// (⌃⌘C / ⌃⌘V), Bigger / Smaller (⌘+ / ⌘−) and Align Left / Center / Right
/// (⌘{ / ⌘| / ⌘}). Show Ruler, size and alignment go through the format bar's controller
/// (`onToggleRuler` / `onFontSizeStep` / `onAlign`) so typing attributes and the bar stay in sync.
private final class EditorTextView: NSTextView {
    var onFontSizeStep: ((CGFloat) -> Void)?
    var onAlign: ((NSTextAlignment) -> Void)?
    var onToggleRuler: (() -> Void)?

    /// Never shown: a TextKit 1 view that computes the ruler's markers while this one isn't
    /// first responder (see `refreshRuler`).
    private lazy var rulerMarkerSource = NSTextView(usingTextLayoutManager: false)

    // MARK: Zoom

    /// TextEdit's zoom range (`-[ScalingScrollView awakeFromNib]`): in this editor's width the
    /// ruler then spans about 104 cm zoomed all the way out and 1.6 cm all the way in.
    private static let zoomRange: ClosedRange<CGFloat> = 0.25...16

    /// TextEdit's zoom (View › Zoom In / Zoom Out / Actual Size): the scroll view's own
    /// magnification, so trackpad pinches zoom as well. It scales the text without re-wrapping
    /// it: lines break where they do at actual size, so zoomed in they run past the right edge.
    /// Nothing stores it, so each editor opens at actual size. Pinches go through `pinch(_:)`
    /// first, so they stop at the ends of the range.
    func configureZoom() {
        guard let scrollView = enclosingScrollView else { return }
        scrollView.allowsMagnification = true
        scrollView.minMagnification = Self.zoomRange.lowerBound
        scrollView.maxMagnification = Self.zoomRange.upperBound
        guard let recognizer = scrollView.gestureRecognizers.first(where: { $0 is NSMagnificationGestureRecognizer }),
              let target = recognizer.target, target !== self, let action = recognizer.action else { return }
        scrollViewPinchTarget = target
        scrollViewPinchAction = action
        recognizer.target = self
        recognizer.action = #selector(pinch(_:))
    }

    /// Where the scroll view's pinch recognizer sent its pinches before `configureZoom`:
    /// the scroll view itself, which zooms by them.
    private weak var scrollViewPinchTarget: AnyObject?
    private var scrollViewPinchAction: Selector?

    /// The recognizer's `magnification` when the scroll view last took a step from it.
    private var lastPinchMagnification: CGFloat = 0

    /// A trackpad pinch, kept inside `zoomRange` before the scroll view zooms by it.
    ///
    /// The scroll view zooms each step by `magnification × (1 + Δ)`, where Δ is how far the
    /// recognizer's `magnification` moved since its last step. When that lands outside its
    /// min/max it still zooms past the limit, against a resistance, and springs back once the
    /// fingers lift (`-[NSScrollView _applyMagnificationDelta:centeredAroundContentPoint:]`,
    /// TextEdit does the same). So a step that would cross a limit is cut to end on it, never
    /// past it, by moving the recognizer's `magnification` back. The recognizer adds each
    /// event to that value, so pinching back the other way zooms again at once. The scroll
    /// view keeps the rest of its pinch handling: the zoom centered on the fingers and the
    /// slight holds at actual size and where the text fills the width.
    @objc private func pinch(_ recognizer: NSMagnificationGestureRecognizer) {
        if recognizer.state == .changed, let scrollView = enclosingScrollView {
            let scale = scrollView.magnification
            let last = lastPinchMagnification
            // The scroll view's own arithmetic, so the capped step comes out on the limit
            // itself: any overshoot, even rounding's, would start the spring.
            func zoomed(by magnification: CGFloat) -> CGFloat { (magnification - last) * scale + scale }
            let proposed = zoomed(by: recognizer.magnification)
            let limit = min(max(proposed, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
            if proposed != limit {
                var capped = last + (limit - scale) / scale
                while zoomed(by: capped) > Self.zoomRange.upperBound { capped = capped.nextDown }
                while zoomed(by: capped) < Self.zoomRange.lowerBound { capped = capped.nextUp }
                recognizer.magnification = capped
            }
        }
        if let target = scrollViewPinchTarget, let action = scrollViewPinchAction {
            NSApp.sendAction(action, to: target, from: recognizer)
        }
        switch recognizer.state {
        case .began, .changed: lastPinchMagnification = recognizer.magnification
        case .ended, .cancelled: lastPinchMagnification = 0
        default: break
        }
    }

    private enum ZoomStep { case zoomIn, zoomOut, actualSize }

    /// TextEdit's steps (`-[ScalingScrollView zoomIn:]` / `zoomOut:`): double or halve,
    /// landing on actual size when that's where the step nearly ends up, animated.
    private func zoom(_ step: ZoomStep) {
        guard let scrollView = enclosingScrollView else { return }
        let scale = scrollView.magnification
        let target: CGFloat = switch step {
        case .zoomIn: scale > 0.4 && scale < 0.6 ? 1 : scale * 2
        case .zoomOut: scale > 1.8 && scale < 2.2 ? 1 : scale / 2
        case .actualSize: 1
        }
        let magnification = min(max(target, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        guard magnification != scale else { return }
        scrollView.animator().setMagnification(magnification, centeredAt: zoomFixedPoint(zoomingTo: magnification))
    }

    /// How close to the editor's left or right edge a zoom may leave the caret, on screen.
    private static let zoomCaretMargin: CGFloat = 16

    /// The point of the text that stays still on screen while zooming to `target`, chosen so
    /// the zoom ends where it should. `setMagnification(_:centeredAt:)` keeps that point fixed
    /// and nothing re-wraps as zoom changes the visible width, so with the visible origin
    /// going from O₀ at scale m₀ to O₁ at m₁, the fixed point is (O₀m₀ − O₁m₁) / (m₀ − m₁).
    ///
    /// The zoom follows the caret. Its line keeps its height on screen, where a zoom around
    /// the middle of the view (TextEdit's, and the scroll view's own) took a caret low in the
    /// view out of sight zooming in. Sideways the left edge stays put, so zooming in doesn't
    /// scroll the start of the lines out of view, unless that would leave the caret beyond the
    /// right edge: then it scrolls just enough to keep it in. Zooming out keeps the caret's
    /// place sideways too, which brings back line starts scrolled out of view. With the caret
    /// scrolled out of sight, the zoom keeps the middle of what's showing and its left edge.
    private func zoomFixedPoint(zoomingTo target: CGFloat) -> NSPoint {
        guard let scrollView = enclosingScrollView else { return .zero }
        let clipView = scrollView.contentView
        let scale = scrollView.magnification
        let start = clipView.bounds.origin
        let size = NSSize(width: clipView.frame.width / target, height: clipView.frame.height / target)
        var end = start
        if let caret = visibleCaretRect() {
            end.y = caret.midY - (caret.midY - start.y) * scale / target
            let margin = Self.zoomCaretMargin / target
            let caretKept = caret.minX - (caret.minX - start.x) * scale / target
            end.x = min(max(min(start.x, caretKept), caret.minX + margin - size.width), caret.minX - margin)
        } else {
            let middle = clipView.bounds.midY
            end.y = middle - (middle - start.y) * scale / target
        }
        // Where the clip view will stop it: against the top or bottom of the text, or its sides.
        end = clipView.constrainBoundsRect(NSRect(origin: end, size: size)).origin
        func fixed(_ start: CGFloat, _ end: CGFloat) -> CGFloat { (start * scale - end * target) / (scale - target) }
        return NSPoint(x: fixed(start.x, end.x), y: fixed(start.y, end.y))
    }

    /// The caret, in the clip view's coordinates, when its line is in view: with a selection,
    /// whichever of its start or end shows (the start if both).
    private func visibleCaretRect() -> NSRect? {
        guard let clipView = enclosingScrollView?.contentView else { return nil }
        let selection = selectedRange()
        let ends = selection.length == 0 ? [selection.location] : [selection.location, NSMaxRange(selection)]
        for index in ends {
            guard let caret = caretRect(at: index).map({ clipView.convert($0, from: self) }) else { continue }
            if caret.midY >= clipView.bounds.minY, caret.midY <= clipView.bounds.maxY { return caret }
        }
        return nil
    }

    /// Where the insertion point at character `index` is drawn, in this view's coordinates.
    private func caretRect(at index: Int) -> NSRect? {
        let index = min(max(index, 0), (string as NSString).length)
        var caret: NSRect?
        if let textLayoutManager {
            guard let content = textLayoutManager.textContentManager,
                  let location = content.location(content.documentRange.location, offsetBy: index) else { return nil }
            textLayoutManager.enumerateTextSegments(in: NSTextRange(location: location), type: .selection,
                                                    options: []) { _, frame, _, _ in
                caret = frame
                return false
            }
        } else if let layoutManager, let container = textContainer {
            // TextKit 1, which the view falls back to for text TextKit 2 can't lay out (tables).
            // Never asked before that: reading `layoutManager` is what makes a view fall back.
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 0),
                                                  actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs,
                                                  in: container) { rect, stop in
                caret = rect
                stop.pointee = true
            }
        }
        let origin = textContainerOrigin
        return caret?.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// ⌘⇧. / ⌘⇧, as TextEdit's menu matches them: by the key's own character, since with ⇧
    /// held `charactersIgnoringModifiers` is ">" or "<" on a US layout and ":" or ";" on a
    /// Spanish one — while where "." itself needs ⇧ (French) it's the shifted character.
    private func zoomStep(for event: NSEvent) -> ZoomStep? {
        let characters = [event.characters(byApplyingModifiers: []), event.charactersIgnoringModifiers]
        if characters.contains(".") { return .zoomIn }
        if characters.contains(",") { return .zoomOut }
        return nil
    }

    // MARK: Ruler

    /// Brings the ruler's markers up to the paragraph at the selection. AppKit fills the
    /// ruler in only for the first responder (`updateRuler` checks that its text layout manager
    /// owns the first responder), so with the title field focused — as when the editor opens —
    /// the ruler showed a bare scale. Then the markers come from `rulerMarkerSource`: the
    /// public `NSLayoutManager.rulerMarkers(for:paragraphStyle:ruler:)` of a TextKit 1 view
    /// with this view's geometry, which builds the same markers AppKit does (checked against
    /// it for default, indented and tabbed paragraphs at 1× and 2× zoom). They stay live: the
    /// ruler's client is this view, so dragging one edits the text as it would when focused.
    ///
    /// `updateRuler` also sets where the scale's zero sits, and until this view's first
    /// `becomeFirstResponder` nothing does: the ruler's `originOffset` stayed 0, so the scale
    /// started at the view's left edge while the markers sat 11pt further right (more when
    /// zoomed). It moved into place on the first click in the text. It's set here to the
    /// value AppKit gives it, the text's leading edge (container origin plus padding).
    func refreshRuler() {
        guard usesRuler, isRulerVisible, let ruler = enclosingScrollView?.horizontalRulerView else { return }
        if window?.firstResponder === self {
            updateRuler()
            return
        }
        let source = rulerMarkerSource
        source.frame = frame
        source.textContainerInset = textContainerInset
        if let container = textContainer, let sourceContainer = source.textContainer {
            sourceContainer.widthTracksTextView = container.widthTracksTextView
            sourceContainer.lineFragmentPadding = container.lineFragmentPadding
            sourceContainer.size = container.size
        }
        guard let layoutManager = source.layoutManager else { return }
        if ruler.clientView !== self { ruler.clientView = self }
        ruler.originOffset = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0)
        ruler.markers = layoutManager.rulerMarkers(for: source, paragraphStyle: paragraphStyleAtSelection, ruler: ruler)
    }

    /// A press on the ruler while the text isn't focused (the title field has focus when the
    /// editor opens): focus the text first, keeping its selection, so the marker or tab stop
    /// being changed shows the caret in the paragraph it edits. Until the text is clicked,
    /// that's the end of the first line (`placeCaretAtEndOfFirstLine`), the paragraph the
    /// ruler is already showing. AppKit then rebuilds the markers for the focused view
    /// before the ruler's own gestures act on the press.
    func focusForRulerPress() {
        guard let window, window.firstResponder !== self, window.makeFirstResponder(self) else { return }
        refreshRuler()
    }

    /// Where the caret starts: the end of the first line (its first paragraph, before the
    /// line break), so the ruler shows that paragraph and edits it if used before the text
    /// is clicked.
    func placeCaretAtEndOfFirstLine() {
        let text = string as NSString
        var contentsEnd = 0
        text.getParagraphStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: 0, length: 0))
        setSelectedRange(NSRange(location: contentsEnd, length: 0))
    }

    // MARK: Fixed text width

    /// The narrowest this view gets, so that it always holds its text container
    /// (`wrapToFixedWidth`). 0 when the text wraps to the view instead.
    private var minimumFrameWidth: CGFloat = 0

    /// Wraps the text at a fixed width instead of at the editor's edge, like TextEdit's
    /// Wrap to Page: the right indent marker stays at `width` on the ruler at every zoom, and
    /// zoom scales the text instead of re-wrapping it. The view still spans at least the
    /// visible width, so clicks right of the text land in it, and gets wider than the visible
    /// area when zoomed in, scrolling sideways.
    ///
    /// Call after setting `textContainerInset` and the padding. With the inset's width at 0
    /// the marker matches where lines really end: AppKit draws the right indent marker at the
    /// container's width minus its padding, leaving out the container's origin, so a
    /// horizontal inset put the marker that far left of the text's actual right edge.
    func wrapToFixedWidth(_ width: CGFloat) {
        guard let container = textContainer, let scrollView = enclosingScrollView else { return }
        let padding = container.lineFragmentPadding
        container.widthTracksTextView = false
        container.size = NSSize(width: width + 2 * padding, height: CGFloat.greatestFiniteMagnitude)
        minimumFrameWidth = container.size.width + 2 * textContainerInset.width
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        // With a tracking container, `NSTextView` itself kept its width at the clip view's as
        // zoom changed the clip view's bounds. Without one, nothing does.
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewBoundsDidChange(_:)),
                                               name: NSView.boundsDidChangeNotification, object: clipView)
        fitWidthToClipView()
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        fitWidthToClipView()
    }

    /// Set while `fitWidthToClipView` resizes this view.
    private var isFittingWidth = false

    /// The visible width (in this view's units, so it grows as zoom shrinks the text), or the
    /// text container's if that's wider (`setFrameSize`).
    ///
    /// Inside `setFrameSize` the clip view re-scrolls to the new frame, which posts another
    /// bounds change, and a magnified clip view's width comes back off in its last bit
    /// (±4.5e-13 at 0.25×). Comparing exactly, each answer resized the view again until the
    /// stack overflowed when zooming out (seen November 3, 2026). So a resize never starts
    /// another, and differences far below a pixel don't count.
    private func fitWidthToClipView() {
        guard !isFittingWidth, let clipView = enclosingScrollView?.contentView else { return }
        let width = max(clipView.bounds.width, minimumFrameWidth)
        guard abs(width - frame.width) > 0.001 else { return }
        isFittingWidth = true
        defer { isFittingWidth = false }
        setFrameSize(NSSize(width: width, height: frame.height))
    }

    /// The paragraph style the ruler shows: the one at the start of the selection, or the
    /// typing attributes' at the end of the text.
    private var paragraphStyleAtSelection: NSParagraphStyle {
        let location = selectedRange().location
        if let storage = textStorage, location < storage.length,
           let style = storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle {
            return style
        }
        return typingAttributes[.paragraphStyle] as? NSParagraphStyle ?? defaultParagraphStyle ?? .default
    }

    /// Keeps the view at least as wide as a fixed-width text container (zoomed in, the clip
    /// view offers less). Without a fixed width the right-indent marker sits at the text's
    /// width, which changes as the editor is laid out and as it zooms.
    override func setFrameSize(_ newSize: NSSize) {
        let newSize = NSSize(width: max(newSize.width, minimumFrameWidth), height: newSize.height)
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { refreshRuler() }
    }

    /// What TextEdit's `setupInitialTextViewSharedStateForTextView:` sets on every text view:
    /// the find bar with incremental (highlight-as-you-type) search, and spell checking while
    /// typing (its `CheckSpellingWhileTyping` default) without grammar checking.
    func configureFindAndSpelling() {
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isContinuousSpellCheckingEnabled = true
        isGrammarCheckingEnabled = false
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Key equivalents visit every view in the window — act only for the focused editor.
        guard window?.firstResponder === self, handleKeyEquivalent(event) else {
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    /// A ⌘-key nothing claimed as a key equivalent (were the SwiftUI host not to pass
    /// `performKeyEquivalent` down to this view) arrives here instead; without this it beeped.
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), handleKeyEquivalent(event) { return }
        super.keyDown(with: event)
    }

    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if modifiers == [.command, .shift], let step = zoomStep(for: event) {
            zoom(step)
            return true
        }
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        return handleKey(key, modifiers: modifiers)
    }

    private func handleKey(_ key: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        switch (modifiers, key) {
        case ([.command], "0"): zoom(.actualSize)
        case ([.command], "f"): finder(.showFindInterface)
        case ([.command, .option], "f"): finder(.showReplaceInterface)
        case ([.command], "g"): finder(.nextMatch)
        case ([.command, .shift], "g"): finder(.previousMatch)
        case ([.command], "e"): finder(.setSearchString)
        case ([.command], "j"): centerSelectionInVisibleArea(nil)
        default:
            guard isRichText else { return false }
            return handleRichKey(key, modifiers: modifiers)
        }
        return true
    }

    /// The rich-only equivalents. Size and alignment characters are matched with or without
    /// ⇧, since whether "+", "{", "|" and "}" need it depends on the keyboard layout.
    private func handleRichKey(_ key: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        let command = modifiers.subtracting(.shift) == .command
        switch (modifiers, key) {
        case ([.command, .option, .shift], "v"): pasteAsPlainText(nil)
        case ([.command, .option], "c"): copyFont(nil)
        case ([.command, .option], "v"): pasteFont(nil)
        case ([.command], "r"): onToggleRuler?()
        case ([.command, .control], "c"): copyRuler(nil)
        case ([.command, .control], "v"): pasteRuler(nil)
        case (_, "+") where command, ([.command], "="): onFontSizeStep?(1)
        case ([.command], "-"): onFontSizeStep?(-1)
        case (_, "{") where command: onAlign?(.left)
        case (_, "|") where command: onAlign?(.center)
        case (_, "}") where command: onAlign?(.right)
        default: return false
        }
        return true
    }

    private func finder(_ action: NSTextFinder.Action) {
        // `performTextFinderAction(_:)` reads the action from its sender's tag.
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        performTextFinderAction(sender)
    }
}

/// The rich editor's ruler: AppKit's text ruler as TextEdit shows it. `NSTextView` is its
/// client and does all the work: the scale in the user's units, the first-line / left /
/// right indent markers, and tab stops (click the ruler to add a left tab, drag to move,
/// drag off to remove, right-click for Left / Center / Right / Decimal), each change undoable
/// and applied to the selected paragraphs.
///
/// The one thing dropped is the accessory row (Styles, alignment, Spacing, Lists) that
/// `NSTextView` puts above the scale. TextEdit never shows that row because its text views
/// use the inspector bar (`setUsesInspectorBar:`), which a sheet can't host and the format
/// bar replaces here. With TextKit 2 the row comes from a private helper, so the ruler
/// itself turns it down: it never takes an accessory view or reserves room for one.
private final class EditorRulerView: NSRulerView {
    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        // Not a `mouseDown` override: a subclass that overrides it turns off the ruler's own
        // gesture recognizers (`-[NSRulerView _subclassOverridesMouseMethods]`), which is how
        // macOS 26 drags markers and shows the tab-stop menu.
        addGestureRecognizer(PressObserver { [weak self] in
            (self?.clientView as? EditorTextView)?.focusForRulerPress()
        })
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var accessoryView: NSView? {
        get { nil }
        set {}
    }

    override var reservedThicknessForAccessoryView: CGFloat {
        get { 0 }
        set {}
    }

    /// Puts the pointer back after AppKit's tracking of a tab stop being added (a click on a
    /// bare spot of the ruler: `NSTextView` makes the marker and tracks it here until mouse-up).
    /// That loop (`-[NSRulerMarker trackMouse:adding:]`) hides the cursor when it starts and
    /// shows it again at the end only if a flag is still set, but it also uses that flag for
    /// its own blank cursor. A drag out of `visibleRect` (the editor box) pops a cursor and
    /// clears the flag, and a drag back in pushes the blank cursor and sets it again. Released
    /// outside, the hide was never undone and the pointer stayed hidden until the app quit.
    /// Released back inside, the blank cursor stayed current until the pointer crossed into
    /// the text. Moving an existing marker doesn't go through here and isn't affected.
    override func trackMarker(_ marker: NSRulerMarker, withMouseEvent event: NSEvent) -> Bool {
        let cursor = NSCursor.current
        let tracked = super.trackMarker(marker, withMouseEvent: event)
        // The loop tests the last drag's location the same way. The loop dequeued the
        // mouse-up, so that's the current event.
        if let mouseUp = NSApp.currentEvent, mouseUp.type == .leftMouseUp, mouseUp.window === window,
           !isMousePoint(convert(mouseUp.locationInWindow, from: nil), in: visibleRect) {
            NSCursor.unhide()
        }
        if NSCursor.current !== cursor { NSCursor.pop() }
        return tracked
    }

    /// Reports each left or right press on its view, then fails at once, so it never claims
    /// the click or holds events back from the view's own recognizers.
    private final class PressObserver: NSGestureRecognizer {
        private let onPress: () -> Void

        init(onPress: @escaping () -> Void) {
            self.onPress = onPress
            super.init(target: nil, action: nil)
            delaysPrimaryMouseButtonEvents = false
            delaysSecondaryMouseButtonEvents = false
        }

        required init?(coder: NSCoder) { nil }

        override func mouseDown(with event: NSEvent) { report() }
        override func rightMouseDown(with event: NSEvent) { report() }

        private func report() {
            onPress()
            state = .failed
        }
    }
}

/// Lets the editor sheet's Esc / Return defer to the find bar. The sheet's Cancel and Done
/// buttons own Esc and Return as key equivalents, which reach them before the find bar's
/// fields: without this, Esc to close the find bar discarded the whole edit and Return for
/// "next match" closed the sheet.
@MainActor
private final class FindBarHost {
    weak var textView: NSTextView?

    private var scrollView: NSScrollView? { textView?.enclosingScrollView }

    /// The find bar's field being edited, if keyboard focus is in it.
    private var focusedFindField: NSTextView? {
        guard let bar = scrollView?.findBarView, scrollView?.isFindBarVisible == true,
              let editor = textView?.window?.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSView, field.isDescendant(of: bar) else { return nil }
        return editor
    }

    /// Esc: lets the focused find field handle it, or closes the bar if it's up. Returns
    /// whether the bar took the key.
    func handleEscape() -> Bool {
        if let field = focusedFindField {
            field.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            return true
        }
        guard scrollView?.isFindBarVisible == true, let textView else { return false }
        let sender = NSMenuItem()
        sender.tag = NSTextFinder.Action.hideFindInterface.rawValue
        textView.performTextFinderAction(sender)
        return true
    }

    /// Return: handed to the focused find field (find next / replace). Returns whether
    /// it took the key.
    func handleReturn() -> Bool {
        guard let field = focusedFindField else { return false }
        field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        return true
    }

}

/// The Plain Text editor, set up the way TextEdit sets up plain documents:
/// the user's fixed-pitch font with character-width tab stops (`-[Document
/// defaultTextAttributes:]`), and smart quotes and dashes off (TextEdit's
/// `SmartSubstitutionsEnabledInRichTextOnly` default). A plain snippet is pasted verbatim, so
/// this goes one step further and also turns off automatic spelling correction, text
/// replacement and link / data detection; spell checking still underlines, and every
/// substitution stays switchable from the context menu. Shares the find bar and its keys
/// with the rich editor via `EditorTextView`.
private struct PlainTextView: NSViewRepresentable {
    @Binding var text: String
    let findBar: FindBarHost

    /// Tab stops every this many characters — TextEdit's `TabWidth` default.
    private static let tabWidth = 8

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = EditorTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? EditorTextView else { return scrollView }
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.allowsUndo = true
        textView.configureFindAndSpelling()
        textView.configureZoom()
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false

        let font = NSFont.userFixedPitchFont(ofSize: NSFont.systemFontSize)
            ?? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = []
        paragraph.defaultTabInterval = CGFloat(Self.tabWidth) * (" " as NSString).size(withAttributes: [.font: font]).width
        textView.font = font
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [.font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.textColor]

        textView.delegate = context.coordinator
        textView.textContainerInset = NSSize(width: 6, height: 8)
        scrollView.hasHorizontalScroller = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        findBar.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // Edits flow out via the delegate, so this only differs after an outside change; never
        // replace the text mid-composition (marked text) or on every keystroke.
        guard let textView = nsView.documentView as? NSTextView, !textView.hasMarkedText(),
              textView.string != text else { return }
        textView.string = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        init(text: Binding<String>) { _text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}

private extension NSAttributedString {
    /// RTF data for the whole string, or nil.
    func rtf() -> Data? {
        rtf(from: NSRange(location: 0, length: length), documentAttributes: [:])
    }
}
