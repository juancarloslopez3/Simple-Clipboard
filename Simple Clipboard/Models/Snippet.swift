import Foundation
import SwiftData
import UniformTypeIdentifiers

/// A reusable preloaded snippet (CLAUDE.md §7 / §11). Plain text stores UTF-8;
/// rich text stores RTF data in `payload`; a file snippet (`isFile`) stores
/// newline-joined file-URL strings — the same encoding as a `.file` `ClipboardItem`.
/// The referenced files are **copied into the app's managed store** when the snippet is
/// saved (`storeManagedFileCopy`), so moving or deleting the user's original no longer
/// breaks the snippet (§11/§12). Legacy snippets may still reference an original in place.
@Model
final class Snippet {
    var id: UUID = UUID()
    var title: String = ""
    var isRichText: Bool = false
    /// File snippet: pastes as the referenced files, like a `.file` history item
    /// (§11/§12). Mutually exclusive with `isRichText`.
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
    /// (mirrors `ClipboardItem.fileURLs`, §7). Empty for text snippets.
    var fileURLs: [URL] {
        guard isFile, let s = String(data: payload, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap { URL(string: String($0)) }
    }

    /// True when the snippet has no non-whitespace content. A snippet must have
    /// content — a title alone isn't one (§11): the snippets list discards
    /// contentless snippets when the editor closes.
    var isEmpty: Bool {
        if isFile { return fileURLs.isEmpty }
        return plainString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Plain-text view of the content, decoding RTF when needed. For a file snippet
    /// this is the newline-joined POSIX paths (the textual form of the files, §12).
    var plainString: String {
        if isFile {
            return fileURLs.map { $0.path(percentEncoded: false) }.joined(separator: "\n")
        }
        if isRichText {
            if let attr = try? NSAttributedString(
                data: payload,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            ) {
                return attr.string
            }
            return plainPreview
        }
        return String(data: payload, encoding: .utf8) ?? plainPreview
    }
}

// MARK: - Save as Snippet (from a history item)

extension Snippet {
    /// The prefill title "Save as Snippet" derives from a history item (§10): its one-line
    /// preview, falling back to the kind label when the preview is empty.
    static func defaultTitle(for item: ClipboardItem) -> String {
        let preview = item.plainPreview.menuPreview(limit: 40)
        return preview.isEmpty ? item.kindLabel : preview
    }

    /// Builds the snippet "Save as Snippet" derives from a history item — shared by the main
    /// window's context menu (§10) and the panel's ⌘S form (§9). Text kinds keep their payload
    /// verbatim (rich stays RTF). `.file` items become **file snippets** whose files are **copied
    /// into the managed store** (`storeManagedFileCopy`) so the snippet outlives the user moving
    /// the originals (§7/§11/§12); `.image`/`.pdf` items — which carry only bytes, no source file
    /// on disk (§8b) — also become file snippets, but their bytes are first persisted to a stable
    /// file (`persistedFileURL(for:)`) so the snippet pastes the real image/PDF, not its preview
    /// label ("PNG · 1920×1080"). `.color` (and image/PDF whose bytes fail to persist) store their
    /// preview *text*. Appended after `folder`'s current last snippet; the caller inserts + saves.
    static func from(_ item: ClipboardItem, title: String, folder: SnippetFolder) -> Snippet {
        let sortIndex = (folder.snippets.map(\.sortIndex).max() ?? -1) + 1

        // `.file` copies each referenced file into the managed store; `.image`/`.pdf` materialize
        // their bytes to a persistent file so a file snippet can reference the real content.
        if item.kind == .file {
            // A file that fails to copy falls back to referencing the original in place.
            let copies = item.fileURLs.map { storeManagedFileCopy(of: $0) ?? $0 }
            return Snippet(
                title: title, isFile: true,
                payload: Data(copies.map(\.absoluteString).joined(separator: "\n").utf8),
                plainPreview: item.plainPreview, sortIndex: sortIndex, folder: folder
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
    /// **copy** (`storeManagedFileCopy`) or an `.image`/`.pdf` item's persisted bytes (both so the
    /// snippet has a stable file to reference — §8b/§12). Lives in Application Support, so the
    /// files outlive the pasteboard's scratch temp dir (`PasteService.temporaryPasteFile`) and
    /// survive relaunches.
    private static var snippetFilesDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: "SimpleClipboard", directoryHint: .isDirectory)
            .appending(path: "SnippetFiles", directoryHint: .isDirectory)
    }

    /// Persists an `.image`/`.pdf` item's bytes to a stable file and returns its URL, so a file
    /// snippet can reference the real image/PDF. The file is named `<label> <dd-MM-yyyy>_<HHmmss>`
    /// (e.g. `Image 07-07-2026_100628`) — the same scheme `PasteService.temporaryPasteFile` uses
    /// when pasting as a file, so a saved image reads identically to a pasted one. Returns nil for
    /// other kinds, an empty payload, or a failed write — the caller then falls back to preview text.
    private static func persistedFileURL(for item: ClipboardItem) -> URL? {
        let ext: String
        let label: String
        switch item.kind {
        case .image: ext = item.payloadType?.preferredFilenameExtension ?? "png"; label = "Image"
        case .pdf: ext = "pdf"; label = "PDF"
        default: return nil
        }
        guard !item.payload.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd-MM-yyyy_HHmmss"
        let dir = snippetFilesDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = "\(label) \(formatter.string(from: Date())).\(ext)"
            let url = dir.appending(path: name)
            try item.payload.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

// MARK: - Managed file-snippet copies (§11/§12)

extension Snippet {
    /// Copies `source` into the managed store, preserving its filename, and returns the copy's
    /// URL. A file snippet references this **copy** rather than the user's original, so moving or
    /// deleting the original no longer breaks the snippet (§11/§12). Each copy gets its own UUID
    /// subdirectory, so identically-named files from different snippets never collide. Returns nil
    /// on failure — the caller then falls back to referencing the original in place.
    static func storeManagedFileCopy(of source: URL) -> URL? {
        guard source.isFileURL else { return nil }
        let dir = snippetFilesDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appending(path: source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    /// True when `url` is a file we copied into the managed store — used to avoid re-copying an
    /// already-stored file and to know a superseded copy is safe to delete. False for a legacy
    /// snippet still referencing the user's original in place.
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
}
