import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// The classified type of a captured pasteboard entry (CLAUDE.md §7 / §8b).
enum ClipboardKind: String, Codable, CaseIterable, Sendable {
    case plainText
    case code
    case richText
    case image
    case url
    case color
    case file
    case pdf

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
        }
    }

    /// Kinds exempt from plain-text mode (CLAUDE.md §12): their "plain string" is just a
    /// label/name (`PNG · 1920×1080`, `PDF · 3 pages`, a file name), so they always paste
    /// in their full original form.
    var isPlainTextExempt: Bool {
        switch self {
        case .image, .file, .pdf: true
        default: false
        }
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
}

/// The filters available in the main window (CLAUDE.md §1b / §10). Declaration order
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

    /// Whether `item` belongs under this filter. `.pdf` additionally matches `.file`
    /// items whose files are all PDFs — a copied PDF *file* stays `.file` by design
    /// (§8b, Finder-paste semantics), but users still expect it under the PDF filter.
    /// Such items appear under both File and PDF.
    func matches(_ item: ClipboardItem) -> Bool {
        switch self {
        case .all:
            return true
        case .pdf:
            return item.presentsAsPDF
        default:
            return item.kind == kind
        }
    }
}
