import AppKit
import ApplicationServices
import PDFKit
import UniformTypeIdentifiers

/// Writes the chosen item/snippet to `NSPasteboard.general` so the user can paste it
/// with ⌘V. Clicks/menu/panel selection are **copy-only**; the two paste
/// shortcuts (`pastePlainText`, `pastePrevious`) additionally synthesize ⌘V into the
/// frontmost app so the shortcut pastes directly (Accessibility-gated — see `synthesizePaste`).
/// Also bumps the source item to the top of history and suppresses re-capture of our write.
@MainActor
@Observable
final class PasteService {
    private let history: HistoryStore
    private let monitor: ClipboardMonitor

    /// Copy-feedback sound (`playSoundOnCopy`), shared with the capture path so an external
    /// ⌘C plays the same sound (`CopySound`).
    private let copySound: CopySound

    /// The multi-item copy on the clipboard whose text item offers Finder a text file, kept so it
    /// can be written again if another app was refused that file (`reofferFinderFile`).
    @ObservationIgnored private var finderFileCopy: FinderFileCopy?

    init(history: HistoryStore, monitor: ClipboardMonitor, copySound: CopySound) {
        self.history = history
        self.monitor = monitor
        self.copySound = copySound
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == FinderOnlyFileURL.finderBundleID else { return }
            MainActor.assumeIsolated { self?.reofferFinderFile() }
        }
    }

    // MARK: Public actions

    /// Place a history item on the clipboard and move it to top. `plainText` is `nil` to follow
    /// the `alwaysPastePlainText` pref, or an explicit value to override it for this one copy —
    /// `true` forces plain, `false` forces the item's full/original form even when the pref is on.
    func activate(_ item: ClipboardItem, plainText: Bool? = nil) {
        writeItem(item, plainText: plainText ?? Pref.alwaysPastePlainText)
        history.touch(item)
        monitor.acknowledgeChange()
        feedback()
    }

    /// Copy several history items at once — the panel's ⌘-click selection and the main window's
    /// multi-selection: each item goes on the clipboard as itself (`writeElements`).
    /// `plainText` is `nil` to follow the `alwaysPastePlainText` pref, or an explicit value to
    /// override it. An explicit `true` is the "Copy as plain text" action, which puts only text on
    /// the clipboard; the pref keeps images, PDFs and files, which it exempts.
    /// History order is left alone: no single item is what's on the clipboard now.
    func activate(_ items: [ClipboardItem], plainText: Bool? = nil) {
        guard items.count > 1 else {
            if let item = items.first { activate(item, plainText: plainText) }
            return
        }
        writeElements(items.map(pasteElement(for:)), plainText: plainText, to: NSPasteboard.general)
        monitor.acknowledgeChange()
        feedback()
    }

    /// Place a snippet on the clipboard. Rich snippets honor the plain-text path; `plainText`
    /// follows / overrides the pref exactly as for items above.
    func activate(_ snippet: Snippet, plainText: Bool? = nil) {
        writeSnippet(snippet, plainText: (plainText ?? Pref.alwaysPastePlainText))
        monitor.acknowledgeChange()
        feedback()
    }

    /// Copy several snippets at once — the snippets pane's multi-selection ⌘C — the same way
    /// as several history items, with `plainText` meaning the same.
    func activate(_ snippets: [Snippet], plainText: Bool? = nil) {
        guard snippets.count > 1 else {
            if let snippet = snippets.first { activate(snippet, plainText: plainText) }
            return
        }
        writeElements(snippets.map(pasteElement(for:)), plainText: plainText, to: NSPasteboard.general)
        monitor.acknowledgeChange()
        feedback()
    }

    /// Activate a history item from a direct user **click**, honoring **Option-click** to invert
    /// the plain-text default for this one copy: with `alwaysPastePlainText` off,
    /// Option-click copies plain text; with it on, Option-click copies the full/original form.
    func activateFromClick(_ item: ClipboardItem) {
        activate(item, plainText: optionClickPlainText())
    }

    /// Activate a snippet from a direct user **click**, honoring Option-click as above.
    func activateFromClick(_ snippet: Snippet) {
        activate(snippet, plainText: optionClickPlainText())
    }

    /// Copy just the POSIX path(s) of a `.file` item as plain text (the main window's
    /// "Copy Path" action). `.file` items are exempt from plain-text mode — clicking one
    /// always writes the pasteable file URLs — so this is the explicit textual alternative.
    func copyPaths(of item: ClipboardItem) {
        guard writePaths(of: item.fileURLs) else { return }
        history.touch(item)
        monitor.acknowledgeChange()
        feedback()
    }

    /// Copy just the POSIX path(s) of a file snippet as plain text — the snippets list's
    /// "Copy Path" action, mirroring the history one above.
    func copyPaths(of snippet: Snippet) {
        guard writePaths(of: snippet.fileURLs) else { return }
        monitor.acknowledgeChange()
        feedback()
    }

    /// Writes the URLs' POSIX paths as newline-joined plain text; false if there are none.
    private func writePaths(of urls: [URL]) -> Bool {
        let paths = urls.map { $0.path(percentEncoded: false) }
        guard !paths.isEmpty else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(paths.joined(separator: "\n"), forType: .string)
        return true
    }

    /// The plain-text override for a click: `nil` (follow the pref) unless **Option** is held,
    /// in which case the pref is inverted for this copy. Reads the live key state,
    /// so it reflects whether Option is down at the moment the click fires.
    private func optionClickPlainText() -> Bool? {
        NSEvent.modifierFlags.contains(.option) ? !Pref.alwaysPastePlainText : nil
    }

    /// Paste the current top item directly into the frontmost app (`pastePlainText` shortcut):
    /// write it to the clipboard, then synthesize ⌘V so the user doesn't have to. Pressing
    /// the shortcut *and* ⌘V would be redundant. `plainText` follows / overrides the pref as in
    /// `activate`; the shortcut passes `true` to force plain text.
    func pasteTop(plainText: Bool? = nil) {
        guard let top = history.recentItems(limit: 1).first else { return }
        activate(top, plainText: plainText)
        synthesizePaste()
    }

    /// Paste the item just below the current top directly into the frontmost app (`pastePrevious`
    /// shortcut): write it to the clipboard (which also moves it to top) and synthesize ⌘V.
    func pastePrevious() {
        let recent = history.recentItems(limit: 2)
        guard recent.count > 1 else { return }
        activate(recent[1])
        synthesizePaste()
    }

    // MARK: Pasteboard writers

    private func writeItem(_ item: ClipboardItem, plainText: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()

        // Plain-text mode only applies to kinds with a real textual form — an image's or PDF's
        // "plain string" is just its preview label (`PNG · 1920×1080`, `PDF · 3 pages`) and a
        // file *is* the file, so `.image`/`.pdf`/`.file` are exempt and always paste in full
        // original form; the explicit textual copy for files is `copyPaths(of:)`.
        if plainText, !item.kind.isPlainTextExempt {
            pb.setString(plainString(of: item), forType: .string)
            return
        }

        switch item.kind {
        case .plainText, .code:
            pb.setString(decodedString(item.payload, fallback: item.plainPreview), forType: .string)
        case .url:
            let s = decodedString(item.payload, fallback: item.plainPreview)
            pb.setString(s, forType: .string)
            pb.setString(s, forType: .URL)
        case .richText:
            pb.setData(item.payload, forType: .rtf)
            // The plain text with list markers, as TextEdit copies it ("\t•\tItem").
            if let attr = NSAttributedString.withListMarkers(rtf: item.payload) {
                pb.setString(attr.string, forType: .string)
            }
        case .image:
            writeImage(item.payload, type: item.payloadType, to: pb)
        case .pdf:
            writePDF(item.payload, to: pb)
        case .color:
            if let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: item.payload) {
                pb.writeObjects([color])
            }
        case .file, .folder:
            // A file moved or deleted since pastes from the copy kept of it (`availableFileURLs`);
            // text contexts still get the path it was copied from.
            writeFileURLs(PasteFiles().pasteURLs(for: item.availableFileURLs), textPaths: item.fileURLs, to: pb)
        }
    }

    private func writeSnippet(_ snippet: Snippet, plainText: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()

        // File snippets are exempt from plain-text mode, like `.file` items: they
        // always paste as the files themselves; the textual alternative is `copyPaths(of:)`.
        if snippet.isFile {
            let stored = snippet.fileURLs
            writeFileURLs(PasteFiles().pasteURLs(for: stored), textPaths: stored, to: pb)
            return
        }

        if plainText || !snippet.isRichText {
            pb.setString(snippet.plainString, forType: .string)
            return
        }
        pb.setData(snippet.payload, forType: .rtf)
        pb.setString(snippet.plainString, forType: .string)
    }

    /// One pasteboard item per URL, each carrying the file URL *and* its POSIX path as
    /// plain text — Finder pastes the actual files while text contexts (Terminal,
    /// editors) paste the paths, mirroring what Finder itself writes on copy.
    /// Shared by `.file` history items and file snippets. `textPaths` overrides which paths text
    /// contexts get, one per URL.
    private func writeFileURLs(_ urls: [URL], textPaths: [URL]? = nil, to pb: NSPasteboard) {
        let pbItems = zip(urls, textPaths ?? urls).map { filePasteboardItem($0, textPath: $1) }
        if !pbItems.isEmpty { pb.writeObjects(pbItems) }
    }

    private func filePasteboardItem(_ url: URL, textPath: URL? = nil) -> NSPasteboardItem {
        let pbItem = NSPasteboardItem()
        pbItem.setString(url.absoluteString, forType: .fileURL)
        if let textPath { pbItem.setString(textPath.path(percentEncoded: false), forType: .string) }
        return pbItem
    }

    /// Writes several items or snippets: one pasteboard item per image, PDF and file, so
    /// Finder and image-taking apps get each of them. All the text goes on a single pasteboard item
    /// instead, ahead of the others, because most text fields read only the first one. It's joined
    /// by blank lines, with files contributing their paths; with no text elements those paths ride
    /// on the first file's item, one per line like Copy Paths, so nothing but files reaches Finder.
    /// An explicit `plainText` of `true` writes only that text, unless there's none (only images
    /// and PDFs).
    ///
    /// Finder turns text on the clipboard into a `.textClipping`, so the text item also offers it as
    /// one file (`offerFinderFile`): an `.rtf` when the item carries RTF, a `.txt` otherwise. The file
    /// leaves out the files' paths, since Finder pastes those files themselves; with plain text only,
    /// it holds exactly the text on the clipboard.
    private func writeElements(_ elements: [PasteElement], plainText: Bool?, to pb: NSPasteboard) {
        let elements = elements.filter { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true }
        let text = elements.compactMap(\.text).joined(separator: elements.contains(where: \.isText) ? "\n\n" : "\n")
        pb.clearContents()
        finderFileCopy = nil
        let files = PasteFiles()
        var finderFile: FinderOnlyFileURL?
        defer {
            if let finderFile {
                finderFileCopy = FinderFileCopy(changeCount: pb.changeCount, elements: elements,
                                                plainText: plainText, provider: finderFile)
            }
        }
        if plainText == true, !text.isEmpty {
            let textItem = NSPasteboardItem()
            textItem.setString(text, forType: .string)
            finderFile = offerFinderFile(on: textItem, text: text, rtf: nil, files: files)
            pb.writeObjects([textItem])
            return
        }

        var pbItems = elements.flatMap { element -> [NSPasteboardItem] in
            switch element {
            case .text: []
            case .image(let data, let type): [imagePasteboardItem(data, type: type, files: files)]
            case .pdf(let data): [pdfPasteboardItem(data, files: files)]
            case .files(let urls, _): files.pasteURLs(for: urls).map { filePasteboardItem($0) }
            }
        }
        if elements.contains(where: \.isText) {
            let rich = !(plainText ?? Pref.alwaysPastePlainText)
            let textItem = NSPasteboardItem()
            if rich, let rtf = Self.combinedRTF(of: elements) {
                textItem.setData(rtf, forType: .rtf)
            }
            textItem.setString(text, forType: .string)
            let texts = elements.filter(\.isText)
            finderFile = offerFinderFile(on: textItem, text: texts.compactMap(\.text).joined(separator: "\n\n"),
                                         rtf: rich ? Self.combinedRTF(of: texts) : nil, files: files)
            pbItems.insert(textItem, at: 0)
        } else if !text.isEmpty {
            pbItems.first?.setString(text, forType: .string)
        }
        if !pbItems.isEmpty { pb.writeObjects(pbItems) }
    }

    /// Writes `text` (or `rtf`, when given) to a paste file and offers it on `textItem` as the file
    /// Finder pastes, through `FinderOnlyFileURL`. Nil if the file can't be written; Finder then
    /// makes its `.textClipping` as before.
    private func offerFinderFile(on textItem: NSPasteboardItem, text: String, rtf: Data?,
                                 files: PasteFiles) -> FinderOnlyFileURL? {
        let url = if let rtf { files.write(rtf, type: .rtf, label: "Text") } else { files.write(text, label: "Text") }
        guard let url else { return nil }
        let provider = FinderOnlyFileURL(url)
        textItem.setDataProvider(provider, forTypes: [.fileURL])
        return provider
    }

    /// Finder came to the front. If another app was refused the text file of the copy that's still
    /// on the clipboard, that refusal stuck for every later reader, Finder included, so write the copy
    /// again: Finder's paste then gets the file and not a `.textClipping`.
    private func reofferFinderFile() {
        guard let copy = finderFileCopy, copy.provider.declined else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount == copy.changeCount else {
            finderFileCopy = nil
            return
        }
        writeElements(copy.elements, plainText: copy.plainText, to: pb)
        monitor.acknowledgeChange()
    }

    /// The elements' text as one RTF document, separated like the plain text, so a rich paste target
    /// gets all of it and not just the first rich element. Nil when none of them is rich.
    private static func combinedRTF(of elements: [PasteElement]) -> Data? {
        guard elements.contains(where: \.isRich) else { return nil }
        let combined = NSMutableAttributedString()
        for element in elements {
            guard let text = element.text else { continue }
            if combined.length > 0 { combined.append(NSAttributedString(string: "\n\n")) }
            combined.append(element.attributedText ?? NSAttributedString(string: text))
        }
        return combined.rtf(from: NSRange(location: 0, length: combined.length),
                            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    /// What an item is in a multi-item copy. Colors go as their text.
    private func pasteElement(for item: ClipboardItem) -> PasteElement {
        switch item.kind {
        case .plainText, .code, .url, .color: .text(plainString(of: item))
        case .richText: .text(plainString(of: item), rtf: item.payload)
        case .image: .image(item.payload, type: item.payloadType)
        case .pdf: .pdf(item.payload)
        case .file, .folder: .files(item.availableFileURLs, textPaths: item.fileURLs)
        }
    }

    /// What a snippet is in a multi-snippet copy.
    private func pasteElement(for snippet: Snippet) -> PasteElement {
        if snippet.isFile { return .files(snippet.fileURLs) }
        return .text(snippet.plainString, rtf: snippet.isRichText ? snippet.payload : nil)
    }

    // MARK: Synthetic paste (shortcuts only)

    /// Synthesize a ⌘V keystroke into the frontmost app so the just-written item pastes itself
    /// (used only by the paste shortcuts — clicks stay copy-only). Requires
    /// Accessibility trust; prompts once and returns if not yet granted (events would be dropped
    /// silently otherwise). Suppresses the user's physically-held keys for the post interval so
    /// the global shortcut's own ⌘/⇧ can't combine into the synthetic ⌘V.
    private func synthesizePaste() {
        guard ensureAccessibilityTrust() else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        let vKey: CGKeyCode = 0x09  // ANSI "V"
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Whether the process is trusted to post synthetic events (post CGEvents to other apps).
    /// Passes the prompt option so the first ungranted attempt opens the system Accessibility
    /// dialog; the user grants it once in System Settings › Privacy & Security › Accessibility.
    /// An old copy of the app is taken out of that list first (`Permission.removeStaleEntry`),
    /// so the prompt adds this one.
    private func ensureAccessibilityTrust() -> Bool {
        if AXIsProcessTrusted() { return true }
        Task {
            await Permission.accessibility.removeStaleEntry()
            // Literal value of `kAXTrustedCheckOptionPrompt` — referencing the imported C global
            // directly is rejected under Swift 6 strict concurrency (it's a mutable global var).
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        return false
    }

    // MARK: Helpers

    /// Writes an image to `pb` reproducing its **original type**.
    private func writeImage(_ data: Data, type: UTType?, to pb: NSPasteboard) {
        pb.writeObjects([imagePasteboardItem(data, type: type, files: PasteFiles())])
    }

    /// One pasteboard item carrying an image: the bytes under their native type (e.g.
    /// `public.jpeg`), a **PNG fallback** for apps that only read PNG/TIFF on inline paste, and a
    /// **file URL** to a temp file with the original extension (so Finder pastes e.g.
    /// `Image ….jpeg`, not a re-typed `.png`). `type` is nil for legacy PNG-only items, which paste
    /// as PNG. Falls back to the bytes alone if the temp file can't be written. The PNG is
    /// **promised**, not encoded up front: for a 12 MP photo the encode takes over half a second,
    /// which stalled every copy (the panel stayed frozen before closing) though most paste targets
    /// take the original type.
    private func imagePasteboardItem(_ data: Data, type: UTType?, files: PasteFiles) -> NSPasteboardItem {
        let type = type ?? .png
        let pbItem = NSPasteboardItem()
        pbItem.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        guard let url = files.write(data, type: type, label: "Image") else { return pbItem }
        // `NSImage(data:)` only parses the header here; the decode + encode wait for a request.
        if type != .png, NSImage(data: data) != nil {
            pbItem.setDataProvider(PromisedPasteboardData { NSImage(data: data)?.pngData }, forTypes: [.png])
        }
        pbItem.setString(url.absoluteString, forType: .fileURL)
        return pbItem
    }

    /// Writes a `.pdf` item to `pb` mirroring `writeImage`.
    private func writePDF(_ data: Data, to pb: NSPasteboard) {
        pb.writeObjects([pdfPasteboardItem(data, files: PasteFiles())])
    }

    /// One pasteboard item carrying a PDF: the bytes under `com.adobe.pdf`, a **PNG render of the
    /// first page** (promised, like the image fallback) for apps that only take bitmaps on inline
    /// paste, and a **file URL** to a temp `.pdf` so Finder pastes a real PDF file. Falls back to
    /// the bytes alone if the temp file can't be written.
    private func pdfPasteboardItem(_ data: Data, files: PasteFiles) -> NSPasteboardItem {
        let pbItem = NSPasteboardItem()
        pbItem.setData(data, forType: .pdf)
        guard let url = files.write(data, type: .pdf, label: "PDF") else { return pbItem }
        pbItem.setDataProvider(PromisedPasteboardData {
            PDFDocument(data: data).flatMap { ClipboardContent.pdfPagePNG($0, maxDimension: 1600) }
        }, forTypes: [.png])
        pbItem.setString(url.absoluteString, forType: .fileURL)
        return pbItem
    }

    /// Best plain-text rendering of an item (used by the plain-text path; `.image`/`.pdf`/
    /// `.file` are exempt from that path and never reach here).
    private func plainString(of item: ClipboardItem) -> String {
        switch item.kind {
        case .plainText, .code, .url:
            return decodedString(item.payload, fallback: item.plainPreview)
        case .richText:
            return NSAttributedString.withListMarkers(rtf: item.payload)?.string ?? item.plainPreview
        case .image, .color, .file, .pdf, .folder:
            return item.plainPreview
        }
    }

    private func decodedString(_ data: Data, fallback: String) -> String {
        String(data: data, encoding: .utf8) ?? fallback
    }

    private func feedback() {
        copySound.play()
    }
}

/// One history item or snippet in a multi-item copy.
private enum PasteElement {
    /// Text, with its RTF when it's rich.
    case text(String, rtf: Data? = nil)
    case image(Data, type: UTType?)
    case pdf(Data)
    /// Files, and the paths text contexts get for them when those differ (a history item's file
    /// read from its kept copy keeps the path it was copied from).
    case files([URL], textPaths: [URL]? = nil)

    var isText: Bool {
        if case .text = self { true } else { false }
    }

    var isRich: Bool {
        if case .text(_, let rtf?) = self { rtf.isEmpty == false } else { false }
    }

    /// What this contributes to text contexts: its text, or a file's path. Images and PDFs have
    /// none: their "plain string" is only a label.
    var text: String? {
        switch self {
        case .text(let text, _): text
        case .files(let urls, let textPaths): (textPaths ?? urls).map { $0.path(percentEncoded: false) }.joined(separator: "\n")
        case .image, .pdf: nil
        }
    }

    /// The rich form of a rich text element.
    var attributedText: NSAttributedString? {
        guard case .text(_, let rtf?) = self else { return nil }
        return NSAttributedString.withListMarkers(rtf: rtf)
    }
}

/// The temp files behind one copy, used purely as paste sources. They share one fresh directory,
/// created on first need because creating it empties it: only the freshest copy's files are on the
/// pasteboard, so these scratch files don't accumulate (the OS reclaims the rest over time). Names
/// stay unique within a copy, so a paste in Finder never asks about duplicates.
@MainActor
private final class PasteFiles {
    private lazy var directory: URL? = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleClipboardPasteboard", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }()
    private var taken = Set<String>()   // lowercased: APFS names are case-insensitive by default

    /// Writes `data` to a file named `<label> <dd-MM-yyyy>_<HHmmss>.<ext>` (e.g.
    /// `Image 23-06-2026_211102.jpeg`), with the extension matching `type` — that becomes the
    /// pasted file's name/format in Finder.
    func write(_ data: Data, type: UTType, label: String) -> URL? {
        guard let url = newFileURL(type: type, label: label) else { return nil }
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// Writes `text` as a UTF-8 `.txt` named like `write(_:type:label:)`. `String.write` also tags
    /// the file's encoding (`com.apple.TextEncoding`), so TextEdit doesn't misread accented letters.
    func write(_ text: String, label: String) -> URL? {
        guard let url = newFileURL(type: .plainText, label: label) else { return nil }
        do {
            try text.write(to: url, atomically: false, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private func newFileURL(type: UTType, label: String) -> URL? {
        guard let directory else { return nil }
        let ext = type.preferredFilenameExtension ?? "png"
        return directory.appendingPathComponent(uniqueName("\(label) \(Date.now.fileNameStamp).\(ext)"))
    }

    /// What goes on the pasteboard for these files. A file a snippet or the history stores goes as a
    /// throwaway clone, so Finder's "Move Item Here" (⌥⌘V) moves the clone and not the file the app
    /// keeps; so does a file whose name is already taken in this copy, under a numbered name. Clones
    /// cost no space. A file that's neither is the user's own and goes as it is, as does one that
    /// won't clone (on another volume than temp).
    func pasteURLs(for urls: [URL]) -> [URL] {
        urls.map { url in
            let name = uniqueName(url.lastPathComponent)
            let stored = Snippet.isManagedFileCopy(url) || ClipboardItem.isStoredFile(url)
            guard stored || name != url.lastPathComponent, let directory else { return url }
            let clone = directory.appending(path: name)
            guard clonefile(url.path(percentEncoded: false), clone.path(percentEncoded: false), 0) == 0 else { return url }
            return clone
        }
    }

    /// `name`, or `name` with a number added when it's already taken in this copy.
    private func uniqueName(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var number = 2
        while taken.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            number += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }
}

/// Gives a multi-item copy's text file to Finder and no other app. Finder pastes a pasteboard
/// item as a file only when the item has a file URL, and makes a `.textClipping` from any other text,
/// so the text item offers its file this way. Other apps would take that file over the text: a rich
/// `NSTextView` pastes it as an attachment, and web views and Electron apps treat it as an upload. So
/// the URL goes out only while Finder is frontmost, which it is whenever it pastes. Any other reader
/// gets nothing and falls back to the text. A refused type stays empty for every later reader, which
/// `declined` reports so `PasteService` can write the copy again when Finder comes to the front.
private final class FinderOnlyFileURL: NSObject, NSPasteboardItemDataProvider {
    static let finderBundleID = "com.apple.finder"

    private let url: URL
    private(set) var declined = false

    init(_ url: URL) {
        self.url = url
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.finderBundleID else {
            declined = true
            return
        }
        item.setString(url.absoluteString, forType: type)
    }
}

/// A multi-item copy with a Finder text file, as `PasteService.writeElements` wrote it.
private struct FinderFileCopy {
    let changeCount: Int
    let elements: [PasteElement]
    let plainText: Bool?
    let provider: FinderOnlyFileURL
}

/// Supplies one pasteboard type on demand, so a costly fallback representation is only
/// produced if a paste target actually asks for it. The pasteboard item retains its provider,
/// and AppKit collects any still-unrequested data before the app quits, so the promise holds.
private final class PromisedPasteboardData: NSObject, NSPasteboardItemDataProvider {
    private let make: @Sendable () -> Data?

    init(_ make: @escaping @Sendable () -> Data?) {
        self.make = make
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        if let data = make() { item.setData(data, forType: type) }
    }
}
