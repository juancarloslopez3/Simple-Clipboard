import AppKit
import AVKit
import ImageIO
import PDFKit
import Quartz
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Quick Look–style space-bar preview for the floating history panel. Hover a row
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
/// full view. Standard content — never glass.
private struct ClipboardPreviewCard: View {
    let item: ClipboardItem
    let onClose: () -> Void
    /// The file on screen, whose Finder tags the header shows (`PreviewShownFileKey`).
    @State private var shownFile: URL?

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
        .onPreferenceChange(PreviewShownFileKey.self) { shownFile = $0 }
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
            // One line each, so the header is as tall with the tags as without them.
            .lineLimit(1)
            .layoutPriority(1)
            Spacer(minLength: 12)
            FinderTagList(file: shownFile)
            Text(item.createdAt.clipboardRowString)
                .font(.caption)
                .foregroundStyle(.secondary)
                // One line however tight the row: wrapping, it would make the header taller.
                .lineLimit(1)
                .fixedSize()
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
            RichTextDisplayView(rtfData: item.payload, fallback: item.plainPreview)
        case .image:
            AsyncZoomableImage(source: .data(item.payload), placeholder: ThumbnailCache.image(for: item),
                               contentID: item.id) { unavailable }
        case .color:
            colorPreview
        case .file, .folder:
            FilePreviewContent(item: item)
        case .pdf:
            if let document = PDFDocument(data: item.payload) {
                PDFDocumentView(document: document, contentID: item.id)
            } else {
                unavailable
            }
        }
    }

    /// Full text from the payload (the stored `plainPreview` is capped at 2000 chars).
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

/// Space-bar Quick Look preview for the snippets panel — the snippet counterpart
/// of `ClipboardPreviewOverlay`. Shares the panel's `ClipboardPreviewState` (`presentedID` is the
/// snippet's stable `id`) and the same tap-vs-hold Space semantics handled by `ClipboardPanel`; this
/// view only renders the overlay and dismisses on a backdrop click.
struct SnippetPreviewOverlay: View {
    let snippet: Snippet
    let onClose: () -> Void
    /// A file snippet's file to open on (the editor's selected file); nil opens on the first
    /// file that still exists.
    var startingAt: URL? = nil
    /// Called with the file a multi-file snippet's preview pages to.
    var onPageChange: ((URL) -> Void)? = nil

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.18))
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture(perform: onClose)

            SnippetPreviewCard(snippet: snippet, onClose: onClose,
                               startingAt: startingAt, onPageChange: onPageChange)
                .frame(maxWidth: 760, maxHeight: 560)
                .padding(32)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
    }
}

/// The snippet preview surface: a header (⌾ close · title · type · time) over a type-specific
/// full view — mirrors `ClipboardPreviewCard`. Plain text scrolls, rich text shows as plain text
/// with its tabs and indents (`RichTextDisplayView`), a file snippet previews the referenced file
/// (Quick Look, or PDFKit for a PDF). Standard content — never glass.
private struct SnippetPreviewCard: View {
    let snippet: Snippet
    let onClose: () -> Void
    let startingAt: URL?
    let onPageChange: ((URL) -> Void)?
    /// The file on screen, whose Finder tags the header shows (`PreviewShownFileKey`).
    @State private var shownFile: URL?

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
        .onPreferenceChange(PreviewShownFileKey.self) { shownFile = $0 }
    }

    /// Content-type label / glyph, taken from `ClipboardKind` so they match the snippet rows
    /// and history modal for the equivalent kind.
    private var kind: ClipboardKind {
        if snippet.isFile { return ClipboardKind.presenting(fileURLs: snippet.fileURLs) == .folder ? .folder : .file }
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
                Text(snippet.isFile ? snippet.fileKindLabel : kind.label).font(.caption).foregroundStyle(.secondary)
            }
            // One line each, so the header is as tall with the tags as without them.
            .lineLimit(1)
            .layoutPriority(1)
            Spacer(minLength: 12)
            FinderTagList(file: shownFile)
            Text(snippet.createdAt.clipboardRowString)
                .font(.caption)
                .foregroundStyle(.secondary)
                // One line however tight the row: wrapping, it would make the header taller.
                .lineLimit(1)
                .fixedSize()
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if snippet.isFile {
            SnippetFilePreviewContent(snippet: snippet, startingAt: startingAt, onPageChange: onPageChange)
        } else if snippet.isRichText {
            RichTextDisplayView(rtfData: snippet.payload, fallback: snippet.plainPreview)
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
/// open. SwiftUI's `.onKeyPress` marks the repeats `.handled`, but on macOS they
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
/// way out alongside Space / Esc / the backdrop click.
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

// MARK: - Finder tags

/// The file a preview has on screen — the pager's current page, or its only file — so the card's
/// header can show its Finder tags. Nil for content that isn't a file.
private struct PreviewShownFileKey: PreferenceKey {
    static let defaultValue: URL? = nil

    static func reduce(value: inout URL?, nextValue: () -> URL?) {
        value = value ?? nextValue()
    }
}

/// One of a file's Finder tags: its name and its color.
struct FinderTag: Hashable {
    let name: String
    /// Finder's color number, the index into `NSWorkspace.fileLabelColors`: 0 for a tag without a
    /// color, then gray, green, purple, blue, yellow, red and orange.
    let color: Int
}

extension URL {
    /// The item's Finder tags, in Finder's order. Read from the attribute Finder keeps them in,
    /// since `tagNames` has no colors. An alias's or link's own tags, not its original's. Empty when
    /// it has none or can't be read.
    var finderTags: [FinderTag] {
        guard isFileURL else { return [] }
        let attribute = "com.apple.metadata:_kMDItemUserTags"
        let data = withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return nil }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, attribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
            return read > 0 ? data.prefix(read) : nil
        }
        guard let data,
              let entries = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String]
        else { return [] }
        // Each entry is the name, then a newline and the color number when it has a color.
        return entries.compactMap { entry in
            let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first, !name.isEmpty else { return nil }
            let color = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            return FinderTag(name: String(name), color: (0...7).contains(color) ? color : 0)
        }
    }
}

/// The Finder tags of the file a preview shows, in the header's row before the time, as Finder's Get
/// Info lists them: each one's colored dot (a ring for a tag without a color) and name. Just the dots
/// when the names don't fit, with the names in the tooltip. Nothing for a file without tags.
///
/// In the row, not on a line of their own under the title: that line came and went as the pager
/// turned to a file with tags and back, changing the header's height, so the pager under it moved
/// in the middle of its slide and its footer's name jumped.
private struct FinderTagList: View {
    let file: URL?

    var body: some View {
        let tags = file?.finderTags ?? []
        if !tags.isEmpty {
            let names = tags.map(\.name).formatted(.list(type: .and))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    ForEach(tags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            FinderTagDot(tag: tag)
                            Text(tag.name).lineLimit(1)
                        }
                    }
                }
                HStack(spacing: 3) {
                    ForEach(tags, id: \.self) { FinderTagDot(tag: $0) }
                }
                .help(names)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: names))
        }
    }
}

/// A Finder tag's dot: filled with its color, or a ring for a tag without one.
struct FinderTagDot: View {
    let tag: FinderTag
    var size: CGFloat = 8

    var body: some View {
        let colors = NSWorkspace.shared.fileLabelColors
        if tag.color > 0, colors.indices.contains(tag.color) {
            Circle()
                .fill(Color(nsColor: colors[tag.color]))
                .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                .frame(width: size, height: size)
        } else {
            Circle()
                .strokeBorder(.secondary, lineWidth: 1)
                .frame(width: size, height: size)
        }
    }
}

/// File-snippet preview — the snippet's files (`FilePreviewPager`, which pages through several,
/// and through what's inside a folder among them) when at least one still exists, else a
/// "File not found" placeholder.
private struct SnippetFilePreviewContent: View {
    let snippet: Snippet
    let startingAt: URL?
    let onPageChange: ((URL) -> Void)?

    private var urls: [URL] { snippet.fileURLs }

    var body: some View {
        let pages = PreviewPage.pages(for: urls)
        if pages.contains(where: { fileExists($0.url) }) {
            // `id`: a new listing (an item added to a folder) starts the pager over.
            FilePreviewPager(pages: pages, startingAt: startingAt, onPageChange: onPageChange).id(pages)
        } else {
            VStack(spacing: 12) {
                Label(urls.first?.lastPathComponent ?? snippet.plainPreview,
                      systemImage: urls.first?.isFolder == true ? ClipboardKind.folder.symbol : "doc")
                    .font(.headline)
                Text(urls.isEmpty ? String(localized: "No file")
                     : urls.first?.isFolder == true ? String(localized: "Folder not found") : String(localized: "File not found"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// File preview: the real documents (`FilePreviewPager`; a folder pages through what's inside it)
/// when at least one still exists — at its original location or as the copy kept of it
/// (`availableFileURLs`) — falling back to the stored thumbnail / name otherwise
/// (copied files may have moved).
private struct FilePreviewContent: View {
    let item: ClipboardItem

    private var urls: [URL] { item.availableFileURLs }

    var body: some View {
        let urls = urls
        let pages = PreviewPage.pages(for: urls)
        if pages.contains(where: { fileExists($0.url) }) {
            // `id`: the main window's overlay stays up while the selection moves to another row.
            FilePreviewPager(pages: pages).id(pages)
        } else {
            VStack(spacing: 12) {
                if let thumbnail = ThumbnailCache.image(for: item) {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 280)
                        .clipShape(.rect(cornerRadius: 8))
                }
                let isFolder = item.displayKind == .folder
                Label(item.plainPreview, systemImage: isFolder ? ClipboardKind.folder.symbol : "doc")
                    .font(.headline)
                Text(urls.isEmpty ? String(localized: "No file")
                     : isFolder ? String(localized: "Folder not found") : String(localized: "File not found"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One page of `FilePreviewPager`: a file to show, the folder it's in when it's one of a folder's
/// items, and the entry of the list it belongs to.
private struct PreviewPage: Hashable {
    let url: URL
    /// The folder this file is directly inside, when the preview opened a folder into its items; nil
    /// for an entry of the list itself.
    let folder: URL?
    /// The entry of the list this page comes from: the file itself, or the list's folder it's
    /// somewhere inside. What the snippet editor's grid selects as the preview pages.
    let root: URL

    /// The list's pages: one per file, except that a folder gets one per item inside it
    /// (`URL.folderContents` — the items the row's badge counts), each naming the folder. A folder among those items is a single page, which opens
    /// into its own items (`pages(inside:root:)`); an empty or unreadable folder keeps one page.
    static func pages(for urls: [URL]) -> [PreviewPage] {
        urls.flatMap { url in
            pages(inside: url, root: url) ?? [PreviewPage(url: url, folder: nil, root: url)]
        }
    }

    /// One page per item inside `folder`, or nil when it has none to show (not a folder, empty, or
    /// unreadable).
    static func pages(inside folder: URL, root: URL) -> [PreviewPage]? {
        guard let contents = folder.folderContents, !contents.isEmpty else { return nil }
        return contents.map { PreviewPage(url: $0, folder: folder, root: root) }
    }
}

/// A folder the footer's folder menu lists: one of the list's folders, or one somewhere inside it.
private struct FolderMenuEntry {
    let folder: URL
    /// The list's folder it's in (itself, for that folder).
    let root: URL
    /// How deep under `root` it is, 0 for the root: the menu indents it that far.
    let depth: Int
    /// How many items it holds; nil when it can't be read.
    let itemCount: Int?

    /// Each of `roots` followed by the folders inside it, each of those by its own, in Finder's name
    /// order: the tree the menu draws. Stops after `limit` folders, which `isTruncated` reports, so a
    /// huge tree still opens at once. Links aren't folders (`URL.isFolder`), so it can't loop.
    static func tree(of roots: [URL], limit: Int = 300) -> (entries: [FolderMenuEntry], isTruncated: Bool) {
        var entries: [FolderMenuEntry] = []
        var isTruncated = false
        func visit(_ folder: URL, root: URL, depth: Int) {
            guard !isTruncated else { return }
            guard entries.count < limit else {
                isTruncated = true
                return
            }
            let contents = folder.folderContents
            entries.append(FolderMenuEntry(folder: folder, root: root, depth: depth, itemCount: contents?.count))
            for child in contents ?? [] where child.isFolder {
                visit(child, root: root, depth: depth + 1)
            }
        }
        for root in roots { visit(root, root: root, depth: 0) }
        return (entries, isTruncated)
    }
}

/// Shows a file list one file at a time, like a photo gallery; a folder in the list shows each
/// item inside it in turn (`PreviewPage`). Several pages get a footer (‹ name · 2 of 5 ›), which
/// also names the folder a page comes from (‹ 📁 Project ⌃ › notes.txt · 2 of 5 ›), and page on a
/// two-finger horizontal swipe or ←/→; a single file is just its `FilePreviewPage`, while a folder's
/// single item still gets the footer so it shows the folder. Opens on `startingAt` when given (the
/// snippet editor's selected file — a folder opens on its first item), else on the first page that
/// still exists; a missing one keeps its page and says so.
///
/// Folders inside folders: the footer's folder name opens a menu of the whole tree
/// (`FolderMenuButton`), and a folder's own page has Show Items. Going into one pages through its
/// items alone (`openedFolder`); picking one of the list's folders in the menu comes back to the
/// list, at that folder's first item.
///
/// The pages sit side by side on one strip that moves as a whole, and the ones next to the current
/// page stay mounted. So whichever type a page is, its neighbor is already rendered: it follows
/// the fingers into view instead of being created when the page turns, which left a blank slide
/// followed by content popping in for anything slower than a cached image (Quick Look, the icon
/// fallback, a player).
private struct FilePreviewPager: View {
    /// The list's pages (`PreviewPage.pages(for:)`), where the pager opens.
    let listPages: [PreviewPage]
    /// Told the list entry each page turn lands on (the folder, for an item somewhere inside one),
    /// so the snippet editor's selection can follow.
    let onPageChange: ((URL) -> Void)?

    /// A folder inside one of the list's folders that the user went into, and its pages; nil while
    /// the pager shows the list.
    @State private var openedFolder: (folder: URL, pages: [PreviewPage])?
    @State private var page: Int
    /// The page the mounted neighbors surround. Follows `page` once its slide has finished, since
    /// mounting a page is the slow part (opening a PDF, starting a Quick Look view) and would
    /// stutter the slide.
    @State private var settledPage: Int
    /// How far the strip follows the fingers during a swipe.
    @State private var dragOffset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Swipe distance (points) that turns the page when the fingers lift.
    private let commitDistance: CGFloat = 80
    /// Swipe speed (points per second) that turns the page however short the swipe: a flick.
    private let flickSpeed: CGFloat = 450
    /// Space between two pages on the strip.
    private let pageGap: CGFloat = 24

    init(pages: [PreviewPage], startingAt start: URL? = nil, onPageChange: ((URL) -> Void)? = nil) {
        self.listPages = pages
        self.onPageChange = onPageChange
        let first = start.flatMap { start in pages.firstIndex { $0.root == start } }
            ?? pages.firstIndex { fileExists($0.url) } ?? 0
        _page = State(initialValue: first)
        _settledPage = State(initialValue: first)
    }

    /// The pages being paged through: the opened folder's, else the list's.
    private var pages: [PreviewPage] { openedFolder?.pages ?? listPages }

    /// The list's folders, in order: the roots of the footer's folder menu.
    private var listFolders: [URL] {
        var seen = Set<URL>()
        return listPages.compactMap(\.folder).filter { seen.insert($0).inserted }
    }

    var body: some View {
        Group {
            if pages.count > 1 || pages.first?.folder != nil {
                VStack(spacing: 0) {
                    pageStrip
                    Divider()
                    footer
                }
                .background(PagerInputMonitor(
                    canStep: { pages.indices.contains(page + $0) },
                    onStep: { go(to: page + $0) },
                    onSwipeChanged: { dragOffset = rubberBanded($0) },
                    onSwipeEnded: endSwipe))
            } else if let url = pages.first?.url {
                FilePreviewPage(url: url).equatable()
            }
        }
        .preference(key: PreviewShownFileKey.self, value: pages.indices.contains(page) ? pages[page].url : nil)
    }

    /// The pages to keep mounted: the settled page, the current one and the ones next to them.
    private var mountedPages: ClosedRange<Int> {
        let lower = max(min(page, settledPage) - 1, 0)
        let upper = min(max(page, settledPage) + 1, pages.count - 1)
        return lower...upper
    }

    private var pageStrip: some View {
        GeometryReader { geometry in
            let step = geometry.size.width + pageGap
            ZStack {
                ForEach(Array(mountedPages), id: \.self) { index in
                    FilePreviewPage(url: pages[index].url)
                        .equatable()
                        .environment(\.isCurrentPreviewPage, index == page)
                        .environment(\.openPreviewFolder, PreviewFolderOpener { folder in
                            show(folder, root: pages[page].root)
                        })
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .offset(x: CGFloat(index - page) * step)
                        // Off-screen pages still have frames, and clipping doesn't stop them
                        // taking clicks meant for the backdrop.
                        .allowsHitTesting(index == page)
                        .accessibilityHidden(index != page)
                }
            }
            // Another folder's pages are new pages, not the old ones with other files.
            .id(openedFolder?.folder)
            .offset(x: dragOffset)
        }
        .clipped()
    }

    /// ‹ name · count ›, with the name and count centred between the arrows while they fit, and the
    /// name taking all the room there is once they don't. It switches to the new page at once rather
    /// than in the strip's slide: animated, each text cross-faded from the old one, and the two
    /// translucent copies (the count's unchanged "of 5" exactly over itself) drew it bolder.
    private var footer: some View {
        HStack(spacing: 8) {
            PagerArrowButton(symbol: "chevron.left", help: "Previous File", enabled: page > 0) {
                go(to: page - 1)
            }
            Spacer(minLength: 0)
            PageTitle(page: pages[page], folderRoots: listFolders) { entry in
                show(entry.folder, root: entry.root)
            }
            Text("\(page + 1) of \(pages.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
            Spacer(minLength: 0)
            PagerArrowButton(symbol: "chevron.right", help: "Next File", enabled: page < pages.count - 1) {
                go(to: page + 1)
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .transaction { $0.animation = nil }
    }

    /// The fingers move the content, so a rightward drag reveals the previous file. Past either
    /// end there is nothing to reveal, so the page resists instead.
    private func rubberBanded(_ distance: CGFloat) -> CGFloat {
        let target = distance > 0 ? page - 1 : page + 1
        return pages.indices.contains(target) ? distance : distance * 0.2
    }

    /// Turns the page after a long enough swipe or a flick, unless the fingers were heading back
    /// when they lifted.
    private func endSwipe(_ distance: CGFloat, _ velocity: CGFloat) {
        let isFlick = abs(velocity) >= flickSpeed
        let commits = isFlick ? (velocity > 0) == (distance > 0) : abs(distance) >= commitDistance
        guard commits else { return settle() }
        go(to: distance > 0 ? page - 1 : page + 1)
    }

    private func go(to target: Int) {
        guard pages.indices.contains(target) else { return settle() }
        withAnimation(slide) {
            page = target
            dragOffset = 0
        } completion: {
            settledPage = page
        }
        onPageChange?(pages[target].root)
    }

    /// Shows `folder`'s items: one of the list's folders brings back the list at its first item, a
    /// folder inside one pages through its own. Jumps there without the slide, as opening a folder
    /// does in Finder. The folder already shown, or one with nothing to show, changes nothing.
    private func show(_ folder: URL, root: URL) {
        guard folder != pages[page].folder else { return }
        if folder == root {
            guard let first = listPages.firstIndex(where: { $0.folder == folder }) else { return }
            openedFolder = nil
            jump(to: first)
        } else {
            guard let folderPages = PreviewPage.pages(inside: folder, root: root) else { return }
            openedFolder = (folder, folderPages)
            jump(to: 0)
        }
        onPageChange?(root)
    }

    private func jump(to target: Int) {
        page = target
        settledPage = target
        dragOffset = 0
    }

    private func settle() {
        withAnimation(slide) { dragOffset = 0 }
    }

    private var slide: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.3)
    }
}

/// The pager footer's name for a page: the file's name, after the folder it's in when it's one of a
/// folder's items (📁 Project ⌃ › notes.txt) — a button that goes to another folder
/// (`FolderMenuButton`). When both names are long they share the room, each shortened in the middle.
private struct PageTitle: View {
    let page: PreviewPage
    /// The list's folders, whose trees the folder button's menu offers.
    let folderRoots: [URL]
    let onChooseFolder: (FolderMenuEntry) -> Void

    var body: some View {
        HStack(spacing: 4) {
            if let folder = page.folder {
                FolderMenuButton(folder: folder, roots: folderRoots, onChoose: onChooseFolder)
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            Text(page.url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// The footer's folder name, as a pop-up button: it opens a menu of the list's folders and every
/// folder inside them, as an indented tree with each one's item count and the one shown ticked, to
/// go to any of them. Empty folders are listed but can't be picked: they have nothing to page
/// through. A native menu rather than a popover, since the floating panel closes when another
/// window takes key, and its click-outside monitors don't see a menu's clicks.
private struct FolderMenuButton: View {
    let folder: URL
    let roots: [URL]
    let onChoose: (FolderMenuEntry) -> Void

    @State private var presenter = FolderMenuPresenter()
    @State private var isHovering = false

    var body: some View {
        Button {
            let tree = FolderMenuEntry.tree(of: roots)
            presenter.present(tree.entries, isTruncated: tree.isTruncated, current: folder, onChoose: onChoose)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: ClipboardKind.folder.symbol)
                Text(folder.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // The folder's own tags, as dots after its name the way Finder lists them: the
                // header shows the tags of the item on screen.
                let tags = folder.finderTags
                if !tags.isEmpty {
                    HStack(spacing: 2) {
                        ForEach(tags, id: \.self) { FinderTagDot(tag: $0, size: 7) }
                    }
                }
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(isHovering ? 1 : 0), in: .rect(cornerRadius: 5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .background(FolderMenuAnchor(presenter: presenter))
        .help("Choose a Folder")
        .accessibilityLabel(Text(folder.lastPathComponent))
    }
}

/// Builds and opens `FolderMenuButton`'s menu, and reports the folder picked in it.
@MainActor
private final class FolderMenuPresenter: NSObject {
    /// The view the menu opens from (`FolderMenuAnchor`), behind the button.
    weak var anchor: NSView?
    private var entries: [FolderMenuEntry] = []
    private var onChoose: ((FolderMenuEntry) -> Void)?

    /// Opens the menu with `current` ticked and over the button, as a pop-up button opens on its
    /// selection.
    func present(_ entries: [FolderMenuEntry], isTruncated: Bool, current: URL,
                 onChoose: @escaping (FolderMenuEntry) -> Void) {
        guard let anchor else { return }
        self.onChoose = onChoose
        let (menu, currentItem) = makeMenu(entries, isTruncated: isTruncated, current: current)
        menu.popUp(positioning: currentItem, at: NSPoint(x: 0, y: anchor.isFlipped ? 0 : anchor.bounds.height), in: anchor)
    }

    /// The menu for `entries`, and its item for `current`: each folder indented by its depth, with
    /// its Finder icon and item count, the list's folders' trees set off by separators.
    func makeMenu(_ entries: [FolderMenuEntry], isTruncated: Bool, current: URL) -> (NSMenu, NSMenuItem?) {
        self.entries = entries
        let menu = NSMenu()
        menu.autoenablesItems = false
        var currentItem: NSMenuItem?
        for (index, entry) in entries.enumerated() {
            if entry.depth == 0, index > 0 { menu.addItem(.separator()) }
            let item = NSMenuItem(title: entry.folder.lastPathComponent, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.indentationLevel = min(entry.depth, 15)
            item.image = Self.icon(for: entry.folder)
            if let count = entry.itemCount { item.badge = NSMenuItemBadge(count: count) }
            item.isEnabled = (entry.itemCount ?? 0) > 0
            if entry.folder.standardizedFileURL == current.standardizedFileURL {
                item.state = .on
                currentItem = item
            }
            menu.addItem(item)
        }
        if isTruncated {
            menu.addItem(.separator())
            let more = NSMenuItem(title: String(localized: "More folders not shown"), action: nil, keyEquivalent: "")
            more.isEnabled = false
            menu.addItem(more)
        }
        return (menu, currentItem)
    }

    @objc private func choose(_ item: NSMenuItem) {
        guard entries.indices.contains(item.tag) else { return }
        onChoose?(entries[item.tag])
    }

    /// The folder's Finder icon at menu size (a custom folder icon shows too).
    private static func icon(for folder: URL) -> NSImage {
        let icon = (NSWorkspace.shared.icon(forFile: folder.path(percentEncoded: false)).copy() as? NSImage) ?? NSImage()
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}

/// An empty view behind `FolderMenuButton`, so its menu has a view to open from.
private struct FolderMenuAnchor: NSViewRepresentable {
    let presenter: FolderMenuPresenter

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        presenter.anchor = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        presenter.anchor = nsView
    }
}

extension EnvironmentValues {
    /// False on a mounted page next to the one on screen (`FilePreviewPager`), which must not play.
    @Entry var isCurrentPreviewPage = true
    /// Goes into a folder the pager shows as a page (its Show Items); nil outside a pager.
    @Entry fileprivate var openPreviewFolder: PreviewFolderOpener? = nil
}

/// `openPreviewFolder`'s action. Every one counts as equal: the pager's newest closure reads the
/// same state as its first, and a closure that compared unequal on every update would re-render the
/// folder pages on each swipe event.
private struct PreviewFolderOpener: Equatable {
    let open: @MainActor (URL) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

/// The footer's ‹ / › buttons: the way to page without a trackpad or the keyboard.
private struct PagerArrowButton: View {
    let symbol: String
    let help: LocalizedStringKey
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 20)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Paging input for `FilePreviewPager`, caught by local monitors ahead of the page: the preview's
/// content can be a remote Quick Look view or an `AVPlayerView`, and the panel keeps its search
/// field focused, so neither gesture nor key would reliably reach a SwiftUI handler. Only events
/// for this view's window count, so the floating panel and the main window can't page each other.
private struct PagerInputMonitor: NSViewRepresentable {
    /// Whether there's a page that way: -1 the previous one, +1 the next.
    let canStep: (Int) -> Bool
    /// ←/→: -1 or +1.
    let onStep: (Int) -> Void
    /// The swipe's total horizontal distance in points (+ = content moving right).
    let onSwipeChanged: (CGFloat) -> Void
    /// The total at the end of the swipe (0 when it was cancelled) and its speed in points per
    /// second when the fingers lifted (+ = content moving right).
    let onSwipeEnded: (CGFloat, CGFloat) -> Void

    @MainActor final class Coordinator {
        private enum Swipe { case idle, undecided, paging, passedThrough }

        var input: PagerInputMonitor
        var monitor: Any?
        private var swipe = Swipe.idle
        private var total = CGSize.zero
        private var velocity: CGFloat = 0
        private var lastTimestamp: TimeInterval = 0
        /// The `.began` the content hasn't seen yet, while `swipe` is `.undecided`.
        private var withheldBegan: NSEvent?
        /// The last swipe paged: its coasting momentum events must not scroll the next page.
        private var swallowsMomentum = false
        /// Which way the swipe under way may turn the page (-1 back, +1 forward): both over content
        /// that doesn't pan sideways, only past the edge it's at over content that does.
        private var pagingSteps: Set<Int> = []

        init(input: PagerInputMonitor) { self.input = input }

        func handleArrow(_ event: NSEvent, in view: NSView) -> Bool {
            guard event.window === view.window,
                  event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
            else { return false }
            switch event.keyCode {
            case 123: input.onStep(-1)   // ←
            case 124: input.onStep(1)    // →
            default: return false
            }
            return true
        }

        /// A horizontal swipe pages unless the content under the pointer can pan that way (a
        /// zoomed image, PDF or sheet); a vertical one always scrolls the content. Zoomed content
        /// already panned as far as it goes to one side pages on a swipe that would take it further:
        /// at its left edge a swipe to the right goes back, at its right edge one to the left goes
        /// forward, as a photo viewer does.
        ///
        /// The content sees nothing of a gesture until its direction is known. A scroll view that
        /// receives `.began` handles the gesture itself (responsive scrolling), so a photo or PDF
        /// page under the pointer would keep it from paging. A vertical gesture, or one that pans
        /// zoomed content, gets its `.began` late; a paging one never reaches the content, so no
        /// scroll view sees half a gesture.
        func handleScroll(_ event: NSEvent, in view: NSView) -> Bool {
            guard event.window === view.window else { return false }
            if event.momentumPhase != [] { return swallowsMomentum }
            switch event.phase {
            case .mayBegin, .began:
                if event.phase == .began { swallowsMomentum = false }
                let location = view.convert(event.locationInWindow, from: nil)
                let steps = view.bounds.contains(location) ? pagingSteps(at: event.locationInWindow, in: view) : []
                guard !steps.isEmpty else {
                    swipe = .passedThrough
                    return false
                }
                pagingSteps = steps
                swipe = .undecided
                withheldBegan = event.phase == .began ? event : nil
                total = CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
                velocity = 0
                lastTimestamp = event.timestamp
                return true
            case .changed:
                guard swipe == .undecided || swipe == .paging else { return false }
                total.width += event.scrollingDeltaX
                total.height += event.scrollingDeltaY
                let elapsed = event.timestamp - lastTimestamp
                if elapsed > 0 {
                    // Smoothed: a single event's delta is too noisy to judge a flick by.
                    velocity = velocity * 0.5 + (event.scrollingDeltaX / elapsed) * 0.5
                }
                lastTimestamp = event.timestamp
                if swipe == .undecided {
                    guard max(abs(total.width), abs(total.height)) >= 6 else { return true }
                    // Rightward (+) shows what's to the left: the previous page.
                    let step = total.width > 0 ? -1 : 1
                    guard abs(total.width) > abs(total.height), pagingSteps.contains(step) else {
                        swipe = .passedThrough
                        // Straight to the window: through the app it would come back here.
                        if let withheldBegan { view.window?.sendEvent(withheldBegan) }
                        withheldBegan = nil
                        return false
                    }
                    swipe = .paging
                    swallowsMomentum = true
                }
                input.onSwipeChanged(pagingDistance)
                return true
            case .ended, .cancelled:
                defer {
                    swipe = .idle
                    withheldBegan = nil
                }
                guard swipe == .undecided || swipe == .paging else { return false }
                if swipe == .paging {
                    // Fingers that rested before lifting aren't flicking, whatever came before.
                    let isRecent = event.timestamp - lastTimestamp < 0.1
                    let distance = pagingDistance
                    if event.phase == .ended, distance != 0 {
                        input.onSwipeEnded(distance, isRecent ? velocity : 0)
                    } else {
                        input.onSwipeEnded(0, 0)
                    }
                }
                return true
            default:
                return false
            }
        }

        /// The swipe's distance, held at zero on the side it may not page to: zoomed content paging
        /// past its left edge doesn't slide on to the next page when the fingers turn back.
        private var pagingDistance: CGFloat {
            if !pagingSteps.contains(-1) { return min(total.width, 0) }
            if !pagingSteps.contains(1) { return max(total.width, 0) }
            return total.width
        }

        /// Which way a swipe starting here may page: either way over content that doesn't pan
        /// sideways (where the pager's own resistance shows the first or last page); over content
        /// that does, only past an edge it has been panned to, and only toward a page that's there,
        /// so at the first or last page zoomed content keeps its own bounce.
        private func pagingSteps(at locationInWindow: NSPoint, in view: NSView) -> Set<Int> {
            guard let room = horizontalPanRoom(at: locationInWindow, in: view) else { return [-1, 1] }
            var steps: Set<Int> = []
            if !room.left, input.canStep(-1) { steps.insert(-1) }
            if !room.right, input.canStep(1) { steps.insert(1) }
            return steps
        }

        /// Whether the content under the pointer can still pan to show more on its left and on its
        /// right; nil when it doesn't pan sideways (it fits the card's width, or isn't zoomable).
        private func horizontalPanRoom(at locationInWindow: NSPoint, in view: NSView) -> HorizontalPanRoom? {
            guard let root = view.window?.contentView else { return nil }
            let point = root.superview?.convert(locationInWindow, from: nil) ?? locationInWindow
            var candidate = root.hitTest(point)
            while let current = candidate {
                if let pannable = current as? any HorizontallyPannable {
                    if let room = pannable.horizontalPanRoom { return room }
                } else if let scrollView = current as? NSScrollView, let document = scrollView.documentView {
                    // Both in the document's coordinates; the slack is a point on screen.
                    let visible = scrollView.documentVisibleRect
                    let bounds = document.bounds
                    if visible.width < bounds.width - 1 {
                        let slack = 1 / max(scrollView.magnification, 0.01)
                        return HorizontalPanRoom(left: visible.minX > bounds.minX + slack,
                                                 right: visible.maxX < bounds.maxX - slack)
                    }
                }
                candidate = current.superview
            }
            return nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(input: self) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak view, weak coordinator] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let view, let coordinator else { return false }
                return event.type == .keyDown
                    ? coordinator.handleArrow(event, in: view)
                    : coordinator.handleScroll(event, in: view)
            }
            return consumed ? nil : event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.input = self
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }
}

/// One file's full preview. PDFs get PDFKit (all pages, pinch zoom) — `QLPreviewView` renders via
/// a remote out-of-process view that is effectively a static snapshot inside the panel: no scroll
/// view in its hierarchy, so scrolling/zooming a multi-page PDF is impossible. Images get the
/// zoomable `NSScrollView`-backed view for the same reason, and audio / video files get
/// `AVPlayerView` (the snapshot shows Quick Look's player controls but they never take a click).
/// Word, PowerPoint and Excel files are rendered by the app from Quick Look's own Office HTML
/// (`OfficeDocumentPreview`: Quick Look shows them at a fixed 100 % that can't be zoomed out),
/// calendar files as event cards (`CalendarFilePreview`), contact cards as contacts
/// (`ContactFilePreview`) and web locations as their link (`InternetLocationPreview`): Quick Look
/// has only their icon. Everything else keeps Quick Look, falling back to the big icon + name card
/// for files it can't render. A folder — one inside a copied folder, or an empty one — gets
/// its big icon and how many items it holds.
///
/// An alias (or a symbolic link) shows its original the same way, under the alias's name; where
/// that comes down to an icon — a type nothing previews, or an original that can't be found — it's
/// the icon with the alias arrow.
///
/// `Equatable` so a swipe, which re-renders the pager on every event, doesn't re-evaluate this
/// body: that would re-open the `PDFDocument` each time. Whether the page is the current one
/// reaches the player through the environment, for the same reason.
private struct FilePreviewPage: View, Equatable {
    let url: URL

    var body: some View {
        if let alias = FileAlias(url) {
            if let original = alias.original {
                FileContentPreview(url: original)
                    .environment(\.previewedAlias, url)
            } else {
                // The alias's own icon, which has the arrow; Finder's alias keeps its original's.
                FileIconPreviewView(url: url, caption: String(localized: "Original item not found"))
            }
        } else {
            FileContentPreview(url: url)
        }
    }
}

/// What `FilePreviewPage` shows for a file that isn't an alias, or for an alias's original.
private struct FileContentPreview: View {
    let url: URL

    var body: some View {
        if !fileExists(url) {
            let isFolder = url.isFolder
            VStack(spacing: 12) {
                Label(url.lastPathComponent, systemImage: isFolder ? ClipboardKind.folder.symbol : "doc")
                    .font(.headline)
                Text(isFolder ? String(localized: "Folder not found") : String(localized: "File not found"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let count = url.folderContents?.count {
            FolderPreviewPage(url: url, itemCount: count)
        } else if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true,
                  let document = PDFDocument(url: url) {
            PDFDocumentView(document: document, contentID: url)
        } else if isImageFileURL(url) {
            AsyncZoomableImage(source: .file(url), contentID: url) { FileQuickLookOrIconView(url: url) }
        } else if isMediaFileURL(url) {
            MediaPreviewView(url: url)
        } else if let kind = OfficeDocumentKind(url: url) {
            OfficeDocumentPreview(url: url, kind: kind)
        } else if isCalendarFileURL(url) {
            CalendarFilePreview(url: url)
        } else if isContactFileURL(url) {
            ContactFilePreview(url: url)
        } else if isInternetLocationFileURL(url) {
            InternetLocationPreview(url: url)
        } else {
            FileQuickLookOrIconView(url: url)
        }
    }
}

/// Whether there's an item at `url`. A link counts even when what it leads to is gone, so a broken
/// one still gets its page, with the alias arrow (`FilePreviewPage`).
private func fileExists(_ url: URL) -> Bool {
    var info = stat()
    return url.withUnsafeFileSystemRepresentation { path in
        path.map { lstat($0, &info) == 0 } ?? false
    }
}

/// A Finder alias or a symbolic link (both are alias files to `URLResourceValues`), and the item it
/// leads to.
private struct FileAlias {
    /// The original item, or nil when it can't be found: deleted, or on a volume that isn't mounted
    /// (which isn't mounted to find out).
    let original: URL?

    /// Nil when `url` is neither an alias nor a link.
    init?(_ url: URL) {
        guard Self.isAlias(url) else { return nil }
        var current = url
        // An alias can lead to another one; a loop of them leads nowhere.
        for _ in 0..<8 {
            guard let next = try? URL(resolvingAliasFileAt: current, options: [.withoutUI, .withoutMounting]),
                  next != current
            else { break }
            guard Self.isAlias(next) else {
                original = FileManager.default.fileExists(atPath: next.path(percentEncoded: false)) ? next : nil
                return
            }
            current = next
        }
        original = nil
    }

    private static func isAlias(_ url: URL) -> Bool {
        url.isFileURL && (try? url.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true
    }
}

extension EnvironmentValues {
    /// The alias whose original a preview page shows, if it is one (`FilePreviewPage`): its icon
    /// fallback then names the alias and draws the arrow.
    @Entry fileprivate var previewedAlias: URL? = nil
}

/// `original`'s Finder icon with the alias arrow in its lower-left corner, as Finder draws an alias
/// of it — also for one made by a tool that, unlike Finder, doesn't store the icon in the alias.
/// The system's own icon for `alias` where the arrow badge isn't available.
@MainActor
private func aliasIcon(original: URL, alias: URL) -> NSImage {
    guard let badgeType = UTType("com.apple.icon-decoration.system.alias"), badgeType.isDeclared else {
        return NSWorkspace.shared.icon(forFile: alias.path(percentEncoded: false))
    }
    let base = NSWorkspace.shared.icon(forFile: original.path(percentEncoded: false))
    let badge = NSWorkspace.shared.icon(for: badgeType)
    // Drawn at whatever size it's shown, so it stays sharp. The badge sits where Finder puts it.
    return NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
        base.draw(in: rect)
        let side = rect.width * 0.27
        badge.draw(in: NSRect(x: rect.minX + rect.width * 0.2 - side / 2,
                              y: rect.minY + rect.height * 0.15 - side / 2,
                              width: side, height: side))
        return true
    }
}

/// True when the URL points at a bitmap/vector image. Quick Look renders images through a
/// static out-of-process snapshot inside the floating panel, so image files are shown with
/// `ZoomableImageView` (trackpad pinch zoom + pan) instead — matching `.image` history items.
private func isImageFileURL(_ url: URL) -> Bool {
    UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
}

/// True when the URL points at an iCalendar file (`.ics`, `.vcs`).
private func isCalendarFileURL(_ url: URL) -> Bool {
    UTType(filenameExtension: url.pathExtension)?.conforms(to: .calendarEvent) == true
}

/// True when the URL points at a contact card file (`.vcf`).
private func isContactFileURL(_ url: URL) -> Bool {
    UTType(filenameExtension: url.pathExtension)?.conforms(to: .vCard) == true
}

/// True when the URL points at a web location: a `.webloc` (or another of the Mac's internet
/// locations, such as `.inetloc`) or a Windows `.url` shortcut.
private func isInternetLocationFileURL(_ url: URL) -> Bool {
    guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
    return type.conforms(to: .internetLocation) || type.conforms(to: .internetShortcut)
}

/// True when the URL points at an audio or video file. Quick Look's player sits in the same
/// static out-of-process snapshot as its images, so play / scrub / volume never take a click;
/// these files are played in-process by `MediaPreviewView` instead.
private func isMediaFileURL(_ url: URL) -> Bool {
    UTType(filenameExtension: url.pathExtension)?.conforms(to: .audiovisualContent) == true
}

/// Audio / video file preview: `AVPlayerView` with its standard inline controls when
/// AVFoundation can play the file, else the Quick Look / icon fallback (formats such as MKV
/// or WebM that only a Quick Look plug-in, or nothing, can render). Playability is probed
/// asynchronously (a few ms) and tagged with its URL, so a preview that moved to another
/// file never shows the previous file's verdict.
private struct MediaPreviewView: View {
    let url: URL
    @State private var probe: (url: URL, isPlayable: Bool)?
    @Environment(\.isCurrentPreviewPage) private var isCurrentPage

    var body: some View {
        ZStack {
            if let probe, probe.url == url {
                if probe.isPlayable {
                    MediaPlayerView(url: url, isActive: isCurrentPage)
                } else if isCurrentPage {
                    // Quick Look autostarts media it can render, so it waits to be on screen.
                    FileQuickLookOrIconView(url: url)
                } else {
                    Color.clear
                }
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            let isPlayable = (try? await AVURLAsset(url: url).load(.isPlayable)) ?? false
            guard !Task.isCancelled else { return }
            probe = (url, isPlayable)
        }
    }
}

/// In-process `AVPlayerView`: its controls are real views in the panel, so they take clicks
/// like any other control. Plays while `isActive` (Quick Look's `autostarts` behaviour) and pauses
/// when the pager moves off its page or the preview closes. A new `url` swaps in a fresh player.
private struct MediaPlayerView: NSViewRepresentable {
    let url: URL
    let isActive: Bool

    final class Coordinator {
        var isActive: Bool
        init(isActive: Bool) { self.isActive = isActive }
    }

    func makeCoordinator() -> Coordinator { Coordinator(isActive: isActive) }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = makePlayer()
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if (nsView.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            nsView.player?.pause()
            nsView.player = makePlayer()
        } else if context.coordinator.isActive != isActive {
            // Only on a change: updates also run while the user has paused it on purpose.
            if isActive { nsView.player?.play() } else { nsView.player?.pause() }
        }
        context.coordinator.isActive = isActive
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        nsView.player?.pause()
        nsView.player = nil
    }

    private func makePlayer() -> AVPlayer {
        let player = AVPlayer(url: url)
        if isActive { player.play() }
        return player
    }
}

/// Quick Look content preview when the system can actually render the file, else the big
/// icon + name fallback. Availability is probed via `QLThumbnailGenerator`: a file
/// that can produce a *thumbnail* representation has a Quick Look renderer, while one that
/// can't (archives, executables, unknown types…) would get Quick Look's generic sheet with
/// its size/date/"Open with" chrome — replaced here by `FileIconPreviewView`.
struct FileQuickLookOrIconView: View {
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

/// A folder's page — one inside a copied folder, or an empty one: its big icon, how many items it
/// holds and, when it holds some, Show Items, which pages through them (`openPreviewFolder`). An
/// alias of a folder gets the icon with the arrow and the count, but not Show Items: its original
/// is outside the folders the pager's menu goes back through.
private struct FolderPreviewPage: View {
    let url: URL
    let itemCount: Int
    @Environment(\.openPreviewFolder) private var openFolder
    @Environment(\.previewedAlias) private var alias

    var body: some View {
        FileIconPreviewView(url: url, caption: itemCount == 0 ? String(localized: "Empty Folder")
                            : itemCount == 1 ? String(localized: "1 item") : String(localized: "\(itemCount) items")) {
            if itemCount > 0, alias == nil, let openFolder {
                Button("Show Items") { openFolder.open(url) }
                    .padding(.top, 4)
            }
        }
    }
}

/// The no-preview fallback: the file's large Finder icon over its name, centered — Quick
/// Look's own generic layout minus the size/date/"Open with" chrome. `caption` goes
/// under the name ("Empty Folder"), and `accessory` under that (a folder's Show Items). For an
/// alias's original (`previewedAlias`) it's the alias's name and the original's icon with the arrow.
private struct FileIconPreviewView<Accessory: View>: View {
    let url: URL
    var caption: String? = nil
    @ViewBuilder var accessory: Accessory
    @Environment(\.previewedAlias) private var alias

    var body: some View {
        let named = alias ?? url
        VStack(spacing: 16) {
            Image(nsImage: alias.map { aliasIcon(original: url, alias: $0) }
                  ?? NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                .resizable()
                .interpolation(.high)
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
            VStack(spacing: 4) {
                Text(named.lastPathComponent.isEmpty ? named.path(percentEncoded: false) : named.lastPathComponent)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .truncationMode(.middle)
                if let caption {
                    Text(caption)
                        .foregroundStyle(.secondary)
                }
            }
            accessory
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension FileIconPreviewView where Accessory == EmptyView {
    init(url: URL, caption: String? = nil) {
        self.init(url: url, caption: caption) { EmptyView() }
    }
}

/// What an image preview shows: an `.image` item's stored bytes, or an image file.
private enum PreviewImageSource: Sendable {
    case data(Data)
    case file(URL)

    var imageSource: CGImageSource? {
        switch self {
        case .data(let data): CGImageSourceCreateWithData(data as CFData, nil)
        case .file(let url): CGImageSourceCreateWithURL(url as CFURL, nil)
        }
    }

    var nsImage: NSImage? {
        switch self {
        case .data(let data): NSImage(data: data)
        case .file(let url): NSImage(contentsOf: url)
        }
    }

    /// The full-size bitmap, decoded by ImageIO (runs off the main actor). Nil for animated
    /// images, which `NSImage` plays, and for content ImageIO can't decode (e.g. SVG).
    func decodedImage() -> NSImage? {
        guard let source = imageSource, !Self.isAnimated(source),
              let image = ClipboardContent.orientedImage(from: source) else { return nil }
        // A bitmap rep, not `NSImage(cgImage:size:)`: that one's snapshot rep reports its pixels
        // at the screen's backing scale, doubling `ImageZoomScrollView`'s pixel-exact frame.
        let rep = NSBitmapImageRep(cgImage: image)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }

    private static func isAnimated(_ source: CGImageSource) -> Bool {
        guard CGImageSourceGetCount(source) > 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return false }
        let frameDelays: [(CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSDelayTime),
        ]
        return frameDelays.contains { dictionary, delay in
            (properties[dictionary] as? [CFString: Any])?[delay] != nil
        }
    }
}

/// `ZoomableImageView` for content that may be a huge photo: an iPhone shot is 24 MP, ~100 MB
/// decoded. `NSImage` decodes lazily on its first draw — on the main thread, so opening such a
/// preview froze the panel for most of a second before the card appeared. Here ImageIO decodes
/// the bitmap off the main actor while `placeholder` (the stored row thumbnail) stands in at the
/// image's full size, so the swap only sharpens the picture and keeps any zoom already applied.
/// Animated images and content ImageIO can't decode keep `NSImage`; content neither can open
/// shows `fallback`.
private struct AsyncZoomableImage<Fallback: View>: View {
    let source: PreviewImageSource
    let placeholder: NSImage?
    let contentID: AnyHashable
    @ViewBuilder let fallback: () -> Fallback

    /// The loaded image (nil: unreadable), tagged with its content: one loaded for other content
    /// (the preview moved to another item) counts as still loading.
    @State private var loaded: (contentID: AnyHashable, image: NSImage?)?

    init(source: PreviewImageSource, placeholder: NSImage? = nil, contentID: some Hashable,
         @ViewBuilder fallback: @escaping () -> Fallback) {
        self.source = source
        self.placeholder = placeholder
        self.contentID = AnyHashable(contentID)
        self.fallback = fallback
    }

    /// The loaded image, else the placeholder stretched to the image's full size. Nil while
    /// loading without a placeholder, and once the content turned out unreadable.
    private var shown: (image: NSImage, pixelSize: NSSize?)? {
        if let loaded, loaded.contentID == contentID {
            return loaded.image.map { ($0, nil) }
        }
        guard let placeholder, let size = ClipboardContent.orientedPixelSize(of: source.imageSource) else { return nil }
        return (placeholder, size)
    }

    var body: some View {
        ZStack {
            // One view for the placeholder and the loaded image, so the swap keeps it and its zoom.
            if let shown {
                ZoomableImageView(image: shown.image, pixelSize: shown.pixelSize, contentID: contentID)
            } else if loaded?.contentID == contentID {
                fallback()
            }
        }
        .task(id: contentID) {
            guard loaded?.contentID != contentID else { return }
            let source = source
            let decoded = await Task.detached(priority: .userInitiated) { source.decodedImage() }.value
            guard !Task.isCancelled else { return }
            loaded = (contentID, decoded ?? source.nsImage)
        }
    }
}

/// Zoomable image preview backed by `NSScrollView` magnification (1 = 100 %, one image pixel per
/// point). The image opens scaled to fit the card — small images scaled up to fill it, as far as
/// the 500 % maximum; trackpad pinch / smart-magnify zooms about the pointer, and two-finger
/// scrolling pans once zoomed in. Zooms from 20 % to 500 % (`PreviewZoom.range`); a big photo
/// whose fit is below 20 % zooms out to its fit. No zoom controls: a photo is pinched.
///
/// `image` may be a small stand-in for the picture (`AsyncZoomableImage`'s thumbnail), stretched
/// to the picture's `pixelSize` so the full bitmap later lands in the same frame. A new
/// `contentID` (item id / file URL) re-fits; a new image for the same content keeps the zoom.
private struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    /// The picture's pixel size when `image` stands in for it; nil uses `image`'s own.
    var pixelSize: NSSize?
    let contentID: AnyHashable

    func makeCoordinator() -> Coordinator { Coordinator(contentID: contentID) }

    final class Coordinator {
        var contentID: AnyHashable
        init(contentID: AnyHashable) { self.contentID = contentID }
    }

    func makeNSView(context: Context) -> ImageZoomScrollView {
        ImageZoomScrollView(image: image, pixelSize: pixelSize)
    }

    func updateNSView(_ nsView: ImageZoomScrollView, context: Context) {
        let isNewContent = context.coordinator.contentID != contentID
        context.coordinator.contentID = contentID
        nsView.setImage(image, pixelSize: pixelSize, refit: isNewContent)
    }
}

private final class ImageZoomScrollView: NSScrollView {
    private let imageView = NSImageView()
    /// Magnification that fits the image in the clip view (no more than the 500 % maximum).
    private var fittedMagnification: CGFloat = 1
    /// The clip view's and the image's sizes the fit was worked out for.
    private var fittedSizes: (available: NSSize, natural: NSSize)?
    /// New content: the next layout applies the fit whatever the zoom.
    private var needsFit = true
    /// The pinch, without AppKit's holds at 100 % and at the fit (`PreviewPinch`).
    private var pinch: PreviewPinch?

    init(image: NSImage, pixelSize: NSSize?) {
        super.init(frame: .zero)
        pinch = PreviewPinch(host: self, scrollView: { [weak self] in self })
        drawsBackground = false
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = PreviewZoom.minimumScale
        maxMagnification = PreviewZoom.maximumScale
        usesPredominantAxisScrolling = false

        let clipView = ImageCenteringClipView()
        clipView.drawsBackground = false
        contentView = clipView

        imageView.imageScaling = .scaleAxesIndependently
        documentView = imageView
        setImage(image, pixelSize: pixelSize, refit: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pinch?.hostDidMoveToWindow()
    }

    /// `refit` re-applies the fit for new content; otherwise the live zoom is left alone.
    func setImage(_ image: NSImage, pixelSize: NSSize?, refit: Bool) {
        guard imageView.image !== image else { return }
        imageView.image = image
        // Frame at pixel size so magnification 1 is pixel-exact (matches the `PNG · W×H` label).
        imageView.frame = NSRect(origin: .zero, size: pixelSize ?? Self.pixelSize(of: image))
        if refit { needsFit = true }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        refit()
    }

    /// Works the fit out again when the card or the image changes size, moving the live
    /// magnification only while it is still at the previous fit — a user's zoom is never clobbered.
    ///
    /// Only then: layout passes run while a pinch goes on, and re-fitting in them put a big photo
    /// back at its fit after each slow step (a step from a 9 % fit moved it by less than the old
    /// absolute "still at the fit" tolerance), so a slow pinch never got anywhere.
    private func refit() {
        let available = contentSize
        let natural = imageView.frame.size
        guard available.width > 1, available.height > 1,
              natural.width > 0, natural.height > 0,
              needsFit || fittedSizes?.available != available || fittedSizes?.natural != natural
        else { return }

        let fit = PreviewZoom.clampedFit(min(available.width / natural.width, available.height / natural.height))
        let wasAtFit = needsFit || abs(magnification / fittedMagnification - 1) < 0.001
        fittedSizes = (available, natural)
        fittedMagnification = fit
        let range = PreviewZoom.range(fit: fit)
        minMagnification = range.lowerBound
        maxMagnification = range.upperBound
        if wasAtFit {
            magnification = fit
        }
        needsFit = false
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

    /// `FilePreviewPager` mounts and drops these as it pages; closing releases the out-of-process
    /// preview right away instead of with the window.
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? QLPreviewView)?.close()
    }
}

/// Read-only rich text for the Space previews, shown as plain text: the same look as the
/// plain-text preview's `Text` (body font, label color, 16pt margin, "—" when empty). Fonts,
/// sizes, colors, alignment and spacing are dropped. What lays the text out is kept: each
/// paragraph's tab stops and indents as the RTF sets them, and list items with their markers in
/// the text ("\t•\tItem", as the editor and TextEdit show them and as a plain paste has them).
///
/// It's AppKit text because SwiftUI `Text` only has its default tab stops, every 28pt, and no
/// indents, so a right tab, custom columns or a list item's wrapped lines would come out wrong.
private struct RichTextDisplayView: NSViewRepresentable {
    let rtfData: Data
    /// Shown when the RTF can't be read.
    let fallback: String

    /// SwiftUI `Text`'s tab grid (AppKit's default tab stops), for paragraphs that set none past
    /// their last stop.
    private static let tabInterval: CGFloat = 28

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// The RTF currently shown. `updateNSView` runs on every parent re-render; re-applying the
    /// same data re-parsed it and reset the scroll position and selection each time.
    final class Coordinator {
        var appliedData: Data?
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        Self.configure(textView)
        apply(to: textView, context.coordinator)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        apply(to: textView, context.coordinator)
    }

    private func apply(to textView: NSTextView, _ coordinator: Coordinator) {
        guard coordinator.appliedData != rtfData else { return }
        coordinator.appliedData = rtfData
        textView.textStorage?.setAttributedString(Self.plainText(rtf: rtfData, fallback: fallback))
    }

    /// The plain-text preview's 16pt padding, all of it inset so a paragraph's indents are
    /// measured from the same left edge as the text.
    static func configure(_ textView: NSTextView) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.textContainer?.lineFragmentPadding = 0
    }

    static func plainText(rtf: Data, fallback: String) -> NSAttributedString {
        let rich = NSAttributedString.withListMarkers(rtf: rtf)
        let string = rich?.string ?? fallback
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = []
        paragraph.defaultTabInterval = tabInterval
        let text = NSMutableAttributedString(string: string.isEmpty ? "—" : string, attributes: [
            .font: NSFont.preferredFont(forTextStyle: .body),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
        guard let rich, !string.isEmpty else { return text }
        // The list itself isn't carried over: its markers are already in the text, and TextKit 2
        // would draw them a second time.
        rich.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: rich.length)) { value, range, _ in
            guard let style = value as? NSParagraphStyle else { return }
            let kept = NSMutableParagraphStyle()
            kept.tabStops = style.tabStops
            kept.defaultTabInterval = style.defaultTabInterval > 0 ? style.defaultTabInterval : tabInterval
            kept.firstLineHeadIndent = style.firstLineHeadIndent
            kept.headIndent = style.headIndent
            kept.tailIndent = style.tailIndent
            text.addAttribute(.paragraphStyle, value: kept, range: range)
        }
        return text
    }
}
