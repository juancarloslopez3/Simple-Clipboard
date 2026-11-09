import AppKit

/// Polls `NSPasteboard.general.changeCount` (~0.4 s) and hands new contents to the
/// `HistoryStore`. `NSPasteboard` has no change notification.
@MainActor
@Observable
final class ClipboardMonitor {
    private let pasteboard = NSPasteboard.general
    private var lastChange: Int
    private var timer: Timer?
    private let history: HistoryStore
    private let prefetch = PasteboardPrefetch()
    /// A change is with `prefetch` and not read yet; polls wait for it.
    private var prefetching = false

    init(history: HistoryStore) {
        self.history = history
        self.lastChange = NSPasteboard.general.changeCount
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // This poll runs for the app's whole life: a tolerance lets the system coalesce its
        // wakeups with other timers (energy), at ≤0.1 s of extra capture latency.
        timer.tolerance = 0.1
        self.timer = timer
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
        guard !prefetching else { return }
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChange else { return }
        lastChange = changeCount

        // Copies from ignored apps (password managers…) are dropped before the pasteboard is even
        // read, so their content is never decoded or held in memory.
        let source = NSWorkspace.shared.frontmostApplication
        if let bundleID = source?.bundleIdentifier, Pref.ignoredAppBundleIDs.contains(bundleID) { return }

        // The first read of a copy made on an iPhone/iPad waits for it to arrive from the device, so
        // the helper takes that read off the main thread (`PasteboardPrefetch`); this one is then instant.
        prefetching = true
        prefetch.prefetch { [weak self] in
            guard let self else { return }
            prefetching = false
            // Replaced meanwhile (another copy, or our own write): the next poll reads what's there now.
            guard pasteboard.changeCount == changeCount else { return }
            read(from: source)
        }
    }

    private func read(from source: NSRunningApplication?) {
        guard let content = ClipboardContent(reading: pasteboard, trimWhitespace: Pref.trimWhitespacePreview,
                                             maxPayloadBytes: Pref.ignoreLargerThanBytes) else {
            // A photo/file copied on an iPhone or iPad is unreadable without Full Disk Access.
            if ClipboardContent.isUnreadableRemoteCopy(pasteboard) { FullDiskAccess.requestIfNeeded() }
            return
        }
        // A copy made on an iPhone/iPad or another Mac has no app here — the frontmost one just
        // happened to be in front — so it is credited to Finder.
        if pasteboard.types?.contains(ClipboardContent.remoteClipboardType) == true {
            history.capture(content, sourceBundleID: Self.finderBundleID, sourceAppName: Self.finderName)
        } else {
            history.capture(content, sourceBundleID: source?.bundleIdentifier, sourceAppName: source?.localizedName)
        }
    }

    private static let finderBundleID = "com.apple.finder"

    /// Finder's localized name, as its running process reports it.
    private static var finderName: String {
        NSRunningApplication.runningApplications(withBundleIdentifier: finderBundleID).first?.localizedName ?? "Finder"
    }
}

/// Universal Clipboard pulls a copy made on an iPhone/iPad off the device only when some process
/// first reads it, and that read blocks — up to 10 s for the type list, then as long as the transfer
/// takes (seconds for a photo). `NSPasteboard` is main-thread-only, so the monitor never takes that
/// first read: this helper — the app's own executable, relaunched with `helperArgument` and kept
/// running — touches each new pasteboard first. Once pboard holds the data, the monitor's
/// main-thread read returns at once. One request at a time; the helper quits with the app (its
/// stdin closes). If it can't run, the monitor just reads directly, as it used to.
@MainActor
final class PasteboardPrefetch {
    static let helperArgument = "--pasteboard-prefetch"

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var completion: (() -> Void)?
    private var watchdog: Task<Void, Never>?
    /// Helper launches that died or hung in a row; past `maxFailures` this stops relaunching it.
    private var failures = 0
    private static let maxFailures = 3
    /// pboard itself gives up on a remote copy after 10 s (types) + 20 s (data).
    private static let timeout: Duration = .seconds(35)

    /// Has the helper read the current pasteboard, then calls `completion` on the main actor —
    /// right away if the helper isn't available.
    func prefetch(then completion: @escaping () -> Void) {
        guard self.completion == nil, let input = helperInput() else { return completion() }
        self.completion = completion
        do {
            try input.write(contentsOf: Data("\n".utf8))
        } catch {
            return helperFailed()
        }
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.timeout)
            if !Task.isCancelled { self?.helperFailed() }
        }
    }

    /// The running helper's stdin, launching it first if needed. Nil when it can't run.
    private func helperInput() -> FileHandle? {
        if let input { return input }
        guard failures < Self.maxFailures, let executable = Bundle.main.executableURL else { return nil }
        let process = Process()
        let stdin = Pipe(), stdout = Pipe()
        // Writing after the helper died must fail (→ `helperFailed`), not raise SIGPIPE and kill the app.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.executableURL = executable
        process.arguments = [Self.helperArgument]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] ended in
            let pid = ended.processIdentifier
            Task { @MainActor in if self?.process?.processIdentifier == pid { self?.helperFailed() } }
        }
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard !handle.availableData.isEmpty else {
                handle.readabilityHandler = nil   // closed: `terminationHandler` follows
                return
            }
            Task { @MainActor in self?.finish() }
        }
        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            failures += 1
            return nil
        }
        self.process = process
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        return input
    }

    /// The helper answered.
    private func finish() {
        failures = 0
        complete()
    }

    /// The helper died, hung or couldn't be written to: drop it (the next request relaunches it)
    /// and let the waiting monitor read directly.
    private func helperFailed() {
        output?.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        input = nil
        output = nil
        failures += 1
        complete()
    }

    private func complete() {
        watchdog?.cancel()
        watchdog = nil
        let completion = completion
        self.completion = nil
        completion?()
    }

    /// The helper process's whole life: for each line on stdin, read the general pasteboard and
    /// answer with a line, until stdin closes. Reading every type of a remote copy is what pulls it
    /// off the device; a local copy is already here, so its type list is all it costs.
    static func runHelper() -> Never {
        while readLine() != nil {
            let pasteboard = NSPasteboard.general
            if pasteboard.types?.contains(ClipboardContent.remoteClipboardType) == true {
                for item in pasteboard.pasteboardItems ?? [] {
                    for type in item.types { _ = item.data(forType: type) }
                }
            }
            print("ok")
            fflush(stdout)
        }
        exit(0)
    }
}

/// Full Disk Access, which recording photos and files copied on an iPhone/iPad needs: Universal
/// Clipboard delivers them as files in a folder only such apps may read
/// (`ClipboardContent.isUnreadableRemoteCopy`). macOS applies a grant on the app's next launch.
@MainActor
enum FullDiskAccess {
    private static var askedThisLaunch = false

    /// Explains why an iPhone copy wasn't recorded and offers the System Settings pane — once per
    /// launch, and never again once its "Do not show this message again" box is ticked. The poll timer doesn't fire
    /// while the modal alert is up, so it can't stack a second one.
    static func requestIfNeeded() {
        guard !askedThisLaunch, !Pref.suppressFullDiskAccessPrompt else { return }
        askedThisLaunch = true
        let alert = NSAlert()
        alert.messageText = String(localized: "Allow Simple Clipboard to Save iPhone Copies")
        alert.informativeText = String(localized: "Photos and files you copy on your iPhone or iPad arrive in a protected folder that only apps with Full Disk Access can read. To keep them in your history, turn on Simple Clipboard in System Settings › Privacy & Security › Full Disk Access, then reopen the app.")
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        alert.showsSuppressionButton = true
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { Pref.suppressFullDiskAccessPrompt = true }
        if response == .alertFirstButtonReturn { PermissionGuide.shared.show(.fullDiskAccess) }
    }

    /// Lists a folder only Full Disk Access opens: Universal Clipboard's own (the one that matters
    /// here), or Safari's on a Mac without it. Without access the listing just fails, with no prompt.
    /// (Not the TCC database: macOS 27 no longer keeps it at the old path, so probing it never succeeds.)
    nonisolated static var isGranted: Bool {
        let probes = ["Library/Group Containers/group.com.apple.coreservices.useractivityd", "Library/Safari"]
            .map { URL.homeDirectory.appending(path: $0).path(percentEncoded: false) }
        guard let probe = probes.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return false }
        return (try? FileManager.default.contentsOfDirectory(atPath: probe)) != nil
    }
}
