import AppKit

/// Polls `NSPasteboard.general.changeCount` (~0.4 s) and hands new contents to the
/// `HistoryStore` (CLAUDE.md §8a). `NSPasteboard` has no change notification.
@MainActor
@Observable
final class ClipboardMonitor {
    private let pasteboard = NSPasteboard.general
    private var lastChange: Int
    private var timer: Timer?
    private let history: HistoryStore

    init(history: HistoryStore) {
        self.history = history
        self.lastChange = NSPasteboard.general.changeCount
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Suppress capturing our own programmatic pasteboard write (PasteService).
    func acknowledgeChange() {
        lastChange = pasteboard.changeCount
    }

    private func poll() {
        guard pasteboard.changeCount != lastChange else { return }
        lastChange = pasteboard.changeCount

        guard let content = ClipboardContent(reading: pasteboard, trimWhitespace: Pref.trimWhitespacePreview) else { return }
        history.capture(content, from: NSWorkspace.shared.frontmostApplication)
    }
}
