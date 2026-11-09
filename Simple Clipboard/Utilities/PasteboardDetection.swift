import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Reads `NSPasteboard` and classifies it into a `ClipboardContent` using the type
/// precedence in CLAUDE.md §8b: file → color → image → pdf → code → url → richText → plainText.
extension ClipboardContent {

    @MainActor
    init?(reading pb: NSPasteboard, trimWhitespace: Bool) {
        let types = pb.types ?? []

        // Trimmed plain string, if any usable text is present.
        let rawString = pb.string(forType: .string)
        let usableText: String? = {
            guard let s = rawString, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return s
        }()

        func preview(_ s: String) -> String {
            let p = trimWhitespace ? s.trimmingCharacters(in: .whitespacesAndNewlines) : s
            return String(p.prefix(2000))
        }

        // 1. File — one or more file URLs.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            // A *single* image file (copied from Finder, a screenshot tool, etc. — any type
            // conforming to `public.image`: PNG, JPEG, GIF, HEIC…) is captured as `.image`,
            // keeping the file's *original* bytes + type so it previews and re-pastes as the
            // same image/format rather than a bare file reference (CLAUDE.md §8b / §12). The
            // PNG fallback covers files whose bytes can't be read directly.
            if urls.count == 1, let img = Self.image(atFileURL: urls[0]) {
                let original = try? Data(contentsOf: urls[0])
                let (payload, type) = original.map { ($0, img.type) } ?? (img.image.pngData, .png)
                if let payload {
                    self.init(
                        kind: .image,
                        payload: payload,
                        payloadType: type,
                        plainPreview: Self.imagePreview(format: type, size: img.image.pixelSize),
                        thumbnail: img.image.thumbnailPNG(maxDimension: 256)
                    )
                    return
                }
            }
            let joined = urls.map(\.absoluteString).joined(separator: "\n")
            let names = urls.map { $0.lastPathComponent.isEmpty ? $0.path : $0.lastPathComponent }
            // Anything else (multiple files, or a non-image file) stays `.file`. Show a preview
            // by thumbnailing the first image or PDF file, if any (CLAUDE.md §8b).
            let thumbnail = urls.lazy.compactMap { Self.fileThumbnail(for: $0) }.first
            self.init(
                kind: .file,
                payload: Data(joined.utf8),
                plainPreview: names.joined(separator: ", "),
                thumbnail: thumbnail
            )
            return
        }

        // 2. Color — archived NSColor.
        if types.contains(.color),
           let color = pb.readObjects(forClasses: [NSColor.self], options: nil)?.first as? NSColor,
           let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true) {
            self.init(
                kind: .color,
                payload: data,
                plainPreview: color.hexPreview,
                thumbnail: nil
            )
            return
        }

        // 3. Image — bitmap with no usable text (screenshots, copied images). Accept any
        // pasteboard type that conforms to `public.image` (PNG, JPEG, GIF, BMP, HEIC, WebP,
        // TIFF…), not just PNG/TIFF. Keep the **original** bytes + type so paste reproduces the
        // original format (§12); fall back to a normalized PNG if those bytes are unreadable.
        if usableText == nil,
           let imageType = types.lazy.compactMap({ UTType($0.rawValue) }).first(where: { $0.conforms(to: .image) }),
           let image = NSImage(pasteboard: pb),
           let captured = Self.captureImage(from: pb, type: imageType, image: image) {
            self.init(
                kind: .image,
                payload: captured.payload,
                payloadType: captured.type,
                plainPreview: Self.imagePreview(format: captured.type, size: image.pixelSize),
                thumbnail: image.thumbnailPNG(maxDimension: 256)
            )
            return
        }

        // 4. PDF — document/vector data with no usable text and no bitmap (step 3 claims
        // pasteboards that also carry an image type, so existing captures are unchanged —
        // this catches PDF-only copies, e.g. from vector editors or "Copy as PDF", which
        // were previously dropped). Keeps the original bytes so preview/paste reproduce the
        // document (§12); the thumbnail is the rendered first page.
        if usableText == nil,
           let pdfData = pb.data(forType: .pdf), !pdfData.isEmpty,
           let document = PDFDocument(data: pdfData) {
            self.init(
                kind: .pdf,
                payload: pdfData,
                plainPreview: Self.pdfPreview(pageCount: document.pageCount),
                thumbnail: Self.pdfPagePNG(document, maxDimension: 256)
            )
            return
        }

        // 5. Code — text that looks like source code. Checked *before* richText so
        // syntax-highlighted code copied as RTF/HTML (editors, GitHub, etc.) is captured as
        // `.code` with a plain payload, not as rich text (CLAUDE.md §8b). Code is best pasted
        // as plain text anyway — editor-specific highlight colors rarely transfer usefully.
        if let text = usableText, Self.looksLikeCode(text) {
            self.init(
                kind: .code,
                payload: Data(text.utf8),
                plainPreview: preview(text),
                thumbnail: nil
            )
            return
        }

        // 6. URL (the text *is* a URL) — a string that is a single valid web URL. Checked
        // *before* richText so a URL that also carries rich formatting (RTF/HTML — e.g. a
        // link copied from a web page or rich document) is captured as `.url`, not rich
        // text (CLAUDE.md §8b). A hyperlink whose visible text is *not* a URL (e.g. "Click
        // here") fails this and stays rich text at step 7, preserving its text.
        if let text = usableText, let url = Self.singleWebURL(in: text) {
            self.init(
                kind: .url,
                payload: Data(url.absoluteString.utf8),
                plainPreview: url.absoluteString,
                thumbnail: nil
            )
            return
        }

        // 7. Rich Text — normalize RTF/RTFD/HTML to RTF data.
        // Skip pure-whitespace rich text (e.g. a copied blank space) so it isn't
        // recorded; fall through to URL/plainText for anything still meaningful (§8b).
        if let rtf = Self.normalizedRTF(from: pb, types: types) {
            let plain = usableText ?? rtf.plain
            if !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.init(
                    kind: .richText,
                    payload: rtf.data,
                    plainPreview: preview(plain),
                    thumbnail: nil
                )
                return
            }
        }

        // 8. URL (an explicit URL object) — for non-rich link copies (e.g. "Copy Link",
        // or an app that exposes only `.URL`). Below richText so a rich link with non-URL
        // visible text isn't reduced to a bare URL (§8b).
        if let url = pb.readObjects(forClasses: [NSURL.self], options: nil)?.first as? URL,
           !url.isFileURL {
            self.init(
                kind: .url,
                payload: Data(url.absoluteString.utf8),
                plainPreview: url.absoluteString,
                thumbnail: nil
            )
            return
        }

        // 9. Plain Text. (Code was already split off at step 5.)
        if let text = usableText {
            self.init(
                kind: .plainText,
                payload: Data(text.utf8),
                plainPreview: preview(text),
                thumbnail: nil
            )
            return
        }

        return nil
    }

    /// Heuristic for CLAUDE.md §8b: does this text look like source code? Two tiers — any one
    /// "strong" tell (rare in prose) classifies immediately; otherwise two "weak" tells are
    /// needed. Tuned so prose, addresses, and plain lists stay `.plainText`.
    static func looksLikeCode(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return false }
        let lines = trimmed.components(separatedBy: .newlines)
        let codeLines = lines.map { $0.trimmingCharacters(in: .whitespaces) }

        // ---- Strong tells: any single one is enough. ----

        // Multi-character operators / sequences essentially absent from prose.
        let operators = ["=>", "->", "::", "==", "!=", "===", "!==", ">=", "<=",
                         "&&", "||", "+=", "-=", "*=", "/=", "%=", "</", "/>", "/*",
                         "*/", "});", "})", "){", "();", "($", "[]", "{}", "!important"]
        if operators.contains(where: trimmed.contains) { return true }

        // A line that ends with a statement terminator / block brace, or is a lone bracket.
        if codeLines.contains(where: {
            $0.hasSuffix(";") || $0.hasSuffix("{") || $0.hasSuffix("}") ||
            $0 == "{" || $0 == "}" || $0 == "[" || $0 == "]" || $0 == "})" || $0 == "});"
        }) { return true }

        // A line beginning with an unambiguous declaration / preprocessor / markup / SQL token.
        // (Deliberately omits English-common words like "let", "var", "from", "return", "for",
        // "if", "while", "with" — those would misfire on prose.)
        let keywords = ["function ", "func ", "def ", "fn ", "class ", "struct ", "enum ",
                        "interface ", "import ", "package ", "namespace ", "public ", "private ",
                        "protected ", "static ", "const ", "void ", "async ", "await ", "yield ",
                        "lambda ", "elif ", "except", "println", "printf", "console.", "system.out",
                        "#include", "#define", "#import", "#!/", "<?php", "<!doctype", "<html",
                        "<div", "<span", "<script", "<style", "select ", "insert into",
                        "create table", "@media", "@import"]
        if codeLines.contains(where: { line in
            let l = line.lowercased()
            return keywords.contains(where: { l.hasPrefix($0) })
        }) { return true }

        // A block opener: a line ending in `:` whose next line is indented (Python/CSS/YAML).
        for i in lines.indices.dropLast() where codeLines[i].hasSuffix(":") && !codeLines[i].isEmpty {
            if lines[i + 1].hasPrefix("\t") || lines[i + 1].hasPrefix("  ") { return true }
        }

        // Two or more `identifier = value` assignment lines — an assignment block.
        if codeLines.filter(isAssignmentLine).count >= 2 { return true }

        // ---- Weak tells: need two together. ----
        var weak = 0
        // Indented continuation lines (tabs or ≥2 spaces).
        if lines.count >= 2, lines.dropFirst().contains(where: { $0.hasPrefix("\t") || $0.hasPrefix("  ") }) {
            weak += 1
        }
        // A single `identifier = value` assignment line.
        if codeLines.contains(where: isAssignmentLine) { weak += 1 }
        // A call expression: `name(` immediately after an identifier character.
        if containsCallExpression(trimmed) { weak += 1 }

        return weak >= 2
    }

    /// `identifier = value` (a single `=`, identifier-ish left side) — not `==`/`>=`/etc.
    private static func isAssignmentLine(_ line: String) -> Bool {
        guard let eq = line.range(of: " = ") else { return false }
        let lhs = line[line.startIndex..<eq.lowerBound].trimmingCharacters(in: .whitespaces)
        guard !lhs.isEmpty, lhs.count <= 40 else { return false }
        return lhs.allSatisfy { $0.isLetter || $0.isNumber || "_$.[]".contains($0) }
    }

    /// True if `text` contains a `name(` call: an identifier character immediately before a `(`.
    private static func containsCallExpression(_ text: String) -> Bool {
        var previous: Character?
        for ch in text {
            if ch == "(", let p = previous, p.isLetter || p.isNumber || p == "_" { return true }
            previous = ch
        }
        return false
    }

    /// Returns RTF data (+ a decoded plain string) from whichever rich representation is present.
    private static func normalizedRTF(from pb: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> (data: Data, plain: String)? {
        func rtf(from attr: NSAttributedString) -> (Data, String)? {
            guard let data = try? attr.data(
                from: NSRange(location: 0, length: attr.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            ) else { return nil }
            return (data, attr.string)
        }

        if let data = pb.data(forType: .rtf), let attr = NSAttributedString(rtf: data, documentAttributes: nil) {
            return rtf(from: attr)
        }
        if let data = pb.data(forType: .rtfd), let attr = NSAttributedString(rtfd: data, documentAttributes: nil) {
            return rtf(from: attr)
        }
        if let data = pb.data(forType: .html),
           let attr = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
               documentAttributes: nil
           ) {
            return rtf(from: attr)
        }
        return nil
    }

    /// An `NSImage` (and its image UTType) loaded from a file URL that is an image, or nil if
    /// the URL isn't an image (or can't be read). Type is checked by content where possible,
    /// falling back to extension.
    private static func image(atFileURL url: URL) -> (image: NSImage, type: UTType)? {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type, type.conforms(to: .image), let image = NSImage(contentsOf: url) else { return nil }
        return (image, type)
    }

    /// A small PNG thumbnail for an image or PDF file URL (PDFs render their first page,
    /// §8b), or nil for any other file (or one that can't be read). Also generates the main
    /// window's snippet-card / editor previews for image/PDF file snippets at display time
    /// (§11) — snippets store no thumbnail (§7). Nonisolated: display-time callers run it
    /// off the main actor (URL in, Data out — both Sendable).
    static func fileThumbnail(for url: URL, maxDimension: CGFloat = 256) -> Data? {
        if let img = image(atFileURL: url) { return img.image.thumbnailPNG(maxDimension: maxDimension) }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        guard type?.conforms(to: .pdf) == true, let document = PDFDocument(url: url) else { return nil }
        return pdfPagePNG(document, maxDimension: maxDimension)
    }

    /// Preview text for a PDF item: label + page count, e.g. `PDF · 3 pages` (CLAUDE.md §8b).
    static func pdfPreview(pageCount: Int) -> String {
        pageCount == 1 ? String(localized: "PDF · 1 page") : String(localized: "PDF · \(pageCount) pages")
    }

    /// A PNG render of `document`'s first page, `maxDimension` px on its longest side
    /// (upscaled if needed — also used for the paste PNG fallback, §12). Nil if the
    /// document has no pages or degenerate bounds.
    static func pdfPagePNG(_ document: PDFDocument, maxDimension: CGFloat) -> Data? {
        guard let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = maxDimension / max(bounds.width, bounds.height)
        let size = NSSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        return page.thumbnail(of: size, for: .mediaBox).pngData
    }

    /// The original bytes + type for a bitmap on the pasteboard: prefers the raw data for the
    /// detected image type (so paste reproduces the original format), falling back to a
    /// normalized PNG when that representation is missing/unreadable.
    private static func captureImage(from pb: NSPasteboard, type: UTType, image: NSImage) -> (payload: Data, type: UTType)? {
        if let data = pb.data(forType: NSPasteboard.PasteboardType(type.identifier)), !data.isEmpty {
            return (data, type)
        }
        if let png = image.pngData { return (png, .png) }
        return nil
    }

    /// Preview text for an image item: a short format label and pixel dimensions, e.g.
    /// `PNG · 1920×1080` (CLAUDE.md §8b). The label is the type's filename extension uppercased
    /// (`png` → "PNG", `jpeg` → "JPEG"), falling back to "Image".
    static func imagePreview(format type: UTType, size: CGSize) -> String {
        let label = type.preferredFilenameExtension?.uppercased() ?? String(localized: "Image")
        return "\(label) · \(Int(size.width))×\(Int(size.height))"
    }

    /// Returns a single web URL if `text` is exactly one (no surrounding words).
    private static func singleWebURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              ["http", "https", "ftp", "mailto"].contains(scheme), url.host != nil || scheme == "mailto"
        else { return nil }
        return url
    }
}

private extension Data {
    var plain: String { String(data: self, encoding: .utf8) ?? "" }
}

extension NSColor {
    /// A `#RRGGBB` (or `#RRGGBBAA`) preview string.
    var hexPreview: String {
        guard let rgb = usingColorSpace(.sRGB) else { return String(localized: "Color") }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        let a = rgb.alphaComponent
        if a < 0.999 {
            return String(format: "#%02X%02X%02X%02X", r, g, b, Int(round(a * 255)))
        }
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

extension NSImage {
    /// Pixel dimensions from the largest bitmap representation (falls back to point size).
    var pixelSize: CGSize {
        if let rep = representations.max(by: { $0.pixelsWide < $1.pixelsWide }), rep.pixelsWide > 0 {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return size
    }

    var pngData: Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// A downscaled PNG no larger than `maxDimension` on its longest side.
    func thumbnailPNG(maxDimension: CGFloat) -> Data? {
        let src = pixelSize
        guard src.width > 0, src.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(src.width, src.height))
        let target = NSSize(width: max(1, src.width * scale), height: max(1, src.height * scale))
        let thumb = NSImage(size: target)
        thumb.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        // `from:` is in the image's *point* space (`self.size`), not pixels. Passing the
        // pixel-space `src` here over-sizes the source rect on Retina/2× images (e.g. macOS
        // screenshots), so only the bottom-left quarter draws and the rest is transparent —
        // which then reads as blank padding in the preview. `.zero` draws the whole image.
        draw(in: NSRect(origin: .zero, size: target),
             from: .zero,
             operation: .copy,
             fraction: 1)
        thumb.unlockFocus()
        return thumb.pngData
    }
}
