import AppKit
import SwiftData

/// Owns inserts/dedupe/pruning of the clipboard history. Holds the
/// SwiftData main context; views read the store directly via `@Query`.
@MainActor
@Observable
final class HistoryStore {
    private let context: ModelContext
    private let copySound: CopySound

    /// How far back capture dedupe looks for kinds other than text and files: an identical item
    /// within the top N is bumped rather than duplicated; identical items older than this are
    /// kept. Text and files look through the whole history instead (`itemsMatching`).
    private static let dedupeWindow = 10

    /// The number of stored items, refreshed after every save below (all history mutations go
    /// through this store), so the sidebar badge can observe a count instead of holding a
    /// full-history `@Query` that refetches every row on each capture.
    private(set) var itemCount = 0

    init(context: ModelContext, copySound: CopySound) {
        self.context = context
        self.copySound = copySound
        refreshItemCount()
    }

    /// Most-recent items, newest first.
    func recentItems(limit: Int? = nil) -> [ClipboardItem] {
        var desc = FetchDescriptor<ClipboardItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        if let limit { desc.fetchLimit = limit }
        return (try? context.fetch(desc)) ?? []
    }

    /// Whether capture dedupes `kind` against the whole history rather than the recent window.
    private static func dedupesWholeHistory(_ kind: ClipboardKind) -> Bool {
        switch kind {
        case .plainText, .code, .richText, .file: true
        default: false
        }
    }

    /// Items of `kind` with exactly this preview, newest first. A SQL predicate on two plain
    /// columns, so the (possibly large, externally stored) payloads of every other row stay unread;
    /// callers then compare payloads or files on these few candidates only.
    private func itemsMatching(kind: ClipboardKind, preview: String) -> [ClipboardItem] {
        let raw = kind.rawValue
        let desc = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.typeRaw == raw && $0.plainPreview == preview },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return (try? context.fetch(desc)) ?? []
    }

    /// Capture a freshly-read pasteboard snapshot, credited to the given source app.
    /// Copies from ignored apps never get here: `ClipboardMonitor.poll` drops them before reading
    /// the pasteboard.
    func capture(_ content: ClipboardContent, sourceBundleID: String?, sourceAppName: String?) {
        let sizeLimit = Pref.ignoreLargerThanBytes
        if sizeLimit > 0, content.payload.count > sizeLimit { return }

        // Past the size guard, every branch below captures — a fresh insert or a dedupe/twin
        // bump to the top — so this is exactly "an external ⌘C landed in history": play the copy
        // sound. Ignored apps, unreadable pasteboards and oversized images/PDFs returned
        // earlier (in `ClipboardMonitor.poll`), and oversized payloads just above, so they stay
        // silent. Internal copies never reach here — `PasteService` suppresses the monitor via
        // `acknowledgeChange` and plays the same sound itself — so a copy is never announced twice.
        copySound.play()

        // Text and files are compared against the whole history (at most `Pref.historySize`, so
        // ≤ 1000 rows), but only against rows with the same kind and preview — the store filters
        // those in SQL, so no other row's payload is loaded. Other kinds keep the short window.
        let wide = Self.dedupesWholeHistory(content.kind)
        let recent = wide
            ? itemsMatching(kind: content.kind, preview: content.plainPreview)
            : recentItems(limit: Self.dedupeWindow)

        // Dedupe against earlier items, not just the top: if an identical capture already
        // exists (e.g. the user re-copied the same text a while ago), bump it to "now" — moving
        // it back to the top instead of duplicating.
        if let existing = recent.first(where: { $0.kind == content.kind && $0.payload == content.payload }) {
            // Same bytes copied from another file (or the same file, moved): remember the latest.
            if let source = content.sourceFileURL { existing.sourceFileURLRaw = source.absoluteString }
            bump(existing, sourceBundleID: sourceBundleID, sourceAppName: sourceAppName)
            if existing.kind == .file { updateKeptFiles(keeping: [existing]) }   // the files as they are now
            return
        }

        // The same file(s) copied from somewhere else have another payload: a copy made on an
        // iPhone/iPad is stored as a fresh copy each time (`ClipboardItem.storeCopy`), and the same
        // file copied on this Mac — or from another folder — references its own location. Compare
        // the files themselves (same names *and* same bytes, so a file that only shares a name is a
        // new entry) within the same window, and let the latest copy supersede the older entry.
        if content.kind == .file {
            let urls = ClipboardItem.fileURLs(fromPayload: content.payload)
            if let existing = recent.first(where: {
                $0.kind == .file && $0.plainPreview == content.plainPreview && $0.hasSameFiles(as: urls)
            }) {   // `recent` is already narrowed to the same names; only now are the bytes read
                existing.deleteStoredFiles()
                context.delete(existing)
            }
        }

        // Plain/rich tie-break: a plain-text and a rich-text capture with the same
        // visible text are treated as one entry — keep the *rich* version. If the new
        // capture is plain text but a rich-text twin already exists, drop the plain one and
        // bump the rich; if the new capture is rich text, supersede the stored plain twin.
        if content.kind == .plainText || content.kind == .richText,
           let twin = itemsMatching(kind: content.kind == .plainText ? .richText : .plainText,
                                    preview: content.plainPreview).first {
            if content.kind == .plainText {
                // incoming plain text is redundant with the rich twin
                bump(twin, sourceBundleID: sourceBundleID, sourceAppName: sourceAppName)
                return
            }
            context.delete(twin)        // incoming rich text supersedes the stored plain twin
        }

        let item = ClipboardItem(
            content: content,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName
        )
        context.insert(item)
        save()    // before pruning, whose overflow fetch only sees saved rows
        let prunedFiles = pruneOverflow()
        // After pruning, so the cache sees history as it now is. Also tidies what a superseded or
        // pruned item's files leave behind.
        if item.kind == .file || prunedFiles { updateKeptFiles(keeping: [item]) }
    }

    /// Brings the file cache (`HistoryFileCache`) in line with history, in the background: keeps a
    /// copy of `newItems`' files, so they still preview and paste once they're moved or deleted
    /// (unless Settings › Storage turned that off), and drops the copies no item needs any more.
    /// Called after every change to the `.file` items in history.
    private func updateKeptFiles(keeping newItems: [ClipboardItem] = [], refreshing: Bool = false) {
        let keepsCopies = Pref.keepCopiedFiles
        let newIDs = keepsCopies ? Set(newItems.filter { $0.kind == .file }.map(\.id)) : []
        let limit = Pref.ignoreLargerThanBytes
        HistoryFileCache.update(fileItems().map { .init(id: $0.id, originals: $0.fileURLs) },
                                keepingFilesOf: newIDs, keepsCopies: keepsCopies, refreshing: refreshing,
                                sizeLimit: limit > 0 ? limit : .max,
                                snippetFiles: newIDs.isEmpty ? [] : snippetFileURLs())
    }

    /// The files file snippets store — where a file `HistoryFileCache` can't clone may already be.
    private func snippetFileURLs() -> [URL] {
        let snippets = (try? context.fetch(FetchDescriptor<Snippet>(predicate: #Predicate { $0.isFile }))) ?? []
        return snippets.flatMap(\.fileURLs)
    }

    /// Moves `item` — the same content as a new capture — back to the top instead of storing a
    /// duplicate, credited to the app of that latest copy.
    private func bump(_ item: ClipboardItem, sourceBundleID: String?, sourceAppName: String?) {
        item.createdAt = .now
        item.sourceBundleID = sourceBundleID
        item.sourceAppName = sourceAppName
        save()
    }

    /// Move an existing item to the top (used when an item is re-selected/copied).
    func touch(_ item: ClipboardItem) {
        item.createdAt = .now
        save()
    }

    func delete(_ item: ClipboardItem) {
        delete([item])
    }

    /// Deletes several items with one save — the main window's multi-selection ⌘⌫.
    func delete(_ items: [ClipboardItem]) {
        let hadFiles = items.contains { $0.kind == .file }
        for item in items {
            item.deleteStoredFiles()
            context.delete(item)
        }
        save()
        if hadFiles { updateKeptFiles() }   // their copies, unless another item has the same files
    }

    func clear() {
        try? context.delete(model: ClipboardItem.self)
        save()
        HistoryFileCache.discardAll()
    }

    /// Clear History from the panel, the menu bar and the hotkey: asks with a native alert first,
    /// unless history is already empty or the alert's "Don’t ask again" (recorded only on Clear)
    /// turned `confirmBeforeClearingHistory` off — Settings › General turns it back on.
    /// `beforeAsking` runs only when the alert is about to show (the panel hides itself so its
    /// light-dismiss monitors don't fight the modal). The sidebar asks with its own sheet.
    func clearAfterConfirming(beforeAsking: () -> Void = {}) {
        guard Pref.confirmBeforeClearingHistory, itemCount > 0 else { return clear() }
        beforeAsking()
        let alert = NSAlert()
        alert.messageText = String(localized: "Clear Clipboard History?")
        alert.informativeText = String(localized: "This permanently removes all saved clipboard items. This can’t be undone.")
        alert.alertStyle = .warning
        let clearButton = alert.addButton(withTitle: String(localized: "Clear History"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        clearButton.hasDestructiveAction = true
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don’t ask again")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if alert.suppressionButton?.state == .on { Pref.confirmBeforeClearingHistory = false }
        clear()
    }

    /// Drops stored file copies whose item is gone (`ClipboardItem.storedFilesDirectory`). Run once
    /// at launch; while running, every deletion above takes its item's copies with it.
    func deleteUnreferencedStoredFiles() {
        ClipboardItem.deleteUnreferencedStoredFiles(keeping: fileItems())
    }

    /// The `.file` items, newest first.
    func fileItems() -> [ClipboardItem] {
        let file = ClipboardKind.file.rawValue
        let descriptor = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.typeRaw == file },
                                                        sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: File cache (Settings › Storage)

    private var keptFilesTimer: Timer?

    /// Keeps the copies of copied files (`HistoryFileCache`) in step with their originals: now, and
    /// every half hour while the app runs. Called once at launch, where it also moves copies kept
    /// before they were shared into the shared store. The first launch with the file cache also
    /// keeps the files of the items already in history.
    func startRefreshingKeptFiles() {
        var earlierItems: [ClipboardItem] = []
        if !Pref.didKeepEarlierCopiedFiles {
            Pref.didKeepEarlierCopiedFiles = true
            earlierItems = fileItems()
        }
        updateKeptFiles(keeping: earlierItems, refreshing: true)
        guard keptFilesTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshKeptFiles() }
        }
        timer.tolerance = 5 * 60
        keptFilesTimer = timer
    }

    /// Re-clones kept copies whose original was edited or saved over since it was copied, so an old
    /// version never takes up space while the original is still there, and tidies the cache.
    func refreshKeptFiles() {
        updateKeptFiles(refreshing: true)
    }

    /// Settings › Storage's "Keep copies of copied files" changed: turned on, keeps the files of the
    /// items in history now; turned off, drops the copies of files still where they were copied
    /// from (those of files gone since stay, as their items need them).
    func keepCopiedFilesChanged() {
        updateKeptFiles(keeping: Pref.keepCopiedFiles ? fileItems() : [])
    }

    /// Items with a file that's gone with no copy kept: it no longer previews or pastes.
    func itemsWithMissingFiles() -> [ClipboardItem] {
        fileItems().filter { item in item.availableFileURLs.contains { !ClipboardItem.fileExists($0) } }
    }

    /// Enforce the history-size cap, deleting the oldest beyond it, and tidy the file cache
    /// after any file items that went.
    func prune() {
        if pruneOverflow() { updateKeptFiles() }
    }

    /// Deletes the items beyond the history-size cap; true when any were `.file` items. Fetches only
    /// the overflow (`fetchOffset`) rather than materializing every item (~55 ms at 1000 items). The
    /// store applies that offset to saved rows — unsaved inserts come back merged into the
    /// result — so callers save first, and anything still unsaved is never treated as overflow.
    private func pruneOverflow() -> Bool {
        var overflow = FetchDescriptor<ClipboardItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        overflow.fetchOffset = max(1, Pref.historySize)
        let unsaved = Set(context.insertedModelsArray.map(\.persistentModelID))
        let doomed = ((try? context.fetch(overflow)) ?? []).filter { !unsaved.contains($0.persistentModelID) }
        guard !doomed.isEmpty else { return false }
        let hadFiles = doomed.contains { $0.kind == .file }
        for item in doomed {
            item.deleteStoredFiles()
            context.delete(item)
        }
        save()
        return hadFiles
    }

    private func save() {
        do { try context.save() } catch { NSLog("HistoryStore save failed: \(error)") }
        refreshItemCount()
    }

    private func refreshItemCount() {
        let count = (try? context.fetchCount(FetchDescriptor<ClipboardItem>())) ?? 0
        if count != itemCount { itemCount = count }   // unchanged → no observer churn
    }
}
