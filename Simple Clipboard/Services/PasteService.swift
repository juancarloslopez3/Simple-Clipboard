import AppKit
import ApplicationServices
import PDFKit
import UniformTypeIdentifiers

/// Writes the chosen item/snippet to `NSPasteboard.general` so the user can paste it
/// with ⌘V (CLAUDE.md §12). Clicks/menu/panel selection are **copy-only**; the two paste
/// shortcuts (`pastePlainText`, `pastePrevious`, §14) additionally synthesize ⌘V into the
/// frontmost app so the shortcut pastes directly (Accessibility-gated — see `synthesizePaste`).
/// Also bumps the source item to the top of history and suppresses re-capture of our write.
@MainActor
@Observable
final class PasteService {
    private let history: HistoryStore
    private let monitor: ClipboardMonitor

    /// Copy-feedback sound (`playSoundOnCopy`, §13), shared with the capture path so an external
    /// ⌘C plays the same sound (`CopySound`, §8a).
    private let copySound: CopySound

    init(history: HistoryStore, monitor: ClipboardMonitor, copySound: CopySound) {
        self.history = history
        self.monitor = monitor
        self.copySound = copySound
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

    /// Place a snippet on the clipboard. Rich snippets honor the plain-text path; `plainText`
    /// follows / overrides the pref exactly as for items above.
    func activate(_ snippet: Snippet, plainText: Bool? = nil) {
        writeSnippet(snippet, plainText: (plainText ?? Pref.alwaysPastePlainText))
        monitor.acknowledgeChange()
        feedback()
    }

    /// Activate a history item from a direct user **click**, honoring **Option-click** to invert
    /// the plain-text default for this one copy (CLAUDE.md §12): with `alwaysPastePlainText` off,
    /// Option-click copies plain text; with it on, Option-click copies the full/original form.
    func activateFromClick(_ item: ClipboardItem) {
        activate(item, plainText: optionClickPlainText())
    }

    /// Activate a snippet from a direct user **click**, honoring Option-click as above.
    func activateFromClick(_ snippet: Snippet) {
        activate(snippet, plainText: optionClickPlainText())
    }

    /// Copy just the POSIX path(s) of a `.file` item as plain text (the main window's
    /// "Copy Path" action, §12). `.file` items are exempt from plain-text mode — clicking one
    /// always writes the pasteable file URLs — so this is the explicit textual alternative.
    func copyPaths(of item: ClipboardItem) {
        guard writePaths(of: item.fileURLs) else { return }
        history.touch(item)
        monitor.acknowledgeChange()
        feedback()
    }

    /// Copy just the POSIX path(s) of a file snippet as plain text — the snippets list's
    /// "Copy Path" action, mirroring the history one above (§11/§12).
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
    /// in which case the pref is inverted for this copy (CLAUDE.md §12). Reads the live key state,
    /// so it reflects whether Option is down at the moment the click fires.
    private func optionClickPlainText() -> Bool? {
        NSEvent.modifierFlags.contains(.option) ? !Pref.alwaysPastePlainText : nil
    }

    /// Paste the current top item directly into the frontmost app (`pastePlainText` shortcut,
    /// §14): write it to the clipboard, then synthesize ⌘V so the user doesn't have to. Pressing
    /// the shortcut *and* ⌘V would be redundant. `plainText` follows / overrides the pref as in
    /// `activate`; the shortcut passes `true` to force plain text.
    func pasteTop(plainText: Bool? = nil) {
        guard let top = history.recentItems(limit: 1).first else { return }
        activate(top, plainText: plainText)
        synthesizePaste()
    }

    /// Paste the item just below the current top directly into the frontmost app (`pastePrevious`
    /// shortcut, §14): write it to the clipboard (which also moves it to top) and synthesize ⌘V.
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
        // original form (CLAUDE.md §12); the explicit textual copy for files is `copyPaths(of:)`.
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
            if let attr = NSAttributedString(rtf: item.payload, documentAttributes: nil) {
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
        case .file:
            writeFileURLs(item.fileURLs, to: pb)
        }
    }

    private func writeSnippet(_ snippet: Snippet, plainText: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()

        // File snippets are exempt from plain-text mode, like `.file` items (§12): they
        // always paste as the files themselves; the textual alternative is `copyPaths(of:)`.
        if snippet.isFile {
            writeFileURLs(snippet.fileURLs, to: pb)
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
    /// editors) paste the paths, mirroring what Finder itself writes on copy (§12).
    /// Shared by `.file` history items and file snippets.
    private func writeFileURLs(_ urls: [URL], to pb: NSPasteboard) {
        let pbItems = urls.map { url -> NSPasteboardItem in
            let pbItem = NSPasteboardItem()
            pbItem.setString(url.absoluteString, forType: .fileURL)
            pbItem.setString(url.path(percentEncoded: false), forType: .string)
            return pbItem
        }
        if !pbItems.isEmpty { pb.writeObjects(pbItems) }
    }

    // MARK: Synthetic paste (shortcuts only)

    /// Synthesize a ⌘V keystroke into the frontmost app so the just-written item pastes itself
    /// (CLAUDE.md §12, used only by the paste shortcuts — clicks stay copy-only). Requires
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
    private func ensureAccessibilityTrust() -> Bool {
        // Literal value of `kAXTrustedCheckOptionPrompt` — referencing the imported C global
        // directly is rejected under Swift 6 strict concurrency (it's a mutable global var).
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // MARK: Helpers

    /// Writes an image to `pb` reproducing its **original type** (CLAUDE.md §12). One pasteboard
    /// item carries: the bytes under their native type (e.g. `public.jpeg`), a **PNG fallback**
    /// for apps that only read PNG/TIFF on inline paste, and a **file URL** to a temp file with
    /// the original extension (so Finder pastes e.g. `Image ….jpeg`, not a re-typed `.png`).
    /// `type` is nil for legacy PNG-only items, which paste as PNG. Falls back to bitmap-only
    /// if the temp file can't be written.
    private func writeImage(_ data: Data, type: UTType?, to pb: NSPasteboard) {
        let type = type ?? .png
        guard let url = temporaryPasteFile(data: data, type: type, label: "Image") else {
            pb.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
            return
        }
        let pbItem = NSPasteboardItem()
        pbItem.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        if type != .png, let png = NSImage(data: data)?.pngData {
            pbItem.setData(png, forType: .png)
        }
        pbItem.setString(url.absoluteString, forType: .fileURL)
        pb.writeObjects([pbItem])
    }

    /// Writes a `.pdf` item to `pb` mirroring `writeImage` (CLAUDE.md §12): one pasteboard item
    /// carries the PDF bytes under `com.adobe.pdf`, a **PNG render of the first page** for apps
    /// that only take bitmaps on inline paste, and a **file URL** to a temp `.pdf` so Finder
    /// pastes a real PDF file. Falls back to data-only if the temp file can't be written.
    private func writePDF(_ data: Data, to pb: NSPasteboard) {
        guard let url = temporaryPasteFile(data: data, type: .pdf, label: "PDF") else {
            pb.setData(data, forType: .pdf)
            return
        }
        let pbItem = NSPasteboardItem()
        pbItem.setData(data, forType: .pdf)
        if let document = PDFDocument(data: data),
           let png = ClipboardContent.pdfPagePNG(document, maxDimension: 1600) {
            pbItem.setData(png, forType: .png)
        }
        pbItem.setString(url.absoluteString, forType: .fileURL)
        pb.writeObjects([pbItem])
    }

    /// Writes `data` to a temp file used purely as a paste source, returning its URL. The file
    /// is named `<label> <dd-MM-yyyy>_<HHmmss>.<ext>` (e.g. `Image 23-06-2026_211102.jpeg`),
    /// with the extension matching `type` — that becomes the pasted file's name/format in
    /// Finder. The dedicated temp subdirectory is cleared each call so these scratch files don't
    /// accumulate (only the freshest is on the pasteboard); the OS reclaims it over time.
    private func temporaryPasteFile(data: Data, type: UTType, label: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleClipboardPasteboard", isDirectory: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd-MM-yyyy_HHmmss"
        let ext = type.preferredFilenameExtension ?? "png"
        let name = "\(label) \(formatter.string(from: Date())).\(ext)"
        do {
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name)
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// Best plain-text rendering of an item (used by the plain-text path; `.image`/`.pdf`/
    /// `.file` are exempt from that path and never reach here — §12).
    private func plainString(of item: ClipboardItem) -> String {
        switch item.kind {
        case .plainText, .code, .url:
            return decodedString(item.payload, fallback: item.plainPreview)
        case .richText:
            return NSAttributedString(rtf: item.payload, documentAttributes: nil)?.string ?? item.plainPreview
        case .image, .color, .file, .pdf:
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
