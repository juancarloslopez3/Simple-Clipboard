import SwiftData
import SwiftUI

/// Sidebar: a Clipboard row with a live count badge + the user's snippet folders, with a
/// `+ / –` footer to add/remove folders.
struct SidebarView: View {
    @Binding var selection: SidebarItem?
    @Environment(\.modelContext) private var context
    @Environment(HistoryStore.self) private var history
    @Query(sort: \SnippetFolder.sortIndex) private var folders: [SnippetFolder]

    @State private var renamingFolderID: UUID?
    @State private var renameText = ""
    @FocusState private var renameFieldFocused: Bool
    @State private var emojiFolderID: UUID?
    @State private var emojiText = ""

    // Folder awaiting delete confirmation (drives the native warning alert below); deleting a
    // folder cascades its snippets, so we confirm first — until the alert's "Don’t ask again"
    // turns `confirmBeforeDeletingFolders` off (Settings › General turns it back on).
    @State private var folderPendingDeletion: SnippetFolder?
    @AppStorage(Pref.Key.confirmBeforeDeletingFolders) private var confirmFolderDeletes = Pref.Default.confirmBeforeDeletingFolders
    /// Clear History's confirmation sheet — skipped once its "Don’t ask again" turns
    /// `confirmBeforeClearingHistory` off (Settings › General turns it back on).
    @State private var isConfirmingClearHistory = false
    @AppStorage(Pref.Key.confirmBeforeClearingHistory) private var confirmClearHistory = Pref.Default.confirmBeforeClearingHistory

    // Last folder row tapped + when, for the hand-rolled double-tap detection in `folderRow`.
    @State private var lastTap: (id: UUID, at: Date)?
    private let renameTapInterval: TimeInterval = 0.35

    var body: some View {
        List(selection: $selection) {
            // The store's maintained count, not a `@Query` of every item just to count them.
            Label("Clipboard", systemImage: "doc.on.clipboard")
                .badge(history.itemCount)
                .tag(SidebarItem.clipboard)
                .contextMenu {
                    Button(role: .destructive) {
                        requestClearHistory()
                    } label: {
                        Label("Clear History", systemImage: "trash")
                    }
                    .disabled(history.itemCount == 0)
                }

            Section("Snippets") {
                ForEach(folders) { folder in
                    folderRow(folder)
                        .tag(SidebarItem.snippetFolder(folder.id))
                }
            }
        }
        // Right-clicking empty List space (not a row — rows keep their own menus above)
        // offers New Folder, mirroring the footer's `+` (Finder convention).
        .contextMenu {
            Button(action: addFolder) {
                Label("New Folder", systemImage: "plus")
            }
        }
        .navigationTitle("Simple Clipboard")
        .safeAreaInset(edge: .bottom) { footer }
        // Same confirmation as the panel's Clear History, as a sheet on this window. A suppression
        // checkbox reaches the alerts attached above it, and the nearest one wins — so each of
        // these two alerts records its own "Don’t ask again".
        .alert("Clear Clipboard History?", isPresented: $isConfirmingClearHistory) {
            Button("Clear History", role: .destructive) { history.clear() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes all saved clipboard items. This can’t be undone.")
        }
        .dialogSuppressionToggle("Don’t ask again", isSuppressed: suppressClearHistoryConfirmation)
        // Native warning modal before a (cascading) folder delete.
        .alert(
            "Delete “\(folderPendingDeletion?.name ?? "")”?",
            isPresented: isPresentingDeleteConfirmation,
            presenting: folderPendingDeletion
        ) { folder in
            Button("Delete Folder", role: .destructive) { delete(folder) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("All snippets in this folder will be removed. This can't be undone.")
        }
        .dialogSuppressionToggle("Don’t ask again", isSuppressed: suppressFolderDeleteConfirmation)
        // Return on a *selected* folder starts renaming (Finder convention). While a rename
        // is already in progress, ignore it here so Return falls through to the text field's
        // `onSubmit` and commits the edit instead of restarting it.
        .onKeyPress(.return) {
            guard renamingFolderID == nil,
                  case .snippetFolder(let id) = selection,
                  let folder = folders.first(where: { $0.id == id }) else { return .ignored }
            beginRename(folder)
            return .handled
        }
    }

    @ViewBuilder
    private func folderGlyph(_ folder: SnippetFolder) -> some View {
        FolderGlyph(emoji: folder.emoji)
    }

    private func setEmoji(_ value: String, for folder: SnippetFolder) {
        folder.emoji = value
        try? context.save()
        emojiFolderID = nil
    }

    private func emojiPicker(_ folder: SnippetFolder) -> some View {
        FolderEmojiPicker(current: folder.emoji) { setEmoji($0, for: folder) }
    }

    @ViewBuilder
    private func folderRow(_ folder: SnippetFolder) -> some View {
        if renamingFolderID == folder.id {
            // Keep the folder icon visible while editing (a bare TextField would drop it).
            Label {
                TextField("Folder name", text: $renameText)
                    .textFieldStyle(.plain)
                    .focused($renameFieldFocused)
                    .onSubmit { commitRename(folder) }
                    .onExitCommand { renamingFolderID = nil }
            } icon: {
                folderGlyph(folder)
            }
            .onAppear { renameFieldFocused = true }
            // Clicking another row commits the in-progress edit (Finder convention).
            .onChange(of: renameFieldFocused) { _, focused in
                if !focused, renamingFolderID == folder.id { commitRename(folder) }
            }
        } else {
            Label { Text(folder.name) } icon: { folderGlyph(folder) }
                .badge(folder.snippets.count)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // Any gesture on the row content consumes the click before `List`'s native
                // (AppKit) selection runs, so we drive selection ourselves. We use a *single*
                // tap gesture and disambiguate the double-tap by hand (`handleTap`): a lone
                // single-tap gesture fires immediately, whereas pairing it with a `count: 2`
                // gesture forces SwiftUI to delay every selection by the double-tap window
                // (~0.25 s) to rule out a second tap — which made switching folders feel
                // sluggish. A tap selects; a second tap on the same row within
                // `renameTapInterval` renames. `contentShape` above makes the whole row —
                // not just the text — the hit target.
                .onTapGesture { handleTap(folder) }
                .popover(isPresented: Binding(
                    get: { emojiFolderID == folder.id },
                    set: { if !$0 { emojiFolderID = nil } }
                ), arrowEdge: .trailing) { emojiPicker(folder) }
                .contextMenu {
                    Button("Rename") { beginRename(folder) }
                    Button("Change Icon") { emojiText = ""; emojiFolderID = folder.id }
                    Button("Delete", role: .destructive) { requestDelete(folder) }
                }
        }
    }

    private var footer: some View {
        HStack(spacing: 2) {
            Button(action: addFolder) {
                Image(systemName: "plus").frame(width: 24, height: 22)
            }
            .help("Add Snippet Folder")
            Button(action: removeSelectedFolder) {
                Image(systemName: "minus").frame(width: 24, height: 22)
            }
            .help("Remove Snippet Folder")
            .disabled(!isFolderSelected)
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var isFolderSelected: Bool {
        if case .snippetFolder = selection { return true }
        return false
    }

    /// Bridges the optional `folderPendingDeletion` to the alert's `isPresented` binding;
    /// dismissing (Cancel / Esc) clears the pending folder.
    private var isPresentingDeleteConfirmation: Binding<Bool> {
        Binding(
            get: { folderPendingDeletion != nil },
            set: { if !$0 { folderPendingDeletion = nil } }
        )
    }

    /// The Clear History alert's "Don’t ask again" — recorded only when the user goes on to clear.
    private var suppressClearHistoryConfirmation: Binding<Bool> {
        Binding(
            get: { !confirmClearHistory },
            set: { confirmClearHistory = !$0 }
        )
    }

    private func requestClearHistory() {
        if confirmClearHistory {
            isConfirmingClearHistory = true
        } else {
            history.clear()
        }
    }

    // MARK: Folder interaction

    /// Single-tap selection with manual double-tap detection, so selection fires instantly
    /// instead of waiting out a `count: 2` gesture's disambiguation window (see `folderRow`).
    private func handleTap(_ folder: SnippetFolder) {
        let now = Date()
        if let last = lastTap, last.id == folder.id, now.timeIntervalSince(last.at) < renameTapInterval {
            lastTap = nil
            beginRename(folder)
        } else {
            selection = .snippetFolder(folder.id)
            lastTap = (folder.id, now)
        }
    }

    // MARK: Folder CRUD

    private func addFolder() {
        let next = (folders.map(\.sortIndex).max() ?? -1) + 1
        let folder = SnippetFolder(name: String(localized: "New Folder"), sortIndex: next)
        context.insert(folder)
        try? context.save()
        selection = .snippetFolder(folder.id)
        beginRename(folder)
    }

    private func removeSelectedFolder() {
        guard case .snippetFolder(let id) = selection, let folder = folders.first(where: { $0.id == id }) else { return }
        requestDelete(folder)
    }

    /// Stage `folder` for deletion, surfacing the confirmation alert — or delete it straight
    /// away with confirmation turned off.
    private func requestDelete(_ folder: SnippetFolder) {
        if confirmFolderDeletes {
            folderPendingDeletion = folder
        } else {
            delete(folder)
        }
    }

    /// The folder alert's "Don’t ask again" — recorded only when the user goes on to delete.
    private var suppressFolderDeleteConfirmation: Binding<Bool> {
        Binding(
            get: { !confirmFolderDeletes },
            set: { confirmFolderDeletes = !$0 }
        )
    }

    private func delete(_ folder: SnippetFolder) {
        // The cascade deletes the snippets but not their stored file copies.
        folder.snippets.forEach { $0.deleteOwnedManagedFiles() }
        context.delete(folder)
        try? context.save()
        folderPendingDeletion = nil
        selection = .clipboard
    }

    private func beginRename(_ folder: SnippetFolder) {
        selection = .snippetFolder(folder.id)
        renameText = folder.name
        renamingFolderID = folder.id
    }

    private func commitRename(_ folder: SnippetFolder) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { folder.name = trimmed }
        try? context.save()
        renamingFolderID = nil
    }
}
