import Foundation

extension Date {
    private static let rowFormatter: DateFormatter = {
        let f = DateFormatter()
        // Locale-driven so month names localize (English "Jun" → Spanish "jun", §17);
        // the whole template — including the quoted connector "at" → "a las" — is a
        // localizable string so translators control the full layout. `HH` keeps 24-hour
        // time regardless of locale.
        f.locale = Locale.current
        f.dateFormat = String(localized: "d MMM yyyy 'at' HH:mm",
                              comment: "Row/preview timestamp; keep the connector inside single quotes")
        return f
    }()

    /// Timestamp formatted like `18 Jun 2026 at 15:17` / `18 jun 2026 a las 15:17` (CLAUDE.md §1b, §17).
    var clipboardRowString: String { Date.rowFormatter.string(from: self) }
}

extension String {
    /// One-line, trimmed, length-limited rendering for menus.
    func menuPreview(limit: Int = 60) -> String {
        let collapsed = replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }

    /// Trimmed, length-limited rendering that *preserves* line breaks, for the floating panel's
    /// bigger multi-line history rows (CLAUDE.md §9). The view caps how many lines are shown.
    func multilinePreview(limit: Int = 240) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }
}
