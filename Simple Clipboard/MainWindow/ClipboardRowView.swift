import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One history row: source-app icon · app name · type · timestamp, with a type-specific
/// preview below (CLAUDE.md §1b). Standard content — never glass.
struct ClipboardRowView: View {
    let item: ClipboardItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: AppIconResolver.icon(for: item.sourceBundleID))
                .resizable()
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                // Baseline-align the header so the caption-sized type label and timestamp sit on
                // the headline's baseline instead of floating at its vertical middle.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // Title = source app, subtitle = content type. Fall back to the type as the
                    // title when the source app is unknown, so a title always renders.
                    Text(item.sourceAppName ?? item.kindLabel).font(.headline)
                    if item.sourceAppName != nil {
                        Text(item.kindLabel).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(item.createdAt.clipboardRowString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                preview
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .code:
            Text(item.plainPreview)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .image, .pdf:
            // Image thumbnail plus the format line (e.g. "PNG · 1920×1080" / "PDF · 3 pages",
            // §8b) so the detail is visible here too — the header only shows the generic
            // "Image" / "PDF". Only images show a thumbnail; PDF rows stay text-only,
            // matching the panel's `presentsAsPDF` exclusion (§9/§10).
            VStack(alignment: .leading, spacing: 4) {
                if item.kind == .image, let nsImage = item.thumbnail.flatMap(NSImage.init(data:)) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 64, alignment: .leading)
                        // Clip before the full-width frame: after it, the rounded rect spans the
                        // whole row, leaving the thumbnail's trailing corners square.
                        .clipShape(.rect(cornerRadius: 6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Lead the format line with the kind glyph (photo / PDF) — the same
                // `kindSymbol` the history modal's rows use (§9), so an image row shows an
                // image icon and a PDF row a PDF icon.
                Label(item.plainPreview, systemImage: item.kindSymbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .color:
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(swatchColor)
                    .frame(width: 34, height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.3)))
                Text(item.plainPreview).font(.callout.monospaced()).foregroundStyle(.secondary)
            }
        case .file:
            // Image files (e.g. a copied screenshot `.png`) carry a thumbnail — show it
            // above the file name. PDF file items also carry one (§8b) but stay text-only
            // like `.pdf` rows (§9/§10); other files just get the name.
            VStack(alignment: .leading, spacing: 4) {
                if !item.isPDFFileItem, let nsImage = item.thumbnail.flatMap(NSImage.init(data:)) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 64, alignment: .leading)
                        .clipShape(.rect(cornerRadius: 6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // `kindSymbol` gives a plain `doc` for ordinary files but a PDF glyph for a
                // PDF file item (`isPDFFileItem`), matching the history modal (§9/§10).
                Label(item.plainPreview, systemImage: item.kindSymbol)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        default:
            textPreview
        }
    }

    private var textPreview: some View {
        Text(item.plainPreview)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var swatchColor: Color {
        if let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: item.payload) {
            return Color(nsColor: nsColor)
        }
        return .gray
    }
}

/// Resolves and caches source-app icons from a bundle ID (CLAUDE.md §7).
enum AppIconResolver {
    @MainActor private static var cache: [String: NSImage] = [:]
    @MainActor private static let fallback = NSWorkspace.shared.icon(for: .applicationBundle)

    @MainActor static func icon(for bundleID: String?) -> NSImage {
        guard let bundleID else { return fallback }
        if let cached = cache[bundleID] { return cached }
        let icon: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = fallback
        }
        cache[bundleID] = icon
        return icon
    }
}
