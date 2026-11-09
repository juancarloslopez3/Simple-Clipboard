import SwiftData
import SwiftUI

/// Identifies the selected sidebar row. Snippet folders are referenced
/// by `id` so the value stays `Hashable` for `List` selection.
enum SidebarItem: Hashable {
    case clipboard
    case snippetFolder(UUID)
}

/// The two-pane main window. Toolbar / search / sidebar render as
/// Liquid Glass automatically on macOS 26 — no glass code here.
struct MainWindowView: View {
    @State private var selection: SidebarItem? = .clipboard
    /// The folder a "New Snippet" request (the toolbar button or the snippets panel's) targets, driving `SnippetsListView`
    /// to open its editor once that folder is showing.
    @State private var pendingComposeFolder: UUID?
    @Query(sort: \SnippetFolder.sortIndex) private var folders: [SnippetFolder]
    @Environment(SnippetComposer.self) private var composer
    @Environment(\.modelContext) private var context

    var body: some View {
        // Sidebar is always visible: a constant `.all` visibility keeps it shown,
        // `.toolbar(removing: .sidebarToggle)` drops the system hide/show button, and
        // `SidebarCollapseDisabler` stops a divider drag from collapsing it. Its width is
        // clamped to a fixed range so the divider can't squeeze or stretch it out of shape.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SidebarView(selection: $selection)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
                .background(SidebarCollapseDisabler())
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
            // New Snippet for the folder on screen. Declared here rather than in `SnippetsListView`
            // so it sits before Settings: items from the detail view land after this toolbar's.
            if let folderID = shownFolderID {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Snippet", systemImage: "plus") { pendingComposeFolder = folderID }
                        .help("New Snippet")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Open Settings")
            }
        }
        // Suppress the native toolbar right-click menu (Icon and Text / Icon Only / Text Only) —
        // SwiftUI exposes no modifier for it, so reach the host window's NSToolbar.
        .background(ToolbarMenuDisabler())
        // Clicking a sidebar, history or snippet row focuses that list, so its selection turns
        // blue and the other list's turns gray.
        .background(ListClickFocuser())
        // Consume the panel's "New Snippet" request. `onAppear` catches a request raised while the
        // window was closed (the value is already set when the view first appears, so `onChange`
        // alone would miss it); `onChange` catches one raised while the window is already open.
        .onAppear { if composer.pendingRequest { beginCompose() } }
        .onChange(of: composer.pendingRequest) { _, pending in if pending { beginCompose() } }
    }

    /// The snippet folder the detail pane is showing, if any.
    private var shownFolderID: UUID? {
        guard case .snippetFolder(let id) = selection, folders.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// Route a "New Snippet" request to a folder: prefer the folder the panel's picker chose
    /// (`composer.folderID`), else keep the current selection if it's a folder,
    /// else the first folder, else create a default one. Selecting it shows `SnippetsListView`,
    /// which opens its editor when `composePending` turns true.
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
/// "Icon and Text / Icon Only / Text Only". SwiftUI offers no modifier for it,
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

/// Moves keyboard focus to whichever list was clicked. A selected row draws blue only while
/// its list is first responder and gray otherwise, but SwiftUI's `List` changes the selection on a
/// row click without taking first responder — so the previously focused list stayed blue and the
/// clicked one gray. This zero-size backing view installs a local mouse-down monitor for its window
/// that makes the clicked `NSTableView` first responder before the click is handled. A click on a
/// text field or control inside a row (the folder rename field) is left alone so it keeps focus.
///
/// A click on a list's empty space also clears its selection (Finder-style). SwiftUI already does
/// that below the last row but ignores the `.inset` style's padding above the first one, right
/// under the history filter bar. The sidebar is exempt: it always keeps a selection.
private struct ListClickFocuser: NSViewRepresentable {
    final class Coordinator {
        var monitor: Any?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak view] event in
            MainActor.assumeIsolated {
                if let window = view?.window, event.window === window { Self.focusList(under: event, in: window) }
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

    /// Hit-tests the click the way `NSWindow.sendEvent` will deliver it (from the frame view, in
    /// window coordinates), then walks up to the enclosing table, if any.
    private static func focusList(under event: NSEvent, in window: NSWindow) {
        guard let hit = window.contentView?.superview?.hitTest(event.locationInWindow) else { return }
        var ancestor: NSView? = hit
        while let current = ancestor, !(current is NSTableView) {
            if current is NSControl || current is NSText { return }
            ancestor = current.superview
        }
        guard let table = ancestor as? NSTableView else { return }
        if window.firstResponder !== table { window.makeFirstResponder(table) }
        if hit === table, table.row(at: table.convert(event.locationInWindow, from: nil)) < 0, !table.isInSidebar {
            table.deselectAll(nil)
        }
    }
}

extension NSView {
    /// Whether this view sits in the main window's sidebar column — tells the sidebar's list apart
    /// from the detail pane's.
    var isInSidebar: Bool {
        var ancestor = superview
        while let current = ancestor, !(current is NSSplitView) { ancestor = current.superview }
        guard let controller = (ancestor as? NSSplitView)?.delegate as? NSSplitViewController,
              let sidebar = controller.splitViewItems.first(where: { $0.behavior == .sidebar }) else { return false }
        return isDescendant(of: sidebar.viewController.view)
    }
}

/// Keeps the sidebar from collapsing when its divider is dragged past the minimum width, or via
/// the Toggle Sidebar command (⌃⌘S). `columnVisibility: .constant(.all)` alone doesn't stop
/// either, and SwiftUI offers no modifier for it, so this zero-size backing view — placed inside
/// the sidebar column — walks up to the `NSSplitView` hosting `NavigationSplitView` and turns
/// `canCollapse` off on its sidebar item.
private struct SidebarCollapseDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> CollapseDisablingView { CollapseDisablingView() }

    func updateNSView(_ nsView: CollapseDisablingView, context: Context) {
        nsView.disableCollapse()
    }

    final class CollapseDisablingView: NSView {
        private weak var sidebarItem: NSSplitViewItem?
        private var observation: NSKeyValueObservation?

        /// Apply as soon as the view joins the window's hierarchy: SwiftUI doesn't reliably call
        /// `updateNSView` again after that, so a one-shot attempt at creation time could miss the
        /// split view entirely and leave the sidebar collapsible for the whole session.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            disableCollapse()
        }

        func disableCollapse() {
            var ancestor = superview
            while let current = ancestor, !(current is NSSplitView) { ancestor = current.superview }
            guard let controller = (ancestor as? NSSplitView)?.delegate as? NSSplitViewController,
                  let item = controller.splitViewItems.first(where: { $0.behavior == .sidebar }) else { return }
            item.canCollapse = false
            // A collapsed state restored from a previous session would otherwise stick.
            if item.isCollapsed { item.isCollapsed = false }
            // SwiftUI can turn `canCollapse` back on when it reconfigures the column; switch it
            // straight back off.
            guard item !== sidebarItem else { return }
            sidebarItem = item
            observation = item.observe(\.canCollapse) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    if let item = self?.sidebarItem, item.canCollapse { item.canCollapse = false }
                }
            }
        }
    }
}
