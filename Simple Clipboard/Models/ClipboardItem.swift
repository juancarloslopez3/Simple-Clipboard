import CryptoKit
import Foundation
import SwiftData
import UniformTypeIdentifiers

/// One captured pasteboard entry. The type is stored as a raw string
/// (`typeRaw`) so it can be used in `@Query` predicates; `kind` is the typed accessor.
@Model
final class ClipboardItem {
    var id: UUID = UUID()
    var typeRaw: String = ClipboardKind.plainText.rawValue
    /// Encoded payload per `kind` — see `ClipboardContent`.
    @Attribute(.externalStorage) var payload: Data = Data()
    /// UTType identifier of the payload's format, for `.image` items (e.g. `public.jpeg`) so
    /// paste can reproduce the original type. `nil` for other kinds and legacy PNG-only images.
    var payloadTypeRaw: String?
    /// For an `.image` captured from a copied image file, where that file was (a file-URL string),
    /// so saving it as a snippet can clone the file instead of writing the bytes out again.
    /// `nil` for other items and for images captured before this existed.
    var sourceFileURLRaw: String?
    var plainPreview: String = ""
    @Attribute(.externalStorage) var thumbnail: Data?
    var sourceBundleID: String?
    var sourceAppName: String?
    var createdAt: Date = Date.now

    var kind: ClipboardKind {
        get { ClipboardKind(rawValue: typeRaw) ?? .plainText }
        set { typeRaw = newValue.rawValue }
    }

    /// The payload's format type (for `.image` items), or `nil` for other kinds / legacy items.
    var payloadType: UTType? {
        payloadTypeRaw.flatMap(UTType.init(_:))
    }

    /// Where this image's file was when captured (`sourceFileURLRaw`). The file may have moved or
    /// changed since, so check it against `payload` before relying on it.
    var sourceFileURL: URL? {
        sourceFileURLRaw.flatMap(URL.init(string:))
    }

    /// The file URLs of a `.file` item, decoded from the newline-joined payload.
    /// Empty for other kinds (or an unreadable payload).
    var fileURLs: [URL] {
        kind == .file ? Self.fileURLs(fromPayload: payload) : []
    }

    /// The preview history rows show. An item holding several files lists their names one per line,
    /// the first three then "…"; anything else is `plainPreview`. Worked out here rather than stored
    /// because capture compares `plainPreview` against earlier items to spot repeat copies, and
    /// search reads it.
    var rowPreview: String {
        let urls = fileURLs
        return urls.count > 1 ? Self.fileNamesPreview(urls) : plainPreview
    }

    /// What this item's file-count badge says (`[URL].fileBadgeCount`): a copied folder counts the
    /// items inside it, read from the copy kept of it once it's gone, plus one per other file. Nil for
    /// a single file and for other kinds.
    var fileBadgeCount: Int? {
        let urls = fileURLs
        guard urls.contains(where: \.isFolder) else { return urls.count > 1 ? urls.count : nil }
        return availableFileURLs.fileBadgeCount
    }

    /// Lines `rowPreview` takes for a text-style row: one more than the usual three when it ends in "…".
    var rowPreviewLineLimit: Int {
        Self.fileNamesLineLimit(fileCount: fileURLs.count)
    }

    /// Several files' names, one per line: the first three, then "…". How history rows and file
    /// snippets list a multi-file entry.
    static func fileNamesPreview(_ urls: [URL]) -> String {
        let names = urls.prefix(fileNamesLimit).map { $0.lastPathComponent.isEmpty ? $0.path : $0.lastPathComponent }
        return (urls.count > fileNamesLimit ? names + ["…"] : names).joined(separator: "\n")
    }

    /// Lines `fileNamesPreview` takes: one more than the usual three when it ends in "…".
    static func fileNamesLineLimit(fileCount: Int) -> Int {
        fileCount > fileNamesLimit ? fileNamesLimit + 1 : fileNamesLimit
    }

    private static let fileNamesLimit = 3

    /// Decodes a `.file` payload (newline-joined file URLs) — also for a `ClipboardContent` not yet stored.
    static func fileURLs(fromPayload payload: Data) -> [URL] {
        guard let s = String(data: payload, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap { URL(string: String($0)) }
    }

    /// The kind this item *presents* as. Capture keeps copied files `.file` for Finder-paste
    /// semantics, but a `.file` item whose files are all PDFs or all images
    /// presents as `.pdf` / `.image`: those filters match it and rows label it that way. One whose
    /// files are all folders presents as `.folder` ("Folder", a folder glyph) and stays under the
    /// File filter. For a `.file` item this decodes the file list and looks up each type, so a row
    /// resolves it once per render and reads `.symbol` / `.label(fileCount:)` off the result.
    var displayKind: ClipboardKind {
        kind == .file ? ClipboardKind.presenting(fileURLs: fileURLs) : kind
    }

    /// Kind label for display: follows `displayKind`, plural for several files ("Images").
    var kindLabel: String { displayKind.label(fileCount: fileURLs.count) }

    /// Kind symbol for display, matching `kindLabel`.
    var kindSymbol: String { displayKind.symbol }

    /// Whether this item *presents* as a PDF — a `.pdf` capture or a PDF `.file` item
    /// whose files are all PDFs. The PDF filter matches these and the panel suppresses their
    /// large inline thumbnail preview so PDF rows stay compact glyph rows.
    var presentsAsPDF: Bool { displayKind == .pdf }

    init(
        kind: ClipboardKind,
        payload: Data,
        payloadTypeRaw: String? = nil,
        plainPreview: String,
        thumbnail: Data? = nil,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = UUID()
        self.typeRaw = kind.rawValue
        self.payload = payload
        self.payloadTypeRaw = payloadTypeRaw
        self.plainPreview = plainPreview
        self.thumbnail = thumbnail
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.createdAt = createdAt
    }

    convenience init(content: ClipboardContent, sourceBundleID: String?, sourceAppName: String?) {
        self.init(
            kind: content.kind,
            payload: content.payload,
            payloadTypeRaw: content.payloadType?.identifier,
            plainPreview: content.plainPreview,
            thumbnail: content.thumbnail,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName
        )
        self.sourceFileURLRaw = content.sourceFileURL?.absoluteString
    }
}

// MARK: - Stored copies of files from other devices

extension ClipboardItem {
    /// Where a `.file` item keeps its own copies of files copied on another device. Universal
    /// Clipboard delivers those into a system folder and deletes them on the next remote copy, so
    /// the item references a copy here instead — one UUID subdirectory per file, so equal names
    /// never collide. `HistoryStore` deletes an item's copies along with it.
    static var storedFilesDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: "SimpleClipboard", directoryHint: .isDirectory)
            .appending(path: "HistoryFiles", directoryHint: .isDirectory)
    }

    /// Copies `source` (a file or folder) into `storedFilesDirectory`, keeping its name, and returns
    /// the copy — or nil on failure. On APFS the copy is a clone: instant, and no extra space.
    static func storeCopy(of source: URL) -> URL? {
        let dir = storedFilesDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let copy = dir.appending(path: source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: copy)
            return copy
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
    }

    /// The store's top-level folder holding `url`, when `url` is in the store.
    private static func storeFolder(of url: URL) -> String? {
        // `.path(percentEncoded:)` keeps a directory URL's trailing slash; normalize before comparing.
        var root = storedFilesDirectory.standardizedFileURL.path(percentEncoded: false)
        while root.hasSuffix("/") { root.removeLast() }
        let path = url.standardizedFileURL.path(percentEncoded: false)
        guard path.hasPrefix(root + "/"), let folder = path.dropFirst(root.count + 1).split(separator: "/").first else { return nil }
        return String(folder)
    }

    /// The UUID subdirectory holding `url`, when `url` is one of the copies of files from other
    /// devices. Never the kept copies' folder, which no single item owns.
    private static func storedCopyFolder(of url: URL) -> URL? {
        guard let folder = storeFolder(of: url), folder != HistoryFileCache.keptFolderName else { return nil }
        return storedFilesDirectory.appending(path: folder, directoryHint: .isDirectory)
    }

    /// Deletes the stored copies among `urls`.
    static func deleteStoredFiles(at urls: [URL]) {
        for folder in urls.compactMap(storedCopyFolder) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Deletes the copies of files from other devices this item references — none for most items.
    /// Its kept copies (`HistoryFileCache`) may be other items' too: `HistoryStore` has the cache
    /// drop the ones no item needs once the item is gone.
    func deleteStoredFiles() {
        guard kind == .file else { return }
        Self.deleteStoredFiles(at: fileURLs)
    }

    /// Whether this item's files are the same files as `urls`, wherever either copy lives: same names,
    /// in order, and byte-for-byte the same contents (a folder compares everything inside it). The same
    /// file copied on an iPhone/iPad and on this Mac has two different payloads (a stored copy vs the
    /// original's location), so this is how capture recognizes it. A file that's gone is compared by
    /// the copy kept of it (`availableFileURLs`); same name with other contents — or a file that's gone
    /// with no copy — is a different file.
    func hasSameFiles(as urls: [URL]) -> Bool {
        let mine = availableFileURLs
        guard !mine.isEmpty, mine.count == urls.count else { return false }
        return zip(mine, urls).allSatisfy { stored, new in
            stored.lastPathComponent == new.lastPathComponent
                && FileManager.default.contentsEqual(atPath: stored.path(percentEncoded: false),
                                                     andPath: new.path(percentEncoded: false))
        }
    }

    /// Deletes stored copies no item in `items` references — left behind by a crash between copy and
    /// save, or by the store reset in `AppModel.makeContainer`. The kept copies' folder stays (the
    /// cache tidies it itself), and so do the per-item folders kept copies lived in before they were
    /// shared, named by item id, until the cache moves them in.
    static func deleteUnreferencedStoredFiles(keeping items: [ClipboardItem]) {
        let referenced = Set(items.flatMap(\.fileURLs).compactMap { storedCopyFolder(of: $0)?.lastPathComponent })
            .union(items.map(\.id.uuidString))
            .union([HistoryFileCache.keptFolderName])
        HistoryFileCache.sweep(keeping: referenced)
    }
}

// MARK: - Kept copies of copied files (Settings › Storage)

extension ClipboardItem {
    /// Where each of this item's files can be read now: the original while it's still there, else
    /// the copy kept of it (`HistoryFileCache`), so a moved or deleted file still previews and
    /// pastes. A file with neither stays its original, shown as missing. Text forms (Copy Path, the
    /// paths pasted into text fields) keep using `fileURLs`, where the user copied from.
    var availableFileURLs: [URL] {
        fileURLs.map { url in
            guard !Self.fileExists(url), !Self.isStoredFile(url) else { return url }
            return HistoryFileCache.keptCopy(of: url) ?? url
        }
    }

    /// Whether `url` is in the history's file store — a kept copy, or a file copied on another
    /// device. `PasteService` pastes those as throwaway clones, so Finder's "Move Item Here"
    /// (⌥⌘V) can't move them out of the store.
    static func isStoredFile(_ url: URL) -> Bool {
        storeFolder(of: url) != nil
    }

    static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }
}

/// Keeps a copy of the files copied to the clipboard, so a history item still previews and pastes
/// after its original is moved or deleted, until the item leaves history: pruned past the history
/// size, deleted, or cleared. Settings › Storage shows what the copies use.
///
/// Each file is kept once, however many items include it: copies are keyed by the original's path
/// (`Kept/<key>/<name>`), and a file inside a kept folder is read from that folder's copy instead of
/// getting its own. Every change to history runs `update`, which tidies the cache on its own: it
/// deletes the copies no item needs any more (moving out of a folder's copy what an item still
/// needs first), merges a file's copy into a kept folder's copy holding the same file, and, with
/// keeping turned off, drops the copies of files still where they were copied from.
///
/// The copies are APFS clones (`clonefile`): instant, and sharing the original's disk blocks, so a
/// copy uses no space of its own until the original is deleted or changed. A snippet's copy of a
/// file is a clone too (`Snippet.storeManagedFileCopy`), and clones of clones share the same blocks.
/// A file on another volume can't be cloned: it's kept by cloning a snippet's copy of the same file
/// when there is one, and otherwise isn't kept (it comes back with its drive). Items over the
/// "Ignore items larger than" limit aren't kept either, nor folders with over `folderEntryLimit`
/// entries, whose clone takes an inode per entry.
///
/// A copy follows its original while that's still there: a refresh re-clones copies whose original
/// was edited or saved over since, so an old version never holds disk space the original no longer
/// shares. All file work runs in order on one serial queue, so an update queued after another runs
/// after it, and a big folder's clone never holds up the main thread.
enum HistoryFileCache {
    /// One history item's files.
    struct Entry: Sendable {
        let id: UUID
        let originals: [URL]
    }

    /// The kept copies' folder inside `ClipboardItem.storedFilesDirectory`, beside the copies of
    /// files from other devices (UUID-named folders).
    static let keptFolderName = "Kept"

    /// Where kept copies live: one folder per kept file or folder, named by `key(for:)` of its
    /// original's path, holding the copy under the original's name (Finder pastes it under that name).
    static var keptDirectory: URL {
        ClipboardItem.storedFilesDirectory.appending(path: keptFolderName, directoryHint: .isDirectory)
    }

    private static let queue = DispatchQueue(label: "com.simpleclipboard.history-file-cache", qos: .utility)

    /// Folders with more entries than this aren't kept.
    static let folderEntryLimit = 10_000

    // MARK: Finding a copy (any thread)

    /// The copy standing in for `original`: its own, else the one inside the nearest kept folder
    /// holding it. Nil when there's none.
    static func keptCopy(of original: URL) -> URL? {
        let hint: URL.DirectoryHint = original.hasDirectoryPath ? .isDirectory : .notDirectory
        for (folder, relative) in ancestors(of: normalizedPath(original)) {
            let copy = location(of: relative, inCopyOf: folder, hint: hint)
            if ClipboardItem.fileExists(copy) { return copy }
        }
        return nil
    }

    /// How many files and folders the cache keeps — each once, however many items include it.
    static func keptCopyCount() -> Int {
        let slots = (try? FileManager.default.contentsOfDirectory(atPath: keptDirectory.path(percentEncoded: false))) ?? []
        return slots.filter { !$0.hasPrefix(".") && !$0.hasSuffix(stagingSuffix) }.count
    }

    // MARK: Changing the cache

    /// Brings the cache in line with history, in the background. `entries` are all the `.file` items
    /// in history, newest first. Keeps a copy of the files of the items in `newItems` (just copied,
    /// or copied again, which brings their copies up to date) unless they add up to more than
    /// `sizeLimit`. With `refreshing`, re-clones every copy whose original changed. Always deletes
    /// what no item needs and merges duplicates (see the type's notes). `snippetFiles` are the
    /// snippets' stored files, the fallback for a file on another volume.
    static func update(_ entries: [Entry], keepingFilesOf newItems: Set<UUID>, keepsCopies: Bool,
                       refreshing: Bool, sizeLimit: Int, snippetFiles: [URL]) {
        queue.async {
            var pass = Pass(entries: entries, keepsCopies: keepsCopies, snippetFiles: snippetFiles)
            pass.adoptEarlierCopies()
            pass.dropUnneededCopies()
            if keepsCopies {
                for entry in entries where newItems.contains(entry.id) { pass.keep(entry, sizeLimit: sizeLimit) }
            }
            if refreshing { pass.refresh() }
            pass.mergeDuplicates()
        }
    }

    /// Deletes the whole store — kept copies and files copied on other devices — and waits for it,
    /// so it's done even when the app quits right after (Clear History, quitting without saving
    /// history).
    static func discardAll() {
        queue.sync { try? FileManager.default.removeItem(at: ClipboardItem.storedFilesDirectory) }
    }

    /// Deletes the store's top-level folders not named in `referenced`. Waits for it: remote copies
    /// are created on the main thread, and one made while this lists the folder would be swept.
    static func sweep(keeping referenced: Set<String>) {
        queue.sync {
            let fm = FileManager.default
            guard let folders = try? fm.contentsOfDirectory(at: ClipboardItem.storedFilesDirectory,
                                                            includingPropertiesForKeys: nil) else { return }
            for folder in folders where !referenced.contains(folder.lastPathComponent) {
                try? fm.removeItem(at: folder)
            }
        }
    }

    /// Runs `work` on the cache's queue once everything queued before it is done — how Settings ›
    /// Storage measures the copies as they are after pending updates.
    static func perform<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    // MARK: Paths and keys

    /// `url`'s path as the cache keys it: without `.`/`..` or a trailing slash, and precomposed (APFS
    /// treats both Unicode forms of a name as one file). Not `standardizedFileURL`, which drops a
    /// leading `/private` only while the file exists, so a deleted file's key would change.
    static func normalizedPath(_ url: URL) -> String {
        var path = url.standardized.path(percentEncoded: false).precomposedStringWithCanonicalMapping
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// `path` and then each folder above it, nearest first, each with `path` relative to it ("" for
    /// `path` itself). The root is left out: nothing that large is kept.
    fileprivate static func ancestors(of path: String) -> [(folder: String, relative: String)] {
        var result: [(folder: String, relative: String)] = []
        var folder = path
        while folder.count > 1, folder.hasPrefix("/") {
            result.append((folder, folder == path ? "" : String(path.dropFirst(folder.count + 1))))
            folder = (folder as NSString).deletingLastPathComponent
        }
        return result
    }

    /// The slot of the copy of the file or folder at `path`: 32 hex digits of its SHA-256, so any
    /// path fits in a name and two paths never share a slot.
    fileprivate static func key(for path: String) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var name: [UInt8] = []
        name.reserveCapacity(32)
        for byte in SHA256.hash(data: Data(path.utf8)).prefix(16) {
            name.append(digits[Int(byte >> 4)])
            name.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: name, as: UTF8.self)
    }

    fileprivate static func slot(for path: String) -> URL {
        keptDirectory.appending(path: key(for: path), directoryHint: .isDirectory)
    }

    /// Where the copy of `folder` (a kept file or folder's path) is: in its slot, under its name.
    fileprivate static func copyLocation(of folder: String) -> URL {
        slot(for: folder).appending(path: (folder as NSString).lastPathComponent)
    }

    /// Where the entry at `relative` inside `folder`'s copy is ("" for the copy itself).
    fileprivate static func location(of relative: String, inCopyOf folder: String, hint: URL.DirectoryHint = .inferFromPath) -> URL {
        let copy = copyLocation(of: folder)
        return relative.isEmpty ? URL(filePath: copy.path(percentEncoded: false), directoryHint: hint)
                                : copy.appending(path: relative, directoryHint: hint)
    }

    /// A slot being filled, beside the one it replaces; one left by a crash is deleted with the junk.
    fileprivate static let stagingSuffix = ".new"

    /// How many folders down `path` is.
    fileprivate static func depth(_ path: String) -> Int {
        path.utf8.reduce(0) { $1 == UInt8(ascii: "/") ? $0 + 1 : $0 }
    }

    // MARK: One update (on `queue`)

    /// The work of one `update`: what items reference, what's kept, and the steps that reconcile them.
    private struct Pass {
        let entries: [Entry]
        let keepsCopies: Bool
        let snippetFiles: [URL]
        /// The originals items reference (files copied on this Mac), by `normalizedPath`.
        private(set) var referenced: [String: URL] = [:]
        /// The paths whose slot holds a copy.
        private(set) var kept: Set<String> = []

        /// Reads what's kept, deleting every slot no referenced path or folder above one maps to: the
        /// copies of items gone from history, and staging folders a crash left.
        init(entries: [Entry], keepsCopies: Bool, snippetFiles: [URL]) {
            self.entries = entries
            self.keepsCopies = keepsCopies
            self.snippetFiles = snippetFiles
            for entry in entries {
                for url in entry.originals where !ClipboardItem.isStoredFile(url) {
                    referenced[normalizedPath(url)] = url
                }
            }
            var folders: Set<String> = []
            for path in referenced.keys { folders.formUnion(ancestors(of: path).map(\.folder)) }
            var pathsByKey: [String: String] = [:]
            for folder in folders { pathsByKey[key(for: folder)] = folder }

            let fm = FileManager.default
            for folder in (try? fm.contentsOfDirectory(at: keptDirectory, includingPropertiesForKeys: nil)) ?? [] {
                if let path = pathsByKey[folder.lastPathComponent], ClipboardItem.fileExists(copyLocation(of: path)) {
                    kept.insert(path)
                } else {
                    try? fm.removeItem(at: folder)
                }
            }
        }

        /// The copy `path` reads from — its own, else the nearest kept folder's holding it — and
        /// whose copy that is. `outside` skips its own, for finding a folder's copy of the same file.
        func copy(of path: String, outside: Bool = false) -> (folder: String, url: URL)? {
            for (folder, relative) in ancestors(of: path) where kept.contains(folder) && !(outside && relative.isEmpty) {
                let url = location(of: relative, inCopyOf: folder)
                if ClipboardItem.fileExists(url) { return (folder, url) }
            }
            return nil
        }

        /// Whether an item needs a copy of the file at `path`: one references it, and copies are
        /// kept or its original is gone (the copy is all that's left).
        func needsCopy(_ path: String) -> Bool {
            guard let original = referenced[path] else { return false }
            return keepsCopies || !ClipboardItem.fileExists(original)
        }

        /// Moves the copies kept before copies were shared — `HistoryFiles/<item id>/<index>/<name>`,
        /// one per item — into their files' slots, the newest item's first. A copy of a file that
        /// already has one goes, unless it's another version of a file a kept folder holds.
        mutating func adoptEarlierCopies() {
            let fm = FileManager.default
            for entry in entries {
                let folder = ClipboardItem.storedFilesDirectory.appending(path: entry.id.uuidString, directoryHint: .isDirectory)
                guard ClipboardItem.fileExists(folder) else { continue }
                for (index, original) in entry.originals.enumerated() where !ClipboardItem.isStoredFile(original) {
                    let earlier = folder.appending(path: String(index), directoryHint: .isDirectory)
                        .appending(path: original.lastPathComponent)
                    guard ClipboardItem.fileExists(earlier) else { continue }
                    let path = normalizedPath(original)
                    if let current = copy(of: path), current.folder == path || isClone(earlier, of: current.url) { continue }
                    move(earlier, intoSlotOf: path)
                }
                try? fm.removeItem(at: folder)
            }
        }

        /// Deletes the copies no item needs (`needsCopy`), after moving out of a folder's copy the
        /// files inside it that an item still needs.
        mutating func dropUnneededCopies() {
            for path in kept.sorted(by: { depth($0) < depth($1) }) where !needsCopy(path) {
                extract(from: path, goneOnly: false)
                delete(path)
            }
        }

        /// Keeps `entry`'s files: clones each that has no copy, and re-clones a copy that no longer
        /// matches — the kept folder's it's read from when there's one, so the file stays in one copy.
        /// Nothing when the files add up to more than `sizeLimit`.
        mutating func keep(_ entry: Entry, sizeLimit: Int) {
            let present = entry.originals.filter { ClipboardItem.fileExists($0) && !ClipboardItem.isStoredFile($0) }
            guard !present.isEmpty, fits(present, sizeLimit: sizeLimit) else { return }
            for original in present {
                let path = normalizedPath(original)
                if let current = copy(of: path) {
                    if isClone(current.url, of: original) { continue }
                    if current.folder != path, replace(current.folder, with: URL(filePath: current.folder, directoryHint: .isDirectory)) {
                        continue
                    }
                }
                replace(path, with: original)
            }
        }

        /// Re-clones the copies whose original was edited or saved over since, so an old version
        /// never takes up space while the original is still there. Copies of originals that are gone
        /// stay as they are, and so do copies from another volume (they can't be cloned again).
        mutating func refresh() {
            for path in kept.sorted(by: { depth($0) < depth($1) }) {
                guard kept.contains(path), let original = referenced[path], ClipboardItem.fileExists(original),
                      sameVolume(original, keptDirectory), !isClone(copyLocation(of: path), of: original) else { continue }
                replace(path, with: original)
            }
        }

        /// Deletes a file's own copy when the copy of a kept folder holding it has the same file, so
        /// the file is kept once. Deepest first, so a chain of nested copies folds into the outermost.
        mutating func mergeDuplicates() {
            for path in kept.sorted(by: { depth($0) > depth($1) }) {
                guard let outer = copy(of: path, outside: true), isClone(outer.url, of: copyLocation(of: path)) else { continue }
                delete(path)
            }
        }

        // MARK: Steps

        /// Moves the files inside `folder`'s copy that read from that copy and need one (`needsCopy`)
        /// into their own slots — with `goneOnly`, just those whose originals are gone. Shallowest
        /// first, so a folder moved out takes what's inside it along.
        mutating func extract(from folder: String, goneOnly: Bool) {
            let prefix = folder + "/"
            let inside = referenced.filter { $0.key.hasPrefix(prefix) }.sorted { depth($0.key) < depth($1.key) }
            for (path, original) in inside where goneOnly ? !ClipboardItem.fileExists(original) : needsCopy(path) {
                guard let current = copy(of: path), current.folder == folder else { continue }
                move(current.url, intoSlotOf: path)
            }
        }

        /// Clones `original` into `path`'s slot, through a staging folder so a failed clone leaves the
        /// earlier copy. A folder's copy first gives up the files inside it whose originals are gone
        /// and that an item still needs, since the new clone won't have them. Falls back to cloning a
        /// snippet's copy of the same file. True once the slot holds the new copy.
        @discardableResult
        mutating func replace(_ path: String, with original: URL) -> Bool {
            if kept.contains(path) { extract(from: path, goneOnly: true) }
            let fm = FileManager.default
            let target = slot(for: path)
            let staging = keptDirectory.appending(path: target.lastPathComponent + stagingSuffix, directoryHint: .isDirectory)
            try? fm.removeItem(at: staging)
            guard (try? fm.createDirectory(at: staging, withIntermediateDirectories: true)) != nil else { return false }
            let destination = staging.appending(path: (path as NSString).lastPathComponent).path(percentEncoded: false)
            let cloned = clonefile(original.path(percentEncoded: false), destination, 0) == 0
                || snippetCopy(of: original).map { clonefile($0.path(percentEncoded: false), destination, 0) == 0 } == true
            guard cloned else {
                try? fm.removeItem(at: staging)
                return false
            }
            try? fm.removeItem(at: target)
            guard (try? fm.moveItem(at: staging, to: target)) != nil else {
                try? fm.removeItem(at: staging)
                kept.remove(path)
                return false
            }
            kept.insert(path)
            return true
        }

        /// Moves `source` (a copy, on the same volume, so it's a rename) into `path`'s slot.
        mutating func move(_ source: URL, intoSlotOf path: String) {
            let fm = FileManager.default
            let target = slot(for: path)
            try? fm.removeItem(at: target)
            guard (try? fm.createDirectory(at: target, withIntermediateDirectories: true)) != nil,
                  (try? fm.moveItem(at: source, to: copyLocation(of: path))) != nil else {
                try? fm.removeItem(at: target)
                kept.remove(path)
                return
            }
            kept.insert(path)
        }

        mutating func delete(_ path: String) {
            try? FileManager.default.removeItem(at: slot(for: path))
            kept.remove(path)
        }

        /// A snippet's stored copy of `original`: same name, same contents.
        private func snippetCopy(of original: URL) -> URL? {
            let name = original.lastPathComponent
            let size = byteCount(of: original)
            return snippetFiles.first { candidate in
                candidate.lastPathComponent == name
                    && byteCount(of: candidate) == size
                    && FileManager.default.contentsEqual(atPath: candidate.path(percentEncoded: false),
                                                         andPath: original.path(percentEncoded: false))
            }
        }
    }

    // MARK: Comparing and measuring

    /// Whether `copy` still shares all its contents with `original` (or with another copy of the same
    /// file): APFS gives a clone its original's content identifier, and a file a new one once it's
    /// written or saved over. A folder matches when every entry inside does.
    private static func isClone(_ copy: URL, of original: URL) -> Bool {
        guard let a = contentIdentifiers(original), let b = contentIdentifiers(copy) else { return false }
        return a == b
    }

    /// Each entry's content identifier by path relative to `root` (0 for folders, links and empty
    /// files), or nil past `folderEntryLimit`. Finder's `.DS_Store` files are left out: it rewrites
    /// them just from showing a folder, and they'd make the copy look out of date. An empty file has
    /// no blocks to share, and APFS gives each clone of one a new identifier, so comparing those
    /// would re-clone any folder holding one on every refresh.
    private static func contentIdentifiers(_ url: URL) -> [String: Int64]? {
        let root = uncached(url)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileContentIdentifierKey, .fileSizeKey]
        let rootValues = try? root.resourceValues(forKeys: keys.union([.isDirectoryKey]))
        guard rootValues?.isDirectory == true else {
            if rootValues?.fileSize == 0 { return ["": 0] }
            return rootValues?.fileContentIdentifier.map { ["": $0] }
        }
        var base = root.standardizedFileURL.path(percentEncoded: false)
        while base.hasSuffix("/") { base.removeLast() }
        var result: [String: Int64] = [:]
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return nil }
        for case let url as URL in entries where url.lastPathComponent != ".DS_Store" {
            guard result.count < folderEntryLimit else { return nil }
            let values = try? url.resourceValues(forKeys: keys)
            let path = String(url.standardizedFileURL.path(percentEncoded: false).dropFirst(base.count))
            result[path] = values?.isRegularFile == true && values?.fileSize != 0 ? values?.fileContentIdentifier ?? -1 : 0
        }
        return result
    }

    /// Whether `urls` add up to `sizeLimit` bytes or less, without counting past it (or past
    /// `folderEntryLimit` entries in a folder).
    private static func fits(_ urls: [URL], sizeLimit: Int) -> Bool {
        var total = 0
        for url in urls.map(uncached) {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                total += byteCount(of: url)
                if total > sizeLimit { return false }
                continue
            }
            guard let entries = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return false }
            var count = 0
            for case let file as URL in entries {
                count += 1
                total += (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                if count > folderEntryLimit || total > sizeLimit { return false }
            }
        }
        return true
    }

    private static func byteCount(of url: URL) -> Int {
        (try? uncached(url).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    /// A new URL for `url`'s file: a URL caches the resource values it read, and one kept across
    /// updates would report a file as it was then.
    private static func uncached(_ url: URL) -> URL {
        URL(filePath: url.path(percentEncoded: false), directoryHint: url.hasDirectoryPath ? .isDirectory : .notDirectory)
    }

    private static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let volume = { (url: URL) in (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject }
        guard let first = volume(a), let second = volume(b) else { return false }
        return first.isEqual(second)
    }
}
