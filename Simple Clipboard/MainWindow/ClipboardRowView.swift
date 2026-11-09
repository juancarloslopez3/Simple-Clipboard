import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One history row: source-app icon · app name · type · timestamp, with a type-specific
/// preview below. Standard content — never glass.
struct ClipboardRowView: View {
    let item: ClipboardItem

    var body: some View {
        // Resolved once per render — for a `.file` item it decodes the file list.
        let displayKind = item.displayKind
        let kindLabel = displayKind.label(fileCount: item.fileURLs.count)
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
                    Text(item.sourceAppName ?? kindLabel).font(.headline)
                    if item.sourceAppName != nil {
                        Text(kindLabel).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(item.createdAt.clipboardRowString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                preview(displayKind)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func preview(_ displayKind: ClipboardKind) -> some View {
        switch item.kind {
        case .code:
            Text(item.plainPreview)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .image, .pdf:
            // Image thumbnail plus the format line (e.g. "PNG · 1920×1080" / "PDF · 3 pages")
            // so the detail is visible here too — the header only shows the generic
            // "Image" / "PDF". Only images show a thumbnail; PDF rows stay text-only,
            // matching the panel's `presentsAsPDF` exclusion.
            VStack(alignment: .leading, spacing: 4) {
                if item.kind == .image, let nsImage = ThumbnailCache.image(for: item) {
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
                // `kindSymbol` the history modal's rows use, so an image row shows an
                // image icon and a PDF row a PDF icon.
                Label(item.plainPreview, systemImage: displayKind.symbol)
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
            // Files with a preview (images, and PDFs among other files) show it above the
            // names, every one that fits the row. PDF-only items stay text-only like `.pdf` rows,
            // and other files just get the name.
            let urls = item.fileURLs
            let thumbnail = displayKind != .pdf ? ThumbnailCache.image(for: item) : nil
            VStack(alignment: .leading, spacing: 4) {
                if let thumbnail {
                    // Moved or deleted files preview from their kept copies.
                    FileThumbnailStrip(urls: item.availableFileURLs, placeholder: thumbnail)
                }
                // Centered so the badge sits in the middle of the names when they run to several lines.
                HStack(alignment: .center, spacing: 6) {
                    // `displayKind` gives a plain `doc` for ordinary files, and the photo / PDF /
                    // folder glyph when all of them are images / PDFs / folders, matching the
                    // history modal.
                    Label(item.rowPreview, systemImage: displayKind.symbol)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(urls.count > 1 ? item.rowPreviewLineLimit : 1)
                    FileCountBadge(count: item.fileBadgeCount)
                }
            }
        default:
            textPreview
        }
    }

    private var textPreview: some View {
        Text(item.plainPreview.withoutTabs)
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

/// The capsule every small row tag is drawn in: a snippet's kind ("Rich Text", "Images") and the
/// file count (⧉ 3). They often sit side by side (snippet cards, the panel's snippet rows), so they
/// share one font, padding and fill and come out the same height.
struct RowTag<Content: View>: View {
    private let content: Content
    /// Increased on a selected row's accent fill, where a tint-colored capsule would vanish.
    @Environment(\.backgroundProminence) private var prominence

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(prominence == .increased ? AnyShapeStyle(.white.opacity(0.2)) : AnyShapeStyle(.tint.opacity(0.2)), in: .capsule)
            .fixedSize()
    }
}

extension RowTag where Content == Text {
    /// A text tag. `label` is shown as is, so pass an already-localized string.
    init(_ label: String) {
        self.init { Text(label) }
    }
}

/// Marks a row that holds several files (⧉ 3), or a folder, with how many items it holds — summed
/// with the other files copied alongside it (`fileBadgeCount`): right after the file names in a
/// history row, beside the kind tag in a snippet card's header, at the row's trailing edge in the
/// floating panel. Draws nothing for nil — a single file.
struct FileCountBadge: View {
    let count: Int?

    var body: some View {
        if let count {
            RowTag {
                HStack(spacing: 2) {
                    // Small, so the glyph fits inside the text's line height and the capsule is
                    // exactly as tall as a text tag's.
                    Image(systemName: "square.on.square.fill").imageScale(.small)
                    Text(count, format: .number).monospacedDigit()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(count) files"))
        }
    }
}

/// The main window's previews of a row's files, side by side, as many as fit the row. When some
/// don't fit, the last tile is dimmed and counts what isn't visible: itself and the ones after it,
/// so the clear tiles plus "+N" add up to the row's previews. The floating panel has no room for
/// this and keeps its single preview card.
///
/// Only the first file's thumbnail is stored, so the others are generated from the files
/// when the row appears. `placeholder` holds the row's height meanwhile and remains if none of
/// the files can be read anymore.
struct FileThumbnailStrip: View {
    private static let height: CGFloat = 64
    private static let spacing: CGFloat = 6
    /// The narrowest tile that still holds its "+N", for a very tall image.
    private static let moreTileMinWidth: CGFloat = 44
    /// More than the widest window usually fits, and the most thumbnails one row ever generates.
    private static let maxCount = 16

    private struct Tile {
        let image: NSImage
        let width: CGFloat
        /// What the tile's "+N" says, when it has one.
        let more: Int?
    }

    let placeholder: NSImage?
    private let urls: [URL]
    @State private var loaded: [NSImage] = []
    /// All the row's previews, including those past `maxCount`. Files found unreadable drop out,
    /// so past `maxCount` it can count a file that has since gone.
    @State private var previewCount = 0
    @State private var isLoading = true
    @State private var availableWidth: CGFloat = 0
    @Environment(\.displayScale) private var displayScale

    init(urls: [URL], placeholder: NSImage?) {
        self.placeholder = placeholder
        self.urls = urls.count > 1 ? urls : []
    }

    /// Whether `url` is a file `ClipboardContent.fileThumbnail` can preview.
    static func canHaveThumbnail(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf)
    }

    private var shown: [NSImage] {
        loaded.isEmpty ? (placeholder.map { [$0] } ?? []) : loaded
    }

    /// The tiles that fit `availableWidth`, at least one. Only the "+N" tile is ever cropped, apart
    /// from an image wider than the row.
    private var tiles: [Tile] {
        guard availableWidth > 0 else { return [] }
        var widths = shown.map { image in
            let natural = image.size.height > 0 ? image.size.width / image.size.height * Self.height : Self.height
            return min(natural, availableWidth)
        }
        var ends: [CGFloat] = []   // where the row would end after each tile
        for width in widths {
            let end = (ends.last.map { $0 + Self.spacing } ?? 0) + width
            if !ends.isEmpty, end > availableWidth { break }
            ends.append(end)
        }
        var count = ends.count
        // While loading, previews still on their way aren't an overflow unless the row is full.
        let overflows = !loaded.isEmpty && (count < loaded.count || (!isLoading && previewCount > count))
        if overflows {
            let room = availableWidth - ends[count - 1] - Self.spacing
            if count < shown.count, room >= Self.moreTileMinWidth {
                // The dimmed tile can be cropped, so it takes whatever room is left.
                widths[count] = room
                count += 1
            } else if count == 1, shown.count > 1, availableWidth - Self.spacing >= 2 * Self.moreTileMinWidth {
                // A lone wide image would be covered by the "+N", leaving no preview: make room.
                widths[0] = availableWidth - Self.spacing - Self.moreTileMinWidth
                widths[1] = Self.moreTileMinWidth
                count = 2
            } else {
                while count > 1,
                      ends[count - 2] + Self.spacing + max(widths[count - 1], Self.moreTileMinWidth) > availableWidth {
                    count -= 1
                }
            }
        }
        return (0..<count).map { index in
            let isMoreTile = overflows && index == count - 1
            return Tile(image: shown[index],
                        width: isMoreTile ? max(widths[index], min(Self.moreTileMinWidth, availableWidth)) : widths[index],
                        more: isMoreTile ? previewCount - index : nil)
        }
    }

    var body: some View {
        // Measured on an empty view, so the width can't depend on the tiles drawn in it.
        Color.clear
            .frame(height: shown.isEmpty ? 0 : Self.height)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
            .overlay(alignment: .leading) {
                HStack(spacing: Self.spacing) {
                    ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                        Image(nsImage: tile.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: tile.width, height: Self.height)
                            .overlay {
                                if let more = tile.more {
                                    moreLabel(more)
                                }
                            }
                            .clipShape(.rect(cornerRadius: 6))
                    }
                }
            }
            .task(id: urls) {
                let previewable = urls.filter(Self.canHaveThumbnail)
                previewCount = previewable.count
                isLoading = true
                var images: [NSImage] = []
                for url in previewable.prefix(Self.maxCount) {
                    let image = await ThumbnailCache.fileImage(for: url, scale: displayScale)
                    guard !Task.isCancelled else { return }
                    guard let image else {
                        previewCount -= 1
                        continue
                    }
                    images.append(image)
                    loaded = images
                }
                isLoading = false
            }
    }

    private func moreLabel(_ more: Int) -> some View {
        ZStack {
            Color.black.opacity(0.55)
            Text(verbatim: "+\(more)")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(more) more"))
    }
}

/// Resolves and caches source-app icons from a bundle ID.
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

/// Decoded history-row thumbnails, keyed by item id. A stored thumbnail
/// never changes, so each is decoded once and the same `NSImage` returned on every render —
/// rows are rebuilt on hover, search keystrokes and every history update, and a fresh
/// `NSImage(data:)` each time made SwiftUI decode and upload the bitmap again. `NSCache`
/// bounds the memory and evicts under pressure; a miss simply decodes again.
enum ThumbnailCache {
    @MainActor private static let images: NSCache<NSUUID, NSImage> = {
        let cache = NSCache<NSUUID, NSImage>()
        cache.totalCostLimit = 64 * 1_048_576   // decoded bitmap bytes
        return cache
    }()

    @MainActor static func image(for item: ClipboardItem) -> NSImage? {
        let key = item.id as NSUUID
        if let cached = images.object(forKey: key) { return cached }
        guard let data = item.thumbnail, let image = NSImage(data: data) else { return nil }
        let pixels = image.representations.first.map { $0.pixelsWide * $0.pixelsHigh } ?? 0
        images.setObject(image, forKey: key, cost: max(pixels * 4, data.count))
        return image
    }

    @MainActor private static let fileImages: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.totalCostLimit = 64 * 1_048_576   // decoded bitmap bytes
        return cache
    }()

    /// A thumbnail generated off the main actor from an image or PDF file, for
    /// `FileThumbnailStrip`. Nil when the file has no preview or can't be read.
    @MainActor static func fileImage(for url: URL, scale: CGFloat) async -> NSImage? {
        let key = url as NSURL
        if let cached = fileImages.object(forKey: key) { return cached }
        let data = await Task.detached(priority: .utility) {
            ClipboardContent.fileThumbnail(for: url, maxDimension: 128, scale: scale)
        }.value
        guard let data, let image = NSImage(data: data) else { return nil }
        let pixels = image.representations.first.map { $0.pixelsWide * $0.pixelsHigh } ?? 0
        fileImages.setObject(image, forKey: key, cost: max(pixels * 4, data.count))
        return image
    }
}
