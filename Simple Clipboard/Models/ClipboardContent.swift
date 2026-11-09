import Foundation
import SwiftUI
import Synchronization
import UniformTypeIdentifiers

/// The classified type of a captured pasteboard entry.
enum ClipboardKind: String, Codable, CaseIterable, Sendable {
    case plainText
    case code
    case richText
    case image
    case url
    case color
    case file
    case pdf
    /// Display only: what a `.file` item whose files are all folders presents as
    /// (`ClipboardItem.displayKind`). Capture never produces it and it's never stored — a copied
    /// folder stays `.file`, so it pastes, filters and saves like any other copied file.
    case folder

    /// Human-readable label shown in rows and the filter bar.
    var label: String {
        switch self {
        case .plainText: String(localized: "Plain Text")
        case .code: String(localized: "Code")
        case .richText: String(localized: "Rich Text")
        case .image: String(localized: "Image")
        case .url: String(localized: "URL")
        case .color: String(localized: "Color")
        case .file: String(localized: "File")
        case .pdf: String(localized: "PDF")
        case .folder: String(localized: "Folder")
        }
    }

    /// Generic SF Symbol used when no richer preview applies (menu rows, fallbacks).
    var symbol: String {
        switch self {
        case .plainText: "text.alignleft"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .richText: "doc.richtext"
        case .image: "photo"
        case .url: "link"
        case .color: "paintpalette"
        case .file: "doc"
        case .pdf: "doc.text.image"
        case .folder: "folder"
        }
    }

    /// `label` for an item holding `fileCount` files: "Files" rather than "File", and so on.
    func label(fileCount: Int) -> String {
        guard fileCount > 1 else { return label }
        switch self {
        case .image: return String(localized: "Images")
        case .pdf: return String(localized: "PDFs")
        case .file: return String(localized: "Files")
        case .folder: return String(localized: "Folders")
        default: return label
        }
    }

    /// The kind a list of files presents as: `.pdf` when all of them are PDFs, `.image` when all
    /// of them are images, `.folder` when all of them are folders (`URL.isFolder`), else `.file`.
    /// A directory's extension says nothing about its type, so a folder named `Shots.png` isn't
    /// an image.
    static func presenting(fileURLs urls: [URL]) -> ClipboardKind {
        let types = urls.map { $0.hasDirectoryPath ? nil : UTType(filenameExtension: $0.pathExtension) }
        guard !types.isEmpty else { return .file }
        if types.allSatisfy({ $0?.conforms(to: .pdf) == true }) { return .pdf }
        if types.allSatisfy({ $0?.conforms(to: .image) == true }) { return .image }
        if urls.allSatisfy(\.isFolder) { return .folder }
        return .file
    }

    /// Kinds exempt from plain-text mode: their "plain string" is just a
    /// label/name (`PNG · 1920×1080`, `PDF · 3 pages`, a file name), so they always paste
    /// in their full original form.
    var isPlainTextExempt: Bool {
        switch self {
        case .image, .file, .pdf, .folder: true
        default: false
        }
    }

    /// Whether a multi-item "Copy as plain text" has anything to take from this kind: everything
    /// but images and PDFs, whose "plain string" is only a label. A file contributes its path.
    var hasTextForm: Bool {
        self != .image && self != .pdf
    }
}

// MARK: - Folders

extension URL {
    /// Whether this file URL is a folder: a directory other than a package (an app, a bundle, an
    /// `.rtfd`), which Finder shows — and copies — as a single file. Asks the disk; a folder that's
    /// gone is recognized by the trailing slash its URL was copied with.
    var isFolder: Bool {
        guard isFileURL else { return false }
        if let values = try? resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
           let isDirectory = values.isDirectory {
            return isDirectory && values.isPackage != true
        }
        return hasDirectoryPath
            && UTType(filenameExtension: pathExtension, conformingTo: .directory)?.conforms(to: .package) != true
    }

    /// What this folder holds, as Finder lists it: the items directly inside, sorted by name, with
    /// hidden ones (`.DS_Store` and the like) left out. Subfolders stay folders, their URLs ending in
    /// a slash. Nil when it isn't a folder or can't be read.
    ///
    /// History rows badge a folder with its item count on every render, so a listing is kept until
    /// the folder's modification time changes, which an item added, removed or renamed in it does.
    /// That time is read with `stat`: a `URL` caches its resource values, and the listing hands out
    /// the same URLs again.
    var folderContents: [URL]? {
        guard isFolder else { return nil }
        let key = standardizedFileURL.path(percentEncoded: false)
        var info = stat()
        let modified = stat(key, &info) == 0 ? [Int(info.st_mtimespec.tv_sec), info.st_mtimespec.tv_nsec] : nil
        if let modified, let cached = folderListings.withLock({ $0[key] }), cached.modified == modified {
            return cached.contents
        }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: self, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles])
        else { return nil }
        let sorted = contents.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if let modified {
            folderListings.withLock { listings in
                if listings.count >= 256 { listings.removeAll() }
                listings[key] = (modified, sorted)
            }
        }
        return sorted
    }
}

/// `URL.folderContents`' listings by folder path, with the modification time (seconds, nanoseconds)
/// each was read at.
private let folderListings = Mutex<[String: (modified: [Int], contents: [URL])]>([:])

extension Array where Element == URL {
    /// What a row's file-count badge (`FileCountBadge`) says for these files: each folder counts the
    /// items inside it (`URL.folderContents`) and anything else one, summed — the pages the preview
    /// turns through. A list with a folder always has a badge,
    /// even for one item (or none); one without, from two files up. Nil when there's no badge.
    var fileBadgeCount: Int? {
        var hasFolder = false
        let count = reduce(0) { total, url in
            guard url.isFolder else { return total + 1 }
            hasFolder = true
            // A folder that's gone (and has no kept copy) still counts as itself.
            return total + (url.folderContents?.count ?? 1)
        }
        return hasFolder || count > 1 ? count : nil
    }
}

/// A value-type snapshot of one captured pasteboard entry, before it becomes a
/// persisted `ClipboardItem`. Detection/decoding lives in `PasteboardDetection.swift`.
struct ClipboardContent: Sendable {
    var kind: ClipboardKind
    /// Encoded payload per `kind` (UTF-8 string, RTF data, original image bytes, archived
    /// NSColor, file-URL list, raw PDF bytes).
    var payload: Data
    /// UTType of the payload format, for `.image` items (so paste reproduces the original
    /// type, e.g. JPEG/GIF/HEIC); `nil` for other kinds.
    var payloadType: UTType? = nil
    /// Always-available text preview for menus and search.
    var plainPreview: String
    /// Small PNG thumbnail for image rows (nil otherwise).
    var thumbnail: Data?
    /// The file a copied image file's bytes came from (`ClipboardItem.sourceFileURLRaw`); `nil`
    /// for other captures.
    var sourceFileURL: URL? = nil
}

/// The filters available in the main window. Declaration order
/// is the filter-bar order. Note: no "Color" filter by design — color items still
/// appear under `.all`.
enum ClipboardFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case plainText
    case richText
    case url
    case code
    case image
    case pdf
    case file

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: String(localized: "All")
        case .plainText: String(localized: "Plain Text")
        case .richText: String(localized: "Rich Text")
        case .url: String(localized: "URL")
        case .code: String(localized: "Code")
        case .image: String(localized: "Image")
        case .pdf: String(localized: "PDF")
        case .file: String(localized: "File")
        }
    }

    /// The `ClipboardKind` this filter matches, or `nil` for `.all`.
    private var kind: ClipboardKind? {
        switch self {
        case .all: nil
        case .plainText: .plainText
        case .richText: .richText
        case .url: .url
        case .code: .code
        case .image: .image
        case .pdf: .pdf
        case .file: .file
        }
    }

    /// Whether `item` belongs under this filter. `.pdf` and `.image` additionally match `.file`
    /// items whose files are all PDFs / all images — copied files stay `.file` by design
    /// (Finder-paste semantics), but users still expect them under those filters. Such items
    /// appear under File too.
    func matches(_ item: ClipboardItem) -> Bool {
        switch self {
        case .all:
            return true
        case .pdf:
            return item.presentsAsPDF
        case .image:
            return item.displayKind == .image
        default:
            return item.kind == kind
        }
    }
}
