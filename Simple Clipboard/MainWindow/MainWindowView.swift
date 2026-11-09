import SwiftData
import SwiftUI

/// Identifies the selected sidebar row (CLAUDE.md §1b). Snippet folders are referenced
/// by `id` so the value stays `Hashable` for `List` selection.
enum SidebarItem: Hashable {
    case clipboard
    case snippetFolder(UUID)
}

/// The two-pane main window (CLAUDE.md §10). Toolbar / search / sidebar render as
/// Liquid Glass automatically on macOS 26 — no glass code here.
struct MainWindowView: View {
    @State private var selection: SidebarItem? = .clipboard
    /// The folder the snippets panel's "New Snippet" request targets, driving `SnippetsListView`
    /// to open its editor once that folder is showing (CLAUDE.md §9/§11).
    @State private var pendingComposeFolder: UUID?
    @Query(sort: \SnippetFolder.sortIndex) private var folders: [SnippetFolder]
    @Environment(SnippetComposer.self) private var composer
    @Environment(\.modelContext) private var context

    var body: some View {
        // Sidebar is always visible: a constant `.all` visibility disables collapsing and
        // `.toolbar(removing: .sidebarToggle)` drops the system hide/show button (§10).
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SidebarView(selection: $selection)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            switch selection {
            case .clipboard, .none:
                ClipboardListView()
            case .snippetFolder(let id):
                if let folder = folders.first(where: { $0.id == id }) {
                    SnippetsListView(folder: folder, composePending: composeBinding(for: id))
                } else {
                    ContentUnavailableView("Select a Folder", systemImage: "folder")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Open Settings")
            }
        }
        // Suppress the native toolbar right-click menu (Icon and Text / Icon Only / Text Only) —
        // SwiftUI exposes no modifier for it, so reach the host window's NSToolbar (§10).
        .background(ToolbarMenuDisabler())
        // Consume the panel's "New Snippet" request. `onAppear` catches a request raised while the
        // window was closed (the value is already set when the view first appears, so `onChange`
        // alone would miss it); `onChange` catches one raised while the window is already open.
        .onAppear { if composer.pendingRequest { beginCompose() } }
        .onChange(of: composer.pendingRequest) { _, pending in if pending { beginCompose() } }
    }

    /// Route a "New Snippet" request to a folder: prefer the folder the panel's picker chose
    /// (`composer.folderID`, CLAUDE.md §9/§11), else keep the current selection if it's a folder,
    /// else the first folder, else create a default one. Selecting it shows `SnippetsListView`,
    /// which opens its editor when `composePending` turns true (CLAUDE.md §11).
    private func beginCompose() {
        composer.pendingRequest = false
        let targetID: UUID
        if let chosen = composer.folderID, folders.contains(where: { $0.id == chosen }) {
            targetID = chosen
        } else if case .snippetFolder(let id) = selection, folders.contains(where: { $0.id == id }) {
            targetID = id
        } else if let first = folders.first {
            targetID = first.id
        } else {
            let folder = SnippetFolder(name: String(localized: "Snippets"), sortIndex: 0)
            context.insert(folder)
            try? context.save()
            targetID = folder.id
        }
        composer.folderID = nil
        selection = .snippetFolder(targetID)
        pendingComposeFolder = targetID
    }

    /// A `Bool` binding that's true only for the folder awaiting a compose, cleared once
    /// `SnippetsListView` picks it up.
    private func composeBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { pendingComposeFolder == id },
            set: { active in if !active, pendingComposeFolder == id { pendingComposeFolder = nil } }
        )
    }
}

/// Disables the window toolbar's display-mode context menu — the native right-click list
/// "Icon and Text / Icon Only / Text Only" (CLAUDE.md §10). SwiftUI offers no modifier for it,
/// so this zero-size backing view reaches the enclosing `NSWindow`'s `NSToolbar` and turns
/// display-mode customization off (macOS 15+). Applied once the window/toolbar exist.
private struct ToolbarMenuDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        disable(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        disable(from: nsView)
    }

    /// The toolbar is attached to the window after the view is installed, so defer to the next
    /// runloop turn where `view.window?.toolbar` is available.
    private func disable(from view: NSView) {
        DispatchQueue.main.async { [weak view] in
            view?.window?.toolbar?.allowsDisplayModeCustomization = false
        }
    }
}
