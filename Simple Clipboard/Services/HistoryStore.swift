import AppKit
import SwiftData

/// Owns inserts/dedupe/pruning of the clipboard history (CLAUDE.md §8c–e). Holds the
/// SwiftData main context; views read the store directly via `@Query`.
@MainActor
@Observable
final class HistoryStore {
    private let context: ModelContext
    private let copySound: CopySound

    /// How far back capture dedupe looks: an identical item within the top N is bumped
    /// rather than duplicated; identical items older than this are kept (§8c).
    private static let dedupeWindow = 10

    init(context: ModelContext, copySound: CopySound) {
        self.context = context
        self.copySound = copySound
    }

    var itemCount: Int {
        (try? context.fetchCount(FetchDescriptor<ClipboardItem>())) ?? 0
    }

    /// Most-recent items, newest first.
    func recentItems(limit: Int? = nil) -> [ClipboardItem] {
        var desc = FetchDescriptor<ClipboardItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        if let limit { desc.fetchLimit = limit }
        return (try? context.fetch(desc)) ?? []
    }

    /// Capture a freshly-read pasteboard snapshot (§8c–d).
    func capture(_ content: ClipboardContent, from app: NSRunningApplication?) {
        if let bid = app?.bundleIdentifier, Pref.ignoredAppBundleIDs.contains(bid) { return }

        let sizeLimit = Pref.ignoreLargerThanBytes
        if sizeLimit > 0, content.payload.count > sizeLimit { return }

        // Past the ignore/size guards, every branch below captures — a fresh insert or a
        // dedupe/twin bump to the top — so this is exactly "an external ⌘C landed in history":
        // play the copy sound (§13). Ignored apps, oversized payloads and unreadable pasteboards
        // returned earlier (the last in `ClipboardMonitor.poll`), so they stay silent. Internal
        // copies never reach here — `PasteService` suppresses the monitor via `acknowledgeChange`
        // and plays the same sound itself — so a copy is never announced twice.
        copySound.play()

        let recent = recentItems(limit: Self.dedupeWindow)

        // Dedupe against the most-recent items, not just the top: if an identical capture
        // already exists within the last `dedupeWindow` items (e.g. the user re-copied the
        // same text a few items ago), bump it to "now" — moving it back to the top instead
        // of duplicating. Older identical items beyond the window are left alone (§8c).
        if let existing = recent.first(where: { $0.kind == content.kind && $0.payload == content.payload }) {
            existing.createdAt = .now
            save()
            return
        }

        // Plain/rich tie-break (§8c): a plain-text and a rich-text capture with the same
        // visible text are treated as one entry — keep the *rich* version. If the new
        // capture is plain text but a rich-text twin already exists, drop the plain one and
        // bump the rich; if the new capture is rich text, supersede the stored plain twin.
        if content.kind == .plainText || content.kind == .richText,
           let twin = recent.first(where: {
               ($0.kind == .plainText || $0.kind == .richText)
                   && $0.kind != content.kind
                   && $0.plainPreview == content.plainPreview
           }) {
            if content.kind == .plainText {
                twin.createdAt = .now   // incoming plain text is redundant with the rich twin
                save()
                return
            }
            context.delete(twin)        // incoming rich text supersedes the stored plain twin
        }

        context.insert(ClipboardItem(
            content: content,
            sourceBundleID: app?.bundleIdentifier,
            sourceAppName: app?.localizedName
        ))
        prune()
        save()
    }

    /// Move an existing item to the top (used when an item is re-selected/copied).
    func touch(_ item: ClipboardItem) {
        item.createdAt = .now
        save()
    }

    func delete(_ item: ClipboardItem) {
        context.delete(item)
        save()
    }

    func clear() {
        try? context.delete(model: ClipboardItem.self)
        save()
    }

    /// Enforce the history-size cap, deleting the oldest beyond it (§8d).
    func prune() {
        let cap = max(1, Pref.historySize)
        let all = recentItems()
        guard all.count > cap else { return }
        for item in all[cap...] { context.delete(item) }
    }

    private func save() {
        do { try context.save() } catch { NSLog("HistoryStore save failed: \(error)") }
    }
}
