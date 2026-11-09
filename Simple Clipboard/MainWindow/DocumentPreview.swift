import AppKit
import Contacts
import PDFKit
import SwiftUI
import WebKit

// MARK: - Zoom

/// A document view the Space preview's zoom controls drive (`PreviewZoomControls`).
@MainActor
protocol PreviewZoomable: AnyObject {
    /// Zooms one stop in (+1) or out (-1).
    func zoom(byStep step: Int)
    func zoomToFit()
}

/// Content that pans sideways itself, so `FilePreviewPager` leaves a horizontal swipe over it alone
/// except past the edge it's panned to. (A plain `NSScrollView` is recognized without it.)
@MainActor
protocol HorizontallyPannable: AnyObject {
    /// Whether it can still pan to show more on its left and on its right; nil when it doesn't pan
    /// sideways (it fits).
    var horizontalPanRoom: HorizontalPanRoom? { get }
}

/// Whether zoomed content can still pan to show more on its left and on its right: false on the side
/// it's already at the edge of.
struct HorizontalPanRoom {
    let left: Bool
    let right: Bool
}

/// What a zoomable preview reports to its controls: the scale (1 = 100 %), how far it can go, the
/// page on screen, and whether the pointer is over it. The document view writes it; the controls
/// read it and call back through `target`.
@MainActor
@Observable
final class PreviewZoom {
    private(set) var scale: CGFloat = 1
    private(set) var canZoomIn = false
    private(set) var canZoomOut = false
    private(set) var page = 0
    private(set) var pageCount = 0
    /// The pointer is over the document (its view's own tracking area, which keeps working in the
    /// floating panel and while the controls are under the pointer).
    var isPointerInside = false
    /// Bumped by a keyboard zoom, which shows the controls for a moment.
    private(set) var flashCount = 0
    @ObservationIgnored weak var target: (any PreviewZoomable)?

    /// Every preview — document, slide, sheet or image — zooms between 20 % and 500 %.
    static let minimumScale: CGFloat = 0.2
    static let maximumScale: CGFloat = 5

    /// The zoom range for content whose fit (`zoomToFit`) is `fit`: 20 % to 500 %, except that a fit
    /// below 20 % (a big photo, a very wide sheet) stays reachable, so the whole of it is always one
    /// click or pinch away. A fit above 500 % is clamped by the caller (`clampedFit`).
    static func range(fit: CGFloat) -> ClosedRange<CGFloat> {
        max(min(minimumScale, fit), 0.001)...maximumScale
    }

    /// A fit no larger than the 500 % maximum (a tiny image or page in a big card).
    static func clampedFit(_ fit: CGFloat) -> CGFloat {
        min(fit, maximumScale)
    }

    /// The zoom steps the buttons and ⌘+ / ⌘− go through, as in Preview.
    private static let stops: [CGFloat] = [0.2, 0.25, 0.33, 0.5, 0.67, 0.75, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5]

    /// The next stop from `scale` in the direction of `step`, kept within `range`. A stop within 5 %
    /// of the scale is skipped, so every step visibly changes it (a fit of 76 % goes to 67 %, not 75 %).
    static func scale(from scale: CGFloat, step: Int, within range: ClosedRange<CGFloat>) -> CGFloat {
        let next = step > 0 ? stops.first { $0 > scale * 1.05 } : stops.last { $0 < scale * 0.95 }
        return min(max(next ?? (step > 0 ? range.upperBound : range.lowerBound), range.lowerBound), range.upperBound)
    }

    func update(scale: CGFloat, range: ClosedRange<CGFloat>) {
        if abs(self.scale - scale) > 0.0001 { self.scale = scale }
        let canIn = scale < range.upperBound * 0.999
        let canOut = scale > range.lowerBound * 1.001
        if canZoomIn != canIn { canZoomIn = canIn }
        if canZoomOut != canOut { canZoomOut = canOut }
    }

    func update(page: Int, of count: Int) {
        if self.page != page { self.page = page }
        if pageCount != count { pageCount = count }
    }

    func setPointerInside(_ inside: Bool) {
        if isPointerInside != inside { isPointerInside = inside }
    }

    func zoomIn() { target?.zoom(byStep: 1) }
    func zoomOut() { target?.zoom(byStep: -1) }
    func zoomToFit() { target?.zoomToFit() }
    func flash() { flashCount += 1 }
}

/// A preview's trackpad pinch, ahead of AppKit's own handling of it. A local monitor takes the
/// magnify events of a pinch that begins over `host` — what AppKit's hit test finds there, so not
/// the zoom controls over it or a pager's page out of view — and hands each event's change and
/// the pointer's place to `zoom`. `init(host:scrollView:onZoom:)` zooms a scroll view (an image, a
/// PDF) by AppKit's own step, kept within its `minMagnification…maxMagnification`.
///
/// Ahead of AppKit, for two reasons. AppKit's pinch holds the zoom at 100 % and at the fit for a
/// long stretch of the fingers' travel (`_magnificationInflectionPoints`: a steady pinch on a Word
/// page stopped at 98 % for as much travel again as it took to get there) and springs back to them
/// when the fingers lift inside it, so a photo could never be pinched below its fit; in a card a
/// few hundred points wide that read as the pinch not working. It also runs past min / max against
/// a resistance and springs back. And `NSApplication` was seen not to hand magnify events on to a
/// window that wasn't key (in an inactive test app), while a local monitor sees them before it
/// decides. (Not the scroll view's pinch recognizer: magnify events reach `magnifyWithEvent:`
/// without going through its action.)
@MainActor
final class PreviewPinch {
    private weak var host: NSView?
    private let zoom: @MainActor (_ change: CGFloat, _ locationInWindow: NSPoint) -> Void
    private var monitor: Any?
    /// The pinch under way began over `host`, so its events are this view's.
    private var isPinching = false

    init(host: NSView, zoom: @escaping @MainActor (_ change: CGFloat, _ locationInWindow: NSPoint) -> Void) {
        self.host = host
        self.zoom = zoom
    }

    /// Zooms `scrollView()` without AppKit's holds and overshoot, then calls `onZoom` (for zoom
    /// controls to follow: PDFView doesn't report a pinch's magnification).
    convenience init(host: NSView, scrollView: @escaping @MainActor () -> NSScrollView?,
                     onZoom: @escaping @MainActor () -> Void = {}) {
        self.init(host: host) { change, locationInWindow in
            guard let scrollView = scrollView() else { return }
            // AppKit's own step: the zoom times one plus the change.
            let current = scrollView.magnification
            let target = min(max(current * (1 + change), scrollView.minMagnification), scrollView.maxMagnification)
            guard abs(target - current) > 0.000_01 else { return }
            // Keeps this point (in the clip view's bounds) where it is on screen.
            scrollView.setMagnification(target, centeredAt: scrollView.contentView.convert(locationInWindow, from: nil))
            onZoom()
        }
    }

    /// Call from the host's `viewDidMoveToWindow`: listens while the host is in a window.
    func hostDidMoveToWindow() {
        if host?.window != nil {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return consumed ? nil : event
            }
        } else if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            isPinching = false
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let host, let window = host.window, event.window === window else { return false }
        switch event.phase {
        case .began:
            isPinching = isOverHost(event, host: host, window: window)
            guard isPinching else { return false }
            zoom(event.magnification, event.locationInWindow)
        case .changed:
            guard isPinching else { return false }
            zoom(event.magnification, event.locationInWindow)
        case .ended, .cancelled:
            guard isPinching else { return false }
            isPinching = false
        default:
            // An event outside a phased gesture: a step of its own.
            guard !isPinching, isOverHost(event, host: host, window: window) else { return isPinching }
            zoom(event.magnification, event.locationInWindow)
        }
        return true
    }

    private func isOverHost(_ event: NSEvent, host: NSView, window: NSWindow) -> Bool {
        guard let hit = window.contentView?.superview?.hitTest(event.locationInWindow) else { return false }
        return hit.isDescendant(of: host)
    }
}

extension View {
    /// The zoom controls over a zoomable preview, shown while the pointer is over it (and for a
    /// moment after a keyboard zoom), and ⌘+ / ⌘− / ⌘0 while it's the page on screen.
    func previewZoomControls(_ zoom: PreviewZoom) -> some View {
        modifier(PreviewZoomOverlay(zoom: zoom))
    }
}

private struct PreviewZoomOverlay: ViewModifier {
    let zoom: PreviewZoom
    @Environment(\.isCurrentPreviewPage) private var isCurrentPage
    @State private var isFlashing = false

    func body(content: Content) -> some View {
        let isVisible = zoom.isPointerInside || isFlashing
        content
            .overlay(alignment: .bottom) {
                PreviewZoomControls(zoom: zoom)
                    .padding(.bottom, 10)
                    .opacity(isVisible ? 1 : 0)
                    .allowsHitTesting(isVisible)
                    .animation(.easeOut(duration: 0.18), value: isVisible)
            }
            .background(PreviewZoomKeys(zoom: zoom, isActive: isCurrentPage))
            .task(id: zoom.flashCount) {
                guard zoom.flashCount > 0 else { return }
                isFlashing = true
                try? await Task.sleep(for: .seconds(1.2))
                if !Task.isCancelled { isFlashing = false }
            }
    }
}

/// − · 62 % · + (· 3 / 12): zoom out, zoom to fit (the percentage), zoom in, and the page on screen
/// for a document of several pages. Standard material, not glass: it floats over content.
private struct PreviewZoomControls: View {
    let zoom: PreviewZoom

    var body: some View {
        HStack(spacing: 0) {
            ZoomControlButton(symbol: "minus", help: "Zoom Out", enabled: zoom.canZoomOut, action: zoom.zoomOut)
            Button(action: zoom.zoomToFit) {
                Text(Double(zoom.scale), format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .frame(minWidth: 40)
                    .padding(.vertical, 3)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Zoom to Fit")
            ZoomControlButton(symbol: "plus", help: "Zoom In", enabled: zoom.canZoomIn, action: zoom.zoomIn)
            if zoom.pageCount > 1 {
                // Not `Divider()`: the separator color vanishes in the material over a white page.
                Capsule()
                    .fill(.secondary)
                    .frame(width: 1.5, height: 14)
                    // The + button's frame already leaves space on its side of the glyph.
                    .padding(.trailing, 8)
                    .accessibilityHidden(true)
                Text(verbatim: "\(zoom.page + 1) / \(zoom.pageCount)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 8)
            }
        }
        .font(.caption)
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: .capsule)
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .fixedSize()
    }
}

private struct ZoomControlButton: View {
    let symbol: String
    let help: LocalizedStringKey
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// ⌘+ (or ⌘=) / ⌘− / ⌘0 for the preview on screen in this view's window. A local monitor, since
/// the panel's search field (or the main window's list) keeps keyboard focus while a preview is up.
private struct PreviewZoomKeys: NSViewRepresentable {
    let zoom: PreviewZoom
    let isActive: Bool

    @MainActor final class Coordinator {
        var zoom: PreviewZoom
        var isActive: Bool
        var monitor: Any?

        init(zoom: PreviewZoom, isActive: Bool) {
            self.zoom = zoom
            self.isActive = isActive
        }

        func handle(_ event: NSEvent, in view: NSView) -> Bool {
            guard isActive, event.window === view.window else { return false }
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard modifiers == .command || modifiers == [.command, .shift] else { return false }
            switch event.charactersIgnoringModifiers {
            case "=", "+": zoom.zoomIn()
            case "-": zoom.zoomOut()
            case "0": zoom.zoomToFit()
            default: return false
            }
            zoom.flash()
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(zoom: zoom, isActive: isActive) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view, weak coordinator] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let view, let coordinator else { return false }
                return coordinator.handle(event, in: view)
            }
            return consumed ? nil : event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.zoom = zoom
        context.coordinator.isActive = isActive
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }
}

// MARK: - PDF

/// Scrollable multi-page PDF preview backed by PDFKit's `PDFView` — opens scaled to fit, with
/// native page scrolling, trackpad pinch zoom and the zoom controls (`previewZoomControls`). Used
/// for PDF items and files, and for Word documents and presentations (`OfficeDocumentPreview`).
///
/// `document` is rebuilt by some callers on every body evaluation (a fresh `PDFDocument` from the
/// same bytes), so updates compare `contentID` — the stable identity of the *content* (item id /
/// file URL) — instead of the instance: swapping in an equal-but-new document resets PDFKit's zoom
/// and scroll position.
struct PDFDocumentView: View {
    let document: PDFDocument
    let contentID: AnyHashable
    @State private var zoom = PreviewZoom()

    init(document: PDFDocument, contentID: some Hashable) {
        self.document = document
        self.contentID = AnyHashable(contentID)
    }

    var body: some View {
        PDFKitView(document: document, contentID: contentID, zoom: zoom)
            .previewZoomControls(zoom)
    }
}

private struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    let contentID: AnyHashable
    let zoom: PreviewZoom

    func makeCoordinator() -> Coordinator { Coordinator(contentID: contentID) }

    final class Coordinator {
        var contentID: AnyHashable
        init(contentID: AnyHashable) { self.contentID = contentID }
    }

    func makeNSView(context: Context) -> FittedPDFView {
        let view = FittedPDFView()
        view.displayMode = .singlePageContinuous
        view.document = document
        view.zoomState = zoom
        return view
    }

    func updateNSView(_ nsView: FittedPDFView, context: Context) {
        nsView.zoomState = zoom
        guard context.coordinator.contentID != contentID else { return }
        context.coordinator.contentID = contentID
        nsView.show(document)
    }
}

/// `PDFView` that manages its own scale-to-fit (`autoScales` off). Pinch zoom is handled by
/// PDFView's **internal scroll view** (`allowsMagnification` — magnify events never reach the
/// PDFView responder chain), so the fit must never be re-applied while a gesture is live:
/// `autoScales`' re-fit stomped the pinch on single-page documents, and re-applying fit from
/// every `layout()` pass reset the scroll view's magnification/position mid-flight — pinch
/// dead, scrolling pinned to page 1. Fit is therefore applied **only when the view's size
/// actually changes** (first layout, card resize, a new document), and only while the scale is
/// still at the previous fit, so a user's zoom is never clobbered; steady-state layout passes
/// (scrolling, zooming) touch nothing. The gesture is bounded by the internal scroll view's own
/// magnification limits — its defaults (0.1…100) ignore `min`/`maxScaleFactor` — and its
/// recognizer is taken over by `PreviewPinch`, which zooms without AppKit's holds at 100 % and
/// at the fit.
///
/// Zooms from 20 % to 500 % (`PreviewZoom.range`): below the fit, so a long document can be skimmed
/// several pages to the screen, and below 20 % only as far as a whole page needs.
private final class FittedPDFView: PDFView, PreviewZoomable {
    weak var zoomState: PreviewZoom? {
        didSet {
            guard zoomState !== oldValue else { return }
            zoomState?.target = self
            publish()
        }
    }

    private var fittedSize: NSSize = .zero
    private var fitScale: CGFloat = 0
    /// The internal scroll view's pinch, without AppKit's holds (`PreviewPinch`).
    private var pinch: PreviewPinch?
    private var pointerArea: NSTrackingArea?
    private var needsPointerSeed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pinch = PreviewPinch(host: self, scrollView: { [weak self] in self?.internalScrollView },
                             onZoom: { [weak self] in self?.publish() })
        let center = NotificationCenter.default
        for name in [Notification.Name.PDFViewScaleChanged, .PDFViewPageChanged, .PDFViewDocumentChanged] {
            center.addObserver(self, selector: #selector(viewChanged(_:)), name: name, object: self)
        }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerArea = area
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// A tracking area reports only crossings, and the card usually opens right under the pointer,
    /// so the first layout with a size checks where it is (`seedPointer`).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsPointerSeed = window != nil
        pinch?.hostDidMoveToWindow()
    }

    /// A new document for the same view (the main window's preview following the selection).
    func show(_ document: PDFDocument) {
        self.document = document
        fittedSize = .zero
        needsLayout = true
    }

    /// PDFView's internal scroll view, which does the zooming.
    private var internalScrollView: NSScrollView? {
        subviews.lazy.compactMap { $0 as? NSScrollView }.first
    }

    override func layout() {
        super.layout()
        seedPointer()
        guard bounds.size != fittedSize else { return }
        let fit = PreviewZoom.clampedFit(scaleFactorForSizeToFit)
        guard fit > 0 else { return }
        let wasAtFit = fittedSize == .zero || abs(scaleFactor - fitScale) < 0.001
        fittedSize = bounds.size
        fitScale = fit
        let range = scaleRange(fit: fit)
        minScaleFactor = range.lowerBound
        maxScaleFactor = range.upperBound
        if let scroll = internalScrollView {
            scroll.minMagnification = range.lowerBound
            scroll.maxMagnification = range.upperBound
        }
        if wasAtFit {
            scaleFactor = fit
        }
        publish()
    }

    /// 20 % to 500 % (`PreviewZoom.range`), reaching below 20 % only when the width fit or a whole
    /// page in view needs it (a poster, a long receipt).
    private func scaleRange(fit: CGFloat) -> ClosedRange<CGFloat> {
        var pageFit = fit
        if let page = currentPage ?? document?.page(at: 0) {
            var size = page.bounds(for: displayBox).size
            if page.rotation % 180 != 0 { size = NSSize(width: size.height, height: size.width) }
            if size.width > 0, size.height > 0 {
                // Less a little for PDFView's margins around the page.
                pageFit = min(bounds.width / size.width, bounds.height / size.height) * 0.92
            }
        }
        return PreviewZoom.range(fit: min(fit, pageFit))
    }

    func zoom(byStep step: Int) {
        scaleFactor = PreviewZoom.scale(from: scaleFactor, step: step, within: minScaleFactor...maxScaleFactor)
    }

    func zoomToFit() {
        scaleFactor = fitScale > 0 ? fitScale : PreviewZoom.clampedFit(scaleFactorForSizeToFit)
    }

    @objc private func viewChanged(_ notification: Notification) {
        publish()
    }

    private func publish() {
        guard let zoomState else { return }
        zoomState.target = self
        zoomState.update(scale: scaleFactor, range: minScaleFactor...maxScaleFactor)
        let index = currentPage.flatMap { document?.index(for: $0) } ?? 0
        zoomState.update(page: index, of: document?.pageCount ?? 0)
    }

    private func seedPointer() {
        guard needsPointerSeed, let window, !bounds.isEmpty else { return }
        needsPointerSeed = false
        zoomState?.setPointerInside(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === pointerArea { zoomState?.setPointerInside(true) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === pointerArea { zoomState?.setPointerInside(false) }
    }
}

// MARK: - Office documents

/// An Office file's page: a Word document as pages and a presentation as slides in the PDF
/// view, a workbook as its sheets (`SpreadsheetPreview`) — rendered from Quick Look's own Office
/// HTML by `OfficePreviewRenderer`, so they open fitted to the card and zoom in and out freely. A
/// small spinner shows while a file renders the first time (well under a second for most); a file
/// that can't be rendered gets Quick Look's own view, as before.
struct OfficeDocumentPreview: View {
    let url: URL
    let kind: OfficeDocumentKind

    private enum Content {
        case pages(PDFDocument)
        case sheets([OfficeSheet])
        case unavailable
    }

    /// Tagged with its file, so a page reused for another file never shows the previous one.
    @State private var loaded: (url: URL, content: Content)?

    var body: some View {
        ZStack {
            if let loaded, loaded.url == url {
                switch loaded.content {
                case .pages(let document):
                    PDFDocumentView(document: document, contentID: url)
                case .sheets(let sheets):
                    SpreadsheetPreview(sheets: sheets)
                case .unavailable:
                    FileQuickLookOrIconView(url: url)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            guard loaded?.url != url else { return }
            let preview = await OfficePreviewRenderer.shared.preview(of: url, kind: kind)
            guard !Task.isCancelled else { return }
            let content: Content = switch preview {
            case .pages(let data)?: PDFDocument(data: data).map { .pages($0) } ?? .unavailable
            case .sheets(let sheets)?: .sheets(sheets)
            case nil: .unavailable
            }
            loaded = (url, content)
        }
    }
}

/// A workbook: the selected sheet, zoomable, over a strip of sheet tabs when there are several.
private struct SpreadsheetPreview: View {
    let sheets: [OfficeSheet]
    @State private var selection = 0
    @State private var zoom = PreviewZoom()

    var body: some View {
        VStack(spacing: 0) {
            SheetView(sheet: sheets[min(selection, sheets.count - 1)], zoom: zoom)
                .previewZoomControls(zoom)
            if sheets.count > 1 {
                Divider()
                SheetTabs(sheets: sheets, selection: $selection)
            }
        }
    }
}

/// The sheet tabs, as Numbers and Excel put them under the sheet. Scrolls sideways when they don't fit.
private struct SheetTabs: View {
    let sheets: [OfficeSheet]
    @Binding var selection: Int

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(sheets.indices, id: \.self) { index in
                    let isSelected = index == selection
                    Button { selection = index } label: {
                        Text(sheets[index].name)
                            .lineLimit(1)
                            .fontWeight(isSelected ? .semibold : .regular)
                            .foregroundStyle(isSelected ? .primary : .secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.quaternary.opacity(isSelected ? 1 : 0), in: .rect(cornerRadius: 5))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .font(.caption)
    }
}

private struct SheetView: NSViewRepresentable {
    let sheet: OfficeSheet
    let zoom: PreviewZoom

    func makeNSView(context: Context) -> SheetWebView {
        let view = SheetWebView()
        view.zoomState = zoom
        view.show(sheet)
        return view
    }

    func updateNSView(_ nsView: SheetWebView, context: Context) {
        nsView.zoomState = zoom
        nsView.show(sheet)
    }

    static func dismantleNSView(_ nsView: SheetWebView, coordinator: ()) {
        nsView.stopLoading()
        nsView.navigationDelegate = nil
    }
}

/// One sheet's page, zoomed by the preview rather than by WebKit: WebKit's own pinch stops at
/// 100 %, so a wide sheet could never be seen whole. Its pinch is turned off and the gesture sets
/// the page scale directly (`magnification`), which below 100 % lays the sheet out smaller with
/// more of it in view. Opens at 100 %, as Numbers and Excel do (the percentage goes to the
/// full-width fit); zooms from 20 % — or the width fit, when that's smaller — up to 500 %. Links in
/// cells open in the browser; nothing else navigates.
final class SheetWebView: WKWebView, PreviewZoomable, HorizontallyPannable, WebScrollTracking, WKNavigationDelegate {
    weak var zoomState: PreviewZoom? {
        didSet {
            guard zoomState !== oldValue else { return }
            zoomState?.target = self
            publish()
        }
    }

    private var sheet: OfficeSheet?
    /// The sheet's size at 100 %; zero until its page has loaded.
    private var contentSize: CGSize = .zero
    /// The width the opening scale was last applied for.
    private var fittedWidth: CGFloat = 0
    /// Still at the opening scale (nothing zoomed since), so a resize re-applies it.
    private var isAtOpeningScale = true
    /// Where the page is scrolled sideways, as it last reported it (`WebScrollReporter`), in CSS
    /// pixels: the left of the part in view, that part's width and the sheet's. Nil until it has.
    fileprivate var scrollPosition: WebScrollPosition?
    private var pinch: PreviewPinch?
    private var pointerArea: NSTrackingArea?
    private var needsPointerSeed = false

    init() {
        let configuration = OfficeWebContent.configuration()
        let reporter = WebScrollReporter()
        WebScrollReporter.install(reporter, in: configuration.userContentController)
        super.init(frame: .zero, configuration: configuration)
        reporter.view = self
        pinch = PreviewPinch(host: self) { [weak self] change, locationInWindow in
            self?.pinchZoom(by: change, at: locationInWindow)
        }
        allowsMagnification = false
        allowsBackForwardNavigationGestures = false
        navigationDelegate = self
        underPageBackgroundColor = .white
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerArea = area
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// A tracking area reports only crossings, and the card usually opens right under the pointer,
    /// so the first layout with a size checks where it is (`seedPointer`).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsPointerSeed = window != nil
        pinch?.hostDidMoveToWindow()
    }

    func show(_ sheet: OfficeSheet) {
        guard sheet != self.sheet else { return }
        self.sheet = sheet
        contentSize = .zero
        fittedWidth = 0
        isAtOpeningScale = true
        scrollPosition = nil
        // Measured at 100 %: below it the layout viewport widens, and a narrow sheet would measure
        // as wide as that.
        setMagnification(1, centeredAt: .zero)
        loadFileURL(sheet.url, allowingReadAccessTo: sheet.folder)
    }

    // MARK: Scale

    /// The scale that fits the sheet's width (never above 100 %).
    private var fitScale: CGFloat {
        guard contentSize.width > 0, bounds.width > 0 else { return 1 }
        return min(1, bounds.width / contentSize.width)
    }

    private let openingScale: CGFloat = 1

    /// `PreviewZoom.range` for the width fit, but no smaller than 10 %: a sheet too wide to fit even
    /// then is past reading, and its cells would be under a pixel.
    private var scaleRange: ClosedRange<CGFloat> {
        let range = PreviewZoom.range(fit: fitScale)
        return max(range.lowerBound, 0.1)...range.upperBound
    }

    /// Sets the scale keeping the content under `anchor` (a point in this view) where it is.
    /// WebKit's `centeredAt` isn't such an anchor: it scrolls to (scroll − point) × new / old, so
    /// the point passed is the one that makes that come out right.
    private func setScale(_ target: CGFloat, anchor: CGPoint) {
        let old = magnification
        let range = scaleRange
        let new = min(max(target, range.lowerBound), range.upperBound)
        if abs(new - old) > 0.0005 {
            let factor = old / new - 1
            setMagnification(new, centeredAt: CGPoint(x: anchor.x * factor, y: anchor.y * factor))
        }
        publish()
    }

    override func layout() {
        super.layout()
        seedPointer()
        guard contentSize != .zero, bounds.width > 0, bounds.width != fittedWidth else { return }
        fittedWidth = bounds.width
        setScale(isAtOpeningScale ? openingScale : magnification, anchor: .zero)
    }

    /// Pinches normally arrive through `pinch` (`PreviewPinch`); this catches any that reach the
    /// view itself, and keeps WebKit's own zoom out of it.
    override func magnify(with event: NSEvent) {
        pinchZoom(by: event.magnification, at: event.locationInWindow)
    }

    private func pinchZoom(by change: CGFloat, at locationInWindow: NSPoint) {
        guard contentSize != .zero else { return }
        isAtOpeningScale = false
        setScale(magnification * (1 + change), anchor: convert(locationInWindow, from: nil))
    }

    /// Two-finger double tap: 100 % at the pointer, and from there the width fit (or 200 % for a
    /// sheet that already fits).
    override func smartMagnify(with event: NSEvent) {
        guard contentSize != .zero else { return }
        isAtOpeningScale = false
        let target: CGFloat = abs(magnification - 1) > 0.01 ? 1 : (fitScale < 0.99 ? fitScale : 2)
        setScale(target, anchor: convert(event.locationInWindow, from: nil))
    }

    func zoom(byStep step: Int) {
        guard contentSize != .zero else { return }
        isAtOpeningScale = false
        setScale(PreviewZoom.scale(from: magnification, step: step, within: scaleRange),
                 anchor: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    func zoomToFit() {
        guard contentSize != .zero else { return }
        isAtOpeningScale = false
        setScale(fitScale, anchor: .zero)
    }

    var horizontalPanRoom: HorizontalPanRoom? {
        guard contentSize.width * magnification > bounds.width + 1 else { return nil }
        // Not reported yet: it pans both ways, as far as the pager knows.
        guard let scroll = scrollPosition else { return HorizontalPanRoom(left: true, right: true) }
        // A point on screen, in CSS pixels.
        let slack = 1 / max(Double(magnification), 0.01)
        return HorizontalPanRoom(left: scroll.left > slack, right: scroll.left + scroll.width < scroll.total - slack)
    }

    private func publish() {
        guard let zoomState else { return }
        zoomState.target = self
        zoomState.update(scale: magnification, range: contentSize == .zero ? magnification...magnification : scaleRange)
        zoomState.update(page: 0, of: 0)
    }

    // MARK: Pointer

    private func seedPointer() {
        guard needsPointerSeed, let window, !bounds.isEmpty else { return }
        needsPointerSeed = false
        zoomState?.setPointerInside(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === pointerArea { zoomState?.setPointerInside(true) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === pointerArea { zoomState?.setPointerInside(false) }
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let loading = sheet
        Task { @MainActor [weak self] in
            let measured = try? await self?.evaluateJavaScript(
                "[document.documentElement.scrollWidth, document.documentElement.scrollHeight]") as? [Double]
            guard let self, self.sheet == loading, let measured, measured.count == 2 else { return }
            self.contentSize = CGSize(width: max(measured[0], 1), height: max(measured[1], 1))
            self.fittedWidth = 0
            self.needsLayout = true
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if navigationAction.navigationType == .linkActivated {
            if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            return .cancel
        }
        return url.isFileURL ? .allow : .cancel
    }
}

/// Where a web page is scrolled sideways, in CSS pixels: the left of the part in view, that part's
/// width and the page's.
typealias WebScrollPosition = (left: Double, width: Double, total: Double)

/// A web view that keeps `WebScrollReporter`'s reports.
@MainActor
fileprivate protocol WebScrollTracking: AnyObject {
    var scrollPosition: WebScrollPosition? { get set }
}

extension WebScrollTracking {
    /// `HorizontallyPannable`'s room for the reported position at `magnification`; nil while the
    /// page fits the view's width (or hasn't reported yet).
    func panRoom(magnification: CGFloat) -> HorizontalPanRoom? {
        guard let scroll = scrollPosition, scroll.total > scroll.width + 1 else { return nil }
        // A point on screen, in CSS pixels.
        let slack = 1 / max(Double(magnification), 0.01)
        return HorizontalPanRoom(left: scroll.left > slack, right: scroll.left + scroll.width < scroll.total - slack)
    }
}

/// Tells a web view (a sheet's, a web location's) where its page is scrolled sideways, so the pager
/// knows when a zoomed or wide page is at its left or right edge. A script in the app's own content
/// world (which runs whether or not the page may run its own) reports on every scroll and resize of
/// the page or of its visual viewport, which a zoom moves.
@MainActor
private final class WebScrollReporter: NSObject, WKScriptMessageHandler {
    weak var view: (any WebScrollTracking)?

    private static let name = "previewScroll"

    /// The visual viewport is the part in view at any zoom; `scrollX` / `innerWidth` are its stand-in
    /// where there's none.
    private static let source = """
        (() => {
          const report = () => {
            const v = window.visualViewport;
            window.webkit.messageHandlers.\(name).postMessage([
              v ? v.pageLeft : window.scrollX,
              v ? v.width : window.innerWidth,
              document.documentElement.scrollWidth]);
          };
          addEventListener('scroll', report, { passive: true });
          addEventListener('resize', report);
          if (window.visualViewport) {
            visualViewport.addEventListener('scroll', report);
            visualViewport.addEventListener('resize', report);
          }
          report();
        })();
        """

    /// The controller keeps `reporter`, which keeps its view weakly.
    static func install(_ reporter: WebScrollReporter, in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: .defaultClient))
        controller.add(reporter, contentWorld: .defaultClient, name: name)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let values = message.body as? [Double], values.count == 3 else { return }
        view?.scrollPosition = (left: values[0], width: values[1], total: values[2])
    }
}

// MARK: - Calendar files

/// An `.ics` file's page: its events as cards — date and time, place, link, repeat, alerts,
/// organizer, invitees and notes — sized to the card and scrolling when there are many. Quick
/// Look's own calendar preview is a day grid showing only the title. A file that can't be read gets
/// Quick Look's view, as before.
struct CalendarFilePreview: View {
    let url: URL
    @State private var loaded: (url: URL, file: CalendarFile?)?

    var body: some View {
        ZStack {
            if let loaded, loaded.url == url {
                if let file = loaded.file {
                    CalendarFileView(file: file)
                } else {
                    FileQuickLookOrIconView(url: url)
                }
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            guard loaded?.url != url else { return }
            let url = url
            let file = await Task.detached(priority: .userInitiated) {
                (try? Data(contentsOf: url, options: .mappedIfSafe)).flatMap(CalendarFile.init(data:))
            }.value
            guard !Task.isCancelled else { return }
            loaded = (url, file)
        }
    }
}

private struct CalendarFileView: View {
    let file: CalendarFile

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if file.events.count > 1 || file.name != nil {
                    VStack(alignment: .leading, spacing: 2) {
                        if let name = file.name {
                            Text(name).font(.headline)
                        }
                        if file.events.count > 1 {
                            Text("\(file.events.count) events")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, 16)
                }
                ForEach(Array(file.events.enumerated()), id: \.element.id) { index, event in
                    if index > 0 {
                        Divider().padding(.vertical, 18)
                    }
                    CalendarEventView(event: event)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CalendarEventView: View {
    let event: CalendarFile.Event

    /// More invitees than this collapse into "N more".
    private let inviteeLimit = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                CalendarDateBadge(date: event.start, isTask: event.isTask)
                VStack(alignment: .leading, spacing: 3) {
                    Group {
                        if event.title.isEmpty {
                            Text("Untitled Event")
                        } else {
                            Text(event.title)
                        }
                    }
                    .font(.title3.weight(.semibold))
                    .strikethrough(event.isCancelled)
                    if event.isCancelled {
                        Text("Cancelled")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                    } else if event.isTask {
                        Text("Reminder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(dateLines, id: \.self) { line in
                        Text(line).foregroundStyle(.secondary)
                    }
                    if let zoneLine {
                        Text(zoneLine)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                if let location = event.location {
                    detail("mappin.and.ellipse") { Text(location) }
                }
                if let url = event.url {
                    detail("link") {
                        Link(destination: url) {
                            Text(url.absoluteString)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .help(url.absoluteString)
                    }
                }
                if let recurrence {
                    detail("repeat") { Text(recurrence) }
                }
                if let alarms {
                    detail("bell") { Text(alarms) }
                }
                if let organizer = event.organizer {
                    detail("person.crop.circle") { organizerView(organizer) }
                }
                if !event.attendees.isEmpty {
                    detail("person.2") { attendeesView }
                }
                if let notes = event.notes {
                    detail("text.alignleft") { Text(Self.linkified(notes)) }
                }
            }
        }
        .textSelection(.enabled)
    }

    private func detail(_ symbol: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func organizerView(_ organizer: CalendarFile.Person) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(organizer.displayName)
                Text("Organizer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if organizer.name != nil, let email = organizer.email {
                Text(email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var attendeesView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if event.attendees.count == 1 {
                    Text("1 invitee")
                } else {
                    Text("\(event.attendees.count) invitees")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(event.attendees.prefix(inviteeLimit), id: \.self) { attendee in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    ResponseMark(response: attendee.response)
                    Text(attendee.person.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if attendee.isOptional {
                        Text("Optional")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .help(attendee.person.email ?? attendee.person.displayName)
            }
            if event.attendees.count > inviteeLimit {
                Text("\(event.attendees.count - inviteeLimit) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The day, then the times: "Tuesday, 10 November 2026" / "10:00 – 11:30" (or "All day"); an
    /// event across days on one line.
    private var dateLines: [String] {
        guard let start = event.start else { return [] }
        let calendar = Calendar.current
        let day = start.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        if event.isAllDay {
            // A to-do's date is just when it's due.
            if event.isTask { return [day] }
            // DTEND is the day after the last one.
            let lastDay = event.end.flatMap { calendar.date(byAdding: .day, value: -1, to: $0) } ?? start
            guard lastDay > start, !calendar.isDate(lastDay, inSameDayAs: start) else {
                return [day, String(localized: "All day")]
            }
            return [(start..<lastDay).formatted(.interval.day().month(.abbreviated).year()), String(localized: "All day")]
        }
        guard let end = event.end, end > start else {
            return [day, start.formatted(date: .omitted, time: .shortened)]
        }
        if calendar.isDate(start, inSameDayAs: end) {
            return [day, (start..<end).formatted(.interval.hour().minute())]
        }
        return [(start..<end).formatted(date: .abbreviated, time: .shortened)]
    }

    /// The times in the zone the event was written in, when that zone is a different offset from
    /// the viewer's: "16:00 – 17:30 · Eastern Time".
    private var zoneLine: String? {
        guard !event.isAllDay, let zone = event.timeZone, let start = event.start,
              zone.secondsFromGMT(for: start) != TimeZone.current.secondsFromGMT(for: start)
        else { return nil }
        let sameDay = event.end.map { end in
            var calendar = Calendar.current
            calendar.timeZone = zone
            return calendar.isDate(start, inSameDayAs: end)
        } ?? true
        let times: String
        if let end = event.end, end > start {
            let style = Date.IntervalFormatStyle(date: sameDay ? .omitted : .abbreviated, time: .shortened, timeZone: zone)
            times = (start..<end).formatted(style)
        } else {
            times = start.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone))
        }
        let name = zone.localizedName(for: .generic, locale: .current) ?? zone.identifier
        return "\(times) · \(name)"
    }

    private var recurrence: String? {
        guard let rule = event.recurrence else { return nil }
        let interval = rule.interval
        var parts: [String] = []
        switch rule.frequency {
        case .daily: parts.append(interval == 1 ? String(localized: "Every day") : String(localized: "Every \(interval) days"))
        case .weekly: parts.append(interval == 1 ? String(localized: "Every week") : String(localized: "Every \(interval) weeks"))
        case .monthly: parts.append(interval == 1 ? String(localized: "Every month") : String(localized: "Every \(interval) months"))
        case .yearly: parts.append(interval == 1 ? String(localized: "Every year") : String(localized: "Every \(interval) years"))
        }
        let symbols = Calendar.current.weekdaySymbols
        let days = rule.weekdays.compactMap { symbols.indices.contains($0 - 1) ? symbols[$0 - 1] : nil }
        if !days.isEmpty, rule.frequency != .daily {
            parts.append(days.formatted(.list(type: .and)))
        }
        if let count = rule.count, count > 1 {
            parts.append(String(localized: "\(count) times"))
        } else if let until = rule.until {
            parts.append(String(localized: "Until \(until.formatted(date: .abbreviated, time: .omitted))"))
        }
        return parts.joined(separator: " · ")
    }

    private var alarms: String? {
        guard !event.alarms.isEmpty else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.weekOfMonth, .day, .hour, .minute]
        formatter.maximumUnitCount = 2
        let texts = event.alarms.map { offset -> String in
            guard abs(offset) >= 60, let amount = formatter.string(from: abs(offset)) else {
                return String(localized: "At start time")
            }
            return offset < 0 ? String(localized: "\(amount) before") : String(localized: "\(amount) after")
        }
        return texts.formatted(.list(type: .and))
    }

    /// The notes with their web addresses as links.
    private static func linkified(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result)
            else { continue }
            result[lower..<upper].link = url
        }
        return result
    }
}

/// An invitee's answer, as Calendar marks it.
private struct ResponseMark: View {
    let response: CalendarFile.Attendee.Response

    var body: some View {
        Group {
            switch response {
            case .accepted:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .accessibilityLabel(Text("Accepted"))
            case .declined:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    .accessibilityLabel(Text("Declined"))
            case .tentative:
                Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
                    .accessibilityLabel(Text("Maybe"))
            case .pending:
                Image(systemName: "circle").foregroundStyle(.secondary)
                    .accessibilityLabel(Text("No response"))
            }
        }
        .imageScale(.small)
    }
}

/// A tear-off calendar page for the event's day: the month on a red band over the day number.
private struct CalendarDateBadge: View {
    let date: Date?
    let isTask: Bool

    var body: some View {
        Group {
            if let date {
                VStack(spacing: 0) {
                    Text(date.formatted(.dateTime.month(.abbreviated)).uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 16)
                        .background(Color.red)
                    Text(date.formatted(.dateTime.day()))
                        .font(.system(size: 22, weight: .medium))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Image(systemName: isTask ? "checklist" : "calendar")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 48, height: 50)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(.rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .accessibilityHidden(true)
    }
}

// MARK: - Contact cards

/// A contact card file's page: each contact as Contacts' card shows one — a poster with the
/// picture or initials in a large disc over the name, nickname, job and company, then each of its
/// phones, emails, addresses, links, dates, profiles and note in a row under its label — scrolling
/// when there are many. None of Contacts' message / call / mail buttons, and nothing in it is a
/// link: a phone or email row has a button that copies it instead. Read by Contacts' own vCard
/// reader, which involves no access to the
/// user's contacts. Quick Look has only the file's icon. A file it can't read gets Quick Look's view.
struct ContactFilePreview: View {
    let url: URL
    @State private var loaded: (url: URL, cards: [ContactCard]?)?

    var body: some View {
        ZStack {
            if let loaded, loaded.url == url {
                if let cards = loaded.cards {
                    ContactCardsView(cards: cards)
                } else {
                    FileQuickLookOrIconView(url: url)
                }
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            guard loaded?.url != url else { return }
            let url = url
            let cards = await Task.detached(priority: .userInitiated) {
                (try? Data(contentsOf: url, options: .mappedIfSafe)).flatMap(ContactCard.cards(in:))
            }.value
            guard !Task.isCancelled else { return }
            loaded = (url, cards)
        }
    }
}

/// One contact of a vCard file, as its page shows it.
struct ContactCard: Identifiable, Sendable {
    /// A labeled value: "mobile" +34 600 123 456.
    struct Field: Identifiable, Sendable {
        let id: Int
        let label: String
        let value: String
        /// A phone number or email address: its row has a Copy button.
        var isCopyable = false
    }

    let id: Int
    /// The full name, or the company for a company's card; empty when it has neither.
    let name: String
    /// The lines under the name: nickname, job title and department, company.
    let subtitles: [String]
    /// For a card without a picture.
    let initials: String
    let isCompany: Bool
    let imageData: Data?
    let fields: [Field]

    /// The file's contacts, in order; nil when it has none Contacts can read.
    static func cards(in data: Data) -> [ContactCard]? {
        guard let contacts = try? CNContactVCardSerialization.contacts(with: readable(data)), !contacts.isEmpty
        else { return nil }
        return contacts.enumerated().map { ContactCard(contact: $1, id: $0) }
    }

    /// The file in a form Contacts' reader gets right. It reads UTF-8 without a byte-order mark as
    /// Mac Roman in a vCard 4.0 ("Zoë" came out "Zo√´") and rejects a file that starts with one, so
    /// UTF-8 text with accents goes in as UTF-16, which it reads right in every version. Not a card
    /// with quoted-printable values (vCard 2.1), which come out garbled from UTF-16, and which keep
    /// their accents in that encoding anyway.
    private static func readable(_ data: Data) -> Data {
        let data = data.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(data.dropFirst(3)) : data
        guard data.contains(where: { $0 >= 0x80 }),
              let text = String(data: data, encoding: .utf8),
              text.range(of: "QUOTED-PRINTABLE", options: .caseInsensitive) == nil,
              let utf16 = text.data(using: .utf16)
        else { return data }
        return utf16
    }

    /// Every value is read only when the reader filled it in: reading one it didn't raises an
    /// Objective-C exception.
    private init(contact: CNContact, id: Int) {
        self.id = id
        func has(_ key: String) -> Bool { contact.isKeyAvailable(key) }
        func text(_ key: String, _ value: @autoclosure () -> String) -> String {
            has(key) ? value().trimmingCharacters(in: .whitespacesAndNewlines) : ""
        }

        let company = text(CNContactOrganizationNameKey, contact.organizationName)
        isCompany = has(CNContactTypeKey) && contact.contactType == .organization
        let fullName = contact.areKeysAvailable([CNContactFormatter.descriptorForRequiredKeys(for: .fullName)])
            ? CNContactFormatter.string(from: contact, style: .fullName) ?? "" : ""
        name = isCompany && !company.isEmpty ? company : (fullName.isEmpty ? company : fullName)

        var subtitles: [String] = []
        let nickname = text(CNContactNicknameKey, contact.nickname)
        if !nickname.isEmpty {
            let locale = Locale.current
            subtitles.append((locale.quotationBeginDelimiter ?? "“") + nickname + (locale.quotationEndDelimiter ?? "”"))
        }
        let job = [text(CNContactJobTitleKey, contact.jobTitle), text(CNContactDepartmentNameKey, contact.departmentName)]
            .filter { !$0.isEmpty }
        if !job.isEmpty { subtitles.append(job.joined(separator: " · ")) }
        if !company.isEmpty, company != name { subtitles.append(company) }
        self.subtitles = subtitles

        var nameParts = PersonNameComponents()
        nameParts.givenName = text(CNContactGivenNameKey, contact.givenName)
        nameParts.familyName = text(CNContactFamilyNameKey, contact.familyName)
        let personInitials = PersonNameComponentsFormatter.localizedString(from: nameParts, style: .abbreviated)
        initials = isCompany || personInitials.isEmpty ? company.prefix(1).uppercased() : personInitials

        imageData = has(CNContactImageDataKey) ? contact.imageData
            : has(CNContactThumbnailImageDataKey) ? contact.thumbnailImageData : nil

        var fields: [Field] = []
        func add(_ label: String, _ value: String, copyable: Bool = false) {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            fields.append(Field(id: fields.count, label: label, value: value, isCopyable: copyable))
        }
        func label(_ raw: String?, or fallback: String) -> String {
            guard let raw, !raw.isEmpty else { return fallback }
            return CNLabeledValue<NSString>.localizedString(forLabel: raw)
        }

        if has(CNContactPhoneNumbersKey) {
            for phone in contact.phoneNumbers {
                add(label(phone.label, or: String(localized: "phone")), phone.value.stringValue, copyable: true)
            }
        }
        if has(CNContactEmailAddressesKey) {
            for email in contact.emailAddresses {
                add(label(email.label, or: String(localized: "email")), email.value as String, copyable: true)
            }
        }
        if has(CNContactUrlAddressesKey) {
            for address in contact.urlAddresses {
                add(label(address.label, or: String(localized: "homepage")), address.value as String)
            }
        }
        if has(CNContactPostalAddressesKey) {
            for address in contact.postalAddresses {
                add(label(address.label, or: String(localized: "address")),
                    CNPostalAddressFormatter.string(from: address.value, style: .mailingAddress))
            }
        }
        if has(CNContactBirthdayKey), let birthday = contact.birthday, let date = Self.dateText(birthday) {
            add(String(localized: "birthday"), date)
        }
        if has(CNContactDatesKey) {
            for date in contact.dates {
                if let text = Self.dateText(date.value as DateComponents) {
                    add(label(date.label, or: String(localized: "date")), text)
                }
            }
        }
        if has(CNContactRelationsKey) {
            for relation in contact.contactRelations {
                add(label(relation.label, or: String(localized: "related name")), relation.value.name)
            }
        }
        if has(CNContactSocialProfilesKey) {
            for profile in contact.socialProfiles {
                let service = profile.value.service
                let name = service.isEmpty ? label(profile.label, or: String(localized: "profile"))
                    : CNSocialProfile.localizedString(forService: service)
                let username = profile.value.username
                add(name, username.isEmpty ? profile.value.urlString : username)
            }
        }
        if has(CNContactInstantMessageAddressesKey) {
            for address in contact.instantMessageAddresses {
                let service = address.value.service
                add(service.isEmpty ? label(address.label, or: String(localized: "instant message"))
                    : CNInstantMessageAddress.localizedString(forService: service),
                    address.value.username)
            }
        }
        if has(CNContactNoteKey) {
            add(String(localized: "note"), contact.note)
        }
        self.fields = fields
    }

    /// "12 April 1985", or "12 April" for a date saved without its year.
    private static func dateText(_ components: DateComponents) -> String? {
        var components = components
        let calendar = components.calendar ?? Calendar(identifier: .gregorian)
        components.calendar = nil
        components.timeZone = nil
        guard let year = components.year else {
            // A leap year, so 29 February has a date.
            components.year = 2000
            return calendar.date(from: components)?.formatted(.dateTime.month(.wide).day())
        }
        components.year = year
        return calendar.date(from: components)?.formatted(date: .long, time: .omitted)
    }
}

/// The contacts on a Contacts-style poster: its blue-gray gradient — or the first contact's picture,
/// blurred — behind them, white type, the values in tinted rows. The same in light and dark mode,
/// as Contacts' card is. A file of several contacts lists them one under another.
private struct ContactCardsView: View {
    let cards: [ContactCard]

    private var backdropImage: NSImage? {
        cards.first?.imageData.flatMap(NSImage.init(data:))
    }

    var body: some View {
        let backdropImage = backdropImage
        ScrollView {
            LazyVStack(spacing: 0) {
                if cards.count > 1 {
                    Text("\(cards.count) contacts")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.bottom, 14)
                }
                ForEach(cards) { card in
                    if card.id > 0 {
                        Rectangle()
                            .fill(.white.opacity(0.3))
                            .frame(height: 1)
                            .padding(.vertical, 26)
                    }
                    ContactCardView(card: card, overPhoto: backdropImage != nil)
                }
            }
            // A card's width at most, as in Contacts, however wide the window.
            .frame(maxWidth: 460)
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
        .background {
            if let backdropImage {
                Image(nsImage: backdropImage)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 60, opaque: true)
                    .overlay(Color.black.opacity(0.25))
                    .clipped()
            } else {
                ContactPoster.gradient
            }
        }
        // Light scroll bars and selection on the dark poster.
        .environment(\.colorScheme, .dark)
    }
}

/// Contacts' poster colors, taken from its card.
private enum ContactPoster {
    static let gradient = LinearGradient(
        colors: [Color(red: 166 / 255, green: 175 / 255, blue: 198 / 255),
                 Color(red: 146 / 255, green: 160 / 255, blue: 187 / 255),
                 Color(red: 102 / 255, green: 113 / 255, blue: 169 / 255)],
        startPoint: .top, endPoint: .bottom)
    /// The rows' blue-violet tint over the gradient.
    static let rowTint = Color(red: 150 / 255, green: 155 / 255, blue: 1).opacity(0.3)
    /// A row's round button: a lighter blue-violet over the row.
    static let buttonTint = Color(red: 165 / 255, green: 178 / 255, blue: 1).opacity(0.75)
}

/// One contact: the disc, the name and the lines under it centred, then a row per value with its
/// label above it, and a Copy button at the end of a phone's or email's row, where Contacts has its
/// call and mail buttons.
private struct ContactCardView: View {
    let card: ContactCard
    /// The poster is the contact's blurred picture rather than the gradient: plain white rows.
    let overPhoto: Bool

    var body: some View {
        VStack(spacing: 0) {
            ContactPicture(card: card)
                .padding(.bottom, 18)
            Group {
                if card.name.isEmpty {
                    Text("No Name")
                } else {
                    Text(card.name)
                }
            }
            .font(.title2.weight(.bold))
            .multilineTextAlignment(.center)
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            ForEach(card.subtitles, id: \.self) { line in
                Text(line)
                    .font(.system(size: 11, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .padding(.top, 4)
            }
            if !card.fields.isEmpty {
                VStack(spacing: 6) {
                    ForEach(card.fields) { field in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(field.label)
                                    .foregroundStyle(.white.opacity(0.85))
                                Text(field.value)
                                    .font(.title3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if field.isCopyable {
                                ContactCopyButton(value: field.value,
                                                  fill: overPhoto ? .white.opacity(0.28) : ContactPoster.buttonTint)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(overPhoto ? .white.opacity(0.16) : ContactPoster.rowTint,
                                    in: .rect(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding(.top, 20)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.white)
        .textSelection(.enabled)
    }
}

/// The contact's picture, or its initials (a company's or person glyph without them), in Contacts'
/// large disc: the initials on a disc of clear Liquid Glass, a picture cut round with a bright rim.
private struct ContactPicture: View {
    let card: ContactCard
    private let diameter: CGFloat = 150

    var body: some View {
        Group {
            if let data = card.imageData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: diameter, height: diameter)
                    .clipShape(.circle)
                    .overlay {
                        // A shadow just inside a bright rim, as glass has.
                        Circle()
                            .strokeBorder(.black.opacity(0.14), lineWidth: 5)
                            .blur(radius: 3)
                            .padding(1.5)
                            .clipShape(.circle)
                        Circle()
                            .strokeBorder(LinearGradient(colors: [.white, .white.opacity(0.55), .white.opacity(0.9)],
                                                         startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
                    }
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            } else {
                Group {
                    if card.initials.isEmpty {
                        Image(systemName: card.isCompany ? "building.2.fill" : "person.fill")
                            .font(.system(size: diameter * 0.38))
                    } else {
                        Text(card.initials)
                            .font(.system(size: diameter * 0.42, weight: .medium))
                            .minimumScaleFactor(0.5)
                            .padding(.horizontal, diameter * 0.12)
                    }
                }
                .foregroundStyle(.white.opacity(0.95))
                .frame(width: diameter, height: diameter)
                .glassEffect(.clear, in: .circle)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A phone's or email's Copy button, round at the end of its row as Contacts' call and mail buttons
/// are: it puts the value on the clipboard as plain text, and shows a tick for a moment after.
private struct ContactCopyButton: View {
    let value: String
    let fill: Color
    @State private var copies = 0
    @State private var showsCopied = false

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
            showsCopied = true
            copies += 1
        } label: {
            Image(systemName: showsCopied ? "checkmark" : "doc.on.doc.fill")
                .font(.system(size: 12, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 28)
                .background(fill, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(showsCopied ? "Copied" : "Copy")
        .accessibilityLabel(showsCopied ? Text("Copied") : Text("Copy"))
        // Each copy restarts the tick's time.
        .task(id: copies) {
            guard showsCopied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            showsCopied = false
        }
    }
}

// MARK: - Web locations

/// A web location's page. A web address shows the live page itself (`WebLocationPage`); any
/// other (mail, FTP, a file location) shows what it opens — its name and the whole address. Quick
/// Look has only the file's icon. A file without an address it can read gets Quick Look's view.
struct InternetLocationPreview: View {
    let url: URL
    @State private var loaded: (url: URL, link: URL?)?

    var body: some View {
        ZStack {
            if let loaded, loaded.url == url {
                if let link = loaded.link {
                    if WebLocationPage.canShow(link) {
                        WebLocationPage(file: url, link: link)
                    } else {
                        InternetLocationView(file: url, link: link)
                    }
                } else {
                    FileQuickLookOrIconView(url: url)
                }
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            guard loaded?.url != url else { return }
            let url = url
            let link = await Task.detached(priority: .userInitiated) {
                (try? Data(contentsOf: url, options: .mappedIfSafe)).flatMap(InternetLocation.link(in:))
            }.value
            guard !Task.isCancelled else { return }
            loaded = (url, link)
        }
    }
}

enum InternetLocation {
    /// The address a web location file opens: the `URL` of a `.webloc` / `.inetloc` property list,
    /// or the `URL=` line of a Windows `.url` shortcut. Nil when it has none with a scheme.
    static func link(in data: Data) -> URL? {
        if let list = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
            return (list["URL"] as? String).flatMap(url(from:))
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("url=") { return url(from: String(line.dropFirst(4))) }
        }
        return nil
    }

    private static func url(from string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme, !scheme.isEmpty
        else { return nil }
        return url
    }
}

/// How far a web location's live page has got.
enum WebPageStatus {
    /// Not started (a page next to the one on screen), or loading.
    case loading
    case shown
    /// Couldn't be loaded: offline, an address that doesn't answer, a download rather than a page.
    case failed
}

/// A web location's live page: the site itself, as it looks at the card's width, scrolling and
/// zooming as a browser does, over a bar that names it. It's fetched
/// the first time its page is on screen (a page next to it isn't), into private storage that keeps
/// no cookies or data once the preview closes; it plays nothing by itself, and pauses what was
/// played when the pager turns away. The link card stands in while it loads — until it has finished,
/// or a second after it started to draw — and stays, saying so, when it can't load. A link clicked in
/// it opens in the browser.
private struct WebLocationPage: View {
    let file: URL
    let link: URL
    @Environment(\.isCurrentPreviewPage) private var isCurrentPage
    @State private var isStarted = false
    @State private var status = WebPageStatus.loading

    /// Pages on the web: an address the web view can fetch.
    static func canShow(_ link: URL) -> Bool {
        ["http", "https"].contains(link.scheme?.lowercased() ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if isStarted {
                    LiveWebView(url: link, isActive: isCurrentPage) { status = $0 }
                        .opacity(status == .shown ? 1 : 0)
                        .allowsHitTesting(status == .shown)
                }
                if status != .shown {
                    InternetLocationView(file: file, link: link,
                                         status: status == .failed ? .failed : isStarted ? .loading : .idle)
                }
            }
            if status == .shown {
                Divider()
                WebLocationBar(link: link)
            }
        }
        .onChange(of: isCurrentPage, initial: true) { _, isCurrent in
            if isCurrent { isStarted = true }
        }
    }
}

/// Under a live page: its address.
private struct WebLocationBar: View {
    let link: URL

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(Self.shortAddress(link))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(link.absoluteString)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    /// The address without its scheme: "www.apple.com/mac/".
    static func shortAddress(_ link: URL) -> String {
        let address = link.absoluteString
        guard let scheme = link.scheme, address.hasPrefix(scheme + "://") else { return address }
        return String(address.dropFirst(scheme.count + 3))
    }
}

/// The page's `WKWebView`. See `WebLocationPage`.
private struct LiveWebView: NSViewRepresentable {
    let url: URL
    /// The page is the one on screen; media pauses when it stops being.
    let isActive: Bool
    let onStatus: (WebPageStatus) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onStatus: onStatus, isActive: isActive) }

    func makeNSView(context: Context) -> WebLocationWebView {
        let view = WebLocationWebView()
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WebLocationWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onStatus = onStatus
        if coordinator.isActive != isActive {
            coordinator.isActive = isActive
            if !isActive { view.pauseAllMediaPlayback { } }
        }
    }

    static func dismantleNSView(_ view: WebLocationWebView, coordinator: Coordinator) {
        coordinator.reveal?.cancel()
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var onStatus: (WebPageStatus) -> Void
        var isActive: Bool
        var reveal: Task<Void, Never>?
        private var status = WebPageStatus.loading

        init(onStatus: @escaping (WebPageStatus) -> Void, isActive: Bool) {
            self.onStatus = onStatus
            self.isActive = isActive
        }

        private func report(_ new: WebPageStatus) {
            // Shown is final: a later failure (a frame, an interrupted load) leaves the page up.
            guard status != .shown, status != new else { return }
            status = new
            if new != .loading { reveal?.cancel() }
            onStatus(new)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            // A heavy page can take long to finish; it's worth seeing once it has started to draw.
            guard reveal == nil else { return }
            reveal = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.report(.shown)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            report(.shown)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            // A redirect or a load replaced by another cancels the one before; that isn't failing.
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            report(.failed)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            // It had started to draw: show what there is.
            report(.shown)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            report(.failed)
        }

        /// The page and its redirects load here (and anything inside its frames); a link the user
        /// clicks, or a search form sent, opens in the browser. A form that posts data can't be sent
        /// on from there, so it goes nowhere.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            switch navigationAction.navigationType {
            case .linkActivated, .formSubmitted, .formResubmitted:
                guard navigationAction.targetFrame?.isMainFrame != false else { return .allow }
                let isGet = (navigationAction.request.httpMethod ?? "GET").uppercased() == "GET"
                if isGet, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(url)
                }
                return .cancel
            default:
                return ["http", "https", "about", "blob", "data"].contains(url.scheme?.lowercased() ?? "") ? .allow : .cancel
            }
        }

        /// A download, or anything else the view can't show, isn't a page to preview.
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            guard navigationResponse.isForMainFrame, !navigationResponse.canShowMIMEType else { return .allow }
            report(.failed)
            return .cancel
        }

        /// A link that opens a new window (`target="_blank"`, `window.open` on a click) opens in the
        /// browser instead.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url,
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
    }
}

/// The live page's web view: private storage, nothing played without a click, Safari's user agent
/// (sites send a plain web view an older or a mobile page), pinch zoom. It reports where it's
/// scrolled, so a page wider than the card, or zoomed in, pans sideways and turns the pager's page
/// only past its edge (`HorizontallyPannable`).
final class WebLocationWebView: WKWebView, HorizontallyPannable, WebScrollTracking {
    fileprivate var scrollPosition: WebScrollPosition?

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.applicationNameForUserAgent = Self.applicationName
        let reporter = WebScrollReporter()
        WebScrollReporter.install(reporter, in: configuration.userContentController)
        super.init(frame: .zero, configuration: configuration)
        reporter.view = self
        allowsMagnification = true
        allowsBackForwardNavigationGestures = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    var horizontalPanRoom: HorizontalPanRoom? {
        panRoom(magnification: magnification)
    }

    /// "Version/26.2 Safari/605.1.15", with the installed Safari's version.
    private static let applicationName: String = {
        let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
        let version = safari.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
        return "Version/\(version ?? "26.0") Safari/605.1.15"
    }()
}

/// What a web location opens, without loading it: its name, the site and the whole address. The
/// live page's stand-in while it loads (`status`), and what's left when it can't.
private struct InternetLocationView: View {
    let file: URL
    let link: URL
    var status: Status = .idle

    enum Status {
        case idle, loading, failed
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path(percentEncoded: false)))
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
            VStack(spacing: 4) {
                Text(file.deletingPathExtension().lastPathComponent)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .truncationMode(.middle)
                if let host = link.host(percentEncoded: false), !host.isEmpty {
                    Text(host)
                        .foregroundStyle(.secondary)
                }
            }
            Text(link.absoluteString)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .truncationMode(.middle)
                .textSelection(.enabled)
            switch status {
            case .idle:
                EmptyView()
            case .loading:
                ProgressView()
                    .controlSize(.small)
            case .failed:
                Text("The page couldn’t be loaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
