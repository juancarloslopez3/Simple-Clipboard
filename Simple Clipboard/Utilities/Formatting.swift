import AppKit

extension NSAttributedString {
    /// `rtf` read the way TextEdit reads documents, with each list item's marker in the text:
    /// "\t•\tItem" (`NSTextKit1ListMarkerFormatDocumentOption`, which TextEdit sets from its
    /// `IncludesTextListMarkersInsideDocuments` default, on unless changed). A plain read keeps
    /// only the `NSTextList`, which TextKit 2 draws markers from, so its string has no bullets or
    /// numbers. TextEdit's text has them, so they're in the plain text of a TextEdit copy too.
    static func withListMarkers(rtf: Data) -> NSAttributedString? {
        try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf,
                                                     .textKit1ListMarkerFormatDocumentOption: true],
                                documentAttributes: nil)
    }
}

extension Date {
    private static let rowFormatter: DateFormatter = {
        let f = DateFormatter()
        // Locale-driven so month names localize (English "Jun" → Spanish "jun");
        // the whole template — including the quoted connector "at" → "a las" — is a
        // localizable string so translators control the full layout. `HH` keeps 24-hour
        // time regardless of locale.
        f.locale = Locale.current
        f.dateFormat = String(localized: "d MMM yyyy 'at' HH:mm",
                              comment: "Row/preview timestamp; keep the connector inside single quotes")
        return f
    }()

    /// Timestamp formatted like `18 Jun 2026 at 15:17` / `18 jun 2026 a las 15:17`.
    var clipboardRowString: String { Date.rowFormatter.string(from: self) }

    private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd-MM-yyyy_HHmmss"
        return f
    }()

    /// Fixed-format stamp for generated file names, e.g. `23-06-2026_211102` in a pasted
    /// `Image 23-06-2026_211102.jpeg` or a saved snippet's file — never localized.
    var fileNameStamp: String { Date.fileStampFormatter.string(from: self) }
}

extension String {
    /// The text with its tabs taken out, for row and card previews: every line loses the tabs and
    /// spaces it starts and ends with, so each one starts at the left edge (a list's "\t•\tItem"
    /// lines, indented text), and any other tab, with the spaces around it, becomes one space
    /// ("•\tItem" → "• Item"). A preview `Text` would lay tabs out on its 28 pt grid instead,
    /// leaving the lines at ragged indents.
    var withoutTabs: String {
        replacingOccurrences(of: "(?m)^[ \\t]+|[ \\t]+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]*\\t[ \\t]*", with: " ", options: .regularExpression)
    }

    /// One-line, trimmed, length-limited rendering for menus, without tabs (`withoutTabs`).
    func menuPreview(limit: Int = 60) -> String {
        let collapsed = withoutTabs.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }

    /// Trimmed, length-limited rendering that *preserves* line breaks, for the floating panel's
    /// bigger multi-line history rows and the snippet cards. The view caps how
    /// many lines are shown. Tabs come out (`withoutTabs`) unless `keepingTabs`, as code rows ask,
    /// whose indentation is their shape.
    func multilinePreview(limit: Int = 240, keepingTabs: Bool = false) -> String {
        let trimmed = (keepingTabs ? self : withoutTabs).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }
}
