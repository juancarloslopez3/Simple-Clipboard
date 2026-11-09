import Foundation
import SwiftData
import UniformTypeIdentifiers

/// One captured pasteboard entry (CLAUDE.md §7). The type is stored as a raw string
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

    /// The file URLs of a `.file` item, decoded from the newline-joined payload (CLAUDE.md §7).
    /// Empty for other kinds (or an unreadable payload).
    var fileURLs: [URL] {
        guard kind == .file, let s = String(data: payload, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap { URL(string: String($0)) }
    }

    /// Whether this is a `.file` item whose files are all PDFs. Capture keeps such copies
    /// `.file` for Finder-paste semantics (CLAUDE.md §8b), but they *present* as PDFs: the
    /// PDF filter matches them and rows label them "PDF" (`kindLabel`/`kindSymbol`).
    var isPDFFileItem: Bool {
        let urls = fileURLs
        return !urls.isEmpty && urls.allSatisfy {
            UTType(filenameExtension: $0.pathExtension)?.conforms(to: .pdf) == true
        }
    }

    /// Kind label for display — PDF file items read "PDF", not "File" (`isPDFFileItem`).
    var kindLabel: String { isPDFFileItem ? ClipboardKind.pdf.label : kind.label }

    /// Kind symbol for display, matching `kindLabel`.
    var kindSymbol: String { isPDFFileItem ? ClipboardKind.pdf.symbol : kind.symbol }

    /// Whether this item *presents* as a PDF — a `.pdf` capture or a PDF `.file` item
    /// (`isPDFFileItem`). The PDF filter matches these (§8b) and the panel suppresses their
    /// large inline thumbnail preview so PDF rows stay compact glyph rows.
    var presentsAsPDF: Bool { kind == .pdf || isPDFFileItem }

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
    }
}
