import Foundation
import SwiftData
import UniformTypeIdentifiers

/// A reusable preloaded snippet. Plain text stores UTF-8;
/// rich text stores RTF data in `payload`; a file snippet (`isFile`) stores
/// newline-joined file-URL strings — the same encoding as a `.file` `ClipboardItem`.
/// The referenced files are **cloned into the app's managed store** when the snippet is
/// saved (`storeManagedFileCopy`), so moving or deleting the user's original no longer
/// breaks the snippet, yet the clone takes no extra disk space while it and the
/// original are unchanged. A snippet whose file couldn't be stored references it in place
/// until `storeReferencedOriginals` manages to.
@Model
final class Snippet {
    var id: UUID = UUID()
    var title: String = ""
    var isRichText: Bool = false
    /// File snippet: pastes as the referenced files, like a `.file` history item.
    /// Mutually exclusive with `isRichText`.
    var isFile: Bool = false
    /// UTF-8 string for plain, RTF data for rich, newline-joined file-URL strings for file.
    var payload: Data = Data()
    var plainPreview: String = ""
    var sortIndex: Int = 0
    var createdAt: Date = Date.now

    var folder: SnippetFolder?

    init(
        title: String,
        isRichText: Bool = false,
        isFile: Bool = false,
        payload: Data = Data(),
        plainPreview: String = "",
        sortIndex: Int = 0,
        folder: SnippetFolder? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.isRichText = isRichText
        self.isFile = isFile
        self.payload = payload
        self.plainPreview = plainPreview
        self.sortIndex = sortIndex
        self.createdAt = .now
        self.folder = folder
    }

    /// The file URLs of a file snippet, decoded from the newline-joined payload
    /// (mirrors `ClipboardItem.fileURLs`). Empty for text snippets.
    var fileURLs: [URL] {
        guard isFile, let s = String(data: payload, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap { URL(string: String($0)) }
    }

    /// The type label of a file snippet. A single image reads "Image", a single folder "Folder",
    /// and any other single file "File"; several follow the history rows: "Images" / "PDFs" /
    /// "Folders" when all of them are, else "Files".
    var fileKindLabel: String {
        let urls = fileURLs
        let kind = ClipboardKind.presenting(fileURLs: urls)
        return urls.count > 1 || kind == .folder || kind == .image
            ? kind.label(fileCount: urls.count) : ClipboardKind.file.label
    }

    /// What a file snippet's rows show: several files one name per line, the first three then
    /// "…", as history rows list them (`ClipboardItem.rowPreview`); a single file's name. Empty for
    /// text snippets and a file snippet with no files.
    var fileNamesPreview: String {
        guard isFile else { return "" }
        let urls = fileURLs
        if urls.count > 1 { return ClipboardItem.fileNamesPreview(urls) }
        return plainPreview.isEmpty ? plainString : plainPreview
    }

    /// What a file snippet's file-count badge says (`[URL].fileBadgeCount`): a folder among its files
    /// counts the items inside it. Nil for a single file and for text snippets.
    var fileBadgeCount: Int? { fileURLs.fileBadgeCount }

    /// Lines `fileNamesPreview` takes for several files: one more than three when it ends in "…".
    var fileNamesLineLimit: Int {
        ClipboardItem.fileNamesLineLimit(fileCount: fileURLs.count)
    }

    /// True when the snippet has no non-whitespace content. A snippet must have
    /// content — a title alone isn't one: the snippets list discards
    /// contentless snippets when the editor closes.
    var isEmpty: Bool {
        if isFile { return fileURLs.isEmpty }
        return plainString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Plain-text view of the content, decoding RTF when needed. For a file snippet
    /// this is the newline-joined POSIX paths (the textual form of the files).
    var plainString: String {
        if isFile {
            return fileURLs.map { $0.path(percentEncoded: false) }.joined(separator: "\n")
        }
        if isRichText {
            // With list markers, as TextEdit's plain text has them ("\t•\tItem").
            return NSAttributedString.withListMarkers(rtf: payload)?.string ?? plainPreview
        }
        return String(data: payload, encoding: .utf8) ?? plainPreview
    }
}

// MARK: - Save as Snippet (from a history item)

extension Snippet {
    /// The prefill title "Save as Snippet" derives from a history item: its one-line
    /// preview, falling back to the kind label when the preview is empty.
    static func defaultTitle(for item: ClipboardItem) -> String {
        let preview = item.plainPreview.menuPreview(limit: 40)
        return preview.isEmpty ? item.kindLabel : preview
    }

    /// Builds the snippet "Save as Snippet" derives from a history item — shared by the main
    /// window's context menu and the panel's ⌘S form. Text kinds keep their payload
    /// verbatim (rich stays RTF). `.file` items become **file snippets** whose files are **cloned
    /// into the managed store** (`storeManagedFileCopy`) so the snippet outlives the user moving
    /// or deleting the originals. A copied folder is kept whole, as the folder itself
    /// (cloned with everything inside it), as picking one in the editor does;
    /// `.image`/`.pdf` items also become file snippets,
    /// through a stable file (`persistedFileURL(for:)`) so the snippet pastes the real image/PDF,
    /// not its preview label ("PNG · 1920×1080"). `.color` (and image/PDF whose bytes fail to
    /// persist) store their preview *text*. Appended after `folder`'s current last snippet; the
    /// caller inserts + saves.
    static func from(_ item: ClipboardItem, title: String, folder: SnippetFolder) -> Snippet {
        let sortIndex = (folder.snippets.map(\.sortIndex).max() ?? -1) + 1

        if item.kind == .file {
            // A file moved or deleted since it was copied is stored from the copy history kept. A
            // folder is stored as the whole folder, not just the items inside it.
            let urls = item.availableFileURLs.map(storedOrOriginal)
            return Snippet(
                title: title, isFile: true, payload: filePayload(urls),
                plainPreview: fileNames(urls), sortIndex: sortIndex, folder: folder
            )
        }
        if let url = persistedFileURL(for: item) {
            return Snippet(
                title: title, isFile: true, payload: Data(url.absoluteString.utf8),
                plainPreview: url.lastPathComponent, sortIndex: sortIndex, folder: folder
            )
        }

        let payload: Data = switch item.kind {
        case .plainText, .code, .url, .richText: item.payload
        default: Data(item.plainPreview.utf8)   // color, or image/pdf that failed to persist
        }
        return Snippet(
            title: title,
            isRichText: item.kind == .richText,
            payload: payload,
            plainPreview: item.plainPreview,
            sortIndex: sortIndex,
            folder: folder
        )
    }

    /// Directory beside the SwiftData store where a file snippet's content is kept: a real file's
    /// **clone** (`storeManagedFileCopy`) or an `.image`/`.pdf` item's persisted bytes (both so the
    /// snippet has a stable file to reference). Lives in Application Support, so the
    /// files outlive the pasteboard's scratch temp dir (`PasteService.temporaryPasteFile`) and
    /// survive relaunches.
    static var snippetFilesDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: "SimpleClipboard", directoryHint: .isDirectory)
            .appending(path: "SnippetFiles", directoryHint: .isDirectory)
    }

    /// Gives an `.image`/`.pdf` item a stable file and returns its URL, so a file snippet can
    /// reference the real image/PDF. An image still on disk as the file it was copied from
    /// (`sourceFileURL`, unchanged since) is cloned under its own name, which takes no extra space.
    /// Anything else exists only as bytes, so those are written out, named
    /// `<label> <dd-MM-yyyy>_<HHmmss>` (e.g. `Image 07-07-2026_100628`) — the same scheme
    /// `PasteService.temporaryPasteFile` uses, so a saved image reads identically to a pasted one.
    /// Returns nil for other kinds, an empty payload, or a failed write — the caller then falls
    /// back to preview text.
    private static func persistedFileURL(for item: ClipboardItem) -> URL? {
        let ext: String
        let label: String
        switch item.kind {
        case .image: ext = item.payloadType?.preferredFilenameExtension ?? "png"; label = "Image"
        case .pdf: ext = "pdf"; label = "PDF"
        default: return nil
        }
        guard !item.payload.isEmpty else { return nil }
        if let source = item.sourceFileURL,
           (try? Data(contentsOf: source, options: .mappedIfSafe)) == item.payload,
           let clone = storeManagedFileCopy(of: source) {
            return clone
        }
        // Its own subdirectory, like a clone's: a multi-item save writes several images within
        // the same second, and they'd otherwise share a name and overwrite each other.
        let dir = snippetFilesDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = "\(label) \(Date.now.fileNameStamp).\(ext)"
            let url = dir.appending(path: name)
            try item.payload.write(to: url)
            return url
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
    }
}

// MARK: - Managed file-snippet copies

extension Snippet {
    /// Encodes file URLs as a file snippet's payload (newline-joined).
    static func filePayload(_ urls: [URL]) -> Data {
        Data(urls.map(\.absoluteString).joined(separator: "\n").utf8)
    }

    /// A file snippet's `plainPreview`: its file names, comma-separated, as a `.file` item's.
    static func fileNames(_ urls: [URL]) -> String {
        urls.map { $0.lastPathComponent.isEmpty ? $0.path : $0.lastPathComponent }.joined(separator: ", ")
    }

    /// Stores `source` in the managed store and returns the stored file, or `source` itself when it
    /// already is one or can't be stored — the snippet then references it in place, and
    /// `storeReferencedOriginals` tries again on the next launch.
    static func storedOrOriginal(_ source: URL) -> URL {
        isManagedFileCopy(source) ? source : storeManagedFileCopy(of: source) ?? source
    }

    /// Copies `source` into the managed store, preserving its filename, and returns the copy's
    /// URL. A file snippet references this rather than the user's original, so moving or deleting
    /// the original no longer breaks the snippet. `copyItem` **clones** within an APFS
    /// volume — which is where the user's own files and this store normally both live: instant,
    /// sharing the original's storage until one of them changes, and the shared storage stays
    /// allocated for the clone if the original is deleted. From another volume (an external drive)
    /// it's a real copy, the only way to outlive that drive being unplugged — or, with `cloneOnly`,
    /// nil. Each copy gets its own UUID subdirectory, so identically-named files from different
    /// snippets never collide. Also nil on failure.
    static func storeManagedFileCopy(of source: URL, cloneOnly: Bool = false) -> URL? {
        guard source.isFileURL else { return nil }
        let fm = FileManager.default
        let dir = snippetFilesDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appending(path: source.lastPathComponent)
            if cloneOnly {
                guard clonefile(source.path(percentEncoded: false), dest.path(percentEncoded: false), 0) == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
            } else {
                try fm.copyItem(at: source, to: dest)
            }
            return dest
        } catch {
            try? fm.removeItem(at: dir)
            return nil
        }
    }

    /// Stores the files of snippets that still reference an original in place — saved by an older
    /// version, or when storing failed (no permission for that folder yet) — so they stop depending
    /// on it. Clones only: this runs on launch, on the main thread, and must not sit through a
    /// real copy from a slow drive. An original that's already gone stays referenced, shown as
    /// missing.
    static func storeReferencedOriginals(in context: ModelContext) {
        guard let snippets = try? context.fetch(FetchDescriptor<Snippet>()) else { return }
        var changed = false
        for snippet in snippets where snippet.isFile {
            let urls = snippet.fileURLs
            let stored = urls.map { isManagedFileCopy($0) ? $0 : storeManagedFileCopy(of: $0, cloneOnly: true) ?? $0 }
            guard stored != urls else { continue }
            snippet.payload = filePayload(stored)
            changed = true
        }
        if changed { try? context.save() }
    }

    /// True when `url` is a file in the managed store — used to avoid re-storing an already-stored
    /// file and to know a superseded copy is safe to delete. False for a snippet referencing the
    /// user's original in place.
    static func isManagedFileCopy(_ url: URL) -> Bool {
        // `.path(percentEncoded:)` keeps a directory URL's trailing slash, so normalize to a
        // single separator before the prefix test.
        var root = snippetFilesDirectory.standardizedFileURL.path(percentEncoded: false)
        while root.hasSuffix("/") { root.removeLast() }
        return url.standardizedFileURL.path(percentEncoded: false).hasPrefix(root + "/")
    }

    /// Deletes a managed copy — the file plus its now-empty UUID subdirectory — so a replaced or
    /// removed file snippet doesn't orphan bytes in the store. No-op for a URL outside the managed
    /// store (never touches the user's originals, and never the store root itself).
    static func deleteManagedFileCopy(_ url: URL) {
        guard isManagedFileCopy(url) else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        let parent = url.deletingLastPathComponent()
        guard parent.standardizedFileURL != snippetFilesDirectory.standardizedFileURL,
              let contents = try? fm.contentsOfDirectory(atPath: parent.path(percentEncoded: false)),
              contents.isEmpty else { return }
        try? fm.removeItem(at: parent)
    }

    /// Deletes any managed file copies this snippet owns — called when the snippet is discarded
    /// so its stored bytes don't linger. No-op for text snippets and legacy snippets that
    /// reference the user's original file.
    func deleteOwnedManagedFiles() {
        guard isFile else { return }
        for url in fileURLs { Snippet.deleteManagedFileCopy(url) }
    }

    /// Deletes managed copies no snippet references — left behind by folder deletes before they
    /// took their snippets' copies along, or by a crash between copy and save. Run once at launch,
    /// before an editor can store a copy for a snippet that isn't saved yet. Skipped if the fetch
    /// fails, so an unreadable store never empties the folder.
    static func deleteUnreferencedManagedFiles(in context: ModelContext) {
        guard let snippets = try? context.fetch(FetchDescriptor<Snippet>()) else { return }
        let referenced = Set(snippets.flatMap(\.fileURLs).compactMap(managedEntryName))
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: snippetFilesDirectory, includingPropertiesForKeys: nil) else { return }
        for entry in entries where !referenced.contains(entry.lastPathComponent.precomposedStringWithCanonicalMapping) {
            try? fm.removeItem(at: entry)
        }
    }

    /// The top-level store entry holding `url` — a copy's UUID folder, or a saved image/PDF kept at
    /// the root. Found by the store's own folder names rather than its full path, so a snippet
    /// saved before the home folder moved still claims its file.
    private static func managedEntryName(_ url: URL) -> String? {
        let parts = url.standardizedFileURL.pathComponents
        guard let i = parts.indices.dropLast(2).first(where: { parts[$0] == "SimpleClipboard" && parts[$0 + 1] == "SnippetFiles" }) else { return nil }
        return parts[i + 2].precomposedStringWithCanonicalMapping
    }
}
