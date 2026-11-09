import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The content pane when a snippet folder is selected (CLAUDE.md §1c). A `Snippets`
/// header with a primary "New Snippet" (glass) button + a list of snippet cards.
struct SnippetsListView: View {
    @Bindable var folder: SnippetFolder
    /// Set by `MainWindowView` when the snippets panel's "New Snippet" button targets this folder
    /// (CLAUDE.md §9/§11): opening the editor here, then clearing the flag. Defaults to a no-op
    /// binding for callers that don't drive compose.
    @Binding var composePending: Bool
    @Environment(PasteService.self) private var paste
    @Environment(\.modelContext) private var context
    @AppStorage(Pref.Key.alwaysPastePlainText) private var alwaysPlain = Pref.Default.alwaysPastePlainText
    @State private var editing: Snippet?
    /// A just-created snippet being edited, kept **out of the store** (not inserted)
    /// until the editor closes with content — so it doesn't show up in this list, the
    /// menu, or the panel while it's still being created (§11).
    @State private var draft: Snippet?
    /// Transient copy confirmation shown after a context-menu copy (§10), matching the
    /// history pane. Its label spells out the plain-text mode when it differs from the
    /// `alwaysPastePlainText` default (§12).
    @State private var toast = CopyToast()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Snippets").font(.title2.bold())
                Spacer()
                Button(action: addSnippet) {
                    Label("New Snippet", systemImage: "plus")
                }
                .buttonStyle(.glassProminent)   // the single primary action (CLAUDE.md §3)
            }
            .padding()

            if folder.orderedSnippets.isEmpty {
                ContentUnavailableView(
                    "No Snippets",
                    systemImage: "text.quote",
                    description: Text("Add a snippet to “\(folder.name)”.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(folder.orderedSnippets) { snippet in
                            SnippetCard(snippet: snippet)
                                .onTapGesture { editing = snippet }
                                .contextMenu {
                                    Button("Edit") { editing = snippet }
                                    // "Copy" follows the pref, so it names the default mode
                                    // — always "Copied" (§10).
                                    Button("Copy") { copy(copiedLabel(for: snippet, plainText: alwaysPlain)) { paste.activate(snippet) } }
                                    // File snippets are exempt from plain-text mode (§12);
                                    // they get an explicit path-copy instead, like file rows.
                                    if snippet.isFile {
                                        Button(snippet.fileURLs.count > 1 ? String(localized: "Copy Paths") : String(localized: "Copy Path")) {
                                            copy { paste.copyPaths(of: snippet) }
                                        }
                                    } else if alwaysPlain {
                                        // Plain is what Copy already does with the pref on —
                                        // the alternate flips to the formatted form (§12); the
                                        // toast names the resolved mode.
                                        Button("Copy text with formatting") { copy(copiedLabel(for: snippet, plainText: false)) { paste.activate(snippet, plainText: false) } }
                                    } else {
                                        Button("Copy as plain text") { copy(copiedLabel(for: snippet, plainText: true)) { paste.activate(snippet, plainText: true) } }
                                    }
                                    Divider()
                                    Button("Delete", role: .destructive) { delete(snippet) }
                                }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(folder.name)
        .copyToast(toast)
        .sheet(item: $editing, onDismiss: finishEditing) { snippet in
            // A never-committed draft (still held in `draft`) is a *new* snippet; anything
            // else is an existing one being edited — drives the editor's header title.
            SnippetEditorView(snippet: snippet, isNew: snippet === draft)
        }
        // Open the editor for a "New Snippet" request routed here by `MainWindowView` (§11).
        // `onAppear` handles the folder having just been selected for this request (a fresh view,
        // so `onChange` wouldn't fire); `onChange` handles the folder already being on screen.
        .onAppear { if composePending { startCompose() } }
        .onChange(of: composePending) { _, pending in if pending { startCompose() } }
    }

    /// Runs a copy action, then flashes the copy confirmation with `message` (§10).
    private func copy(_ message: String = String(localized: "Copied"), _ action: () -> Void) {
        action()
        toast.flash(message)
    }

    /// Toast text for a snippet copy: spells out the plain-text mode only when it differs from
    /// the `alwaysPastePlainText` default, so an explicit plain/formatted copy names its mode
    /// while a default copy just reads "Copied" (§10/§12). File snippets are exempt.
    private func copiedLabel(for snippet: Snippet, plainText: Bool) -> String {
        guard !snippet.isFile, plainText != alwaysPlain else { return String(localized: "Copied") }
        return plainText ? String(localized: "Copied as plain text") : String(localized: "Copied with formatting")
    }

    /// Begin the "New Snippet" flow requested from the panel (§11): open a blank editor draft and
    /// clear the request so it fires once.
    private func startCompose() {
        composePending = false
        addSnippet()
    }

    /// New snippets start fully blank — the editor's "Title" placeholder and empty
    /// content field invite input; nothing preset to delete (§11). The snippet is a
    /// detached draft (no folder, not inserted) until `finishEditing` commits it.
    private func addSnippet() {
        let next = (folder.snippets.map(\.sortIndex).max() ?? -1) + 1
        let snippet = Snippet(title: "", sortIndex: next)
        draft = snippet
        editing = snippet
    }

    /// Commits a non-empty draft into the folder — the new snippet only appears once
    /// it has actually been created — and sweeps contentless leftovers (§11).
    private func finishEditing() {
        if let draft {
            if !draft.isEmpty {
                context.insert(draft)
                draft.folder = folder
                try? context.save()
            }
            self.draft = nil
        }
        discardEmptySnippets()
    }

    /// A snippet must have content (§11): once the editor closes, drop any snippet
    /// left without non-whitespace content — title or not (e.g. clearing an existing
    /// snippet's title and content, then Done).
    private func discardEmptySnippets() {
        let empties = folder.snippets.filter(\.isEmpty)
        guard !empties.isEmpty else { return }
        empties.forEach(context.delete)
        try? context.save()
    }

    private func delete(_ snippet: Snippet) {
        snippet.deleteOwnedManagedFiles()   // drop its stored file copy, if any (§12)
        context.delete(snippet)
        try? context.save()
    }
}

/// A single snippet card: Title (bold) · timestamp · content preview (CLAUDE.md §1c). A file
/// snippet referencing an **image** also shows a content thumbnail above the text preview —
/// the same presentation as the history rows' image thumbnails (§10/§11). PDF and other
/// files stay text-only, matching the history rows and the panel's snippet rows (§9).
private struct SnippetCard: View {
    let snippet: Snippet
    /// Inline thumbnail for an image file snippet, generated off the referenced file
    /// (snippets store no thumbnail — §7) via the shared `ClipboardContent.fileThumbnail`.
    /// Keyed by the file URL, not the snippet, so replacing the file in the editor
    /// regenerates it; `nil` for text/rich snippets and non-image files.
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Baseline-align the header so the "Rich Text" badge and caption timestamp sit on the
            // headline title's baseline instead of floating at its vertical middle.
            HStack(alignment: .firstTextBaseline) {
                Text(snippet.title.isEmpty ? String(localized: "Untitled") : snippet.title)
                    .font(.headline)
                if snippet.isRichText || snippet.isFile {
                    Text(snippet.isFile ? String(localized: "File") : String(localized: "Rich Text"))
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.tint.opacity(0.2), in: .capsule)
                }
                Spacer()
                Text(snippet.createdAt.clipboardRowString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let thumbnail {
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
                // Lead the file name with the same `doc` glyph the history file rows use
                // (§10), so a file snippet reads as a file here too.
                Label(previewText, systemImage: "doc")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .task(id: thumbnailURL) {
            guard let url = thumbnailURL else { thumbnail = nil; return }
            let data = await Task.detached(priority: .utility) {
                ClipboardContent.fileThumbnail(for: url)
            }.value
            thumbnail = data.flatMap(NSImage.init(data:))
        }
    }

    /// The file a thumbnail would come from — an **image** file snippet's (single) referenced
    /// file; `nil` for PDFs and other files, which stay text-only (§9/§11).
    private var thumbnailURL: URL? {
        guard snippet.isFile, let url = snippet.fileURLs.first else { return nil }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .image) == true ? url : nil
    }

    private var previewText: String {
        // File snippets preview as their cached file *names* (comma-joined, §11); text
        // snippets derive from the content itself — older cached previews were stored
        // newline-collapsed (menuPreview), which would defeat the 3-line preview above.
        if snippet.isFile {
            let p = snippet.plainPreview.isEmpty ? snippet.plainString : snippet.plainPreview
            return p.isEmpty ? String(localized: "Empty") : p
        }
        let p = snippet.plainString.multilinePreview(limit: 240)
        return p.isEmpty ? String(localized: "Empty") : p
    }
}
