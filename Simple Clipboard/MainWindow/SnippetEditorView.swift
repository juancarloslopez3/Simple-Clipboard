import AppKit
import CoreText
import SwiftData
import SwiftUI

/// Edits a snippet's title + content (CLAUDE.md §11). The header type control depends on
/// whether the snippet is new: a **new** draft gets the full **Plain/Rich/File** toggle
/// (so a file snippet can be created from New Snippet), but an **existing** snippet is
/// locked to its category — a text snippet toggles only Plain↔Rich (File isn't offered),
/// and a file snippet shows a fixed "File" label. Plain stores UTF-8; rich stores RTF,
/// edited via an `NSTextView` wrapper; File references a **single** file (`FileSnippetList`)
/// set by dragging one from Finder onto the drop zone or clicking it to open a file picker
/// — the drop zone *is* the add control (no separate button). Switching between Text and
/// File (new drafts only) stashes the other mode's payload for the session, so an accidental
/// flip doesn't destroy content. **Cancel** discards every change made in the session
/// (restoring the snapshot taken on open); **Done** saves.
struct SnippetEditorView: View {
    @Bindable var snippet: Snippet
    /// `true` when editing a just-created draft (not yet committed) — the header reads
    /// "New Snippet" instead of "Edit Snippet".
    var isNew: Bool = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var showingEmptyContentAlert = false
    /// Space / double-click Quick Look of the referenced file in File mode (§11) — the same
    /// `SnippetPreviewOverlay` the panel's snippet Space preview uses, overlaid on the sheet.
    @State private var isPreviewingFile = false
    /// The payload of the mode the editor switched *away* from (text kept with its
    /// plain/rich form, file list as raw payload). Session-only — dies with the sheet.
    @State private var stashedText: StashedText?
    @State private var stashedFiles: Data?
    /// The snippet's fields when the editor opened, captured so **Cancel** can revert every
    /// in-editor change. SwiftData autosaves the live model as it's edited, so discarding
    /// means restoring these values — not just skipping `save()`. Captured once on appear.
    @State private var original: Snapshot?

    private enum SnippetMode: Hashable { case plain, rich, file }
    private struct StashedText { var isRich: Bool; var data: Data }
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

        /// The first file URL the snippet referenced on open (the previously-stored copy, if
        /// any), so replacing the file on save can clean up the one it superseded.
        var fileURL: URL? {
            guard isFile, let s = String(data: payload, encoding: .utf8) else { return nil }
            return s.split(separator: "\n").first.flatMap { URL(string: String($0)) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isNew ? String(localized: "New Snippet") : String(localized: "Edit Snippet")).font(.title3.bold())
                Spacer()
                modeControl
            }

            TextField("Title", text: $snippet.title)
                .textFieldStyle(.roundedBorder)
                .font(.headline)

            Group {
                if snippet.isFile {
                    FileSnippetList(url: snippet.fileURLs.first, isPreviewing: $isPreviewingFile,
                                    onSet: setFile, onRemove: removeFile)
                } else if snippet.isRichText {
                    RichTextEditor(rtfData: rtfBinding)
                } else {
                    TextEditor(text: plainBinding)
                        .font(.body)
                        .padding(4)
                }
            }
            .frame(minHeight: 300)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))

            HStack {
                Spacer()
                // Discard the session's changes (Esc): reverts to the on-open snapshot,
                // bypassing the empty-content prompt entirely. While the file preview is
                // up, Esc peels just it — the sheet's Esc always routes here (the AppKit
                // fields hand cancelOperation to this .cancelAction equivalent).
                Button("Cancel", role: .cancel) {
                    if isPreviewingFile { isPreviewingFile = false } else { cancel() }
                }
                .keyboardShortcut(.cancelAction)
                Button("Done") {
                    // Return while the file preview is up closes it, never the sheet.
                    guard !isPreviewingFile else {
                        isPreviewingFile = false
                        return
                    }
                    // A titled snippet with no content can't be saved (§11): offer to
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
        .padding()
        .frame(width: 720, height: 560)
        // Quick Look of the referenced file (Space tap/hold or double-click on the card,
        // §11) — the panel's snippet preview card, dimming the whole sheet behind it.
        .overlay {
            if isPreviewingFile, snippet.isFile, !snippet.fileURLs.isEmpty {
                SnippetPreviewOverlay(snippet: snippet) { isPreviewingFile = false }
            }
        }
        // Holding Space (hold-to-preview) auto-repeats, and the repeats escaping to the
        // responder chain beeped on every one — consumed while the preview is open (§11).
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
        // Prewarm the font-family cache while the editor is still in Plain mode, so the
        // Rich toggle (and the toolbar's font picker) has the list ready instantly.
        .task { _ = await FontCatalog.families() }
    }

    // MARK: Mode control

    /// The type control in the header. A **new** draft can still pick any of the three
    /// types (so a file snippet can be created from New Snippet, §11); an **existing**
    /// snippet is locked to its category — a text snippet toggles only Plain↔Rich (File is
    /// not offered), and a file snippet shows a fixed "File" label with no toggle at all.
    @ViewBuilder private var modeControl: some View {
        if isNew {
            Picker("", selection: modeBinding) {
                Text("Plain Text").tag(SnippetMode.plain)
                Text("Rich Text").tag(SnippetMode.rich)
                Text("File").tag(SnippetMode.file)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
        } else if snippet.isFile {
            // A file snippet can't become text — it stays a file (§11).
            Label("File", systemImage: "doc")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        } else {
            Picker("", selection: modeBinding) {
                Text("Plain Text").tag(SnippetMode.plain)
                Text("Rich Text").tag(SnippetMode.rich)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
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
            snippet.payload = NSAttributedString(string: text).rtf() ?? Data()
            snippet.isRichText = true
        case (.rich, .plain):
            snippet.payload = Data(snippet.plainString.utf8)
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
            let text = String(data: stash.data, encoding: .utf8) ?? ""
            return NSAttributedString(string: text).rtf() ?? Data()
        }
        let text = NSAttributedString(rtf: stash.data, documentAttributes: nil)?.string ?? ""
        return Data(text.utf8)
    }

    // MARK: File mode

    /// Sets the snippet's single referenced file to the first valid regular-file URL from a
    /// drop or the open panel (a file snippet holds exactly one file, §11); folders and
    /// non-file URLs are ignored, and dropping several keeps only the first.
    private func setFile(_ urls: [URL]) {
        guard let file = urls.first(where: isRegularFileURL)?.standardizedFileURL else { return }
        setFileURLs([file])
    }

    private func removeFile() {
        setFileURLs([])
    }

    private func setFileURLs(_ urls: [URL]) {
        snippet.payload = Data(urls.map(\.absoluteString).joined(separator: "\n").utf8)
        syncPreview()
    }

    /// On save, copy the referenced original into the managed store (§11/§12) so moving or
    /// deleting the user's original no longer breaks the snippet, and reference the copy. During
    /// editing the snippet references the picked file directly (so its real path shows and Quick
    /// Look/Missing work against it) — the copy is deferred to here, so picking a file then
    /// Cancelling never writes to disk. Any copy this edit superseded (the file was replaced, or
    /// removed) is deleted so it doesn't orphan; an unchanged existing snippet already points at
    /// its copy, so neither branch fires.
    private func finalizeFileStorage() {
        if snippet.isFile, let current = snippet.fileURLs.first,
           !Snippet.isManagedFileCopy(current), let copy = Snippet.storeManagedFileCopy(of: current) {
            setFileURLs([copy])
        }
        if let previous = original?.fileURL, Snippet.isManagedFileCopy(previous),
           !snippet.fileURLs.contains(previous) {
            Snippet.deleteManagedFileCopy(previous)
        }
    }

    private func syncPreview() {
        // A file snippet previews as its file *names* (matching the `.file` item preview,
        // §8b), not the full paths `plainString` yields.
        if snippet.isFile {
            let names = snippet.fileURLs.map { $0.lastPathComponent.isEmpty ? $0.path : $0.lastPathComponent }
            snippet.plainPreview = names.joined(separator: ", ")
        } else {
            // Keep line breaks — the snippet card shows up to 3 lines (§11); single-line
            // surfaces (menu, panel row) collapse via menuPreview at display time.
            snippet.plainPreview = snippet.plainString.multilinePreview(limit: 240)
        }
    }

    private var hasTitleButNoContent: Bool {
        snippet.isEmpty && !snippet.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Cancel: discard every change made this session and close. SwiftData autosaves the
    /// live model as it's edited, so reverting the fields to the on-open snapshot — not
    /// skipping `save()` — is what actually discards. A reverted new draft is left empty,
    /// so `finishEditing` never inserts it (§11); an existing snippet keeps its original
    /// content. No empty-content prompt: Cancel already means "throw it away".
    private func cancel() {
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
    /// (§11) — just close; only a stored snippet needs deleting. Also drop any managed file
    /// copy the snippet had stored (§12), so discarding an emptied file snippet doesn't orphan it.
    private func discardSnippet() {
        snippet.deleteOwnedManagedFiles()
        if let previous = original?.fileURL, Snippet.isManagedFileCopy(previous) {
            Snippet.deleteManagedFileCopy(previous)
        }
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

/// A file snippet references a single regular **file**, never a folder (§11). Filters out
/// directories (and non-file URLs) that a drop or multi-select might carry.
private func isRegularFileURL(_ url: URL) -> Bool {
    guard url.isFileURL else { return false }
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path(percentEncoded: false),
                                          isDirectory: &isDirectory) && !isDirectory.boolValue
}

/// The File-mode content area (CLAUDE.md §11): a **single** referenced file, set by
/// **dragging a file from Finder** onto the area or **clicking** the empty drop zone to
/// open a file picker — the drop zone *is* the add control, so there's no separate button.
/// The snippet references the original file (contents aren't stored, §12), so a file that
/// no longer exists at its captured path can't be pasted — it's dimmed and flagged "Missing".
/// The file (its icon / name, not the card's blank space) is **selectable** (one click —
/// selection *is* keyboard focus, so the Finder-style highlight always means Space works)
/// and **Space / double-click** opens the file's Quick Look preview via the `isPreviewing`
/// binding, with the panel's tap-vs-hold Space split (§9/§11).
private struct FileSnippetList: View {
    let url: URL?
    @Binding var isPreviewing: Bool
    let onSet: ([URL]) -> Void
    let onRemove: () -> Void

    @State private var isDropTargeted = false
    /// Selection = focus: clicking the card focuses it (Space lands here, not the title
    /// field); focus moving anywhere else clears the highlight, so it never lies about Space.
    @FocusState private var isSelected: Bool
    /// Tap-vs-hold state for Space, mirroring the panel / history pane (§9/§10).
    @State private var spaceDownTime: Date?
    @State private var spaceOpenedPreview = false
    private let holdThreshold: TimeInterval = 0.2

    var body: some View {
        Group {
            if let url {
                // Click handling lives *inside* the card, scoped to the file identity
                // (icon / name) — clicking the card's blank space or the area around it
                // deselects rather than selects.
                FileSnippetCard(url: url, isSelected: isSelected,
                                onSelect: { isSelected = true },
                                onDeselect: { isSelected = false },
                                onPreview: {
                                    isSelected = true
                                    isPreviewing = true
                                },
                                onReplace: chooseFile, onRemove: onRemove)
                    .focusable()
                    .focused($isSelected)
                    .focusEffectDisabled()   // the card draws its own selection highlight
                    // Space: tap toggles, hold previews only while pressed — same key-up
                    // split as the panel (§9). Only fires while the card holds focus, so
                    // typing a space into the title/content fields is untouched.
                    .onKeyPress(.space, phases: [.down, .repeat, .up]) { press in
                        switch press.phase {
                        case .down: return handleSpaceDown()
                        case .up: return handleSpaceUp()
                        // Auto-repeat while held: swallow so it doesn't read as a second tap.
                        default: return isPreviewing ? .handled : .ignored
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
                    // Clicks on the empty area around the card deselect it (the card's own
                    // surface sits above this layer and handles its blank space itself).
                    .background {
                        Color.clear
                            .contentShape(.rect)
                            .onTapGesture { isSelected = false }
                    }
            } else {
                // The empty state is itself the add control: clicking anywhere in it opens
                // the file picker, so no separate Add button is needed (drop still works).
                // While a drag hovers, the prompt flips to a clear "release to drop" cue.
                Button(action: chooseFile) {
                    ContentUnavailableView {
                        Label(isDropTargeted ? String(localized: "Drop to Add") : String(localized: "No File"),
                              systemImage: isDropTargeted ? "arrow.down.doc.fill" : "doc.badge.plus")
                            .foregroundStyle(isDropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    } description: {
                        Text(isDropTargeted ? String(localized: "Release to add this file.") : String(localized: "Drag a file here, or click to browse."))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        // Fill the whole square with a soft tint while a drag hovers, so it reads
        // unmistakably as the drop target (works in both the empty and filled states).
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.tint.opacity(isDropTargeted ? 0.12 : 0))
        )
        .dropDestination(for: URL.self) { dropped, _ in
            // Only regular files — a dropped folder is rejected (§11), so it shows the
            // "no" cursor rather than silently doing nothing.
            let files = dropped.filter(isRegularFileURL)
            guard !files.isEmpty else { return false }
            onSet(files)   // single-file: only the first dropped file is kept
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay(
            // A bold dashed border on drag-over — the classic "drop here" affordance.
            // Matches the corner radius of the content box's separator border.
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2.5, dash: [7, 5]))
                .opacity(isDropTargeted ? 1 : 0)
        )
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
    }

    /// A single **file** only — a file snippet can't reference a folder (§11).
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Add")
        if panel.runModal() == .OK { onSet(panel.urls) }
    }

    /// Space pressed: open the preview (recording the press so key-up can tell tap from
    /// hold), or close it if it's already up (a tap toggles).
    private func handleSpaceDown() -> KeyPress.Result {
        if isPreviewing {
            isPreviewing = false
            return .handled
        }
        isPreviewing = true
        spaceOpenedPreview = true
        spaceDownTime = Date()
        return .handled
    }

    /// Space released: if this press opened the preview, a quick tap leaves it open and a
    /// long hold closes it on release — the panel's split (§9).
    private func handleSpaceUp() -> KeyPress.Result {
        guard spaceOpenedPreview else { return .ignored }
        let held = spaceDownTime.map { Date().timeIntervalSince($0) } ?? 0
        spaceOpenedPreview = false
        spaceDownTime = nil
        if held >= holdThreshold { isPreviewing = false }
        return .handled
    }
}

/// The chosen file, presented as a centered card (CLAUDE.md §11): the large file-type
/// icon — never a content thumbnail; the content preview is on demand via Space /
/// double-click — the file name, its full path, a "Missing" flag when the file no longer
/// exists at that path, and **Replace / Remove** actions. Dropping a new file onto the
/// surrounding zone also replaces it. `isSelected` paints **Finder-style icon selection**
/// — a soft rounded backdrop behind the icon and an accent pill behind the name. Only the
/// **file identity itself** (icon / name) is the click target: one click selects,
/// double-click previews, and a click on the card's blank space deselects instead.
private struct FileSnippetCard: View {
    let url: URL
    var isSelected: Bool = false
    let onSelect: () -> Void
    let onDeselect: () -> Void
    let onPreview: () -> Void
    let onReplace: () -> Void
    let onRemove: () -> Void

    var body: some View {
        let path = url.path(percentEncoded: false)
        let missing = !FileManager.default.fileExists(atPath: path)
        ZStack {
            // The card surface as its own layer: clicks landing on blank card space hit
            // it and deselect — the icon/name above claim their own clicks first.
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
                .onTapGesture(perform: onDeselect)

            VStack(spacing: 12) {
                // The document icon at a large size (the OS supplies hi-res reps). Only
                // the file identity dims when missing — the badge and actions stay fully
                // legible. Selection highlights Finder-style: a soft rounded backdrop
                // (padding reserved always, so selecting never shifts layout).
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                    .opacity(missing ? 0.5 : 1)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(.separator)
                            .opacity(isSelected ? 1 : 0)
                    )
                    .contentShape(.rect)
                    // Simultaneous select so the first click of a double-click already
                    // selects, with no disambiguation delay on a plain single click.
                    .onTapGesture(count: 2, perform: onPreview)
                    .simultaneousGesture(TapGesture().onEnded(onSelect))

                VStack(spacing: 4) {
                    // Finder-style label selection: an accent pill behind the name. The
                    // name is a click target like the icon (same gesture pair).
                    Text(url.lastPathComponent.isEmpty ? path : url.lastPathComponent)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isSelected ? Color.accentColor : Color.clear)
                        )
                        .contentShape(.rect)
                        .onTapGesture(count: 2, perform: onPreview)
                        .simultaneousGesture(TapGesture().onEnded(onSelect))
                    // No path line: a stored copy's path is a meaningless internal UUID, and even
                    // a legacy snippet's original path is clutter — the name identifies the file.
                }
                .opacity(missing ? 0.5 : 1)

                if missing {
                    Label("File is missing", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                }

                HStack(spacing: 10) {
                    Button("Replace", action: onReplace)
                    Button("Remove", role: .destructive, action: onRemove)
                }
                .controlSize(.small)
                .padding(.top, 8)
            }
            .padding(32)
        }
        .frame(maxWidth: 460)
        .overlay(
            RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.6))
        )
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

/// RTF editor styled after macOS TextEdit's format bar (CLAUDE.md §11): B·I·U·S,
/// text + highlight color, font family/size, paragraph alignment, lists and line
/// spacing, over a plain `NSTextView` (native ruler hidden). The app is an agent (`LSUIElement`)
/// with no system Format menu, so all formatting is driven by this bar / its
/// ⌘B·⌘I·⌘U shortcuts rather than the Font menu.
private struct RichTextEditor: View {
    @Binding var rtfData: Data
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
            RichTextView(rtfData: $rtfData, controller: controller)
        }
        .task { installedFamilies = await FontCatalog.families() }
    }

    // MARK: Toolbar

    // Single non-scrolling row: the groups are sized to fit the fixed-width editor
    // window (CLAUDE.md §11), so there's no horizontal scroll bar. At minimum gaps the
    // groups + this row's padding must stay under ~680pt (the 720pt sheet minus its own
    // padding): a wider row doesn't clip — it overflows the proposed width and drags the
    // content box's right edge past the title field's, breaking the sheet's right
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
        HStack(spacing: 6) {
            SwatchColorPicker(
                currentColor: controller.textColor,
                hasColor: true,
                includeNoColor: false,
                showsAlpha: false,
                help: String(localized: "Text color"),
                apply: { if let color = $0 { controller.applyColor(color) } }
            )
            SwatchColorPicker(
                currentColor: controller.backgroundColor,
                hasColor: controller.hasBackground,
                includeNoColor: true,
                showsAlpha: true,
                showsGlyph: true,
                help: String(localized: "Text background color"),
                apply: { controller.applyBackgroundColor($0 ?? .clear) }
            )
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
            FontSizeField(size: fontSizeBinding, presets: fontSizes)
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
            // Mirrors the native TextEdit / ruler "Lists" popup: a None entry, the
            // static bullet glyphs, then the auto-numbered styles. An inline Picker bound
            // to the detected list kind gives each style a native checkmark when active;
            // default menu style (not .borderlessButton) gives the same gray pop-up box as
            // the font picker.
            Menu {
                Picker("List style", selection: listBinding) {
                    Text("None").tag(ListKind.none)
                    Text("–   Dash").tag(ListKind.dash)
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
                    // Surface the active custom marker as a checked row, so detection
                    // has a tag to match (and to show what's applied).
                    if case .custom(let marker) = controller.currentList {
                        Text("Custom (\(marker))").tag(ListKind.custom(marker))
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

/// Editable font-size control (CLAUDE.md §11): an `NSComboBox` so the user can type a
/// size with the keyboard or pick one of the presets from the dropdown. Input is
/// validated on commit (whole positive points) — no `NSFormatter`, which would grey out
/// the string list items.
private struct FontSizeField: NSViewRepresentable {
    @Binding var size: CGFloat
    let presets: [CGFloat]

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
    /// The marker styles offered by the Lists popup. Static glyphs (`dash`…`check`)
    /// render the same marker on every line; the lettered/numbered ones auto-number per
    /// line; `custom` carries an arbitrary marker string entered via "Other…".
    enum ListKind: Hashable {
        case none
        case dash, bullet, square, check
        case decimalDot, decimalParen
        case upperAlphaDot, lowerAlphaDot, lowerAlphaParen
        case upperRomanDot, lowerRomanDot
        case custom(String)
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
    var textColor: Color = .primary
    var backgroundColor: Color = .clear
    var hasBackground = false

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

    func applyColor(_ color: Color) {
        guard let tv = textView else { return }
        setAttribute(.foregroundColor, value: NSColor(color), to: tv)
        refreshState()
    }

    /// Sets the selected text's background ("highlight") color; a fully transparent
    /// choice (the popover's "no color") clears the attribute instead.
    func applyBackgroundColor(_ color: Color) {
        guard let tv = textView else { return }
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        if resolved.alphaComponent == 0 {
            removeAttribute(.backgroundColor, from: tv)
        } else {
            setAttribute(.backgroundColor, value: resolved, to: tv)
        }
        refreshState()
    }

    // MARK: Paragraph formatting

    func setAlignment(_ alignment: NSTextAlignment) {
        applyParagraphStyle { $0.alignment = alignment }
    }

    func setLineHeightMultiple(_ value: CGFloat) {
        applyParagraphStyle { $0.lineHeightMultiple = value }
    }

    /// Toggles a leading bullet/number marker on each selected paragraph, preserving
    /// the existing run attributes of those lines.
    func setList(_ kind: ListKind) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let paraRange = (storage.string as NSString).paragraphRange(for: tv.selectedRange())
        let attributed = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: paraRange))
        let source = attributed.string as NSString

        var lineRanges: [NSRange] = []
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length),
                                   options: [.byLines, .substringNotRequired]) { _, _, enclosing, _ in
            lineRanges.append(enclosing)
        }
        guard !lineRanges.isEmpty else { return }

        let texts = lineRanges.map { source.substring(with: $0) }
        let markerLengths = texts.map { Self.listMarkerLength($0) }
        let isBlank = zip(texts, markerLengths).map { text, len in
            String((text as NSString).substring(from: len)).trimmingCharacters(in: .whitespaces).isEmpty
        }
        var numbers = [Int?](repeating: nil, count: lineRanges.count)
        var n = 1
        for i in lineRanges.indices where !isBlank[i] { numbers[i] = n; n += 1 }

        attributed.beginEditing()
        for i in lineRanges.indices.reversed() {
            let start = lineRanges[i].location
            if markerLengths[i] > 0 {
                attributed.deleteCharacters(in: NSRange(location: start, length: markerLengths[i]))
            }
            guard kind != .none, !isBlank[i] else { continue }
            let marker = Self.listMarker(kind, number: numbers[i] ?? 1)
            let attrs = start < attributed.length
                ? attributed.attributes(at: start, effectiveRange: nil)
                : (textView?.typingAttributes ?? [:])
            attributed.insert(NSAttributedString(string: marker, attributes: attrs), at: start)
        }
        attributed.endEditing()

        if tv.shouldChangeText(in: paraRange, replacementString: attributed.string) {
            storage.replaceCharacters(in: paraRange, with: attributed)
            tv.didChangeText()
        }
        refreshState()
    }

    /// Reflects the formatting at the caret/selection onto the toolbar.
    func refreshState() {
        let font = activeFont
        let symbolic = font.fontDescriptor.symbolicTraits
        isBold = symbolic.contains(.bold)
        isItalic = symbolic.contains(.italic)
        isUnderline = attributeActive(.underlineStyle)
        isStrikethrough = attributeActive(.strikethroughStyle)
        fontFamily = font.familyName ?? font.fontName
        fontSize = font.pointSize
        let para = activeParagraphStyle
        let resolved = para?.alignment ?? .left
        alignment = resolved == .natural ? .left : resolved
        let lhm = para?.lineHeightMultiple ?? 0
        lineHeightMultiple = lhm == 0 ? 1.0 : lhm
        if let color = activeColor { textColor = Color(nsColor: color) }
        if let bg = activeBackgroundColor, (bg.usingColorSpace(.sRGB)?.alphaComponent ?? 1) > 0 {
            backgroundColor = Color(nsColor: bg)
            hasBackground = true
        } else {
            backgroundColor = .clear
            hasBackground = false
        }
        currentList = detectListKind()
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
        guard let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        if range.length > 0, tv.shouldChangeText(in: range, replacementString: nil) {
            storage.beginEditing()
            storage.addAttribute(key, value: value, range: range)
            storage.endEditing()
            tv.didChangeText()
        }
        tv.typingAttributes[key] = value
    }

    private func removeAttribute(_ key: NSAttributedString.Key, from tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        if range.length > 0, tv.shouldChangeText(in: range, replacementString: nil) {
            storage.beginEditing()
            storage.removeAttribute(key, range: range)
            storage.endEditing()
            tv.didChangeText()
        }
        tv.typingAttributes.removeValue(forKey: key)
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

    /// Matches a leading list marker of any style — an alphanumeric run (decimal / alpha /
    /// roman) ending in `.`/`)` + tab, or a short run of symbol characters + tab (the static
    /// glyphs and "Other…" custom markers) — so re-listing or removing strips whatever
    /// marker is already there. The symbol branch excludes word/space chars so ordinary
    /// tab-indented prose isn't mistaken for a marker.
    private static func listMarkerLength(_ line: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: "^([0-9A-Za-z]+[.)]\\t|[^\\w\\s]{1,3}\\t)") else { return 0 }
        let ns = line as NSString
        return regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))?.range.length ?? 0
    }

    /// The marker text (glyph/number + tab) to prepend for `kind` on the `number`-th
    /// non-blank line. Static styles ignore `number`.
    private static func listMarker(_ kind: ListKind, number n: Int) -> String {
        switch kind {
        case .none: return ""
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

    /// Classifies the list marker on the caret's line so the Lists popup can check the
    /// active style. Lists created from the popup always renumber from item 1, so the
    /// contiguous lettered block's first marker disambiguates alphabetic vs roman
    /// (whose single-letter markers — I, V, X… — otherwise overlap).
    private func detectListKind() -> ListKind {
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

    private var activeColor: NSColor? {
        guard let tv = textView else { return nil }
        let range = tv.selectedRange()
        if range.length > 0, let storage = tv.textStorage, range.location < storage.length {
            // Selected text without an explicit foreground color uses the view's default,
            // so the icon tracks the selection instead of sticking on the last applied color.
            return (storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor)
                ?? tv.textColor
        }
        return (tv.typingAttributes[.foregroundColor] as? NSColor) ?? tv.textColor
    }

    private var activeBackgroundColor: NSColor? {
        guard let tv = textView else { return nil }
        let range = tv.selectedRange()
        if range.length > 0, let storage = tv.textStorage, range.location < storage.length {
            return storage.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? NSColor
        }
        return tv.typingAttributes[.backgroundColor] as? NSColor
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

/// Custom swatch popover used for both the text and background color controls, in place
/// of a native `NSColorWell`. Mirrors the native macOS color grid (a vivid named-color
/// row, a grayscale row, then a hue matrix) with hover feedback and a "Show Colors…"
/// hand-off to the system color panel. The background control enables the "No Color"
/// swatch (`includeNoColor`) — the system minimal-well popover greys that swatch out,
/// which is why this is a custom grid.
private struct SwatchColorPicker: View {
    var currentColor: Color
    var hasColor: Bool
    var includeNoColor: Bool
    var showsAlpha: Bool
    var showsGlyph: Bool = false
    var help: String
    var apply: (Color?) -> Void

    @State private var isPresented = false
    @State private var panelProxy = ColorPanelProxy()
    @State private var hoveredIndex: Int?
    /// Hover on the closed swatch button itself (the popover cells track `hoveredIndex`).
    @State private var isHovered = false

    private let columns = Array(repeating: GridItem(.fixed(16), spacing: 4), count: 12)
    private var showsNoColor: Bool { includeNoColor && !hasColor }

    var body: some View {
        Button { isPresented.toggle() } label: {
            preview
                .frame(width: 36, height: 22)
                .shadow(color: .black.opacity(isHovered ? 0.15 : 0), radius: 2, y: 1)
        }
        .buttonStyle(PressDimButtonStyle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(help)
        .accessibilityLabel(help)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) { popover }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(showsNoColor ? .white : currentColor)
            if showsNoColor { noColorMark }
            // The "A" marks the highlight control (like TextEdit), tinted to stay
            // legible against whatever swatch color is showing.
            if showsGlyph {
                Text("A")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(glyphColor)
            }
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isHovered
                    ? Color(nsColor: .tertiaryLabelColor)
                    : Color(nsColor: .separatorColor))
        }
    }

    /// Legible ink for the "A": dark on the white "no color" swatch, otherwise
    /// black on light fills and white on dark ones.
    private var glyphColor: Color {
        guard !showsNoColor else { return .black }
        let ns = NSColor(currentColor).usingColorSpace(.sRGB) ?? .black
        let luminance = 0.299 * ns.redComponent + 0.587 * ns.greenComponent + 0.114 * ns.blueComponent
        return luminance > 0.6 ? .black : .white
    }

    private var popover: some View {
        VStack(spacing: 4) {
            swatchRow(0..<12)               // vivid named colors
                .padding(.bottom, 6)        // gap only between rows 1 and 2
            swatchRow(12..<24)              // No Color + grayscale
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(24..<palette.count, id: \.self) { i in
                    cell(palette[i], index: i)
                }
            }
            Divider().padding(.top, 4)
            Button("Show Colors…") { showColorPanel() }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
        }
        .padding(12)
        .frame(width: 268)
        .animation(.easeOut(duration: 0.12), value: hoveredIndex)
    }

    private func swatchRow(_ range: Range<Int>) -> some View {
        HStack(spacing: 4) {
            ForEach(range, id: \.self) { i in
                cell(palette[i], index: i)
            }
        }
    }

    private func cell(_ color: Color?, index: Int) -> some View {
        let isHovered = hoveredIndex == index
        return Button {
            apply(color)
            isPresented = false
        } label: {
            ZStack {
                if let color {
                    RoundedRectangle(cornerRadius: 3).fill(color)
                } else {
                    RoundedRectangle(cornerRadius: 3).fill(.white)
                    noColorMark
                }
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(isHovered ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.4),
                                  lineWidth: isHovered ? 2 : 1)
            }
            .frame(width: 16, height: 16)
            .scaleEffect(isHovered ? 1.2 : 1)
            .shadow(color: .black.opacity(isHovered ? 0.25 : 0), radius: isHovered ? 2 : 0)
        }
        .buttonStyle(.plain)
        .zIndex(isHovered ? 1 : 0)
        .onHover { hovering in
            hoveredIndex = hovering ? index : (hoveredIndex == index ? nil : hoveredIndex)
        }
        .help(color == nil ? String(localized: "No color") : "")
    }

    private var noColorMark: some View {
        GeometryReader { geo in
            Path { path in
                path.move(to: CGPoint(x: 2, y: geo.size.height - 2))
                path.addLine(to: CGPoint(x: geo.size.width - 2, y: 2))
            }
            .stroke(.red, lineWidth: 1.2)
        }
    }

    private func showColorPanel() {
        isPresented = false
        let panel = NSColorPanel.shared
        panel.showsAlpha = showsAlpha
        if hasColor { panel.color = NSColor(currentColor) }
        panelProxy.onChange = { apply($0) }
        panel.setTarget(panelProxy)
        panel.setAction(#selector(ColorPanelProxy.changed(_:)))
        panel.orderFront(nil)
    }

    /// Mirrors the native macOS swatch grid (10 rows × 12): a vivid named-color row,
    /// a grayscale row (led by the "No Color" swatch when allowed), then a hue matrix
    /// whose columns start at blue (210°) and step by 30°, darkest shade → lightest tint.
    private var palette: [Color?] {
        var colors: [Color?] = [
            Color(red: 1.00, green: 0.15, blue: 0.15),   // red
            Color(red: 1.00, green: 0.58, blue: 0.10),   // orange
            Color(red: 1.00, green: 0.90, blue: 0.15),   // yellow
            Color(red: 0.30, green: 0.82, blue: 0.27),   // green
            Color(red: 0.22, green: 0.84, blue: 0.80),   // cyan
            Color(red: 0.15, green: 0.47, blue: 1.00),   // blue
            Color(red: 0.90, green: 0.28, blue: 0.90),   // magenta
            Color(red: 0.60, green: 0.26, blue: 0.85),   // purple
            Color(red: 0.58, green: 0.39, blue: 0.22),   // brown
            .white,
            Color(white: 0.5),                           // gray
            .black,
        ]
        if includeNoColor {
            colors.append(nil)                           // No Color
            for i in 0..<11 { colors.append(Color(white: 1.0 - Double(i) / 10)) }
        } else {
            for i in 0..<12 { colors.append(Color(white: 1.0 - Double(i) / 11)) }
        }
        let hueOffset = 210.0 / 360.0
        let shades: [(s: Double, b: Double)] = [(1, 0.40), (1, 0.55), (1, 0.70), (1, 0.85),
                                                (0.8, 1), (0.6, 1), (0.4, 1), (0.2, 1)]
        for shade in shades {
            for i in 0..<12 {
                let hue = (hueOffset + Double(i) / 12).truncatingRemainder(dividingBy: 1)
                colors.append(Color(hue: hue, saturation: shade.s, brightness: shade.b))
            }
        }
        return colors
    }
}

/// Receives live color changes from the shared `NSColorPanel` ("Show Colors…").
@MainActor
private final class ColorPanelProxy: NSObject {
    var onChange: ((Color) -> Void)?
    @objc func changed(_ sender: NSColorPanel) { onChange?(Color(nsColor: sender.color)) }
}

/// `NSTextView` wrapper (native ruler hidden — formatting comes from our custom toolbar).
/// Edits flow out as RTF via the delegate; the `controller` (set here) lets the format bar
/// reach the text view.
private struct RichTextView: NSViewRepresentable {
    @Binding var rtfData: Data
    var controller: RichTextController

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFontPanel = false
        // Hide AppKit's ruler + its format-controls accessory row (Styles / Spacing /
        // Lists / writing-direction). All formatting is driven by our custom toolbar, so
        // the native ruler is redundant clutter.
        textView.usesRuler = false
        textView.isRulerVisible = false
        textView.delegate = context.coordinator
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.font = NSFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12)
        scrollView.hasHorizontalRuler = false
        scrollView.rulersVisible = false
        // Text wraps to the container width — never a horizontal scroll bar.
        scrollView.hasHorizontalScroller = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        if let attr = NSAttributedString(rtf: rtfData, documentAttributes: nil) {
            textView.textStorage?.setAttributedString(attr)
        }
        controller.textView = textView
        DispatchQueue.main.async { controller.refreshState() }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // Edits flow out via the delegate; avoid clobbering the field while typing.
    }

    func makeCoordinator() -> Coordinator { Coordinator(rtfData: $rtfData, controller: controller) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var rtfData: Data
        let controller: RichTextController

        init(rtfData: Binding<Data>, controller: RichTextController) {
            _rtfData = rtfData
            self.controller = controller
        }

        func textDidChange(_ notification: Notification) {
            guard let storage = (notification.object as? NSTextView)?.textStorage else { return }
            rtfData = storage.rtf() ?? Data()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            controller.refreshState()
        }
    }
}

private extension NSAttributedString {
    /// RTF data for the whole string, or nil.
    func rtf() -> Data? {
        rtf(from: NSRange(location: 0, length: length), documentAttributes: [:])
    }
}
