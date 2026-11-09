import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Storage preferences: what Simple Clipboard keeps on disk — the history store,
/// the copies kept of copied files (`HistoryFileCache`, which tidies itself, so there's nothing to
/// clear by hand) and the snippets (their content and their files) — then the history items that
/// take the most space, and the file snippets with what each takes. Those two lists work like the main window's: click, ⌘-click, ⇧-click and the arrow keys
/// select, Space previews the selected row, and ⌘⌫, the context menu or a row's trash button
/// deletes — the whole selection when the row is part of it — after the usual confirmation.
struct StorageSettingsView: View {
    @Environment(HistoryStore.self) private var history
    @Environment(\.modelContext) private var modelContext
    @Environment(\.appearsActive) private var appearsActive
    @Query(sort: \ClipboardItem.createdAt, order: .reverse) private var items: [ClipboardItem]
    @Query(sort: \Snippet.createdAt, order: .reverse) private var snippets: [Snippet]

    @AppStorage(Pref.Key.confirmBeforeDeletingItems) private var confirmItemDeletes = Pref.Default.confirmBeforeDeletingItems
    @AppStorage(Pref.Key.confirmBeforeDeletingSnippets) private var confirmSnippetDeletes = Pref.Default.confirmBeforeDeletingSnippets

    @State private var report: StorageReport?
    /// Bumped to measure again: after a change made here, and each time the window comes back to
    /// the front, since files may have been moved or deleted in Finder meanwhile.
    @State private var revision = 0

    @State private var itemSelection: Set<UUID> = []
    @State private var snippetSelection: Set<UUID> = []
    /// The list with keyboard focus: where Space, Esc, the arrow keys, ⌘A and ⌘⌫ go.
    @FocusState private var focusedList: StorageListKind?
    @State private var preview = SpacePreview()
    /// Rows awaiting the delete confirmation, by id.
    @State private var pendingItemDeletion: Set<UUID>?
    @State private var pendingSnippetDeletion: Set<UUID>?

    /// Largest Items shows at most this many rows, and only rows taking at least `minimumListedBytes`:
    /// smaller ones (most text, and files sharing their originals' space) would bury the big ones.
    /// The Snippets list shows this many file snippets of any size; text snippets take next to nothing.
    private static let listedRowLimit = 15
    private static let minimumListedBytes = 5_000

    var body: some View {
        let largestItems = report.map(rankedItems) ?? []
        let largestSnippets = report.map(rankedSnippets) ?? []
        ScrollViewReader { scroller in
            Form {
                Section {
                    UsageSummary(report: report)
                }

                Section("Largest Items") {
                    listContent(largestItems, emptyText: String(localized: "No large items")) { entries in
                        StorageList(kind: .items, entries: entries, selection: $itemSelection, focus: $focusedList,
                                    onSpace: { spacePressed($0, in: .items) },
                                    onEscape: { escapePressed(in: .items) },
                                    onMove: { scroller.scrollTo($0) }) { entry, state in
                            StorageItemRow(item: entry.item, usage: entry.usage, state: state) {
                                requestItemDeletion(state.targets)
                            }
                        } menu: { ids in
                            itemMenu(ids)
                        }
                    }
                }

                Section("Snippets") {
                    listContent(largestSnippets, emptyText: String(localized: "No snippets")) { entries in
                        StorageList(kind: .snippets, entries: entries, selection: $snippetSelection, focus: $focusedList,
                                    onSpace: { spacePressed($0, in: .snippets) },
                                    onEscape: { escapePressed(in: .snippets) },
                                    onMove: { scroller.scrollTo($0) }) { entry, state in
                            StorageSnippetRow(entry: entry, state: state,
                                              deleteHelp: snippetDeleteLabel(state.targets)) {
                                requestSnippetDeletion(state.targets)
                            }
                        } menu: { ids in
                            snippetMenu(ids)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            // A click on blank space clears the selection (Finder-style); a row's own tap and its
            // buttons take precedence over this one.
            .contentShape(.rect)
            .onTapGesture {
                itemSelection = []
                snippetSelection = []
                focusedList = nil
            }
        }
        .overlay {
            // The main window's Space previews, over the whole tab; dismiss with Space,
            // Esc or a click on the backdrop. A row that leaves its list drops the overlay.
            switch preview.list {
            case .items?:
                if itemSelection.count == 1, let entry = largestItems.first(where: { itemSelection.contains($0.id) }) {
                    ClipboardPreviewOverlay(item: entry.item) { closePreview() }
                }
            case .snippets?:
                if snippetSelection.count == 1, let entry = largestSnippets.first(where: { snippetSelection.contains($0.id) }) {
                    SnippetPreviewOverlay(snippet: entry.snippet) { closePreview() }
                }
            case nil:
                EmptyView()
            }
        }
        // ⌘A and ⌘⌫ for the focused list.
        .background(StorageKeyCommands(
            selectAll: { selectAllInFocusedList(items: largestItems.map(\.id), snippets: largestSnippets.map(\.id)) },
            delete: deleteFocusedSelection))
        .task(id: [history.itemCount, snippets.count, revision]) { await measure() }
        .onChange(of: appearsActive) { _, active in
            if active { revision += 1 }
        }
        // One selection at a time, so ⌘⌫ and the menus never act on rows out of sight in the other list.
        .onChange(of: itemSelection) { _, ids in
            if !ids.isEmpty { snippetSelection = [] }
            if preview.list == .items, ids.count != 1 { closePreview() }
        }
        .onChange(of: snippetSelection) { _, ids in
            if !ids.isEmpty { itemSelection = [] }
            if preview.list == .snippets, ids.count != 1 { closePreview() }
        }
        .onDisappear(perform: closePreview)
        .silencesSpaceRepeats(while: preview.list != nil)
        .animation(.easeInOut(duration: 0.15), value: preview.list)
        // The delete confirmations, each with its own "Don’t ask again" (Settings › General turns
        // them back on). A suppression toggle reaches every alert attached inside it, so each pair
        // sits on its own view, and the missing-files alert below gets none.
        .background {
            Color.clear
                .alert(itemDeletionTitle, isPresented: isPresenting($pendingItemDeletion), presenting: pendingItemDeletion) { ids in
                    Button("Delete", role: .destructive) { deleteItems(ids) }
                        .keyboardShortcut(.defaultAction)
                    Button("Cancel", role: .cancel) {}
                } message: { _ in
                    Text("This can’t be undone.")
                }
                .dialogSuppressionToggle("Don’t ask again", isSuppressed: Binding(get: { !confirmItemDeletes },
                                                                               set: { confirmItemDeletes = !$0 }))
        }
        .background {
            Color.clear
                .alert(snippetDeletionTitle, isPresented: isPresenting($pendingSnippetDeletion), presenting: pendingSnippetDeletion) { ids in
                    Button("Delete", role: .destructive) { deleteSnippets(ids) }
                        .keyboardShortcut(.defaultAction)
                    Button("Cancel", role: .cancel) {}
                } message: { _ in
                    Text("This can’t be undone.")
                }
                .dialogSuppressionToggle("Don’t ask again", isSuppressed: Binding(get: { !confirmSnippetDeletes },
                                                                               set: { confirmSnippetDeletes = !$0 }))
        }
    }

    /// A list section's rows: a spinner while measuring, `emptyText` when nothing qualifies.
    @ViewBuilder
    private func listContent<Entry, Content: View>(_ entries: [Entry], emptyText: String,
                                                   @ViewBuilder content: ([Entry]) -> Content) -> some View {
        if report == nil {
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
        } else if entries.isEmpty {
            Text(emptyText).foregroundStyle(.secondary)
        } else {
            content(entries)
        }
    }

    // MARK: Measuring

    private func measure() async {
        history.refreshKeptFiles()   // first, so stale copies don't count
        report = await StorageReport.measure(items: items, snippets: snippets, container: modelContext.container)
    }

    /// The largest `listedRowLimit` items of `minimumListedBytes` or more; ties newest first.
    private func rankedItems(_ report: StorageReport) -> [ItemEntry] {
        let ranked = items.compactMap { item in report.items[item.id].map { ItemEntry(item: item, usage: $0) } }
            .filter { $0.usage.bytes >= Self.minimumListedBytes }
            .sorted { $0.usage.bytes != $1.usage.bytes ? $0.usage.bytes > $1.usage.bytes : $0.item.createdAt > $1.item.createdAt }
        return Array(ranked.prefix(Self.listedRowLimit))
    }

    /// The `listedRowLimit` largest file snippets, however small; ties newest first. Text snippets
    /// aren't listed: their content is a few bytes in the store.
    private func rankedSnippets(_ report: StorageReport) -> [SnippetEntry] {
        let ranked = snippets.filter(\.isFile).compactMap { snippet in
            report.snippets[snippet.id].map { SnippetEntry(snippet: snippet, usage: $0) }
        }
        .sorted { $0.usage.bytes != $1.usage.bytes ? $0.usage.bytes > $1.usage.bytes : $0.snippet.createdAt > $1.snippet.createdAt }
        return Array(ranked.prefix(Self.listedRowLimit))
    }

    // MARK: Selection and preview

    private func selection(of list: StorageListKind) -> Set<UUID> {
        list == .items ? itemSelection : snippetSelection
    }

    /// Space: a tap opens the selected row's preview and the next one closes it; held, the preview
    /// shows only until it's released — the main window's split.
    private func spacePressed(_ phase: KeyPress.Phases, in list: StorageListKind) -> KeyPress.Result {
        switch phase {
        case .down:
            if preview.list != nil {
                closePreview()
                return .handled
            }
            guard selection(of: list).count == 1 else { return .ignored }
            preview = SpacePreview(list: list, pressedAt: .now)
            return .handled
        case .up:
            guard let pressedAt = preview.pressedAt else { return .ignored }
            preview.pressedAt = nil
            if Date.now.timeIntervalSince(pressedAt) >= SpacePreview.holdThreshold { closePreview() }
            return .handled
        default:
            // Auto-repeat while held: swallowed, so it never reads as a second tap.
            return preview.list != nil ? .handled : .ignored
        }
    }

    /// Esc peels one layer: an open preview first, then the selection (Finder-style).
    private func escapePressed(in list: StorageListKind) -> KeyPress.Result {
        if preview.list != nil {
            closePreview()
            return .handled
        }
        guard !selection(of: list).isEmpty else { return .ignored }
        if list == .items { itemSelection = [] } else { snippetSelection = [] }
        return .handled
    }

    private func closePreview() {
        preview = SpacePreview()
    }

    /// ⌘A: every row of the focused list; false (the key goes on) when no list has focus.
    private func selectAllInFocusedList(items itemIDs: [UUID], snippets snippetIDs: [UUID]) -> Bool {
        switch focusedList {
        case .items? where !itemIDs.isEmpty: itemSelection = Set(itemIDs)
        case .snippets? where !snippetIDs.isEmpty: snippetSelection = Set(snippetIDs)
        default: return false
        }
        return true
    }

    /// ⌘⌫: deletes the focused list's selection (after confirming); false when there's none.
    private func deleteFocusedSelection() -> Bool {
        switch focusedList {
        case .items? where !itemSelection.isEmpty: requestItemDeletion(Array(itemSelection))
        case .snippets? where !snippetSelection.isEmpty: requestSnippetDeletion(Array(snippetSelection))
        default: return false
        }
        return true
    }

    // MARK: Menus

    @ViewBuilder
    private func itemMenu(_ ids: [UUID]) -> some View {
        let files = items.filter { ids.contains($0.id) }.flatMap { $0.availableFileURLs.filter(ClipboardItem.fileExists) }
        if !files.isEmpty {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(files) }
            Divider()
        }
        Button(ids.count > 1 ? String(localized: "Delete \(ids.count) Items") : String(localized: "Delete"), role: .destructive) {
            requestItemDeletion(ids)
        }
    }

    @ViewBuilder
    private func snippetMenu(_ ids: [UUID]) -> some View {
        let files = snippetTargets(ids).flatMap { $0.fileURLs.filter(ClipboardItem.fileExists) }
        if !files.isEmpty {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(files) }
            Divider()
        }
        Button(snippetDeleteLabel(ids), role: .destructive) {
            requestSnippetDeletion(ids)
        }
    }

    /// "Delete", or "Delete 3 Snippets".
    private func snippetDeleteLabel(_ ids: [UUID]) -> String {
        ids.count > 1 ? String(localized: "Delete \(ids.count) Snippets") : String(localized: "Delete")
    }

    /// The snippets among `ids`.
    private func snippetTargets(_ ids: some Collection<UUID>) -> [Snippet] {
        snippets.filter { ids.contains($0.id) }
    }

    // MARK: Deleting

    /// Deletes history items once confirmed, or straight away with confirmation turned off — the
    /// history list's setting and alert.
    private func requestItemDeletion(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        closePreview()
        if confirmItemDeletes {
            pendingItemDeletion = Set(ids)
        } else {
            deleteItems(Set(ids))
        }
    }

    private func deleteItems(_ ids: Set<UUID>) {
        let targets = items.filter { ids.contains($0.id) }
        itemSelection.subtract(ids)
        guard !targets.isEmpty else { return }
        history.delete(targets)
        revision += 1
    }

    /// Deletes snippets once confirmed, or straight away with confirmation turned off — the
    /// snippet list's setting and alert.
    private func requestSnippetDeletion(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        closePreview()
        if confirmSnippetDeletes {
            pendingSnippetDeletion = Set(ids)
        } else {
            deleteSnippets(Set(ids))
        }
    }

    private func deleteSnippets(_ ids: Set<UUID>) {
        let targets = snippetTargets(ids)
        snippetSelection.subtract(ids)
        guard !targets.isEmpty else { return }
        for snippet in targets {
            snippet.deleteOwnedManagedFiles()   // its stored file copies
            modelContext.delete(snippet)
        }
        try? modelContext.save()
        revision += 1
    }

    /// "Delete this item?" for one, "Delete 3 items?" for several.
    private var itemDeletionTitle: Text {
        let count = pendingItemDeletion?.count ?? 0
        return Text(count > 1 ? String(localized: "Delete \(count) items?") : String(localized: "Delete this item?"))
    }

    /// "Delete “Title”?" for one snippet, "Delete 3 snippets?" for several.
    private var snippetDeletionTitle: Text {
        let ids = pendingSnippetDeletion ?? []
        guard ids.count > 1 else {
            let title = snippets.first { ids.contains($0.id) }?.title ?? ""
            return Text("Delete “\(title.isEmpty ? String(localized: "Untitled") : title)”?")
        }
        return Text("Delete \(ids.count) snippets?")
    }

    /// Bridges an optional alert payload to `isPresented`; dismissing clears it.
    private func isPresenting<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}

/// "820 MB" — or "—" while measuring.
private func byteString(_ bytes: Int?) -> String {
    guard let bytes else { return "—" }
    return Int64(bytes).formatted(.byteCount(style: .file))
}

// MARK: - Summary

/// What Simple Clipboard uses in all, as one thin segmented bar split into its parts, with a
/// legend naming each part and its size (System Settings › Storage style). History counts the
/// store plus the copies kept of its files, which tidy themselves and so get no part of their own;
/// Snippets counts every snippet's content in the store (text included) plus the snippets' files.
private struct UsageSummary: View {
    let report: StorageReport?

    private struct Part: Identifiable {
        let id: Int
        let name: String
        let bytes: Int
        let color: Color
    }

    private var parts: [Part] {
        [
            Part(id: 0, name: String(localized: "History"),
                 bytes: (report?.historyDatabaseBytes ?? 0) + (report?.fileStoreBytes ?? 0), color: UsageColor.history),
            Part(id: 1, name: String(localized: "Snippets"),
                 bytes: (report?.snippetDataBytes ?? 0) + (report?.snippetFilesBytes ?? 0), color: UsageColor.snippets),
        ]
    }

    var body: some View {
        let parts = parts
        let total = parts.reduce(0) { $0 + $1.bytes }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Simple Clipboard").font(.headline)
                Spacer()
                Text(report == nil ? String(localized: "Measuring…") : String(localized: "\(byteString(total)) used"))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            SegmentedUsageBar(parts: parts.map { ($0.bytes, $0.color, help(for: $0, total: total)) })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Storage used"))
                .accessibilityValue(Text(parts.map { help(for: $0, total: total) }.joined(separator: ", ")))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { legend(parts) }
                VStack(alignment: .leading, spacing: 4) { legend(parts) }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func legend(_ parts: [Part]) -> some View {
        ForEach(parts) { part in
            HStack(spacing: 6) {
                Circle().fill(part.color).frame(width: 8, height: 8)
                Text(part.name)
                Text(report == nil ? "—" : byteString(part.bytes))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.callout)
            .fixedSize()
        }
    }

    /// "History: 310 MB (25%)" — the bar's hover text and accessibility value for a part.
    private func help(for part: Part, total: Int) -> String {
        let share = total > 0 ? Double(part.bytes) / Double(total) : 0
        return "\(part.name): \(byteString(part.bytes)) (\(share.formatted(.percent.precision(.fractionLength(0)))))"
    }
}

/// The summary bar: 8 pt tall with fully rounded ends, one segment per non-empty part in order,
/// 2 pt gaps between them, over an empty track. A part too small to see still gets a sliver.
private struct SegmentedUsageBar: View {
    let parts: [(bytes: Int, color: Color, help: String)]

    private static let height: CGFloat = 8
    private static let gap: CGFloat = 2
    private static let minimumWidth: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let shown = parts.filter { $0.bytes > 0 }
            let widths = Self.widths(for: shown.map(\.bytes), in: proxy.size.width)
            HStack(spacing: Self.gap) {
                ForEach(shown.indices, id: \.self) { index in
                    Rectangle()
                        .fill(shown[index].color)
                        .frame(width: widths[index])
                        .help(shown[index].help)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Self.height)
        .background(.quaternary)
        .clipShape(.capsule)
    }

    /// Widths proportional to `values` across `width` less the gaps, each at least `minimumWidth`.
    private static func widths(for values: [Int], in width: CGFloat) -> [CGFloat] {
        guard !values.isEmpty else { return [] }
        let available = max(0, width - gap * CGFloat(values.count - 1))
        let total = CGFloat(values.reduce(0, +))
        var widths = values.map { CGFloat($0) / total * available }
        let small = widths.indices.filter { widths[$0] < minimumWidth }
        guard !small.isEmpty, small.count < widths.count else { return widths }
        let taken = minimumWidth * CGFloat(small.count)
        let largeTotal = widths.indices.filter { !small.contains($0) }.reduce(0) { $0 + widths[$1] }
        for index in widths.indices {
            widths[index] = small.contains(index) ? minimumWidth : widths[index] / largeTotal * (available - taken)
        }
        return widths
    }
}

/// The summary's categorical colors, in fixed order (validated light and dark: lightness band,
/// chroma, colorblind and normal-vision separation). Each mode has its own steps.
private enum UsageColor {
    static let history = dynamic(light: 0x2A78D6, dark: 0x3987E5)        // blue
    static let snippets = dynamic(light: 0x1BAF7A, dark: 0x199E70)   // aqua

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

// MARK: - Lists

/// Which of the tab's two lists.
private enum StorageListKind: Hashable {
    case items, snippets
}

/// The Space preview: the list whose single selected row it shows (nil: closed), and when the
/// Space press that opened it went down, until that key comes back up.
private struct SpacePreview {
    var list: StorageListKind?
    var pressedAt: Date?

    /// Held at least this long, the preview closes when Space is released.
    static let holdThreshold: TimeInterval = 0.2
}

private struct ItemEntry: Identifiable {
    let item: ClipboardItem
    let usage: StorageReport.ItemUsage
    var id: UUID { item.id }
}

/// A row of the Snippets list: one file snippet and what it takes.
private struct SnippetEntry: Identifiable {
    let snippet: Snippet
    let usage: StorageReport.SnippetUsage
    var id: UUID { snippet.id }
}

/// How one list row draws, and what its trash button and context menu act on.
private struct StorageRowState {
    let isSelected: Bool
    /// The accent fill with white text: selected, in the list with keyboard focus, in the active
    /// window. Otherwise a selected row gets the gray unemphasized fill, as in a native list.
    let isEmphasized: Bool
    /// The whole selection when the row is part of it, else the row alone — what right-clicking a
    /// row acts on in Finder.
    let targets: [UUID]
}

/// Rows inside a form section that select like a native list: click, ⌘-click (toggle), ⇧-click
/// (range), ↑/↓ and ⇧↑/⇧↓, with the native selection fills. Space and Esc go to the owner, and ⌘A
/// and ⌘⌫ come from `StorageKeyCommands`, since menu key equivalents never reach `.onKeyPress`.
/// Not a `List`: that would nest a second scroll view inside the form's.
private struct StorageList<Entry: Identifiable, Row: View, Menu: View>: View where Entry.ID == UUID {
    let kind: StorageListKind
    let entries: [Entry]
    @Binding var selection: Set<UUID>
    let focus: FocusState<StorageListKind?>.Binding
    let onSpace: (KeyPress.Phases) -> KeyPress.Result
    let onEscape: () -> KeyPress.Result
    /// Called with the row the arrow keys moved to, to scroll it into view.
    let onMove: (UUID) -> Void
    @ViewBuilder let row: (Entry, StorageRowState) -> Row
    @ViewBuilder let menu: ([UUID]) -> Menu

    @Environment(\.appearsActive) private var appearsActive
    /// The fixed end of a ⇧-click or ⇧-arrow range.
    @State private var anchor: UUID?
    /// The row the arrow keys move from: the last one clicked or moved to.
    @State private var lead: UUID?

    /// How far a row's selection fill reaches past the form row's content edges.
    private static var inset: CGFloat { 6 }

    var body: some View {
        let ids = entries.map(\.id)
        let emphasized = focus.wrappedValue == kind && appearsActive
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                let selected = selection.contains(entry.id)
                let state = StorageRowState(isSelected: selected, isEmphasized: selected && emphasized,
                                            targets: targets(for: entry.id, in: ids))
                if index > 0 {
                    // Lined up with the text, and hidden beside a selected row, whose fill sets it apart.
                    Divider()
                        .padding(.leading, Self.inset + StorageRowIcon.size + 10)
                        .padding(.trailing, Self.inset)
                        .opacity(selected || selection.contains(ids[index - 1]) ? 0 : 1)
                }
                row(entry, state)
                    .padding(.horizontal, Self.inset)
                    .padding(.vertical, 5)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: emphasized ? .selectedContentBackgroundColor
                                                                : .unemphasizedSelectedContentBackgroundColor))
                        }
                    }
                    // On the accent fill `.primary` and `.secondary` turn white, as in a selected native row.
                    .environment(\.backgroundProminence, state.isEmphasized ? .increased : .standard)
                    .contentShape(.rect)
                    .onTapGesture { click(entry.id, in: ids) }
                    .contextMenu { menu(state.targets) }
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .id(entry.id)
            }
        }
        .padding(.horizontal, -Self.inset)
        .focusable(interactions: .edit)
        .focused(focus, equals: kind)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { move($0, in: ids) }
        .onKeyPress(.space, phases: [.down, .repeat, .up]) { onSpace($0.phase) }
        .onKeyPress(.escape) { onEscape() }
        // A deleted row, or one that dropped out of the list, leaves the selection.
        .onChange(of: ids) { _, ids in
            let shown = Set(ids)
            if !selection.isSubset(of: shown) { selection.formIntersection(shown) }
        }
    }

    private func click(_ id: UUID, in ids: [UUID]) {
        // The click's own modifiers (the mouse-up being handled), else the keyboard's right now.
        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else if flags.contains(.shift), let anchor, ids.contains(anchor) {
            selection = range(from: anchor, to: id, in: ids)
        } else {
            selection = [id]
            anchor = id
        }
        lead = id
        focus.wrappedValue = kind
    }

    /// ↑/↓ select the row above or below; with ⇧ they extend the selection from its anchor.
    private func move(_ press: KeyPress, in ids: [UUID]) -> KeyPress.Result {
        guard !ids.isEmpty else { return .ignored }
        let forward = press.key == .downArrow
        let from = lead.flatMap { selection.contains($0) ? ids.firstIndex(of: $0) : nil }
            ?? (forward ? ids.lastIndex(where: selection.contains) : ids.firstIndex(where: selection.contains))
        let index = from.map { min(max($0 + (forward ? 1 : -1), 0), ids.count - 1) } ?? (forward ? 0 : ids.count - 1)
        let id = ids[index]
        if press.modifiers.contains(.shift), let anchor, selection.contains(anchor) {
            selection = range(from: anchor, to: id, in: ids)
        } else {
            selection = [id]
            anchor = id
        }
        lead = id
        onMove(id)
        return .handled
    }

    private func range(from start: UUID, to end: UUID, in ids: [UUID]) -> Set<UUID> {
        guard let i = ids.firstIndex(of: start), let j = ids.firstIndex(of: end) else { return [end] }
        return Set(ids[min(i, j)...max(i, j)])
    }

    private func targets(for id: UUID, in ids: [UUID]) -> [UUID] {
        selection.contains(id) ? ids.filter(selection.contains) : [id]
    }
}

/// ⌘A and ⌘⌫ for the Storage lists. Menu key equivalents never reach `.onKeyPress`, so — like the
/// main window's `ListKeyCommands` — a local key-down monitor takes them, for this window only and
/// only when a handler returns true (a list has focus); otherwise the key goes on as usual.
private struct StorageKeyCommands: NSViewRepresentable {
    let selectAll: () -> Bool
    let delete: () -> Bool

    @MainActor final class Coordinator {
        var monitor: Any?
        var commands: StorageKeyCommands

        init(commands: StorageKeyCommands) {
            self.commands = commands
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(commands: self) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view, weak coordinator] event in
            // Exactly Command; ⌘A matched by character so it survives non-QWERTY layouts.
            guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command else { return event }
            let isSelectAll = event.charactersIgnoringModifiers?.lowercased() == "a"
            let isDelete = event.keyCode == 51   // 51 = Delete (⌫)
            guard isSelectAll || isDelete else { return event }
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let view, let coordinator, let window = view.window, event.window === window else { return false }
                return isSelectAll ? coordinator.commands.selectAll() : coordinator.commands.delete()
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

// MARK: - Rows

/// One row of either list: icon, title, a caption (orange when a file is missing), the space it
/// takes and a trash button.
private struct StorageRow<Icon: View>: View {
    let title: String
    let subtitle: String
    let warns: Bool
    let bytes: Int
    let state: StorageRowState
    /// The trash button's tooltip: "Delete", or "Delete 3 Items" when it deletes the selection.
    let deleteHelp: String
    let onDelete: () -> Void
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        HStack(spacing: 10) {
            icon()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(warns && !state.isEmphasized ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(byteString(bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(deleteHelp)
            .accessibilityLabel(deleteHelp)
        }
    }
}

/// A row's 28 pt icon: an image, or an SF Symbol on a tinted tile.
private struct StorageRowIcon: View {
    static let size: CGFloat = 28

    let image: NSImage?
    let symbol: String
    /// Cropped to fill the tile, for a thumbnail; a file icon is shown whole.
    var fills = false

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: fills ? .fill : .fit)
                .frame(width: Self.size, height: Self.size)
                .clipShape(.rect(cornerRadius: fills ? 5 : 0))
        } else {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: Self.size, height: Self.size)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 5))
        }
    }
}

/// One history item in Largest Items: its preview, kind, date and file status, and the space it takes.
private struct StorageItemRow: View {
    let item: ClipboardItem
    let usage: StorageReport.ItemUsage
    let state: StorageRowState
    let onDelete: () -> Void

    var body: some View {
        StorageRow(title: title, subtitle: subtitle, warns: usage.missingFileCount > 0, bytes: usage.bytes,
                   state: state, deleteHelp: deleteHelp, onDelete: onDelete) {
            StorageRowIcon(image: item.displayKind == .pdf ? nil : ThumbnailCache.image(for: item),
                           symbol: item.kindSymbol, fills: true)
        }
    }

    private var title: String {
        let preview = item.plainPreview.menuPreview(limit: 80)
        return preview.isEmpty ? item.kindLabel : preview
    }

    /// "File · 4 Nov 2026 at 10:02 · Kept copy" — a kept copy being one whose original was moved
    /// or deleted.
    private var subtitle: String {
        var parts = [item.kindLabel, item.createdAt.clipboardRowString]
        if usage.missingFileCount > 0 {
            parts.append(usage.missingFileCount == 1 ? String(localized: "File not found")
                                                     : String(localized: "\(usage.missingFileCount) files not found"))
        } else if usage.keptFileCount > 0 {
            parts.append(usage.keptFileCount == 1 ? String(localized: "Kept copy")
                                                  : String(localized: "\(usage.keptFileCount) kept copies"))
        }
        return parts.joined(separator: " · ")
    }

    private var deleteHelp: String {
        state.targets.count > 1 ? String(localized: "Delete \(state.targets.count) Items") : String(localized: "Delete")
    }
}

/// One row of Snippets: a file snippet's title, kind, folder, date and file status, and what its
/// content and files take. Its icon is the first file's thumbnail when it's an image (several
/// images included), else that file's Finder icon — never the generic multi-document one.
private struct StorageSnippetRow: View {
    let entry: SnippetEntry
    let state: StorageRowState
    let deleteHelp: String
    let onDelete: () -> Void

    @State private var thumbnail: NSImage?
    @Environment(\.displayScale) private var displayScale

    private var snippet: Snippet { entry.snippet }

    var body: some View {
        let urls = snippet.fileURLs
        let first = urls.first(where: ClipboardItem.fileExists)
        StorageRow(title: title, subtitle: subtitle, warns: entry.usage.missingFileCount > 0, bytes: entry.usage.bytes,
                   state: state, deleteHelp: deleteHelp, onDelete: onDelete) {
            // Folders get the symbol tile Largest Items shows for a folder, not Finder's folder icon.
            let kind = ClipboardKind.presenting(fileURLs: urls)
            StorageRowIcon(image: thumbnail ?? (kind == .folder ? nil : first.map { NSWorkspace.shared.icon(forFile: $0.path(percentEncoded: false)) }),
                           symbol: kind.symbol, fills: thumbnail != nil)
        }
        .task(id: thumbnailURL) {
            guard let url = thumbnailURL else { thumbnail = nil; return }
            thumbnail = await ThumbnailCache.fileImage(for: url, scale: displayScale)
        }
    }

    /// The first existing image file, for a thumbnail; PDFs and other files show their icon.
    private var thumbnailURL: URL? {
        snippet.fileURLs.first { url in
            guard ClipboardItem.fileExists(url) else { return false }
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
                ?? UTType(filenameExtension: url.pathExtension)
            return type?.conforms(to: .image) == true
        }
    }

    /// Its title, else its file names.
    private var title: String {
        if !snippet.title.isEmpty { return snippet.title }
        let preview = snippet.plainPreview.menuPreview(limit: 80)
        return preview.isEmpty ? String(localized: "Untitled") : preview
    }

    /// "Image · 📁 Work · 4 Nov 2026 at 10:02 · File not found".
    private var subtitle: String {
        var parts = [snippet.fileKindLabel]
        if let folder = snippet.folder { parts.append(folder.displayName) }
        parts.append(snippet.createdAt.clipboardRowString)
        let missing = entry.usage.missingFileCount
        if missing > 0 {
            parts.append(missing == 1 ? String(localized: "File not found") : String(localized: "\(missing) files not found"))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Measuring

/// What Simple Clipboard keeps on disk, measured off the main thread. File sizes are what only the
/// app's copies use (`DiskUsage.privateBytes`): a clone sharing its blocks with the original file,
/// or with another copy, counts only the blocks it doesn't share — what deleting it frees.
struct StorageReport: Sendable {
    /// One history item's share.
    struct ItemUsage: Sendable {
        /// Its content and thumbnail in the history store.
        var dataBytes = 0
        /// Its kept copies and files copied on other devices, counting only space they don't share.
        /// A copy another item includes too counts for each of them.
        var fileBytes = 0
        /// Files read from their kept copy, the original having been moved or deleted.
        var keptFileCount = 0
        /// Files gone with no copy kept.
        var missingFileCount = 0

        var bytes: Int { dataBytes + fileBytes }
    }

    /// One snippet's share: its content in the store, and its files in the snippet store counting
    /// only space they don't share.
    struct SnippetUsage: Sendable {
        var dataBytes = 0
        var fileBytes = 0
        /// Files gone: a stored copy deleted from outside the app, or an original referenced in place.
        var missingFileCount = 0

        var bytes: Int { dataBytes + fileBytes }
    }

    /// The history store: its database, SQLite's journal, and the large values SwiftData keeps beside it.
    var databaseBytes = 0
    /// `ClipboardItem.storedFilesDirectory`: kept copies and files copied on other devices.
    var fileStoreBytes = 0
    /// `Snippet.snippetFilesDirectory`.
    var snippetFilesBytes = 0
    /// Every snippet's content, title and preview: their part of `databaseBytes`.
    var snippetDataBytes = 0
    /// The store less the snippets' part: history's share of it (with the store's own overhead).
    var historyDatabaseBytes: Int { max(0, databaseBytes - snippetDataBytes) }
    var items: [UUID: ItemUsage] = [:]
    var snippets: [UUID: SnippetUsage] = [:]

    /// Files and folders in the file store — kept copies, each once however many items include it,
    /// and files copied on other devices.
    var storedFileCount = 0
    /// Files kept after their original was moved or deleted, each once.
    var keptFileCount = 0
    /// Items with a file that's gone with no copy kept.
    var missingItemCount: Int { items.values.filter { $0.missingFileCount > 0 }.count }

    /// One `.file` item's files, for measuring on the file cache's queue.
    private struct FileEntry: Sendable {
        let id: UUID
        let originals: [URL]
    }

    /// One file snippet's files.
    private struct SnippetFileEntry: Sendable {
        let id: UUID
        let urls: [URL]
    }

    @MainActor
    static func measure(items: [ClipboardItem], snippets: [Snippet], container: ModelContainer) async -> StorageReport {
        let ids = items.map(\.id)
        let fileEntries = items.filter { $0.kind == .file }
            .map { FileEntry(id: $0.id, originals: $0.fileURLs) }
        let snippetEntries = snippets.filter(\.isFile).map { SnippetFileEntry(id: $0.id, urls: $0.fileURLs) }
        // Snippets are few and small, and already loaded: measured here.
        let snippetSizes = snippets.map { ($0.id, $0.payload.count + $0.title.utf8.count + $0.plainPreview.utf8.count) }
        let dataSizes = await PayloadSizes.sizes(of: ids, in: container)
        // On the cache's queue, so pending clones and refreshes are done first.
        var report = await HistoryFileCache.perform { measureFiles(fileEntries, snippets: snippetEntries) }
        for id in ids { report.items[id, default: ItemUsage()].dataBytes = dataSizes[id] ?? 0 }
        for (id, bytes) in snippetSizes {
            report.snippets[id, default: SnippetUsage()].dataBytes = bytes
            report.snippetDataBytes += bytes
        }
        return report
    }

    private static func measureFiles(_ entries: [FileEntry], snippets: [SnippetFileEntry]) -> StorageReport {
        var report = StorageReport()
        let store = ClipboardItem.storedFilesDirectory
        report.fileStoreBytes = DiskUsage.privateBytes(store)
        report.snippetFilesBytes = DiskUsage.privateBytes(Snippet.snippetFilesDirectory)
        let storeURL = AppModel.storeURL
        let support = storeURL.deletingLastPathComponent()
            .appending(path: "." + storeURL.deletingPathExtension().lastPathComponent + "_SUPPORT", directoryHint: .isDirectory)
        report.databaseBytes = ["", "-wal", "-shm"]
            .map { DiskUsage.allocatedBytes(URL(filePath: storeURL.path(percentEncoded: false) + $0)) }
            .reduce(DiskUsage.allocatedBytes(support), +)

        var remoteFiles: Set<String> = []   // files copied on other devices
        var goneWithCopy: Set<String> = []  // originals gone, read from their copy
        for entry in entries {
            var usage = ItemUsage()
            for original in entry.originals {
                if ClipboardItem.isStoredFile(original) {   // copied on another device: the store's copy is the file
                    if ClipboardItem.fileExists(original) {
                        usage.fileBytes += DiskUsage.privateBytes(original)
                        remoteFiles.insert(original.standardizedFileURL.path(percentEncoded: false))
                    } else {
                        usage.missingFileCount += 1
                    }
                    continue
                }
                // Its own copy, or the one inside a kept folder holding it.
                let copy = HistoryFileCache.keptCopy(of: original)
                if let copy { usage.fileBytes += DiskUsage.privateBytes(copy) }
                if !ClipboardItem.fileExists(original) {
                    if copy != nil {
                        usage.keptFileCount += 1
                        goneWithCopy.insert(HistoryFileCache.normalizedPath(original))
                    } else {
                        usage.missingFileCount += 1
                    }
                }
            }
            report.items[entry.id] = usage
        }
        report.storedFileCount = HistoryFileCache.keptCopyCount() + remoteFiles.count
        report.keptFileCount = goneWithCopy.count

        for entry in snippets {
            var usage = SnippetUsage()
            for url in entry.urls {
                guard ClipboardItem.fileExists(url) else {
                    usage.missingFileCount += 1
                    continue
                }
                // An original referenced in place isn't the app's to count.
                if Snippet.isManagedFileCopy(url) { usage.fileBytes += DiskUsage.privateBytes(url) }
            }
            report.snippets[entry.id] = usage
        }
        return report
    }
}

/// Each history item's content and thumbnail size in the store, remembered for the app's life (an
/// item's content never changes). Measured on a background context a few items at a time: reading
/// the size loads the content, and a context keeps what it loaded until it goes away.
@MainActor
private enum PayloadSizes {
    private static var known: [UUID: Int] = [:]

    static func sizes(of ids: [UUID], in container: ModelContainer) async -> [UUID: Int] {
        let unknown = ids.filter { known[$0] == nil }
        if !unknown.isEmpty {
            let measured = await Task.detached(priority: .utility) { measure(unknown, in: container) }.value
            known.merge(measured) { $1 }
        }
        return known
    }

    nonisolated private static func measure(_ ids: [UUID], in container: ModelContainer) -> [UUID: Int] {
        var sizes: [UUID: Int] = [:]
        for start in stride(from: 0, to: ids.count, by: 8) {
            let chunk = Array(ids[start..<min(start + 8, ids.count)])
            autoreleasepool {
                let context = ModelContext(container)
                let descriptor = FetchDescriptor<ClipboardItem>(predicate: #Predicate { chunk.contains($0.id) })
                for item in (try? context.fetch(descriptor)) ?? [] {
                    sizes[item.id] = item.payload.count + (item.thumbnail?.count ?? 0)
                }
            }
        }
        return sizes
    }
}

/// Disk space of files and folders.
enum DiskUsage {
    /// Bytes on disk only this file — or everything in this folder — uses: blocks it shares with a
    /// clone aren't counted (APFS's private size), so it's what deleting it frees. 0 when it's gone.
    static func privateBytes(_ url: URL) -> Int {
        sum(over: url) { privateSize(atPath: $0.path(percentEncoded: false)) }
    }

    /// Bytes allocated on disk for this file or everything in this folder, shared or not.
    static func allocatedBytes(_ url: URL) -> Int {
        sum(over: url) { (try? $0.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0 }
    }

    private static func sum(over url: URL, _ size: (URL) -> Int) -> Int {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else { return 0 }
        guard values.isDirectory == true else { return size(url) }
        guard let entries = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        var total = 0
        for case let entry as URL in entries
        where (try? entry.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            total += size(entry)
        }
        return total
    }

    /// `ATTR_CMNEXT_PRIVATESIZE` through `getattrlist`; 0 when unavailable.
    private static func privateSize(atPath path: String) -> Int {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        // u_int32_t length, then the off_t.
        var buffer = [UInt8](repeating: 0, count: 32)
        let options = UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)
        guard getattrlist(path, &request, &buffer, buffer.count, options) == 0 else { return 0 }
        return Int(buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: MemoryLayout<UInt32>.size, as: Int64.self) })
    }
}
