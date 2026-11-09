import AppKit
import PDFKit
import Quartz
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Quick Look–style space-bar preview for the floating history panel (CLAUDE.md §9). Hover a row
/// and press **Space** to see the full content; press Space again, **Esc**, or click outside.
///
/// Shared state only — the panel deals in `id`s (which are stable) and the Space / Esc keys are
/// handled by `ClipboardPanel`'s existing key-down monitor (a single monitor avoids two handlers
/// fighting over Esc). The view resolves `presentedID` back to the live `ClipboardItem` from its
/// `@Query`, so the preview always reflects current data.
@MainActor
@Observable
final class ClipboardPreviewState {
    /// The row the pointer is currently over (set by each history row's `.onHover`).
    var hoveredID: UUID?
    /// The item currently shown in the preview overlay, or `nil` when closed.
    var presentedID: UUID?

    /// Clear both when the panel opens/closes so a stale hover can't preview the wrong item.
    func reset() {
        hoveredID = nil
        presentedID = nil
    }
}

/// Dimmed backdrop + centered preview card. Click the backdrop to dismiss (Space / Esc are
/// handled by `ClipboardPanel`'s key monitor).
struct ClipboardPreviewOverlay: View {
    let item: ClipboardItem
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.18))
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture(perform: onClose)

            ClipboardPreviewCard(item: item, onClose: onClose)
                .frame(maxWidth: 760, maxHeight: 560)
                .padding(32)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
    }
}

/// The preview surface: a header (⌾ close · source app · type · time) over a type-specific
/// full view. Standard content — never glass (CLAUDE.md §3).
private struct ClipboardPreviewCard: View {
    let item: ClipboardItem
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .clipShape(.rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .shadow(radius: 30, y: 12)
    }

    private var header: some View {
        HStack(spacing: 10) {
            PreviewCloseButton(action: onClose)
            Image(nsImage: AppIconResolver.icon(for: item.sourceBundleID))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                // Title = source app, subtitle = content type. Fall back to the type as the
                // title when the source app is unknown, so a title always renders.
                Text(item.sourceAppName ?? item.kindLabel).font(.headline)
                if item.sourceAppName != nil {
                    Text(item.kindLabel).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Text(item.createdAt.clipboardRowString)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .plainText, .code, .url:
            ScrollView {
                Text(fullText.isEmpty ? "—" : fullText)
                    .font(item.kind == .plainText ? .body : .body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        case .richText:
            RichTextDisplayView(rtfData: item.payload)
        case .image:
            if let image = NSImage(data: item.payload) {
                ZoomableImageView(image: image)
            } else {
                unavailable
            }
        case .color:
            colorPreview
        case .file:
            FilePreviewContent(item: item)
        case .pdf:
            if let document = PDFDocument(data: item.payload) {
                PDFDocumentView(document: document, contentID: item.id)
            } else {
                unavailable
            }
        }
    }

    /// Full text from the payload (the stored `plainPreview` is capped at 2000 chars — §8b).
    private var fullText: String {
        String(data: item.payload, encoding: .utf8) ?? item.plainPreview
    }

    private var colorPreview: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 12)
                .fill(swatchColor)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.3)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(item.plainPreview)
                .font(.title3.monospaced())
                .textSelection(.enabled)
        }
        .padding(16)
    }

    private var unavailable: some View {
        ContentUnavailableView("No Preview", systemImage: item.kindSymbol)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var swatchColor: Color {
        if let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: item.payload) {
            return Color(nsColor: nsColor)
        }
        return .gray
    }
}

// MARK: - Snippet preview

/// Space-bar Quick Look preview for the snippets panel (CLAUDE.md §9/§11) — the snippet counterpart
/// of `ClipboardPreviewOverlay`. Shares the panel's `ClipboardPreviewState` (`presentedID` is the
/// snippet's stable `id`) and the same tap-vs-hold Space semantics handled by `ClipboardPanel`; this
/// view only renders the overlay and dismisses on a backdrop click.
struct SnippetPreviewOverlay: View {
    let snippet: Snippet
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.18))
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture(perform: onClose)

            SnippetPreviewCard(snippet: snippet, onClose: onClose)
                .frame(maxWidth: 760, maxHeight: 560)
                .padding(32)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
    }
}

/// The snippet preview surface: a header (⌾ close · title · type · time) over a type-specific
/// full view — mirrors `ClipboardPreviewCard`. Plain text scrolls, rich text renders its RTF, a
/// file snippet previews the referenced file (Quick Look, or PDFKit for a PDF). Standard
/// content — never glass.
private struct SnippetPreviewCard: View {
    let snippet: Snippet
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .clipShape(.rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .shadow(radius: 30, y: 12)
    }

    /// Content-type label / glyph, taken from `ClipboardKind` so they match the snippet rows
    /// and history modal for the equivalent kind (§9/§11).
    private var kind: ClipboardKind {
        if snippet.isFile { return .file }
        if snippet.isRichText { return .richText }
        return .plainText
    }

    private var header: some View {
        HStack(spacing: 10) {
            PreviewCloseButton(action: onClose)
            Image(systemName: kind.symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(snippet.title.isEmpty ? String(localized: "Untitled") : snippet.title).font(.headline)
                Text(kind.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text(snippet.createdAt.clipboardRowString)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if snippet.isFile {
            SnippetFilePreviewContent(snippet: snippet)
        } else if snippet.isRichText {
            RichTextDisplayView(rtfData: snippet.payload)
        } else {
            ScrollView {
                Text(snippet.plainString.isEmpty ? "—" : snippet.plainString)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }
}

/// Swallows **auto-repeat Space key-downs** at the AppKit level while a Space preview is
/// open (§10/§11). SwiftUI's `.onKeyPress` marks the repeats `.handled`, but on macOS they
/// still fall through to the window's responder chain, which plays the "can't type here"
/// error beep for every repeat — so *holding* Space to preview sounded like a stream of
/// error sounds. A local monitor returning `nil` consumes just those repeats before
/// dispatch; the initial press and the key-up (which drive open/close and the tap-vs-hold
/// split) still flow to `.onKeyPress` untouched. Installed only while `active` (preview
/// open), so held-Space typing in text fields elsewhere is never affected.
private struct SpaceRepeatSilencer: ViewModifier {
    let active: Bool
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onChange(of: active) { _, nowActive in
                nowActive ? install() : remove()
            }
            .onDisappear(perform: remove)
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let plainSpace = event.charactersIgnoringModifiers == " "
                && event.modifierFlags.intersection([.command, .option, .control]).isEmpty
            return (plainSpace && event.isARepeat) ? nil : event
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

extension View {
    /// Mutes the responder-chain error beep from held-Space auto-repeats while a Space
    /// preview overlay is open — pass the surface's `isPreviewing` flag.
    func silencesSpaceRepeats(while active: Bool) -> some View {
        modifier(SpaceRepeatSilencer(active: active))
    }
}

/// Quick Look–style circled ✕ at the leading edge of both preview cards' headers — a visible
/// way out alongside Space / Esc / the backdrop click (§9).
private struct PreviewCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Close")
    }
}

/// File-snippet preview — the referenced file rendered by Quick Look when it still exists (PDFKit
/// for a PDF, matching the file history preview, §9/§10), else a "File not found" placeholder. A
/// file snippet references a single file; a legacy multi-file snippet previews the first (§11).
private struct SnippetFilePreviewContent: View {
    let snippet: Snippet

    private var urls: [URL] { snippet.fileURLs }

    var body: some View {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        if let first = existing.first {
            VStack(spacing: 0) {
                fullPreview(of: first)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if urls.count > 1 {
                    Divider()
                    Text(urls.map(\.lastPathComponent).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }
        } else {
            VStack(spacing: 12) {
                Label(urls.first?.lastPathComponent ?? snippet.plainPreview, systemImage: "doc")
                    .font(.headline)
                Text(urls.isEmpty ? String(localized: "No file") : String(localized: "File not found"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// PDF files get the PDFKit preview (scrollable, pinch zoom) like `.pdf` / PDF-file history
    /// items; image files get the zoomable `NSScrollView`-backed view (Quick Look renders images
    /// through a static remote snapshot inside the panel — no pinch zoom, same reason the PDF
    /// branch exists); everything else keeps native Quick Look, falling back to the big icon +
    /// name card for files Quick Look can't render (§9/§11).
    @ViewBuilder
    private func fullPreview(of url: URL) -> some View {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true,
           let document = PDFDocument(url: url) {
            PDFDocumentView(document: document, contentID: url)
        } else if isImageFileURL(url), let image = NSImage(contentsOf: url) {
            ZoomableImageView(image: image)
        } else {
            FileQuickLookOrIconView(url: url)
        }
    }
}

/// File preview: the real document rendered by Quick Look when the file still exists, falling
/// back to the stored thumbnail / name otherwise (CLAUDE.md §10 — copied files may have moved).
private struct FilePreviewContent: View {
    let item: ClipboardItem

    private var urls: [URL] { item.fileURLs }

    var body: some View {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        if let first = existing.first {
            VStack(spacing: 0) {
                fullPreview(of: first)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if urls.count > 1 {
                    Divider()
                    Text(urls.map(\.lastPathComponent).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }
        } else {
            VStack(spacing: 12) {
                if let thumbnail = item.thumbnail.flatMap(NSImage.init(data:)) {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 280)
                        .clipShape(.rect(cornerRadius: 8))
                }
                Label(item.plainPreview, systemImage: "doc")
                    .font(.headline)
                Text(urls.isEmpty ? String(localized: "No file") : String(localized: "File not found"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// PDF files get the same native PDFKit preview as `.pdf` data items (all pages, pinch
    /// zoom) — they present as PDFs everywhere else (§10), and `QLPreviewView` renders via a
    /// remote out-of-process view that is effectively a static snapshot inside the panel:
    /// no scroll view in its hierarchy, so scrolling/zooming a multi-page PDF is impossible.
    /// Image files get the zoomable `NSScrollView`-backed view for the same reason (Quick Look's
    /// remote snapshot can't pinch-zoom). Everything else keeps Quick Look.
    @ViewBuilder
    private func fullPreview(of url: URL) -> some View {
        if item.isPDFFileItem, let document = PDFDocument(url: url) {
            PDFDocumentView(document: document, contentID: url)
        } else if isImageFileURL(url), let image = NSImage(contentsOf: url) {
            ZoomableImageView(image: image)
        } else {
            FileQuickLookOrIconView(url: url)
        }
    }
}

/// True when the URL points at a bitmap/vector image. Quick Look renders images through a
/// static out-of-process snapshot inside the floating panel, so image files are shown with
/// `ZoomableImageView` (trackpad pinch zoom + pan) instead — matching `.image` history items.
private func isImageFileURL(_ url: URL) -> Bool {
    UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
}

/// Quick Look content preview when the system can actually render the file, else the big
/// icon + name fallback (§9/§11). Availability is probed via `QLThumbnailGenerator`: a file
/// that can produce a *thumbnail* representation has a Quick Look renderer, while one that
/// can't (archives, executables, unknown types…) would get Quick Look's generic sheet with
/// its size/date/"Open with" chrome — replaced here by `FileIconPreviewView`.
private struct FileQuickLookOrIconView: View {
    let url: URL
    /// `nil` while the probe runs (a few ms) — renders nothing so neither branch flashes.
    @State private var hasRichPreview: Bool?

    var body: some View {
        ZStack {
            if let hasRichPreview {
                if hasRichPreview {
                    FileQuickLookView(url: url)
                } else {
                    FileIconPreviewView(url: url)
                }
            } else {
                Color.clear
            }
        }
        .task(id: url) { hasRichPreview = await Self.probeRichPreview(url) }
    }

    private static func probeRichPreview(_ url: URL) async -> Bool {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 64, height: 64), scale: 1,
            representationTypes: .thumbnail)
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                continuation.resume(returning: rep?.type == .thumbnail)
            }
        }
    }
}

/// The no-preview fallback: the file's large Finder icon over its name, centered — Quick
/// Look's own generic layout minus the size/date/"Open with" chrome (§9/§11).
private struct FileIconPreviewView: View {
    let url: URL

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                .resizable()
                .interpolation(.high)
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
            Text(url.lastPathComponent.isEmpty ? url.path(percentEncoded: false) : url.lastPathComponent)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .truncationMode(.middle)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Zoomable image preview backed by `NSScrollView` magnification. The image opens scaled to fit
/// the card (never above 100 % of its pixel size, so small images aren't blown up), trackpad
/// pinch / smart-magnify zooms about the pointer, and two-finger scrolling pans once zoomed in.
/// Zooming out floors at the fitted scale, so the full image is always one pinch away.
private struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> ImageZoomScrollView {
        ImageZoomScrollView(image: image)
    }

    func updateNSView(_ nsView: ImageZoomScrollView, context: Context) {
        nsView.setImage(image)
    }
}

private final class ImageZoomScrollView: NSScrollView {
    private let imageView = NSImageView()
    /// Magnification that exactly fits the image in the clip view; recomputed on layout.
    private var fittedMagnification: CGFloat = 1
    private var hasAppliedInitialFit = false

    init(image: NSImage) {
        super.init(frame: .zero)
        drawsBackground = false
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        maxMagnification = 8
        usesPredominantAxisScrolling = false

        let clipView = ImageCenteringClipView()
        clipView.drawsBackground = false
        contentView = clipView

        imageView.imageScaling = .scaleAxesIndependently
        documentView = imageView
        setImage(image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func setImage(_ image: NSImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        // Frame at pixel size so magnification 1 is pixel-exact (matches the `PNG · W×H` label).
        imageView.frame = NSRect(origin: .zero, size: Self.pixelSize(of: image))
        hasAppliedInitialFit = false
        needsLayout = true
    }

    override func layout() {
        super.layout()
        refit()
    }

    /// Keep the fit scale in sync with the available size, moving the live magnification only
    /// while it is still at the fitted value — a user's pinch zoom is never clobbered.
    private func refit() {
        let available = contentSize
        let natural = imageView.frame.size
        guard available.width > 1, available.height > 1,
              natural.width > 0, natural.height > 0 else { return }

        let fit = min(1, available.width / natural.width, available.height / natural.height)
        let wasAtFit = !hasAppliedInitialFit || abs(magnification - fittedMagnification) < 0.001
        fittedMagnification = fit
        minMagnification = fit
        if wasAtFit {
            magnification = fit
            hasAppliedInitialFit = true
        }
    }

    private static func pixelSize(of image: NSImage) -> NSSize {
        let pixelSizes = image.representations
            .map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
            .filter { $0.width > 0 && $0.height > 0 }
        // Vector-backed reps report 0 pixels; fall back to the image's point size.
        return pixelSizes.max { $0.width * $0.height < $1.width * $1.height } ?? image.size
    }
}

/// Clip view that centers a document smaller than the visible area, so a fit-scaled image sits
/// in the middle of the card instead of pinned to the bottom-left.
private final class ImageCenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if doc.frame.width < rect.width {
            rect.origin.x = doc.frame.midX - rect.width / 2
        }
        if doc.frame.height < rect.height {
            rect.origin.y = doc.frame.midY - rect.height / 2
        }
        return rect
    }
}

/// Scrollable multi-page PDF preview backed by PDFKit's `PDFView` — opens scaled to fit,
/// with native page scrolling and trackpad pinch zoom.
///
/// `document` is rebuilt by the caller on every body evaluation (a fresh `PDFDocument`
/// instance from the same bytes), so updates compare `contentID` — the stable identity of
/// the *content* (item id / file URL) — instead of the instance: swapping in an equal-but-new
/// document resets PDFKit's zoom and scroll position.
private struct PDFDocumentView: NSViewRepresentable {
    let document: PDFDocument
    let contentID: AnyHashable

    init(document: PDFDocument, contentID: some Hashable) {
        self.document = document
        self.contentID = AnyHashable(contentID)
    }

    func makeCoordinator() -> Coordinator { Coordinator(contentID: contentID) }

    final class Coordinator {
        var contentID: AnyHashable
        init(contentID: AnyHashable) { self.contentID = contentID }
    }

    func makeNSView(context: Context) -> PDFView {
        let view = FittedPDFView()
        view.displayMode = .singlePageContinuous
        view.document = document
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        guard context.coordinator.contentID != contentID else { return }
        context.coordinator.contentID = contentID
        nsView.document = document
    }
}

/// `PDFView` that manages its own scale-to-fit (`autoScales` off). Pinch zoom is handled by
/// PDFView's **internal scroll view** (`allowsMagnification` — magnify events never reach the
/// PDFView responder chain), so the fit must never be re-applied while a gesture is live:
/// `autoScales`' re-fit stomped the pinch on single-page documents, and re-applying fit from
/// every `layout()` pass reset the scroll view's magnification/position mid-flight — pinch
/// dead, scrolling pinned to page 1. Fit is therefore applied **only when the view's size
/// actually changes** (first layout, card resize), and only while the scale is still at the
/// previous fit, so a user's zoom is never clobbered; steady-state layout passes (scrolling,
/// zooming) touch nothing. The gesture is bounded by the internal scroll view's own
/// magnification limits (fit … 8×) — its defaults (0.1…100) ignore `min`/`maxScaleFactor`.
private final class FittedPDFView: PDFView {
    private var fittedSize: NSSize = .zero

    override func layout() {
        super.layout()
        guard bounds.size != fittedSize else { return }
        let fit = scaleFactorForSizeToFit
        guard fit > 0 else { return }
        let wasAtFit = fittedSize == .zero || abs(scaleFactor - minScaleFactor) < 0.001
        fittedSize = bounds.size
        minScaleFactor = fit
        maxScaleFactor = 8
        if let scroll = subviews.lazy.compactMap({ $0 as? NSScrollView }).first {
            scroll.minMagnification = fit
            scroll.maxMagnification = 8
        }
        if wasAtFit {
            scaleFactor = fit
        }
    }
}

/// Native Quick Look preview of a single file URL, embedded inline.
private struct FileQuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        guard let view = QLPreviewView(frame: .zero, style: .normal) else { return NSView() }
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? QLPreviewView else { return }
        if (view.previewItem as? NSURL)?.absoluteString != url.absoluteString {
            view.previewItem = url as NSURL
        }
    }
}

/// Read-only rich-text rendering of RTF payload data, backed by `NSTextView`
/// (mirrors the editor wrapper in `SnippetEditorView`, but non-editable).
private struct RichTextDisplayView: NSViewRepresentable {
    let rtfData: Data

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        apply(to: textView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        apply(to: textView)
    }

    private func apply(to textView: NSTextView) {
        if let attr = NSAttributedString(rtf: rtfData, documentAttributes: nil) {
            textView.textStorage?.setAttributedString(attr)
        }
    }
}
