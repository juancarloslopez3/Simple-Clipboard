import AppKit
import ImageIO
import os
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// A floating glass `NSPanel` shown by the ⌘⇧V / ⌘⇧B shortcuts, since a
/// `MenuBarExtra` menu can't be opened programmatically. Hosts the shared history/snippets
/// SwiftUI views; selecting an item places it on the clipboard and closes the panel.
@MainActor
final class ClipboardPanel {
    enum Mode { case history, snippets }

    private let container: ModelContainer
    private let paste: PasteService
    private let history: HistoryStore
    private var panel: NSPanel?
    private var mode: Mode = .history
    private var escMonitor: Any?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var flagsMonitor: Any?
    private var escPollTimer: Timer?

    /// Hold-to-preview tracking: whether the in-progress Space press is the one that
    /// opened the preview, and when it went down — so key-up can tell a quick tap (leave it open, the
    /// existing toggle) from a deliberate hold (show only while held, close on release).
    private var spaceOpenedPreview = false
    private var spaceDownTime: Date?
    private let holdThreshold: TimeInterval = 0.2

    /// Drives the Space-to-preview Quick Look overlay. Shared with the SwiftUI
    /// content via `.environment`; the key handling lives in `handlePreviewKey`.
    let previewState = ClipboardPreviewState()

    /// Drives the ⌘S "Save as Snippet" form over the history panel. Set by the
    /// key monitor from the hovered/previewed row; `PanelSaveSnippetHost` shows the form.
    let snippetSaveState = PanelSnippetSaveState()

    /// Drives the snippets panel's "New Snippet" folder picker. The footer's
    /// New Snippet button raises it; `PanelNewSnippetHost` shows the folder chooser, and the key
    /// monitor reads it so Esc peels the picker (and its inline name field) before the panel.
    let newSnippetState = PanelNewSnippetState()

    /// Which overflow folder's side flyout is open. Shared with the SwiftUI content
    /// via `.environment`; the list both sets and clears it. An open card stays open while the
    /// cursor is outside it — leaving the popover does not close it.
    let flyoutState = PanelFlyoutState()

    /// Whether **Option** is currently held while the panel is up, so the UI can show a hint that
    /// clicking will invert the plain-text default. Updated by a local
    /// `.flagsChanged` monitor — a keyboard *global* monitor would need Accessibility; local doesn't.
    let modifierState = PanelModifierState()

    /// The rows picked with ⌘-click during the current ⌘ hold. Rows and folder headers toggle it;
    /// releasing ⌘ copies it all and dismisses (`commitSelection`), so it never outlives the hold.
    let selectionState = PanelSelectionState()

    /// When ⌥ last came up (an event timestamp), and how long before ⌘ that still counts as held.
    /// ⌘⌥ let go together arrive as two events in either order, and ⌥ first shouldn't lose it.
    private var optionReleasedAt = -TimeInterval.infinity
    private static let keyReleaseTolerance: TimeInterval = 0.15

    /// Invoked by the panel's "Main Window" button. Set by `AppModel` once a scene has
    /// captured the real `openWindow` action (a detached panel can't reach the scene graph).
    var onOpenMainWindow: (() -> Void)?

    /// Invoked once the snippets panel's "New Snippet" folder picker is confirmed.
    /// Set by `AppModel`; opens the main window and starts a new snippet in the chosen folder's editor
    /// (a detached panel can't host the sheet-based `SnippetEditorView` itself). The argument is the
    /// destination folder id (`nil` to fall back to the current/first/new folder).
    var onNewSnippet: ((UUID?) -> Void)?

    /// True while a folder's side flyout (a popover) is open, so the light-dismiss monitor
    /// leaves clicks in the popover alone instead of tearing the whole panel down.
    private var flyoutOpen = false

    /// The app that was frontmost when the panel activated us. Making the panel
    /// key **activates this app even with `.nonactivatingPanel`** (verified: `makeKey()` flips
    /// `NSApp.isActive`), which deactivates the app the user was typing in. So `show()` captures
    /// it and `hide(restoreFocus: true)` hands activation back — the user's caret returns without
    /// a click. Dismissals where focus is headed elsewhere (clicking another app, ⌘-Tab, opening
    /// the main window, the Clear History alert) pass `restoreFocus: false`.
    private var previousApp: NSRunningApplication?

    /// When the panel was last shown (`nil` once hidden), and whether key has already been taken
    /// back once since — so `settleKeyLoss` can tell key bouncing off the panel while activation
    /// settles right after opening from the user actually moving on.
    private var shownAt: Date?
    private var reclaimedKey = false

    /// Focus/activation trace for diagnosing the panel closing itself or stranding focus. Read it
    /// with `log show --last 10m --predicate 'subsystem == "com.simpleclipboard.app"'`.
    private static let log = Logger(subsystem: "com.simpleclipboard.app", category: "panel")

    init(container: ModelContainer, paste: PasteService, history: HistoryStore) {
        self.container = container
        self.paste = paste
        self.history = history

        // Esc / Space, caught before the responder chain so the auto-focused search field can't
        // swallow them. Esc closes an open preview, else dismisses the panel. Space previews the
        // hovered row (history item or snippet): a quick tap toggles it (press again to close),
        // holding shows it only while held. With no row hovered Space falls through so typing a
        // space still works. Only Sendable scalars cross the actor boundary (hold
        // needs key-up too).
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let code = Int(event.keyCode)
            let isKeyDown = event.type == .keyDown
            let isRepeat = event.isARepeat
            let isCommandHeld = event.modifierFlags.contains(.command)
            // ⌘S (exactly Command, matched by character so it survives non-QWERTY layouts)
            // saves the hovered history item as a snippet.
            let isSaveShortcut = isKeyDown
                && event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command
                && event.charactersIgnoringModifiers?.lowercased() == "s"
            guard code == 49 || code == 53 || isSaveShortcut else { return event }   // 49 = Space, 53 = Esc
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let panel = self.panel, panel.isVisible else { return false }
                if isSaveShortcut { return self.handleSaveShortcut() }
                return self.handlePreviewKey(code, isKeyDown: isKeyDown, isRepeat: isRepeat, isCommandHeld: isCommandHeld)
            }
            return consumed ? nil : event                          // consume only when we acted
        }

        // Light-dismiss: close on any click outside the panel. Mouse monitors need no permission
        // (only keyboard global monitors require Accessibility), so this stays permission-free.
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        // Clicks in other apps / the desktop never reach us — a global monitor catches those.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible else { return }
                Self.log.notice("global click outside panel → hide")
                // The click is focusing another app itself — restoring the previous one
                // would fight the user's click.
                self.hide(restoreFocus: false)
            }
        }

        // Clicks in our own other windows (main window, menu bar) come through locally; a click in
        // the panel itself keeps it open. Compare window numbers (Int) so no non-Sendable event
        // crosses the actor boundary, and never consume the click — the real target still gets it.
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            let clickedWindow = event.windowNumber
            let isCommandClick = event.type == .leftMouseDown && event.modifierFlags.contains(.command)
            let location = event.locationInWindow
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible else { return }
                if clickedWindow == panel.windowNumber {
                    if isCommandClick { self.handleCommandMouseDown(at: location) }
                    return
                }
                // A folder flyout is a child popover of the panel; clicks there (or anywhere while
                // one is open) must not dismiss the panel, or selecting an item would be lost.
                if self.flyoutOpen { return }
                if Self.hasDescendant(panel, numbered: clickedWindow) { return }
                Self.log.notice("click in own window \(clickedWindow) → hide")
                // The user clicked one of our other windows — focus belongs there now.
                self.hide(restoreFocus: false)
            }
            return event
        }

        // Track Option held/released while the panel is up so the UI can hint the inverted paste
        // mode, and catch the ⌘ release that copies a ⌘-click selection. Local (not
        // global) so it needs no Accessibility permission; only the Bools cross the actor boundary,
        // never the event.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            let option = event.modifierFlags.contains(.option)
            let command = event.modifierFlags.contains(.command)
            // 54/55 = right/left ⌘. Only a press of ⌘ itself counts: the ⌘ of the ⌘⇧V that opened
            // the panel is still down when ⇧ comes up, and shouldn't flash the hint on every open.
            let isCommandKey = event.keyCode == 54 || event.keyCode == 55
            let time = event.timestamp
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible else { return }
                if self.modifierState.optionHeld, !option { self.optionReleasedAt = time }
                self.modifierState.optionHeld = option
                if !command {
                    self.modifierState.commandHeld = false
                    self.commitSelection(invertingPlainText: option || time - self.optionReleasedAt < Self.keyReleaseTolerance)
                } else if isCommandKey {
                    self.modifierState.commandHeld = true
                }
            }
            return event
        }
    }

    /// Show the given mode, or hide if it's already showing.
    func toggle(_ newMode: Mode) {
        if let panel, panel.isVisible, mode == newMode {
            Self.log.notice("toggle: already visible → hide")
            hide()
            return
        }
        mode = newMode
        show()
    }

    /// Dismiss the panel. With `restoreFocus` (the default) activation is handed back to the app
    /// that was frontmost before the panel opened, so the field the user was typing in regains
    /// its caret without a click — pass `false` when focus is deliberately going elsewhere (a
    /// click in another app / our main window, ⌘-Tab, the Main Window button, a modal alert).
    func hide(restoreFocus: Bool = true) {
        // Taken locally up front: `orderOut` can re-enter `hide` via `onResignKey`
        // (restoreFocus: false), which must not clobber this call's hand-back.
        let previous = previousApp
        previousApp = nil
        shownAt = nil
        Self.log.notice("hide restoreFocus=\(restoreFocus) active=\(NSApp.isActive) previous=\(previous?.localizedName ?? "nil", privacy: .public)")
        previewState.reset()
        spaceOpenedPreview = false
        spaceDownTime = nil
        flyoutState.activeFolder = nil
        modifierState.optionHeld = false
        modifierState.commandHeld = false
        selectionState.reset()
        escPollTimer?.invalidate()
        escPollTimer = nil
        snippetSaveState.pendingItemIDs = []
        snippetSaveState.namingFolder = false
        newSnippetState.choosing = false
        newSnippetState.namingFolder = false
        panel?.orderOut(nil)
        releaseContentWhenHidden()
        if restoreFocus, NSApp.isActive, let previous, !previous.isTerminated {
            NSApp.yieldActivation(to: previous)
            previous.activate()
        }
    }

    /// Drop the hidden panel's SwiftUI content once its order-out animation is over. An
    /// ordered-out `NSHostingView` keeps updating, so leaving it installed had the history
    /// `@Query` refetch and every row re-render on each capture while nothing was on screen;
    /// `show()` installs a fresh one anyway. Skipped if the panel was reopened meanwhile.
    private func releaseContentWhenHidden() {
        guard let panel, let content = panel.contentView else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak panel] in
            guard let panel, !panel.isVisible, panel.contentView === content else { return }
            panel.contentView = nil
        }
    }

    /// Esc / Space handling for the Quick Look preview overlay. Returns `true`
    /// when the key was consumed (the caller swallows it). Space supports both a tap (toggle) and
    /// a hold (show only while held), distinguished on key-up by how long the key was down.
    private func handlePreviewKey(_ code: Int, isKeyDown: Bool, isRepeat: Bool, isCommandHeld: Bool) -> Bool {
        switch code {
        case 53:   // Esc — act on the press only; close the save form, else an open preview, else dismiss.
            // Not on a repeat either: holding Esc mustn't peel a layer and then close the panel.
            guard isKeyDown, !isRepeat else { return true }
            // The new-folder icon picker is a child popover: while it has key, Esc just closes it
            // (the popover handles that itself) rather than peeling the name field behind it.
            if snippetSaveState.namingFolder || newSnippetState.namingFolder,
               let key = NSApp.keyWindow, let panel, key !== panel, Self.hasDescendant(panel, numbered: key.windowNumber) {
                return false
            }
            if snippetSaveState.isOpen {
                // Inside the form, Esc peels one layer: the inline folder-name field first.
                if snippetSaveState.namingFolder {
                    snippetSaveState.namingFolder = false
                    return true
                }
                snippetSaveState.pendingItemIDs = []
                return true
            }
            if newSnippetState.choosing {
                // Same one-layer peel for the New Snippet folder picker: the inline name field first.
                if newSnippetState.namingFolder {
                    newSnippetState.namingFolder = false
                    return true
                }
                newSnippetState.choosing = false
                return true
            }
            if previewState.presentedID != nil {
                previewState.presentedID = nil
                return true
            }
            // Clears a ⌘-click selection, so there's a way out of copying it on release. With ⌘ down
            // Esc never closes the panel: `clearSelectionIfEscIsDown` may have got there just before
            // this event, and the selection being gone already doesn't make it a second press.
            if !selectionState.ids.isEmpty {
                selectionState.reset()
                return true
            }
            if isCommandHeld { return true }
            hide()
            return true
        case 49:   // Space — tap toggles the hovered row's preview; hold shows it while pressed.
            // While the ⌘S save form is up, Space belongs to its title field — don't intercept.
            if snippetSaveState.isOpen { return false }
            // While the New Snippet folder picker is up, Space belongs to its inline folder-name
            // field when naming; otherwise swallow it so it can't leak to the search field behind
            // the overlay (the picker has no other text field to receive it).
            if newSnippetState.choosing { return !newSnippetState.namingFolder }
            return isKeyDown ? handleSpaceDown(isRepeat: isRepeat) : handleSpaceUp()
        default:
            return false
        }
    }

    /// ⌘S — save the ⌘-click selection, else the hovered (or previewed) history item, as snippets:
    /// opens the in-panel form asking for a title and destination folder
    /// (`PanelSaveSnippetForm`, or `PanelSaveSnippetsForm` for several rows). History
    /// mode only; with nothing selected or hovered the event falls through. Returns `true` when consumed.
    private func handleSaveShortcut() -> Bool {
        guard mode == .history else { return false }
        if snippetSaveState.isOpen { return true }   // form already up — swallow
        // A ⌘-click selection wins over the hovered row: every picked row goes into the batch form,
        // in pick order. Otherwise ⌘S acts on the hovered (or previewed) row.
        let targets = selectionState.order.isEmpty
            ? (previewState.presentedID ?? previewState.hoveredID).map { [$0] } ?? []
            : selectionState.order
        guard !targets.isEmpty else { return false }
        selectionState.reset()             // releasing ⌘ must not copy the selection behind the form
        previewState.presentedID = nil     // the form replaces an open preview
        flyoutState.activeFolder = nil     // …and closes a folder flyout (it would float above the form)
        snippetSaveState.namingFolder = false
        snippetSaveState.pendingItemIDs = targets
        return true
    }

    /// Space pressed: open the hovered row's preview (recording the press so key-up can tell a tap
    /// from a hold), or close it if one is already open from a prior tap. Returns `true` when consumed.
    private func handleSpaceDown(isRepeat: Bool) -> Bool {
        // Auto-repeat while the key is held: the initial press already opened the preview, so swallow
        // the repeats — don't let one read as a second tap (which would close it) or leak into search.
        if isRepeat { return previewState.presentedID != nil }
        // Already open from an earlier tap → Space closes it (the existing toggle).
        if previewState.presentedID != nil {
            previewState.presentedID = nil
            spaceOpenedPreview = false
            return true
        }
        // Preview only when a row is hovered; otherwise let Space reach the search field.
        guard let hovered = previewState.hoveredID else { return false }
        previewState.presentedID = hovered
        spaceOpenedPreview = true
        spaceDownTime = Date()
        return true
    }

    /// Space released: if this press opened the preview, a quick tap leaves it open (toggle) while a
    /// deliberate hold closes it on release. Returns `true` when consumed.
    private func handleSpaceUp() -> Bool {
        guard spaceOpenedPreview else { return false }
        let held = spaceDownTime.map { Date().timeIntervalSince($0) } ?? 0
        spaceOpenedPreview = false
        spaceDownTime = nil
        if held >= holdThreshold { previewState.presentedID = nil }
        return true
    }

    /// A ⌘ mouse-down in the panel. Folder rows are handled here, not with a gesture on the row,
    /// because hovering one opens its flyout at once and an open flyout (a transient popover) stops
    /// the click from reaching the row. The flyout still closes; the row shows what's selected.
    private func handleCommandMouseDown(at location: NSPoint) {
        guard !snippetSaveState.isOpen, !newSnippetState.choosing, previewState.presentedID == nil,
              let height = panel?.contentView?.bounds.height else { return }
        // Window coordinates count up from the bottom, SwiftUI's global ones down from the top.
        if let members = selectionState.folderMembers(at: CGPoint(x: location.x, y: height - location.y)) {
            selectionState.toggleAll(members)
        }
    }

    /// Esc while rows are selected, read from the keyboard state. ⌘ is necessarily down then, and
    /// ⌘Esc is the system's Game Overlay shortcut on by default since macOS Tahoe, so the key event
    /// usually never reaches the app or the key monitor above. Reading the state needs no permission.
    private func clearSelectionIfEscIsDown() {
        guard !selectionState.ids.isEmpty, CGEventSource.keyState(.hidSystemState, key: 53) else { return }
        selectionState.reset()
    }

    /// ⌘ released: copy what was ⌘-clicked during the hold, in list order, and dismiss like a plain
    /// click. `invertingPlainText` (⌥ held) inverts the plain-text default for this copy, for one
    /// row as for several (`PasteService.activate(_:plainText:)`). With an overlay form up
    /// (⌘-clicking New Snippet) the selection is dropped instead: closing the panel would throw the
    /// form away.
    private func commitSelection(invertingPlainText: Bool) {
        let ids = selectionState.order
        guard !ids.isEmpty else { return }
        selectionState.reset()
        if snippetSaveState.isOpen || newSnippetState.choosing { return }
        let plainText = invertingPlainText ? !Pref.alwaysPastePlainText : nil
        let context = container.mainContext
        switch mode {
        case .history:
            let descriptor = FetchDescriptor<ClipboardItem>(
                predicate: #Predicate { ids.contains($0.id) })
            let fetched = (try? context.fetch(descriptor)) ?? []
            let items = ids.compactMap { id in fetched.first { $0.id == id } }   // pick order
            guard !items.isEmpty else { return }
            paste.activate(items, plainText: plainText)
        case .snippets:
            let folders = (try? context.fetch(FetchDescriptor<SnippetFolder>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
            let all = folders.flatMap(\.orderedSnippets)
            let snippets = ids.compactMap { id in all.first { $0.id == id } }   // pick order
            guard !snippets.isEmpty else { return }
            paste.activate(snippets, plainText: plainText)
        }
        hide()
    }

    /// "Clear History" from the footer button or the hotkey, behind the native
    /// confirmation (`HistoryStore.clearAfterConfirming`). The panel is dismissed before the alert
    /// so its light-dismiss monitors don't fight the modal; with confirmation off it stays open on
    /// the now-empty list.
    func confirmClearHistory() {
        // The modal alert takes focus next, not the previous app.
        history.clearAfterConfirming { hide(restoreFocus: false) }
    }

    private func show() {
        previewState.reset()
        spaceOpenedPreview = false
        spaceDownTime = nil
        modifierState.optionHeld = false
        modifierState.commandHeld = false
        selectionState.reset()   // ⌘⇧B/⌘⇧V can switch modes mid-hold, and ids don't carry across
        escPollTimer?.invalidate()
        // Fast enough to catch a quick tap; does nothing until something is selected.
        escPollTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearSelectionIfEscIsDown() }
        }
        RunLoop.main.add(escPollTimer!, forMode: .common)   // keeps polling during a scroll
        snippetSaveState.pendingItemIDs = []
        snippetSaveState.namingFolder = false
        newSnippetState.choosing = false
        newSnippetState.namingFolder = false
        selectionState.forgetFolderTargets()   // the old content may never report its rows gone
        let panel = panel ?? makePanel()
        self.panel = panel

        let root = PanelRootView(
            mode: mode,
            onDismiss: { [weak self] in self?.hide() },
            onOpenMainWindow: { [weak self] in self?.hide(restoreFocus: false); self?.onOpenMainWindow?() },
            onClearHistory: { [weak self] in self?.confirmClearHistory() },
            onNewSnippet: { [weak self] folderID in self?.hide(restoreFocus: false); self?.onNewSnippet?(folderID) },
            onFlyoutChange: { [weak self] open in self?.setFlyoutOpen(open) }
        )
        .modelContainer(container)
        .environment(paste)
        .environment(previewState)
        .environment(flyoutState)
        .environment(modifierState)
        .environment(selectionState)
        .environment(snippetSaveState)
        .environment(newSnippetState)

        panel.contentView = NSHostingView(rootView: root)
        position(panel)
        // Activation is unavoidable: even with `.nonactivatingPanel`, making the panel key from
        // the background activates the app (so the search field can take typing), deactivating
        // the app the user was typing in. Capture that app *first* — `hide(restoreFocus: true)`
        // hands activation back so the user's caret returns without a click. On a mode switch
        // while already active, keep the app captured when the panel first opened.
        if !NSApp.isActive {
            previousApp = NSWorkspace.shared.frontmostApplication
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        shownAt = Date()
        reclaimedKey = false
        Self.log.notice("show \(String(describing: self.mode), privacy: .public) active=\(NSApp.isActive) key=\(panel.isKeyWindow) previous=\(self.previousApp?.localizedName ?? "nil", privacy: .public)")
        // Once the order-in animation is done: is it really on screen? (`isVisible` alone can be
        // true for a panel the window server never drew.)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak panel] in
            guard let panel, panel.isVisible else { return }
            Self.log.notice("shown onScreen=\(panel.occlusionState.contains(.visible)) active=\(NSApp.isActive) key=\(panel.isKeyWindow)")
        }
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Off: with it on, ordering the panel in while the system doesn't (yet) count the app as
        // active leaves it `isVisible` and key to AppKit but never drawn by the window server —
        // the hotkey then only steals the caret, and the next press "hides" an invisible panel.
        // Deactivation is already covered by `onResignKey` and the click monitors.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow
        // Dismiss when the panel loses keyboard focus (⌘-Tab, another window taking key), with
        // the full `hide` cleanup (state resets).
        // A key hand-off to our own flyout popover must not count — see `panelDidResignKey`.
        panel.onResignKey = { [weak self] in self?.panelDidResignKey() }
        return panel
    }

    /// The panel lost keyboard focus: some other window took key (⌘-Tab, a click the mouse
    /// monitors also see, our own alert). Dismiss — unless key merely moved into one of the
    /// panel's own child windows (a folder flyout popover), which must keep the panel alive.
    /// The verdict waits a turn (`settleKeyLoss`) so AppKit can finish handing key around first.
    private func panelDidResignKey() {
        Self.log.notice("resignKey visible=\(self.panel?.isVisible ?? false) active=\(NSApp.isActive) keyWindow=\(Self.describe(NSApp.keyWindow), privacy: .public) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil", privacy: .public)")
        guard let panel, panel.isVisible else { return }
        if flyoutOpen { return }
        if let key = NSApp.keyWindow, Self.hasDescendant(panel, numbered: key.windowNumber) { return }
        let shown = shownAt
        DispatchQueue.main.async { [weak self] in self?.settleKeyLoss(shownAt: shown) }
    }

    /// Second half of `panelDidResignKey`. When key went nowhere — we're still the active app but
    /// no visible window of ours holds it — a moment after opening, that's key bouncing off the
    /// panel while activation settles, not the user moving on: take it back (once). Dismissing
    /// there would both close the panel the user just asked for and strand focus, leaving our
    /// app active with nothing on screen and the field they were typing in deactivated.
    private func settleKeyLoss(shownAt shown: Date?) {
        // Hidden or reopened since, or key already came back on its own.
        guard let panel, let shown, shownAt == shown, !panel.isKeyWindow else { return }
        if flyoutOpen { return }
        let key = NSApp.keyWindow
        if let key, Self.hasDescendant(panel, numbered: key.windowNumber) { return }
        let keyWentNowhere = NSApp.isActive && key?.isVisible != true
        if keyWentNowhere, panel.isVisible, !reclaimedKey, Date().timeIntervalSince(shown) < 1 {
            Self.log.notice("key lost right after opening with nothing taking it → reclaiming")
            reclaimedKey = true
            panel.makeKeyAndOrderFront(nil)
            return
        }
        // Whatever took key (⌘-Tab, another window) owns focus now — don't restore.
        hide(restoreFocus: false)
    }

    private static func describe(_ window: NSWindow?) -> String {
        guard let window else { return "nil" }
        return "\(type(of: window)) #\(window.windowNumber) visible=\(window.isVisible)"
    }

    /// Whether the window numbered `number` is one of `window`'s child windows at any depth — a
    /// popover opened from one of the panel's popovers (the icon picker's skin tones) counts too.
    private static func hasDescendant(_ window: NSWindow, numbered number: Int) -> Bool {
        window.childWindows?.contains { $0.windowNumber == number || hasDescendant($0, numbered: number) } ?? false
    }

    /// Place the panel just above the cursor, clamped to the active screen.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let mouse = NSEvent.mouseLocation
        let visible = screen.visibleFrame
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height)
        origin.x = min(max(visible.minX + 8, origin.x), visible.maxX - size.width - 8)
        origin.y = min(max(visible.minY + 8, origin.y), visible.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }

    /// Called whenever the SwiftUI list opens or closes a folder flyout — mirrors the state the
    /// click light-dismiss reads so clicks in the popover don't tear down the panel.
    private func setFlyoutOpen(_ open: Bool) {
        flyoutOpen = open
    }
}

/// Shared open-folder state for the history panel's overflow flyouts. Only the
/// SwiftUI list mutates it: dwell-to-open, switching folders, and the deliberate dismissals
/// (settling on an unfoldered item, selecting, searching). An open card stays open while the cursor
/// merely passes outside it. Injected via `.environment`, mirroring `ClipboardPreviewState`.
@MainActor @Observable
final class PanelFlyoutState {
    /// Range label of the folder whose side flyout is open, or `nil` when none is.
    var activeFolder: String?
}

/// Live **Option**-key state while the panel is open. Set by `ClipboardPanel`'s
/// `.flagsChanged` monitor and read by `PanelOptionHint` to show the inverted-paste hint. Injected
/// via `.environment`, mirroring `ClipboardPreviewState` / `PanelFlyoutState`.
@MainActor @Observable
final class PanelModifierState {
    var optionHeld = false
    /// Whether ⌘ was pressed while the panel is up, for `PanelSelectionHint`. Stays false for the
    /// ⌘ of the shortcut that opened the panel.
    var commandHeld = false
}

/// The history items or snippets picked with ⌘-click while the panel is up. `ClipboardPanel` copies
/// them when ⌘ is released; rows and folder headers read it directly, so a toggle only redraws them.
/// Injected via `.environment`, mirroring `ClipboardPreviewState` / `PanelFlyoutState`.
@MainActor @Observable
final class PanelSelectionState {
    /// Where a folder row is, and what ⌘-clicking it selects.
    struct FolderTarget: Equatable {
        /// The row's visible part, in the panel's top-left-origin coordinates.
        var frame: CGRect
        var members: [UUID]
    }

    /// Selected ids in the order they were picked — the order they paste in.
    private(set) var order: [UUID] = []
    var ids: Set<UUID> { Set(order) }

    /// The folder rows on screen, by row instance, for `ClipboardPanel.handleCommandMouseDown`.
    /// Not observed: it changes while scrolling and nothing draws from it.
    @ObservationIgnored var folderTargets: [UUID: FolderTarget] = [:]

    /// Whether the click being handled was made with ⌘ held. Read from the event, not the live key
    /// state, so a ⌘ released just after the click can't turn it into a plain click.
    static var isCommandClick: Bool {
        (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.command)
    }

    func toggle(_ id: UUID) {
        if let index = order.firstIndex(of: id) { order.remove(at: index) } else { order.append(id) }
    }

    /// A folder's ⌘-click: selects all of `group`, or deselects it when it's all selected already.
    func toggleAll(_ group: [UUID]) {
        if Set(group).isSubset(of: order) {
            order.removeAll { group.contains($0) }
        } else {
            order.append(contentsOf: group.filter { !order.contains($0) })
        }
    }

    func reset() {
        order = []
    }

    func folderMembers(at point: CGPoint) -> [UUID]? {
        folderTargets.values.first { $0.frame.contains(point) }?.members
    }

    func forgetFolderTargets() {
        folderTargets = [:]
    }
}

/// The pending "⌘S → Save as Snippet" request while the history panel is up.
/// Set by `ClipboardPanel`'s key monitor from the hovered/previewed row; `PanelSaveSnippetHost`
/// resolves it against the live `@Query` and shows the title/folder form. Injected via
/// `.environment`, mirroring `ClipboardPreviewState`.
@MainActor @Observable
final class PanelSnippetSaveState {
    /// The history items awaiting the form, in list order, or empty when the form is closed. The
    /// panel sets one (the hovered row) or several (its ⌘-click selection, in pick order), as does the
    /// main window's multi-select ⌘S; several get the batch form (`PanelSaveSnippetsForm`) instead of the title/folder form.
    var pendingItemIDs: [UUID] = []
    /// True while the form's inline "New Folder" name field is up. Lives here (not form
    /// `@State`) because the panel's key monitor must see it: Esc then closes just the field,
    /// and Save's default-action Return is suspended so Return commits the name instead.
    var namingFolder = false

    var isOpen: Bool { !pendingItemIDs.isEmpty }
}

/// Drives the snippets panel's "New Snippet" folder picker — the snippets-mode
/// counterpart of `PanelSnippetSaveState`. The footer's New Snippet button sets `choosing`;
/// `PanelNewSnippetHost` shows the picker. `namingFolder` (the inline New-Folder field) lives here,
/// not form `@State`, so the panel's key monitor can peel it with Esc before the picker itself, and
/// suspend Create's default-action Return so Return commits the folder name. Injected via
/// `.environment`, mirroring the panel's other shared `@Observable`s.
@MainActor @Observable
final class PanelNewSnippetState {
    /// True while the folder picker is up (from the footer button until Create/Cancel/Esc).
    var choosing = false
    /// True while the picker's inline "New Folder" name field is up.
    var namingFolder = false
}

/// Borderless panels can't become key by default; allow it so the search field accepts input.
/// `onResignKey` lets `ClipboardPanel` dismiss with full cleanup when keyboard focus moves
/// elsewhere (⌘-Tab, another window); the panel doesn't use `hidesOnDeactivate` (see `makePanel`).
private final class KeyablePanel: NSPanel {
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

// MARK: - SwiftUI content

private struct PanelRootView: View {
    let mode: ClipboardPanel.Mode
    let onDismiss: () -> Void
    let onOpenMainWindow: () -> Void
    let onClearHistory: () -> Void
    /// Terminal "New Snippet" action, called with the chosen folder id once the picker is confirmed
    /// — hides the panel and routes to the main window's editor.
    let onNewSnippet: (UUID?) -> Void
    let onFlyoutChange: (Bool) -> Void
    @Environment(PanelModifierState.self) private var modifier
    @Environment(PanelSelectionState.self) private var selection
    @Environment(PanelNewSnippetState.self) private var newSnippet

    var body: some View {
        VStack(spacing: 0) {
            switch mode {
            case .history: PanelHistoryList(onDismiss: onDismiss, onFlyoutChange: onFlyoutChange)
            case .snippets: PanelSnippetsList(onDismiss: onDismiss, onFlyoutChange: onFlyoutChange)
            }
            PanelOptionHint(count: selection.ids.count)
            PanelSelectionHint()
            // The footer's "New Snippet" button opens the folder picker; the picker's Create then
            // fires the terminal `onNewSnippet` with the chosen folder.
            PanelFooter(mode: mode, onClearHistory: onClearHistory,
                        onNewSnippet: { newSnippet.choosing = true }, onOpenMainWindow: onOpenMainWindow)
        }
        // Slide the Option hint in/out when the key is pressed/released.
        .animation(.easeInOut(duration: 0.12), value: modifier.optionHeld)
        .animation(.easeInOut(duration: 0.12), value: modifier.commandHeld || !selection.ids.isEmpty)
        .frame(width: 420, height: 600)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        // Space-to-preview Quick Look overlay, above the glass but inside the clip —
        // history items vs. snippets resolve `presentedID` against their own store.
        .overlay {
            switch mode {
            case .history: PanelPreviewHost()
            case .snippets: PanelSnippetPreviewHost()
            }
        }
        // ⌘S "Save as Snippet" form over the history panel, above the preview overlay
        // (opening the form closes an open preview, so they never actually stack).
        .overlay {
            if mode == .history { PanelSaveSnippetHost() }
        }
        // "New Snippet" folder picker over the snippets panel — the snippets-mode
        // counterpart of the ⌘S form.
        .overlay {
            if mode == .snippets { PanelNewSnippetHost(onCreate: onNewSnippet) }
        }
        // Clip the composited content (search-field fill, divider, rows) to the same shape as
        // the glass — otherwise their square corners poke out past the rounded surface.
        .clipShape(.rect(cornerRadius: 16))
        .onExitCommand(perform: onDismiss)
    }
}

/// Overlays the panel with a Quick Look preview of the hovered history row when Space is pressed.
/// Resolves `presentedID` against the live store (`ClipboardItemLookup`); Space /
/// Esc are handled by `ClipboardPanel`, so this view only renders the overlay and dismisses on a
/// backdrop click.
private struct PanelPreviewHost: View {
    @Environment(ClipboardPreviewState.self) private var previewState

    var body: some View {
        ZStack {
            if let id = previewState.presentedID {
                ClipboardItemLookup(id: id) { item in
                    ClipboardPreviewOverlay(item: item) { previewState.presentedID = nil }
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: previewState.presentedID)
    }
}

/// Resolves one history item by `id` for an overlay host with a single-row query, so
/// the hosts don't each hold a full-history `@Query` that materializes every item on each
/// capture (~55 ms at 1000 items). Live like any `@Query`: a deleted item resolves to nothing,
/// dropping the overlay.
private struct ClipboardItemLookup<Content: View>: View {
    @Query private var matches: [ClipboardItem]
    private let content: (ClipboardItem) -> Content

    init(id: UUID, @ViewBuilder content: @escaping (ClipboardItem) -> Content) {
        _matches = Query(filter: #Predicate<ClipboardItem> { $0.id == id })
        self.content = content
    }

    var body: some View {
        if let item = matches.first { content(item) }
    }
}

/// Overlays the snippets panel with a Quick Look preview of the hovered snippet row when Space is
/// pressed — the snippet counterpart of `PanelPreviewHost`. Resolves the shared
/// `presentedID` against the live snippet `@Query`; Space / Esc are handled by `ClipboardPanel`.
private struct PanelSnippetPreviewHost: View {
    @Environment(ClipboardPreviewState.self) private var previewState
    @Query private var snippets: [Snippet]

    var body: some View {
        ZStack {
            if let id = previewState.presentedID, let snippet = snippets.first(where: { $0.id == id }) {
                SnippetPreviewOverlay(snippet: snippet) { previewState.presentedID = nil }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: previewState.presentedID)
    }
}

/// Overlays the history panel with the ⌘S "Save as Snippet" form. Resolves the
/// pending id against the live store (`ClipboardItemLookup`, mirroring `PanelPreviewHost`, so a
/// deleted item simply drops the form); ⌘S / Esc are handled by `ClipboardPanel`'s key monitor.
/// Also shared by the **main window's** ⌘S, which injects its own `PanelSnippetSaveState`
/// and handles ⌘S / Esc with hidden key-equivalent buttons instead of a monitor. Several pending
/// items (the main window's multi-select) get the batch form instead.
struct PanelSaveSnippetHost: View {
    @Environment(PanelSnippetSaveState.self) private var saveState

    var body: some View {
        let ids = saveState.pendingItemIDs
        ZStack {
            if ids.count == 1, let id = ids.first {
                ClipboardItemLookup(id: id) { item in
                    PanelSaveSnippetForm(item: item, onClose: close)
                        .id(item.id)   // fresh field/folder state per item, never reused across saves
                }
            } else if ids.count > 1 {
                ClipboardItemsLookup(ids: ids) { items in
                    PanelSaveSnippetsForm(items: items, onClose: close)
                }
                .id(ids)   // fresh titles/folder state per batch
            }
        }
        .animation(.easeInOut(duration: 0.15), value: ids)
    }

    private func close() {
        saveState.pendingItemIDs = []
        saveState.namingFolder = false
    }
}

/// Resolves several history items by id for the batch ⌘S form with one query, handing
/// them over in `ids` order — the many-row counterpart of `ClipboardItemLookup`. Live like any
/// `@Query`: a deleted item drops out, and the content goes once none are left.
private struct ClipboardItemsLookup<Content: View>: View {
    @Query private var matches: [ClipboardItem]
    private let ids: [UUID]
    private let content: ([ClipboardItem]) -> Content

    init(ids: [UUID], @ViewBuilder content: @escaping ([ClipboardItem]) -> Content) {
        _matches = Query(filter: #Predicate<ClipboardItem> { ids.contains($0.id) })
        self.ids = ids
        self.content = content
    }

    var body: some View {
        let byID = Dictionary(matches.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = ids.compactMap { byID[$0] }
        if !ordered.isEmpty { content(ordered) }
    }
}

/// The ⌘S save form: dimmed backdrop (click = cancel) over a card asking for the snippet title
/// and destination folder. The title prefills like the main window's prompt;
/// a cleared field saves with an empty title, rendering "Untitled". The folder list
/// (`PanelFolderPickerList`, shared with the New Snippet picker) ends in a pinned **New Folder…**
/// control; the named folder is **created only on Save** (`PanelFolderPickerModel.resolveFolder`),
/// so Cancel leaves no orphan folder.
private struct PanelSaveSnippetForm: View {
    let item: ClipboardItem
    let onClose: () -> Void
    @Environment(\.modelContext) private var context
    @Environment(PanelSnippetSaveState.self) private var saveState
    @Query(sort: \SnippetFolder.sortIndex) private var folders: [SnippetFolder]
    @State private var title: String
    @State private var picker = PanelFolderPickerModel()
    /// Guards against a Return that reaches both the field's `onSubmit` and the default button.
    @State private var saved = false
    /// Bumped to hand focus back to the title field (`SelectAllTextField.refocus`) when the
    /// inline folder-name field closes.
    @State private var titleRefocus = 0

    init(item: ClipboardItem, onClose: @escaping () -> Void) {
        self.item = item
        self.onClose = onClose
        _title = State(initialValue: Snippet.defaultTitle(for: item))
    }

    var body: some View {
        @Bindable var saveState = saveState
        PanelFormChrome(onCancel: onClose) {
            HStack(spacing: 8) {
                Image(systemName: item.kindSymbol)
                    .foregroundStyle(.secondary)
                Text("Save as Snippet").font(.headline)
            }
            // AppKit-backed so it *takes* first responder from the panel's search field and
            // opens with the prefilled title selected — a SwiftUI `TextField` + `.focused`
            // is left unfocused here and typing keeps landing in search.
            SelectAllTextField(text: $title, placeholder: String(localized: "Title"), refocus: titleRefocus,
                               onSubmit: save)
            VStack(alignment: .leading, spacing: 4) {
                Text("Folder").font(.caption).foregroundStyle(.secondary)
                PanelFolderPickerList(folders: folders, model: picker, namingFolder: $saveState.namingFolder)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", action: onClose)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    // Suspended while the folder-name field is up so Return commits the
                    // name (its `onSubmit`) instead of saving with a half-typed folder.
                    .keyboardShortcut(saveState.namingFolder ? nil : .defaultAction)
            }
        }
        // Return focus to the title when the inline folder-name field closes (commit or the
        // panel-handled Esc); the selection reconciliation lives in the shared picker list.
        .onChange(of: saveState.namingFolder) { _, naming in
            if !naming { titleRefocus &+= 1 }
        }
    }

    private func save() {
        guard !saved else { return }
        saved = true
        let folder = picker.resolveFolder(naming: saveState.namingFolder, folders: folders, context: context)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        context.insert(Snippet.from(item, title: trimmed, folder: folder))
        try? context.save()
        onClose()
    }
}

/// The main window's ⌘S form for several selected rows: one destination folder for all
/// of them, then each item's suggested title (the single form's prefill) to keep or edit. Same
/// chrome, folder list and create-only-on-Save folder as `PanelSaveSnippetForm`; a cleared title
/// saves as "Untitled". The snippets land in the folder in list order.
private struct PanelSaveSnippetsForm: View {
    let items: [ClipboardItem]
    let onClose: () -> Void
    @Environment(\.modelContext) private var context
    @Environment(PanelSnippetSaveState.self) private var saveState
    @Query(sort: \SnippetFolder.sortIndex) private var folders: [SnippetFolder]
    /// The editable titles, by item id.
    @State private var titles: [UUID: String]
    @State private var picker = PanelFolderPickerModel()
    /// Guards against a Return that reaches both a field's `onSubmit` and the default button.
    @State private var saved = false
    /// Bumped to hand focus back to the first title field when the inline folder-name field
    /// closes, like the single form.
    @State private var titleRefocus = 0
    /// Natural height of the title rows, measured so the list hugs a short batch (capped).
    @State private var titlesHeight: CGFloat = 0

    init(items: [ClipboardItem], onClose: @escaping () -> Void) {
        self.items = items
        self.onClose = onClose
        _titles = State(initialValue: Dictionary(
            items.map { ($0.id, Snippet.defaultTitle(for: $0)) }, uniquingKeysWith: { first, _ in first }))
    }

    var body: some View {
        @Bindable var saveState = saveState
        // A little wider than the single form so the titles read better, yet inside the
        // panel's 420pt surface with a margin.
        PanelFormChrome(width: 380, onCancel: onClose) {
            HStack(spacing: 8) {
                Image(systemName: "square.on.square")
                    .foregroundStyle(.secondary)
                Text("Save \(items.count) Snippets").font(.headline)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Folder").font(.caption).foregroundStyle(.secondary)
                PanelFolderPickerList(folders: folders, model: picker, namingFolder: $saveState.namingFolder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Titles").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            titleRow(item, isFirst: index == 0)
                        }
                    }
                    // Room for the fields' bezels and focus ring, which the scroll view would
                    // clip; the outer negative padding keeps the rows aligned with the card.
                    .padding(4)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { titlesHeight = $0 }
                }
                // Scrolls past about ten rows, and is what gives way in a short window.
                .frame(minHeight: min(titlesHeight, 60), maxHeight: min(max(titlesHeight, 1), 290))
                .padding(-4)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", action: onClose)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    // Suspended while the folder-name field is up so Return commits the
                    // name (its `onSubmit`) instead of saving with a half-typed folder.
                    .keyboardShortcut(saveState.namingFolder ? nil : .defaultAction)
            }
        }
        .onChange(of: saveState.namingFolder) { _, naming in
            if !naming { titleRefocus &+= 1 }
        }
    }

    /// The item's kind and its editable title. Only the first field takes focus when the form
    /// opens, so typing starts on the first title; Tab moves down the list.
    private func titleRow(_ item: ClipboardItem, isFirst: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.kindSymbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            SelectAllTextField(
                text: Binding(get: { titles[item.id] ?? "" }, set: { titles[item.id] = $0 }),
                placeholder: String(localized: "Untitled"),
                grabsFocus: isFirst, refocus: isFirst ? titleRefocus : 0,
                onSubmit: save)
        }
    }

    private func save() {
        guard !saved else { return }
        saved = true
        let folder = picker.resolveFolder(naming: saveState.namingFolder, folders: folders, context: context)
        for item in items {
            let title = (titles[item.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            context.insert(Snippet.from(item, title: title, folder: folder))
        }
        try? context.save()
        onClose()
    }
}

/// Overlays the snippets panel with the "New Snippet" folder picker — the
/// snippets-mode counterpart of `PanelSaveSnippetHost`. Shown while `PanelNewSnippetState.choosing`;
/// Esc / the inline name field are handled by `ClipboardPanel`'s key monitor via that shared state.
private struct PanelNewSnippetHost: View {
    /// Terminal action: routes to the main window's editor for the chosen folder id.
    let onCreate: (UUID?) -> Void
    @Environment(PanelNewSnippetState.self) private var state

    var body: some View {
        ZStack {
            if state.choosing {
                PanelNewSnippetForm(
                    onCreate: { folderID in
                        state.namingFolder = false
                        state.choosing = false
                        onCreate(folderID)
                    },
                    onCancel: {
                        state.namingFolder = false
                        state.choosing = false
                    }
                )
            }
        }
        .animation(.easeInOut(duration: 0.15), value: state.choosing)
    }
}

/// The "New Snippet" folder picker: a dimmed backdrop (click = cancel) over a card asking only
/// *which folder* the new snippet belongs in — its title/content are typed in
/// the main-window editor, so there's no title field here. The folder list is the ⌘S form's
/// (`PanelFolderPickerList`); the pending folder is **created only on Create**, so Cancel leaves
/// no orphan folder. Create resolves/creates the folder and hands its id to `onCreate`, which
/// opens the main window's blank editor there.
private struct PanelNewSnippetForm: View {
    let onCreate: (UUID?) -> Void
    let onCancel: () -> Void
    @Environment(\.modelContext) private var context
    @Environment(PanelNewSnippetState.self) private var state
    @Query(sort: \SnippetFolder.sortIndex) private var folders: [SnippetFolder]
    @State private var picker = PanelFolderPickerModel()
    /// Guards against a Return that reaches both the field's `onSubmit` and the default button.
    @State private var created = false

    var body: some View {
        @Bindable var state = state
        PanelFormChrome(onCancel: onCancel) {
            HStack(spacing: 8) {
                Image(systemName: "plus.rectangle.on.rectangle")
                    .foregroundStyle(.secondary)
                Text("New Snippet").font(.headline)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Save in folder").font(.caption).foregroundStyle(.secondary)
                PanelFolderPickerList(folders: folders, model: picker, namingFolder: $state.namingFolder)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                Button("Create", action: create)
                    .buttonStyle(.borderedProminent)
                    // Suspended while the folder-name field is up so Return commits the
                    // name (its `onSubmit`) instead of creating with a half-typed folder.
                    .keyboardShortcut(state.namingFolder ? nil : .defaultAction)
            }
        }
    }

    private func create() {
        guard !created else { return }
        created = true
        let folder = picker.resolveFolder(naming: state.namingFolder, folders: folders, context: context)
        try? context.save()
        onCreate(folder.id)
    }
}

/// Dimmed backdrop (click = cancel) over a centered form card — the shared chrome of the
/// panel's overlay forms (⌘S save, New Snippet). Standard content on a material surface,
/// never glass.
private struct PanelFormChrome<Content: View>: View {
    /// Card width — the panel's forms keep the default to fit its 420pt surface.
    var width: CGFloat = 320
    let onCancel: () -> Void
    private let content: Content

    init(width: CGFloat = 320, onCancel: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.width = width
        self.onCancel = onCancel
        self.content = content()
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.18))
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: 12) { content }
                .padding(16)
                .background(.regularMaterial, in: .rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
                .shadow(radius: 30, y: 12)
                .frame(width: width)
                // Keeps a margin when a tall form (the batch ⌘S one) meets a short window.
                .padding(.vertical, 12)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
    }
}

/// Destination-folder selection shared by the ⌘S save form and the New Snippet picker:
/// the selected destination, the pending not-yet-created folder, and the
/// inline name-field draft. The pending folder is only inserted on Save/Create
/// (`resolveFolder`), so cancelling either form leaves no orphan folder.
@MainActor
@Observable
private final class PanelFolderPickerModel {
    enum Destination: Hashable {
        case existing(UUID)
        case newFolder
    }

    /// Which folder the confirm action targets: an existing one, or the pending new folder.
    var destination: Destination?
    /// Name committed from the inline "New Folder" field. Shown as a selectable row; the
    /// folder itself is only created on Save/Create.
    var pendingFolderName: String?
    /// The pending folder's emoji chosen from the name field's icon button ("" = plain folder glyph).
    var pendingFolderEmoji = ""
    var folderNameDraft = ""

    /// The new folder's name when New Folder… is confirmed with nothing typed: "Untitled
    /// folder", numbered like Finder ("Untitled folder 2", …) with the lowest number no
    /// existing folder uses, compared case-insensitively.
    static func untitledFolderName(avoiding folders: [SnippetFolder]) -> String {
        let taken = Set(folders.map { $0.name.localizedLowercase })
        var name = String(localized: "Untitled folder")
        var number = 2
        while taken.contains(name.localizedLowercase) {
            name = String(localized: "Untitled folder \(number)")
            number += 1
        }
        return name
    }

    /// Default selection: the first existing folder, else the pending new one.
    func selectDefault(from folders: [SnippetFolder]) {
        destination = folders.first.map { Destination.existing($0.id) } ?? .newFolder
    }

    /// Opening the inline name field makes the new folder the *selected* destination (so no
    /// existing folder also reads as selected); closing it without a pending name restores a
    /// sensible selection.
    func namingChanged(_ naming: Bool, folders: [SnippetFolder]) {
        if naming {
            destination = .newFolder
        } else if pendingFolderName == nil, destination == .newFolder {
            selectDefault(from: folders)
        }
    }

    /// The pending folder's name once the inline field is confirmed: the typed name, or with
    /// nothing typed, the name it already had, else "Untitled folder". Choosing New Folder…
    /// means a new folder even unnamed; Esc is the way out of the field without one.
    func committedFolderName(folders: [SnippetFolder]) -> String {
        let draft = folderNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return draft.isEmpty ? (pendingFolderName ?? Self.untitledFolderName(avoiding: folders)) : draft
    }

    /// The name of the folder the confirm action must create, or `nil` to use an existing
    /// one. The still-open inline field counts as confirmed — clicking Save/Create directly
    /// shouldn't drop the new folder.
    func resolvedNewFolderName(naming: Bool, folders: [SnippetFolder]) -> String? {
        if naming { return committedFolderName(folders: folders) }
        if destination == .newFolder { return pendingFolderName ?? String(localized: "Snippets") }
        return nil
    }

    /// The folder the confirm action targets, inserting the pending new one (unsaved — the
    /// caller saves) when needed; falls back to the first folder, else a default "Snippets"
    /// (mirroring `MainWindowView.beginCompose`).
    func resolveFolder(naming: Bool, folders: [SnippetFolder], context: ModelContext) -> SnippetFolder {
        if let name = resolvedNewFolderName(naming: naming, folders: folders) {
            let folder = SnippetFolder(name: name, sortIndex: (folders.map(\.sortIndex).max() ?? -1) + 1)
            folder.emoji = pendingFolderEmoji
            context.insert(folder)
            return folder
        }
        if case .existing(let id) = destination, let picked = folders.first(where: { $0.id == id }) {
            return picked
        }
        if let first = folders.first { return first }
        let folder = SnippetFolder(name: String(localized: "Snippets"), sortIndex: 0)
        context.insert(folder)
        return folder
    }
}

/// The destination-folder list shared by the panel's overlay forms: existing
/// folders plus the pending new one, with a pinned **New Folder…** control beneath the
/// scrolling list (so it stays reachable however many folders there are) that flips into an
/// inline name field. `namingFolder` binds to the host's shared panel state — not local
/// `@State` — so the panel's key monitor can peel the field with Esc and suspend the form's
/// default-action Return while it's open.
private struct PanelFolderPickerList: View {
    let folders: [SnippetFolder]
    @Bindable var model: PanelFolderPickerModel
    @Binding var namingFolder: Bool
    /// Natural height of the folder rows, measured so the list hugs its content (capped) —
    /// same dynamic-frame pattern as the folder flyouts.
    @State private var listHeight: CGFloat = 0
    /// The name field's icon button's emoji picker popover.
    @State private var pickingIcon = false

    var body: some View {
        VStack(spacing: 2) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(folders) { folder in
                        row(name: folder.name, icon: "folder", emoji: folder.emoji, tag: nil,
                            selected: model.destination == .existing(folder.id)) {
                            model.destination = .existing(folder.id)
                            namingFolder = false   // picking an existing folder cancels a name-in-progress
                        }
                    }
                    // The pending new folder — or, with no folders yet, the default one the
                    // confirm action will create (mirrors `beginCompose`). Hidden while
                    // the name field is open, which itself represents (and is) the selected
                    // new folder. The "New folder" tag marks it as not on disk yet.
                    if !namingFolder,
                       let name = model.pendingFolderName ?? (folders.isEmpty ? String(localized: "Snippets") : nil) {
                        row(name: name, icon: "folder.badge.plus", emoji: model.pendingFolderEmoji, tag: String(localized: "New folder"),
                            selected: model.destination == .newFolder) {
                            model.destination = .newFolder
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .frame(height: min(max(listHeight, 1), 140))
            if namingFolder { folderNameField } else { newFolderButton }
        }
        .onAppear { model.selectDefault(from: folders) }
        .onChange(of: namingFolder) { _, naming in model.namingChanged(naming, folders: folders) }
    }

    private func row(name: String, icon: String, emoji: String = "", tag: String?, selected: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if emoji.isEmpty {
                    Image(systemName: icon)
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                } else {
                    FolderGlyph(emoji: emoji).frame(width: 18)
                }
                Text(name).lineLimit(1)
                Spacer(minLength: 0)
                if let tag {
                    Text(tag).font(.caption).foregroundStyle(.tertiary)
                }
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear),
                        in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// Flips into the inline name field. With a pending folder already named, it reopens the
    /// field prefilled so the name can be edited — there's only ever one pending folder.
    private var newFolderButton: some View {
        Button {
            model.folderNameDraft = model.pendingFolderName ?? ""
            namingFolder = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .frame(width: 18)
                Text(model.pendingFolderName == nil ? String(localized: "New Folder…") : String(localized: "Edit Folder Name…"))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// Inline name entry for the new folder. Return / the checkmark commits (an empty name
    /// commits "Untitled folder"); Esc closes just this field, handled by the panel's key
    /// monitor via the host's shared `namingFolder` state.
    private var folderNameField: some View {
        HStack(spacing: 10) {
            // The new folder's icon: click to pick an emoji. Drawn as a small raised chip so it
            // reads as a control, not a decoration.
            Button { pickingIcon = true } label: {
                Group {
                    if model.pendingFolderEmoji.isEmpty {
                        Image(systemName: "folder.badge.plus").foregroundStyle(.secondary)
                    } else {
                        FolderGlyph(emoji: model.pendingFolderEmoji)
                    }
                }
                .frame(width: 26, height: 22)
                .background(.quaternary, in: .rect(cornerRadius: 6))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Change Icon")
            .popover(isPresented: $pickingIcon, arrowEdge: .bottom) {
                FolderEmojiPicker(current: model.pendingFolderEmoji, offersCharacterViewer: false) { value in
                    model.pendingFolderEmoji = value
                    pickingIcon = false
                }
            }
            SelectAllTextField(text: $model.folderNameDraft, placeholder: String(localized: "Folder name"), plain: true,
                               onSubmit: commitFolderName)
                .frame(maxWidth: .infinity)
            Button(action: commitFolderName) {
                // Same tick as a selected folder row (plain checkmark, no circle) — the open
                // field *is* the selected destination while naming.
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.tint.opacity(0.18), in: .rect(cornerRadius: 8))
    }

    private func commitFolderName() {
        model.pendingFolderName = model.committedFolderName(folders: folders)
        model.destination = .newFolder
        namingFolder = false                    // closes the field; the host reacts via `onChange`
    }
}

/// An AppKit `NSTextField` that **grabs first responder and selects its whole content** the
/// moment it lands in the window. The panel's overlay forms need it: inside the
/// floating panel SwiftUI's `@FocusState` loses the race with the already-focused search field,
/// so a plain `TextField` + `.focused` is left unfocused and typing keeps landing in search.
/// The binding updates per keystroke (so Save/✓ always read the latest text) and Return fires
/// `onSubmit`. Bump `refocus` to steal focus + select again after the initial appear — used to
/// hand focus back to the title field when the inline folder-name field closes.
private struct SelectAllTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    /// Borderless, for the inline folder-name row (drawn on its own tinted capsule);
    /// the default is the standard bezeled field, matching `.roundedBorder`.
    var plain = false
    /// Whether the field takes focus as it lands in the window. Off for all but the first of
    /// several fields, which would otherwise race for it.
    var grabsFocus = true
    /// Grab focus again whenever this changes (value-compared, not a grab count).
    var refocus = 0
    var onSubmit: () -> Void = {}

    func makeNSView(context: Context) -> FocusGrabField {
        let field = FocusGrabField(string: text)
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.cell?.sendsActionOnEndEditing = false   // Return only — a Cancel click must not submit
        field.grabsFocusOnInstall = grabsFocus
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        if plain {
            field.isBezeled = false
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
        }
        return field
    }

    func updateNSView(_ field: FocusGrabField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.seenRefocus != refocus {
            context.coordinator.seenRefocus = refocus
            field.grabFocus()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SelectAllTextField
        var seenRefocus: Int

        init(_ parent: SelectAllTextField) {
            self.parent = parent
            seenRefocus = parent.refocus
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        @objc func submit() { parent.onSubmit() }
    }

    /// Steals first responder once installed. The `DispatchQueue.main.async` hop lets SwiftUI
    /// finish the view update that inserted the field — a synchronous steal would move focus
    /// (and flip the search field's `@FocusState`) mid-update.
    final class FocusGrabField: NSTextField {
        var grabsFocusOnInstall = true
        private var grabbedOnInstall = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, grabsFocusOnInstall, !grabbedOnInstall else { return }
            grabbedOnInstall = true
            grabFocus()
        }

        func grabFocus() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
                self.currentEditor()?.selectAll(nil)
            }
        }
    }
}

private struct PanelHistoryList: View {
    let onDismiss: () -> Void
    let onFlyoutChange: (Bool) -> Void
    @Environment(PasteService.self) private var paste
    @Environment(ClipboardPreviewState.self) private var previewState
    @Environment(PanelFlyoutState.self) private var flyout
    @Environment(PanelSelectionState.self) private var selection

    // Mirror the menu-bar dropdown's organization: the first
    // `inlineItemCount` items show directly, the rest collapse into numbered
    // overflow folders sized by `folderSize`.
    @AppStorage(Pref.Key.inlineItemCount) private var inlineCount = Pref.Default.inlineItemCount
    @AppStorage(Pref.Key.folderSize) private var folderSize = Pref.Default.folderSize

    @Query(sort: \ClipboardItem.createdAt, order: .reverse) private var items: [ClipboardItem]
    @State private var search = ""
    @State private var openToken = 0           // invalidates a pending flyout-open (see below)
    @State private var closeToken = 0          // invalidates a pending inline-hover close (see below)

    private var inlineItems: [ClipboardItem] { Array(items.prefix(max(0, inlineCount))) }
    private var groups: [HistoryGroup] {
        HistoryGrouping.folders(for: items, inlineCount: inlineCount, folderSize: folderSize)
    }

    /// Flat search results across the whole history (the grouping is bypassed while searching).
    /// Content only, like the main window's search: matching the source app name made "text"
    /// pull in every image copied from TextEdit.
    private var filtered: [ClipboardItem] {
        guard !search.isEmpty else { return items }
        return items.filter { $0.plainPreview.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelSearchField(text: $search, placeholder: String(localized: "Search history"))
            Divider().opacity(0.4)
            if items.isEmpty {
                PanelEmptyState(text: String(localized: "No clipboard history"))
            } else if !search.isEmpty {
                let matches = filtered   // searched once per render, not per use
                if matches.isEmpty {
                    PanelEmptyState(text: String(localized: "No matches"))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(matches) { item in itemRow(item) }
                        }
                        .padding(8)
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(inlineItems) { item in
                            // Settling on an unfoldered item closes an open card, but only after a
                            // brief dwell — so moving the cursor diagonally *across* an inline item
                            // to reach the card's first row doesn't dismiss it.
                            itemRow(item)
                                .onHover { scheduleInlineClose($0) }
                        }
                        ForEach(groups, id: \.rangeLabel) { group in
                            folderRow(group)
                        }
                    }
                    .padding(8)
                }
            }
        }
        // Let the panel know when a flyout is open so its click light-dismiss leaves the popover
        // alone.
        .onChange(of: flyout.activeFolder) { _, folder in onFlyoutChange(folder != nil) }
        // Searching replaces the folder rows with flat results, so drop any open flyout (otherwise
        // it would silently reappear when the search is cleared).
        .onChange(of: search) { _, value in if !value.isEmpty { flyout.activeFolder = nil } }
    }

    @ViewBuilder
    private func itemRow(_ item: ClipboardItem) -> some View {
        let displayKind = item.displayKind
        PanelRowButton(preview: item.rowPreview.multilinePreview(limit: 240, keepingTabs: item.kind == .code),
                       detail: displayKind.label(fileCount: item.fileURLs.count),
                       symbol: displayKind.symbol,
                       // PDFs stay compact glyph rows — no large inline preview card.
                       thumbnail: displayKind == .pdf ? nil : ThumbnailCache.image(for: item),
                       fileBadgeCount: item.fileBadgeCount,
                       previewLineLimit: item.rowPreviewLineLimit,
                       selectionID: item.id) {
            choose(item)
        }
        // Track the hovered row so Space previews it.
        .onHover { hovering in
            if hovering { previewState.hoveredID = item.id }
            else if previewState.hoveredID == item.id { previewState.hoveredID = nil }
        }
    }

    /// A folder header whose items fly out to the side (a popover) on hover, like the menu's
    /// submenus. Hovering the row dwells it open; once open it *stays* open while the cursor is
    /// outside the card, so a fast/diagonal move toward it can't drop it. It closes
    /// only on a deliberate action — dwelling on another folder, settling on an unfoldered item,
    /// selecting an item, searching, or dismissing the panel. Leaving the row only cancels a
    /// not-yet-opened dwell.
    private func folderRow(_ group: HistoryGroup) -> some View {
        PanelFolderHeader(label: group.rangeLabel, expanded: flyout.activeFolder == group.rangeLabel,
                          memberIDs: group.items.map(\.id))
            .onHover { hovering in
                if hovering { openFlyout(group.rangeLabel) } else { openToken &+= 1 }
            }
            .popover(isPresented: Binding(
                get: { flyout.activeFolder == group.rangeLabel },
                set: { showing in
                    if showing { flyout.activeFolder = group.rangeLabel }
                    else if flyout.activeFolder == group.rangeLabel { flyout.activeFolder = nil }
                }
            ), arrowEdge: .trailing) {
                PanelFolderFlyout(group: group, previewState: previewState) { item in choose(item) }
            }
    }

    /// A row click: ⌘ toggles the row in the selection, a plain click copies it and dismisses.
    private func choose(_ item: ClipboardItem) {
        if PanelSelectionState.isCommandClick {
            selection.toggle(item.id)
        } else {
            paste.activateFromClick(item); onDismiss()
        }
    }

    /// Open the folder's flyout only after the pointer dwells on its row briefly, so sweeping the
    /// pointer down across folders (to reach an inline item or a lower folder) doesn't flash open
    /// whichever it crosses. An already-open folder stays open immediately (no re-dwell). The token
    /// invalidates a pending open, since the `asyncAfter` work itself can't be cancelled — and is
    /// also bumped when the row is left, so passing over a folder en route never opens it.
    private func openFlyout(_ label: String) {
        guard flyout.activeFolder != label else { return }
        openToken &+= 1
        let token = openToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if openToken == token { flyout.activeFolder = label }
        }
    }

    /// Close an open folder card a short moment after the cursor settles on an unfoldered item.
    /// Leaving the item (or hovering nothing) bumps the token to cancel a pending close, so a quick
    /// diagonal pass *across* an inline item on the way to the card never dismisses it.
    private func scheduleInlineClose(_ hovering: Bool) {
        closeToken &+= 1
        guard hovering, flyout.activeFolder != nil else { return }
        let token = closeToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if closeToken == token { flyout.activeFolder = nil }
        }
    }
}

/// The items of one overflow folder, shown as a side popover beside the folder row.
/// The popover is **dynamic**: it grows to fit its rows (the bigger multi-line previews matching the
/// inline list) and only scrolls once the content exceeds `maxHeight`, so a folder of one short item
/// is a small card and a folder of long ones is a tall one — never a fixed half-empty box.
private struct PanelFolderFlyout: View {
    let group: HistoryGroup
    let previewState: ClipboardPreviewState
    let onSelect: (ClipboardItem) -> Void

    private let width: CGFloat = 340
    private let maxHeight: CGFloat = 480
    /// Natural height of the rows, measured so the popover frame can track it (capped).
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            // Non-lazy so every row is laid out and measured up front (folders hold only
            // `folderSize` items), giving an accurate content height for the dynamic frame.
            VStack(spacing: 2) {
                ForEach(group.items) { item in
                    let displayKind = item.displayKind
                    PanelRowButton(preview: item.rowPreview.multilinePreview(limit: 200, keepingTabs: item.kind == .code),
                                   detail: displayKind.label(fileCount: item.fileURLs.count),
                                   symbol: displayKind.symbol,
                                   // PDFs stay compact glyph rows — no large inline preview card.
                                   thumbnail: displayKind == .pdf ? nil : ThumbnailCache.image(for: item),
                                   fileBadgeCount: item.fileBadgeCount,
                                   imagePreviewCap: 160,
                                   previewLineLimit: item.rowPreviewLineLimit,
                                   selectionID: item.id) {
                        onSelect(item)
                    }
                    // Track the hovered flyout row so Space previews folder items too.
                    .onHover { hovering in
                        if hovering { previewState.hoveredID = item.id }
                        else if previewState.hoveredID == item.id { previewState.hoveredID = nil }
                    }
                }
            }
            .padding(8)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(width: width)
        .frame(height: min(max(contentHeight, 1), maxHeight))
    }
}

/// The header row of an overflow folder — folder glyph, range label, and a chevron that
/// turns down while the folder is open.
private struct PanelFolderHeader: View {
    let label: String
    var emoji: String = ""
    let expanded: Bool
    /// The folder's items or snippets: ⌘-clicking the header selects them all
    /// (`ClipboardPanel.handleCommandMouseDown`, which finds the row through `folderTargets`).
    let memberIDs: [UUID]
    @Environment(PanelSelectionState.self) private var selection
    @State private var targetID = UUID()

    var body: some View {
        let selectedCount = memberIDs.count(where: selection.ids.contains)
        HStack(spacing: 10) {
            FolderGlyph(emoji: emoji)
                .imageScale(.large)
                // Same 18pt column as the item-row glyphs so the mixed list stays in one grid.
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.body.weight(.medium))
            Spacer(minLength: 0)
            if selectedCount == memberIDs.count, selectedCount > 0 {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            } else if selectedCount > 0 {
                Text(verbatim: "\(selectedCount)/\(memberIDs.count)")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.tint)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(expanded || selectedCount > 0 ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .onGeometryChange(for: PanelSelectionState.FolderTarget.self) { proxy in
            // Clipped to the scroll view, so a row scrolled under the search field or footer
            // doesn't catch ⌘-clicks meant for them.
            let global = proxy.frame(in: .global)
            let visible = proxy.bounds(of: .scrollView).map { $0.intersection(proxy.frame(in: .local)) }
            return .init(frame: visible?.offsetBy(dx: global.minX, dy: global.minY) ?? global, members: memberIDs)
        } action: { selection.folderTargets[targetID] = $0 }
        .onDisappear { selection.folderTargets[targetID] = nil }
    }
}

/// The snippets panel. Each snippet folder is shown as a folder row whose
/// snippets fly out to the side on hover — mirroring the history panel's overflow folders
/// (`PanelHistoryList`), not a flat sectioned list. Searching bypasses the folders and shows flat
/// matches across every folder.
private struct PanelSnippetsList: View {
    let onDismiss: () -> Void
    let onFlyoutChange: (Bool) -> Void
    @Environment(PasteService.self) private var paste
    @Environment(PanelFlyoutState.self) private var flyout
    @Environment(PanelSelectionState.self) private var selection
    @Query(sort: \SnippetFolder.sortIndex) private var folders: [SnippetFolder]
    @State private var search = ""
    @State private var openToken = 0           // invalidates a pending flyout-open (see below)

    /// Flat search results across every folder (the folder grouping is bypassed while searching),
    /// mirroring the history panel's flat search.
    private var searchResults: [Snippet] {
        guard !search.isEmpty else { return [] }
        return folders.flatMap(\.orderedSnippets).filter {
            $0.title.localizedCaseInsensitiveContains(search)
            || $0.plainPreview.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelSearchField(text: $search, placeholder: String(localized: "Search snippets"))
            Divider().opacity(0.4)
            if folders.isEmpty {
                PanelEmptyState(text: String(localized: "No snippet folders"))
            } else if !search.isEmpty {
                let results = searchResults   // searched once per render, not per use
                if results.isEmpty {
                    PanelEmptyState(text: String(localized: "No matches"))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(results) { snippet in snippetRow(snippet) }
                        }
                        .padding(8)
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(folders) { folder in folderRow(folder) }
                    }
                    .padding(8)
                }
            }
        }
        // Mirror the history panel: tell the panel a flyout is open so its click light-dismiss
        // leaves the popover alone, and drop any open flyout when a search starts.
        .onChange(of: flyout.activeFolder) { _, folder in onFlyoutChange(folder != nil) }
        .onChange(of: search) { _, value in if !value.isEmpty { flyout.activeFolder = nil } }
    }

    /// A folder header whose snippets fly out to the side (a popover) on hover, like the history
    /// panel's overflow folders. Hovering dwells it open; once open it stays open
    /// while the cursor is outside the card, closing only when another folder dwells open, a search
    /// starts, an item is selected, or the panel is dismissed. Keyed by the folder's `id` (names
    /// aren't unique) so `PanelFlyoutState` — shared with the history list — can track it.
    private func folderRow(_ folder: SnippetFolder) -> some View {
        let key = folder.id.uuidString
        let snippets = folder.orderedSnippets
        return PanelFolderHeader(label: folder.name, emoji: folder.emoji, expanded: flyout.activeFolder == key,
                                 memberIDs: snippets.map(\.id))
            .onHover { hovering in
                if hovering { openFlyout(key) } else { openToken &+= 1 }
            }
            .popover(isPresented: Binding(
                get: { flyout.activeFolder == key },
                set: { showing in
                    if showing { flyout.activeFolder = key }
                    else if flyout.activeFolder == key { flyout.activeFolder = nil }
                }
            ), arrowEdge: .trailing) {
                PanelSnippetFolderFlyout(snippets: snippets) { snippet in choose(snippet) }
            }
    }

    /// Open the folder's flyout only after the pointer dwells on its row briefly, so sweeping down
    /// across folders doesn't flash open whichever it crosses. The token invalidates
    /// a pending open — and is bumped when the row is left — since the `asyncAfter` can't be
    /// cancelled. Mirrors `PanelHistoryList.openFlyout`.
    private func openFlyout(_ key: String) {
        guard flyout.activeFolder != key else { return }
        openToken &+= 1
        let token = openToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if openToken == token { flyout.activeFolder = key }
        }
    }

    /// One snippet as a panel row (`PanelSnippetRow`). Used for both flat search results and, via
    /// `PanelSnippetFolderFlyout`, the folder flyouts.
    private func snippetRow(_ snippet: Snippet) -> some View {
        PanelSnippetRow(snippet: snippet) { choose(snippet) }
    }

    /// A row click: ⌘ toggles the row in the selection, a plain click copies it and dismisses.
    private func choose(_ snippet: Snippet) {
        if PanelSelectionState.isCommandClick {
            selection.toggle(snippet.id)
        } else {
            paste.activateFromClick(snippet); onDismiss()
        }
    }
}

/// One snippet as a panel row: the title on top with a "Rich"/"File" capsule badge, a **3-line**
/// content preview below, and the **same content-type glyph the history modal uses** for that kind
/// (`ClipboardKind.symbol`, so they stay in lock-step): plain → `text.alignleft`, rich →
/// `doc.richtext`, file → `doc`. Shared by the flat search list and the folder
/// flyouts so both render identically.
private struct PanelSnippetRow: View {
    let snippet: Snippet
    let onSelect: () -> Void
    @Environment(ClipboardPreviewState.self) private var previewState
    /// Inline thumbnail for an **image** file snippet, so the snippets modal shows image previews
    /// like the history modal's image rows. Generated off the referenced file
    /// (snippets store no thumbnail) once via `.task` and cached, so hovering / re-renders
    /// don't re-read the image. `nil` for text/rich snippets and for PDF/other files (which stay
    /// compact glyph rows, matching the history modal's `presentsAsPDF` exclusion).
    @State private var thumbnail: NSImage?

    var body: some View {
        PanelRowButton(preview: snippet.title.isEmpty ? String(localized: "Untitled") : snippet.title,
                       detail: Self.previewText(snippet),
                       symbol: Self.symbol(snippet),
                       thumbnail: thumbnail,
                       fileBadgeCount: snippet.fileBadgeCount,
                       // Several files list one name per line, plus a line for "…" past three.
                       previewLineLimit: 1, detailLineLimit: snippet.isFile ? snippet.fileNamesLineLimit : 3,
                       badge: Self.badge(snippet),
                       selectionID: snippet.id) {
            onSelect()
        }
        // Track the hovered row so Space previews it — shared by the flat
        // search list and the folder flyouts, so both get the preview from this one place.
        .onHover { hovering in
            if hovering { previewState.hoveredID = snippet.id }
            else if previewState.hoveredID == snippet.id { previewState.hoveredID = nil }
        }
        // Load the image thumbnail once per snippet (keyed by id so a reused row refreshes).
        .task(id: snippet.id) { thumbnail = await Self.loadThumbnail(for: snippet) }
    }

    /// The inline image thumbnail for an image file snippet, or `nil` for anything else. Only
    /// image files get a preview card — PDFs and other files stay compact glyph rows, matching the
    /// history modal. The file is downsampled off the main actor via ImageIO (`Data` is
    /// `Sendable`; `NSImage` never leaves the detached task) and decoded back on return.
    private static func loadThumbnail(for snippet: Snippet) async -> NSImage? {
        guard snippet.isFile, let url = snippet.fileURLs.first else { return nil }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        guard type?.conforms(to: .image) == true,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = await Task.detached(priority: .utility) {
            ClipboardContent.downsampledPNG(from: CGImageSourceCreateWithURL(url as CFURL, nil), maxDimension: 512)
        }.value
        return data.flatMap(NSImage.init(data:))
    }

    /// The row's type tag: "File" / "Files" / "Images" for a file snippet, "Rich" for rich text.
    private static func badge(_ s: Snippet) -> String? {
        if s.isFile { return s.fileKindLabel }
        return s.isRichText ? String(localized: "Rich") : nil
    }

    /// The content-type glyph, taken from `ClipboardKind.symbol` so it matches the history modal's
    /// row icon for the equivalent kind: a folder for a snippet of folders only.
    private static func symbol(_ s: Snippet) -> String {
        if s.isFile { return ClipboardKind.presenting(fileURLs: s.fileURLs) == .folder ? ClipboardKind.folder.symbol : ClipboardKind.file.symbol }
        if s.isRichText { return ClipboardKind.richText.symbol }
        return ClipboardKind.plainText.symbol
    }

    /// Up to a 3-line content preview with line breaks preserved, mirroring the main window's
    /// SnippetCard: a file snippet previews its file name(s); text/rich preview the content.
    private static func previewText(_ s: Snippet) -> String {
        if s.isFile {
            let p = s.fileNamesPreview
            return p.isEmpty ? String(localized: "Empty") : p
        }
        let p = s.plainString.multilinePreview(limit: 240)
        return p.isEmpty ? String(localized: "Empty") : p
    }
}

/// The snippets of one folder, shown as a side popover beside the folder row —
/// the snippet counterpart of `PanelFolderFlyout`. Grows to fit its rows, scrolling only once the
/// content exceeds `maxHeight`; an empty folder shows a short placeholder.
private struct PanelSnippetFolderFlyout: View {
    let snippets: [Snippet]
    let onSelect: (Snippet) -> Void

    private let width: CGFloat = 340
    private let maxHeight: CGFloat = 480
    /// Natural height of the rows, measured so the popover frame can track it (capped).
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                if snippets.isEmpty {
                    Text("No snippets")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                } else {
                    ForEach(snippets) { snippet in
                        PanelSnippetRow(snippet: snippet) { onSelect(snippet) }
                    }
                }
            }
            .padding(8)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(width: width)
        .frame(height: min(max(contentHeight, 1), maxHeight))
    }
}

private struct PanelRowButton: View {
    let preview: String
    let detail: String
    let symbol: String
    /// The image preview of an image row — history rows pass `ThumbnailCache`'s shared decode,
    /// snippet rows one generated off their referenced file; nil for a glyph row.
    let thumbnail: NSImage?
    /// What the row's `FileCountBadge` says — several files, or a folder's items (`fileBadgeCount`) —
    /// at its trailing edge; nil for no badge.
    let fileBadgeCount: Int?
    /// Max height of the image preview card. Folder flyouts pass a smaller value so their
    /// previews stay compact; inline / search / snippet rows keep the full-size default.
    let imagePreviewCap: CGFloat
    /// How many lines the text preview may span before truncating. History rows in the floating
    /// panel pass a larger value for bigger, multi-line previews; snippets stay single-line.
    let previewLineLimit: Int
    /// How many lines the secondary `detail` line may span. History rows keep the kind label to a
    /// single caption line; snippet rows pass a larger value so the content preview spans up to 3
    /// lines (rendered at `.callout`), like the main window's SnippetCard.
    let detailLineLimit: Int
    /// Optional capsule tag beside the preview line — "Rich" for rich-text snippets, matching
    /// the main window's SnippetCard.
    let badge: String?
    /// The history item or snippet behind the row, to show whether it's in the ⌘-click selection.
    let selectionID: UUID
    let action: () -> Void
    @State private var hovering = false
    @Environment(PanelSelectionState.self) private var selection

    init(preview: String, detail: String, symbol: String,
         thumbnail: NSImage? = nil, fileBadgeCount: Int? = nil, imagePreviewCap: CGFloat = 200,
         previewLineLimit: Int = 1, detailLineLimit: Int = 1, badge: String? = nil,
         selectionID: UUID, action: @escaping () -> Void) {
        self.preview = preview
        self.detail = detail
        self.symbol = symbol
        self.thumbnail = thumbnail
        self.fileBadgeCount = fileBadgeCount
        self.imagePreviewCap = imagePreviewCap
        self.previewLineLimit = previewLineLimit
        self.detailLineLimit = detailLineLimit
        self.badge = badge
        self.selectionID = selectionID
        self.action = action
    }

    /// Actual rendered width of the preview, read back via `onGeometryChange`, so the card
    /// height can track the image's aspect ratio at full width (capped). 0 until first layout.
    @State private var previewWidth: CGFloat = 0

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering || selection.ids.contains(selectionID) ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear),
                            in: .rect(cornerRadius: 8))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// Image rows get a large preview card — the image fills the full row width and the card
    /// height tracks its aspect ratio, growing up to `previewHeightCap`; taller images are
    /// cropped (scaledToFill) rather than letterboxed, so there's never empty padding. The label
    /// beneath keeps the same glyph + text columns as every other row, so a mixed list stays in
    /// one grid. Everything else is a compact glyph row. Standard content — never glass.
    @ViewBuilder
    private var content: some View {
        if let thumbnail {
            VStack(alignment: .leading, spacing: 6) {
                imagePreview(thumbnail)
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    textBlock
                    Spacer(minLength: 0)
                    badgeView
                }
            }
        } else {
            // Center the glyph against the whole preview + detail block — every row is at least
            // two lines tall (preview + kind caption), so a first-line-aligned glyph reads as
            // riding high; centering matches the folder rows and standard menu rows. The
            // trailing badge rides the same center line.
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                textBlock
                Spacer(minLength: 0)
                badgeView
            }
        }
    }

    private func imagePreview(_ image: NSImage) -> some View {
        let aspect = image.size.width > 0 && image.size.height > 0
            ? image.size.width / image.size.height
            : 1
        // Fill the full width; height = width / aspect, clamped to the cap. Until the first
        // layout reports a width, fall back to the cap so the row reserves sensible space.
        let height = previewWidth > 0
            ? min(previewWidth / aspect, imagePreviewCap)
            : imagePreviewCap

        return Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay { Image(nsImage: image).resizable().scaledToFill() }
            .clipShape(.rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.2)))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { previewWidth = $0 }
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(preview.isEmpty ? "—" : preview)
                .lineLimit(previewLineLimit)
                .multilineTextAlignment(.leading)
            Text(detail)
                .font(detailLineLimit > 1 ? .callout : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(detailLineLimit)
                .multilineTextAlignment(.leading)
        }
    }

    /// Type tag ("Rich"/"File"), pinned to the row's trailing edge and vertically centered against
    /// the whole preview + detail block (the content HStack centers its children) rather than
    /// riding the title's baseline.
    @ViewBuilder
    private var badgeView: some View {
        // Grouped so the two tags sit 4pt apart (as in the snippet cards) instead of the row's
        // 10pt spacing. Skipped when empty so it doesn't add a phantom gap.
        if fileBadgeCount != nil || badge != nil {
            HStack(spacing: 4) {
                FileCountBadge(count: fileBadgeCount)
                if let badge {
                    RowTag(badge)   // drawn like the count beside it, so the two match in size
                }
            }
        }
        if selection.ids.contains(selectionID) {
            Image(systemName: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
        }
    }
}

private struct PanelSearchField: View {
    @Binding var text: String
    let placeholder: String
    @FocusState private var focused: Bool
    @Environment(PanelNewSnippetState.self) private var newSnippet

    var body: some View {
        // Same 18pt icon column, 10pt gap, and 16pt leading inset as the rows below, so the
        // magnifier sits on the glyph column and the input text on the row-text column.
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .frame(width: 18)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onAppear { focused = true }
        // Typing with focus elsewhere (a list row, a closed flyout) jumps back to search.
        .background(TypeToSearch(placeholder: placeholder))
        // Closing the save-as-snippet form (saved or cancelled) deliberately leaves search
        // unfocused; typing still jumps back to it via `TypeToSearch`.
        .onChange(of: newSnippet.choosing) { _, choosing in if !choosing { focused = true } }
    }
}

private struct PanelEmptyState: View {
    let text: String
    var body: some View {
        VStack {
            Spacer()
            Text(text).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// A thin strip above the footer that appears only while **Option** is held, spelling out what an
/// Option-click will do: it inverts the `alwaysPastePlainText` default for that one
/// copy — so with the pref off it reads "Copy as plain text", and with it on "Copy text with formatting".
/// Also shared by the main window's history pane, which injects its own `PanelModifierState`.
struct PanelOptionHint: View {
    /// How many rows are selected, so a multi-row copy says how many it will copy.
    let count: Int
    @Environment(PanelModifierState.self) private var modifier
    @AppStorage(Pref.Key.alwaysPastePlainText) private var alwaysPlain = Pref.Default.alwaysPastePlainText

    private var label: String {
        if count > 1 {
            return alwaysPlain ? String(localized: "Copy \(count) items with formatting") : String(localized: "Copy \(count) items as plain text")
        }
        return alwaysPlain ? String(localized: "Copy text with formatting") : String(localized: "Copy as plain text")
    }

    var body: some View {
        if modifier.optionHeld {
            HStack(spacing: 6) {
                Image(systemName: "option")
                Text(label)
                Spacer(minLength: 0)
            }
            .modifier(HintStripStyle())
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// The shared look of the ⌥/⌘ hint strips (`PanelOptionHint`, `PanelSelectionHint`, and the
/// onboarding mock of them): accent caption text on a faint accent wash. The plain accent is a
/// mid-luminance blue, too dark for dark glass and too light for light glass at caption size
/// (~3.5:1 either way), so the text is pushed toward white in dark mode and toward black in
/// light mode, keeping the hue.
struct HintStripStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let isLight = colorScheme == .light
        content
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.accentColor.mix(with: isLight ? .black : .white, by: isLight ? 0.35 : 0.4))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.tint.opacity(isLight ? 0.14 : 0.18))
    }
}

/// A thin strip above the footer while ⌘ is held, saying what a ⌘-click does and, once something is
/// selected, what releasing ⌘ does. Same look as `PanelOptionHint`, directly above it in the panel's
/// stack. Hidden under an overlay, where ⌘ means something else (⌘V in a form's field).
private struct PanelSelectionHint: View {
    @Environment(PanelSelectionState.self) private var selection
    @Environment(PanelModifierState.self) private var modifier
    @Environment(ClipboardPreviewState.self) private var previewState
    @Environment(PanelSnippetSaveState.self) private var saveState
    @Environment(PanelNewSnippetState.self) private var newSnippet

    private var label: String {
        switch selection.ids.count {
        case 0: String(localized: "Click items or folders to select them")
        case 1: String(localized: "Release to copy 1 item")
        case let count: String(localized: "Release to copy \(count) items")
        }
    }

    var body: some View {
        let hasSelection = !selection.ids.isEmpty
        if (modifier.commandHeld || hasSelection), !saveState.isOpen, !newSnippet.choosing,
           previewState.presentedID == nil {
            HStack(spacing: 6) {
                Image(systemName: "command")
                Text(label)
                Spacer(minLength: 0)
                if hasSelection {
                    Text("Esc to clear")
                }
            }
            .modifier(HintStripStyle())
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// The bottom action bar — the leading action is mode-specific ("Clear History" in the history
/// panel, "New Snippet" in the snippets panel); "Main Window" is shared. Clear History
/// routes to a native confirmation alert handled panel-side (`confirmClearHistory`); New Snippet
/// raises the in-panel folder picker (`PanelNewSnippetHost`), whose Create then opens the main
/// window's editor in the chosen folder — a detached panel can't host that editor itself.
private struct PanelFooter: View {
    let mode: ClipboardPanel.Mode
    let onClearHistory: () -> Void
    let onNewSnippet: () -> Void
    let onOpenMainWindow: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.4)
            HStack(spacing: 8) {
                switch mode {
                case .history:
                    PanelFooterButton(title: String(localized: "Clear History"), symbol: "trash", action: onClearHistory)
                case .snippets:
                    PanelFooterButton(title: String(localized: "New Snippet"), symbol: "plus", action: onNewSnippet)
                }
                Spacer(minLength: 0)
                PanelFooterButton(title: String(localized: "Main Window"), symbol: "macwindow", action: onOpenMainWindow)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }
}

private struct PanelFooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(hovering ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear),
                            in: .rect(cornerRadius: 8))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
