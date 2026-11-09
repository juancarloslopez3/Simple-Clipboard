import AppKit
import PDFKit
import UniformTypeIdentifiers
import WebKit
import os

/// The Office files the Space preview draws itself instead of handing them to
/// `QLPreviewView`. Quick Look shows these as a web page at a fixed 100 %: a Word page is wider than
/// the panel's card, so it opened cropped, and WebKit's pinch never goes below 100 %, so it couldn't
/// be zoomed out; a sheet showed a handful of columns the same way. The preview starts from the same
/// source Quick Look does — the HTML its Office generator writes — and puts it in views it controls
/// (`OfficePreviewRenderer`).
enum OfficeDocumentKind: Sendable {
    /// Word: printed into real pages, shown in the PDF view.
    case document
    /// PowerPoint: one PDF page per slide.
    case presentation
    /// Excel and CSV: each sheet a web page the preview zooms itself (`SheetWebView`).
    case spreadsheet

    /// The types Quick Look's Office generator (`/System/Library/QuickLook/Office.qlgenerator`)
    /// renders. Named one by one: Keynote and Numbers files conform to the same public
    /// presentation / spreadsheet types but have their own previewer.
    private static let types: [(identifier: String, kind: OfficeDocumentKind)] = [
        ("org.openxmlformats.wordprocessingml.document", .document),
        ("org.openxmlformats.wordprocessingml.document.macroenabled", .document),
        ("org.openxmlformats.wordprocessingml.template", .document),
        ("org.openxmlformats.wordprocessingml.template.macroenabled", .document),
        ("com.microsoft.word.doc", .document),
        ("com.microsoft.word.dot", .document),
        ("org.openxmlformats.presentationml.presentation", .presentation),
        ("org.openxmlformats.presentationml.presentation.macroenabled", .presentation),
        ("org.openxmlformats.presentationml.slideshow", .presentation),
        ("org.openxmlformats.presentationml.slideshow.macroenabled", .presentation),
        ("org.openxmlformats.presentationml.template", .presentation),
        ("org.openxmlformats.presentationml.template.macroenabled", .presentation),
        ("com.microsoft.powerpoint.ppt", .presentation),
        ("com.microsoft.powerpoint.pps", .presentation),
        ("com.microsoft.powerpoint.pot", .presentation),
        ("org.openxmlformats.spreadsheetml.sheet", .spreadsheet),
        ("org.openxmlformats.spreadsheetml.sheet.macroenabled", .spreadsheet),
        ("org.openxmlformats.spreadsheetml.template", .spreadsheet),
        ("org.openxmlformats.spreadsheetml.template.macroenabled", .spreadsheet),
        ("com.microsoft.excel.xls", .spreadsheet),
        ("com.microsoft.excel.xlt", .spreadsheet),
        ("public.comma-separated-values-text", .spreadsheet),
    ]

    init?(url: URL) {
        guard !url.pathExtension.isEmpty, let type = UTType(filenameExtension: url.pathExtension),
              let match = Self.types.first(where: { entry in
                  UTType(entry.identifier).map { type.conforms(to: $0) } ?? false
              })
        else { return nil }
        self = match.kind
    }
}

/// A rendered Office document.
enum OfficePreview: Sendable {
    /// A document's pages or a presentation's slides, as PDF data.
    case pages(Data)
    /// A workbook's sheets, in tab order.
    case sheets([OfficeSheet])
}

/// One sheet of a workbook: a web page Quick Look's generator wrote, in a folder of its own.
struct OfficeSheet: Hashable, Sendable {
    /// The sheet's tab name (user data, never localized).
    let name: String
    let url: URL
    /// The folder the page may read from (its stylesheet and images sit next to it).
    let folder: URL
}

/// Turns Office files into `OfficePreview`s, in three steps:
///
/// 1. `qlmanage -p -o` writes the preview Quick Look would show (its Office generator's HTML, with
///    the document's images and stylesheets as files beside it) into a scratch folder. It's a plain
///    tool run, about 0.1 s for a typical file, and nothing appears on screen.
/// 2. A Word document is loaded in a hidden web view and printed to PDF. WebKit's pagination breaks
///    pages between lines, at the page size and margins the generator gives its page box. A
///    presentation gets one `createPDF` per slide element (the generator's `PageElementXPath`).
/// 3. A workbook needs no rendering: each sheet page is shown live by `SheetWebView` (a large sheet
///    took seconds as PDF and is instant as a page), so its folder lives as long as its cache entry.
///
/// Results are cached per file version (path, modification date, size), failures included, so
/// paging back to a file is instant. Jobs run one at a time: there is one hidden web view, and an
/// app runs one print operation at a time.
@MainActor
final class OfficePreviewRenderer {
    static let shared = OfficePreviewRenderer()

    private static let log = Logger(subsystem: "com.simpleclipboard.app", category: "office-preview")

    private struct Key: Hashable {
        let path: String
        let modified: Date?
        let size: Int?

        init(_ url: URL) {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            path = url.standardizedFileURL.path(percentEncoded: false)
            modified = values?.contentModificationDate
            size = values?.fileSize
        }
    }

    private struct Entry {
        let preview: OfficePreview?
        /// The scratch folder a workbook's sheets live in, removed when the entry is evicted.
        let folder: URL?
    }

    /// Most recent last.
    private var cache: [(key: Key, entry: Entry)] = []
    private let cacheLimit = 12
    private var running: [Key: Task<OfficePreview?, Never>] = [:]
    /// The job queued last; each new job waits for it.
    private var lastJob: Task<Void, Never>?
    private let page = OfficeRenderPage()
    private var didSweepScratch = false

    /// The preview of `url`, rendering it the first time.
    func preview(of url: URL, kind: OfficeDocumentKind) async -> OfficePreview? {
        let key = Key(url)
        if let index = cache.firstIndex(where: { $0.key == key }) {
            let hit = cache.remove(at: index)
            cache.append(hit)
            return hit.entry.preview
        }
        if let task = running[key] { return await task.value }
        let previous = lastJob
        let task = Task { @MainActor in
            await previous?.value
            let rendered = await self.render(url, kind: kind)
            self.store(rendered, for: key)
            self.running[key] = nil
            return rendered.preview
        }
        running[key] = task
        lastJob = Task { _ = await task.value }
        return await task.value
    }

    private func store(_ entry: Entry, for key: Key) {
        cache.removeAll { $0.key == key }
        cache.append((key, entry))
        while cache.count > cacheLimit {
            if let folder = cache.removeFirst().entry.folder {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    private func render(_ url: URL, kind: OfficeDocumentKind) async -> Entry {
        guard let folder = makeScratchFolder() else { return Entry(preview: nil, folder: nil) }
        guard let generated = await Self.generate(url, into: folder) else {
            Self.log.notice("Quick Look wrote no HTML preview for \(url.lastPathComponent, privacy: .private)")
            try? FileManager.default.removeItem(at: folder)
            return Entry(preview: nil, folder: nil)
        }
        // Compiled before anything loads, so every Office web view can block remote content.
        await OfficeWebContent.prepare()
        switch kind {
        case .spreadsheet:
            let sheets = Self.sheets(of: generated, title: url.deletingPathExtension().lastPathComponent)
            guard !sheets.isEmpty else {
                try? FileManager.default.removeItem(at: folder)
                return Entry(preview: nil, folder: nil)
            }
            return Entry(preview: .sheets(sheets), folder: folder)
        case .document, .presentation:
            defer { try? FileManager.default.removeItem(at: folder) }
            let data = await page.pdf(of: generated, slides: kind == .presentation, scratch: folder)
            if data == nil { Self.log.notice("Couldn't render \(url.lastPathComponent, privacy: .private) to PDF") }
            return Entry(preview: data.map { .pages($0) }, folder: nil)
        }
    }

    // MARK: Scratch folders

    /// `…/SimpleClipboardDocumentPreviews/<pid>/`: per process, so a second running copy of the app
    /// (a development build) keeps its own. Folders left by processes that are gone are removed
    /// on first use.
    private var scratchRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleClipboardDocumentPreviews", isDirectory: true)
            .appendingPathComponent(String(ProcessInfo.processInfo.processIdentifier), isDirectory: true)
    }

    private func makeScratchFolder() -> URL? {
        let fileManager = FileManager.default
        if !didSweepScratch {
            didSweepScratch = true
            let parent = scratchRoot.deletingLastPathComponent()
            for folder in (try? fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [] {
                guard let pid = Int32(folder.lastPathComponent), pid != ProcessInfo.processInfo.processIdentifier,
                      kill(pid, 0) != 0, errno == ESRCH
                else { continue }
                try? fileManager.removeItem(at: folder)
            }
        }
        let folder = scratchRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            return nil
        }
    }

    // MARK: Quick Look's HTML

    /// What `qlmanage -o` wrote: the page and the generator's layout hints.
    struct Generated: Sendable {
        let html: URL
        /// The size the generator suggests for its view (the slide strip's width, for one).
        let size: CGSize
        /// The elements that are pages (a presentation's slides), when the generator names them.
        let pageElementXPath: String?
    }

    nonisolated private static func generate(_ url: URL, into folder: URL) async -> Generated? {
        guard await runQuickLook(on: url, into: folder) else { return nil }
        let fileManager = FileManager.default
        guard let bundle = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "qlpreview" }),
              let data = try? Data(contentsOf: bundle.appendingPathComponent("PreviewProperties.plist")),
              let properties = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              (properties["MimeType"] as? String)?.lowercased() == "text/html"
        else { return nil }
        let html = bundle.appendingPathComponent("Preview.html")
        guard fileManager.fileExists(atPath: html.path(percentEncoded: false)) else { return nil }
        func number(_ key: String) -> CGFloat { CGFloat((properties[key] as? NSNumber)?.doubleValue ?? 0) }
        return Generated(html: html, size: CGSize(width: number("Width"), height: number("Height")),
                         pageElementXPath: properties["PageElementXPath"] as? String)
    }

    /// Runs `qlmanage -p -o <folder> <file>`, giving up after 20 s.
    nonisolated private static func runQuickLook(on url: URL, into folder: URL) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", "-o", folder.path(percentEncoded: false), url.path(percentEncoded: false)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationReason == .exit && finished.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
                if process.isRunning { process.terminate() }
            }
        }
    }

    /// A workbook's sheets, from the tab strip the generator puts on its page. A single sheet (and
    /// a CSV) gets no strip, and is the page itself.
    ///
    /// The page and its folder must be spelled alike: WebKit checks that the page is inside the
    /// folder it may read by comparing the two as text, and drops the load when it isn't — leaving
    /// a blank sheet. `standardizedFileURL` strips the `/private` the temporary folder's path
    /// starts with, so only `standardized` (`.` and `..`) is used here.
    nonisolated static func sheets(of generated: Generated, title: String) -> [OfficeSheet] {
        let folder = generated.html.deletingLastPathComponent().standardized
        guard let html = try? String(contentsOf: generated.html, encoding: .utf8) else { return [] }
        let tab = #/<div class="TabHeader">(.*?)</div>\s*<a href="([^"]+)"/#
        let sheets = html.matches(of: tab).compactMap { match -> OfficeSheet? in
            let href = String(match.output.2).removingPercentEncoding ?? String(match.output.2)
            let page = folder.appendingPathComponent(href).standardized
            // The generator's own pages only.
            let folderPath = folder.path(percentEncoded: false)
            guard page.path(percentEncoded: false).hasPrefix(folderPath.hasSuffix("/") ? folderPath : folderPath + "/"),
                  FileManager.default.fileExists(atPath: page.path(percentEncoded: false))
            else { return nil }
            return OfficeSheet(name: decodingEntities(String(match.output.1)), url: page, folder: folder)
        }
        return sheets.isEmpty ? [OfficeSheet(name: title, url: generated.html, folder: folder)] : sheets
    }

    /// Decodes the character references an HTML text can hold (`&amp;`, `&#233;`, `&#x2019;`).
    nonisolated static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}"]
        return text.replacing(#/&(#[xX]?[0-9a-fA-F]+|[a-zA-Z]+);/#) { match in
            let body = String(match.output.1)
            if body.hasPrefix("#") {
                let isHex = body.dropFirst().first.map { $0 == "x" || $0 == "X" } ?? false
                let digits = body.dropFirst(isHex ? 2 : 1)
                if let value = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(value) {
                    return String(Character(scalar))
                }
                return String(match.output.0)
            }
            return named[body] ?? String(match.output.0)
        }
    }
}

/// The web view setup every Office page uses: no page scripts (the generator's pages need none), no
/// stored website data, and only local files and inline data can load — the same no-network rule
/// Quick Look applies to these previews.
@MainActor
enum OfficeWebContent {
    private static var rules: WKContentRuleList?
    private static var preparing: Task<Void, Never>?

    /// Compiles the local-only rule list (once).
    static func prepare() async {
        if rules != nil { return }
        if let preparing { return await preparing.value }
        let task = Task { @MainActor in
            // Content-blocker filters have no alternation, so one exception per scheme.
            let json = """
            [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
             {"trigger":{"url-filter":"^file:"},"action":{"type":"ignore-previous-rules"}},
             {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
             {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}}]
            """
            rules = try? await WKContentRuleListStore.default()?.compileContentRuleList(
                forIdentifier: "SimpleClipboardOfficeLocalOnly", encodedContentRuleList: json)
        }
        preparing = task
        await task.value
        preparing = nil
    }

    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.shouldPrintBackgrounds = true
        configuration.websiteDataStore = .nonPersistent()
        if let rules { configuration.userContentController.add(rules) }
        return configuration
    }
}

/// The hidden web view that renders documents and presentations to PDF. It sits in a borderless
/// window that is never ordered in (a print operation needs a window to run for), and is released
/// after a minute without work so its web content process doesn't linger.
@MainActor
private final class OfficeRenderPage: NSObject, WKNavigationDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var loading: CheckedContinuation<Bool, Never>?
    private var printing: CheckedContinuation<Bool, Never>?
    private var idleRelease: Task<Void, Never>?

    func pdf(of generated: OfficePreviewRenderer.Generated, slides: Bool, scratch: URL) async -> Data? {
        idleRelease?.cancel()
        defer { scheduleRelease() }
        let (window, webView) = host()
        // The generator's suggested width lays a slide strip out on one column; a document's page
        // box has a fixed width, so any width wider than a page works.
        let size = NSSize(width: max(generated.size.width, 640), height: max(min(generated.size.height, 2000), 480))
        window.setContentSize(size)
        webView.frame = NSRect(origin: .zero, size: size)
        guard await load(generated.html, in: webView) else { return nil }
        if slides, let data = await slidePages(of: webView, xpath: generated.pageElementXPath ?? "/html/body/div") {
            return data
        }
        return await printedPages(of: webView, in: window, scratch: scratch)
    }

    private func host() -> (NSWindow, WKWebView) {
        if let window, let webView { return (window, webView) }
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let webView = WKWebView(frame: window.contentLayoutRect, configuration: OfficeWebContent.configuration())
        webView.navigationDelegate = self
        window.contentView = webView
        self.window = window
        self.webView = webView
        return (window, webView)
    }

    private func scheduleRelease() {
        idleRelease = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            self?.release()
        }
    }

    private func release() {
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        window?.contentView = nil
        webView = nil
        window = nil
    }

    // MARK: Loading

    private func load(_ html: URL, in webView: WKWebView) async -> Bool {
        finishLoading(false)
        let loaded = await withCheckedContinuation { continuation in
            loading = continuation
            webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                self?.finishLoading(false)
            }
        }
        if !loaded { webView.stopLoading() }
        return loaded
    }

    private func finishLoading(_ loaded: Bool) {
        loading?.resume(returning: loaded)
        loading = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finishLoading(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finishLoading(false)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.isFileURL == true ? .allow : .cancel
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishLoading(false)
        release()
    }

    // MARK: Slides

    /// One PDF page per slide: each slide element's box, captured on its own.
    private func slidePages(of webView: WKWebView, xpath: String) async -> Data? {
        guard let quoted = try? String(data: JSONSerialization.data(withJSONObject: [xpath]), encoding: .utf8)
        else { return nil }
        let script = """
        (function (xpath) {
          var found = document.evaluate(xpath, document, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
          var boxes = [];
          for (var i = 0; i < found.snapshotLength; i++) {
            var node = found.snapshotItem(i);
            if (node.classList && node.classList.contains('loading-slide')) continue;
            var box = node.getBoundingClientRect();
            if (box.width > 0 && box.height > 0) boxes.push([box.left + scrollX, box.top + scrollY, box.width, box.height]);
          }
          return boxes;
        })(\(quoted)[0])
        """
        guard let boxes = (try? await webView.evaluateJavaScript(script)) as? [[Double]], !boxes.isEmpty else { return nil }
        let document = PDFDocument()
        for box in boxes where box.count == 4 {
            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
            guard let data = try? await webView.pdf(configuration: configuration),
                  let page = PDFDocument(data: data)?.page(at: 0)
            else { continue }
            document.insert(page, at: document.pageCount)
        }
        return document.pageCount > 0 ? document.dataRepresentation() : nil
    }

    // MARK: Printing

    /// A document printed to PDF. The generator draws Word's page as a box (`body > div`) as wide as
    /// the page, with the side margins as padding and the top / bottom ones too; for print those two
    /// become the paper's margins, so every page gets them, not just the first and last.
    private func printedPages(of webView: WKWebView, in window: NSWindow, scratch: URL) async -> Data? {
        let measure = """
        (function () {
          var page = document.querySelector('body > div');
          if (!page) return null;
          var style = getComputedStyle(page);
          return [page.getBoundingClientRect().width, parseFloat(style.paddingTop) || 0, parseFloat(style.paddingBottom) || 0];
        })()
        """
        let box = (try? await webView.evaluateJavaScript(measure)) as? [Double]
        let hasPageBox = (box?.count ?? 0) == 3 && (box?[0] ?? 0) > 100
        let width = hasPageBox ? CGFloat(box?[0] ?? 0) : 612
        let margins = hasPageBox ? (top: CGFloat(box?[1] ?? 0), bottom: CGFloat(box?[2] ?? 0)) : (top: 54, bottom: 54)
        // WebKit lays a printout out 1.25× wider than the paper and shrinks it back to fit; the zoom
        // cancels that, so the page box fills the paper at 1:1 (were the factor ever smaller, the
        // wider layout would just be shrunk to fit too). Each section of the document starts a page.
        let printStyle = """
        @media print {
          html { zoom: 1.25; }
          body { margin: 0 !important; }
          body > div { padding-top: 0 !important; padding-bottom: 0 !important; min-height: 0 !important; }
          body > div + div { break-before: page; }
        }
        """
        if hasPageBox, let quoted = try? String(data: JSONSerialization.data(withJSONObject: [printStyle]), encoding: .utf8) {
            _ = try? await webView.evaluateJavaScript(
                "(function (css) { var style = document.createElement('style'); style.textContent = css; document.head.appendChild(style); return 1; })(\(quoted)[0])")
        }

        let output = scratch.appendingPathComponent("Printed.pdf")
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: width, height: Self.pageHeight(forWidth: width))
        info.topMargin = margins.top
        info.bottomMargin = margins.bottom
        info.leftMargin = hasPageBox ? 0 : 54
        info.rightMargin = hasPageBox ? 0 : 54
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = webView.bounds

        let printed = await withCheckedContinuation { continuation in
            printing = continuation
            operation.runModal(for: window, delegate: self,
                               didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard let self, self.printing != nil else { return }
                self.finishPrinting(false)
                // Whatever is stuck goes with the web view; the next job gets a fresh one.
                self.release()
            }
        }
        guard printed, let data = try? Data(contentsOf: output), (PDFDocument(data: data)?.pageCount ?? 0) > 0
        else { return nil }
        return data
    }

    /// Sent on the print job's own thread, not the main one: WebKit lets its print operations spawn
    /// a thread (`canSpawnSeparateThread`), and AppKit finishes the job there. A main-actor method
    /// here traps on Swift 6's isolation check, so this one only hops back.
    @objc nonisolated private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        Task { @MainActor in self.finishPrinting(success) }
    }

    private func finishPrinting(_ success: Bool) {
        printing?.resume(returning: success)
        printing = nil
    }

    /// The paper height for a page box `width` points wide: the standard size of that width (A4,
    /// Letter, A5, B5 or one of them turned to landscape) — the generator keeps Word's page width
    /// but not its height — else A4's proportions.
    static func pageHeight(forWidth width: CGFloat) -> CGFloat {
        let sizes: [CGSize] = [
            CGSize(width: 595, height: 842), CGSize(width: 612, height: 792), CGSize(width: 420, height: 595),
            CGSize(width: 499, height: 709), CGSize(width: 842, height: 595), CGSize(width: 792, height: 612),
        ]
        if let nearest = sizes.min(by: { abs($0.width - width) < abs($1.width - width) }),
           abs(nearest.width - width) <= 12 {
            return (nearest.height * width / nearest.width).rounded()
        }
        return (width * 842 / 595).rounded()
    }
}
