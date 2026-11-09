import AppKit
import CryptoKit
import SwiftUI

/// "Check for Updates…" (About tab, and quietly every 30 days — `startAutomaticChecks`): asks GitHub for the latest release of the repo, and when it is
/// newer than this build offers to download its `.dmg`, verify it, swap the app bundle in place and
/// relaunch.
///
/// The swap can't happen while the app runs from that bundle, so the new copy is staged in a temp
/// folder and a small shell script — started just before the app quits — waits for this process to
/// exit, replaces the bundle (keeping the old one until the new copy is in place) and opens it.
/// When the app's folder isn't writable (a standard user and `/Applications`), the downloaded image
/// is opened in Finder instead so it can be dragged over by hand.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    static let repo = "juancarloslopez3/simple-clipboard"
    static let releasesURL = URL(string: "https://github.com/\(repo)/releases")!
    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!

    private var isBusy = false
    private var progressWindow: NSWindow?
    private var downloadTask: URLSessionDownloadTask?

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: Automatic check

    /// How often the app looks for a new release on its own.
    private static let automaticInterval: TimeInterval = 30 * 24 * 60 * 60
    private var automaticTimer: Timer?

    /// Starts the background schedule: a quiet check whenever 30 days have passed since the last
    /// successful one (manual checks count too). It only speaks up when a newer release exists —
    /// "up to date" and network errors stay silent and are retried on a later tick. A fresh
    /// install starts the clock instead of checking, so the first run (and its onboarding) is
    /// never interrupted. The app is a long-running agent, so besides launch it re-evaluates
    /// every few hours.
    func startAutomaticChecks() {
        guard automaticTimer == nil else { return }
        if Pref.lastUpdateCheck == nil { Pref.lastUpdateCheck = .now }
        let timer = Timer(timeInterval: 6 * 60 * 60, repeats: true) { _ in
            Task { @MainActor in UpdateChecker.shared.checkIfDue() }
        }
        timer.tolerance = 30 * 60
        RunLoop.main.add(timer, forMode: .common)
        automaticTimer = timer
        // Let launch settle (windows, relaunch routing) before a possible alert.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(15))
            UpdateChecker.shared.checkIfDue()
        }
    }

    private func checkIfDue() {
        guard let last = Pref.lastUpdateCheck,
              Date.now.timeIntervalSince(last) >= Self.automaticInterval else { return }
        // Don't stack an alert on top of another modal; the next tick retries.
        guard NSApp.modalWindow == nil else { return }
        checkForUpdates(silently: true)
    }

    // MARK: Check

    /// `silently`: the automatic check — no "up to date" or error alerts, only the update offer.
    func checkForUpdates(silently: Bool = false) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            let release: Release
            do {
                release = try await Self.fetchLatestRelease()
                Pref.lastUpdateCheck = .now
            } catch {
                if !silently { showError(error) }
                return
            }
            do {
                guard Self.isVersion(release.version, newerThan: Self.currentVersion) else {
                    if !silently { showUpToDate() }
                    return
                }
                guard offerUpdate(release) else { return }
                guard let dmg = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else {
                    NSWorkspace.shared.open(release.htmlURL)
                    return
                }
                try await install(release: release, dmg: dmg)
            } catch is CancellationError {
                closeProgress()
            } catch let error as URLError where error.code == .cancelled {
                closeProgress()   // the progress window's Cancel button
            } catch {
                closeProgress()
                showError(error)
            }
        }
    }

    // MARK: GitHub

    struct Release: Decodable, Sendable {
        struct Asset: Decodable, Sendable {
            let name: String
            let browserDownloadURL: URL
            let size: Int
            /// `sha256:<hex>` — GitHub computes it for every uploaded asset.
            let digest: String?

            enum CodingKeys: String, CodingKey {
                case name, size, digest
                case browserDownloadURL = "browser_download_url"
            }
        }
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: URL
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case name, body, assets
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }

        /// The tag without its leading `v` (`v1.2` → `1.2`).
        var version: String {
            tagName.hasPrefix("v") || tagName.hasPrefix("V") ? String(tagName.dropFirst()) : tagName
        }
    }

    private static func fetchLatestRelease() async throws -> Release {
        var request = URLRequest(url: latestReleaseAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SimpleClipboard/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.badResponse }
        guard http.statusCode == 200 else {
            throw http.statusCode == 404 ? UpdateError.noReleases : UpdateError.badResponse
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// Numeric, component-wise comparison: `1.10` > `1.9`, `2` == `2.0`. Non-numeric suffixes
    /// (`1.2-beta`) are ignored within a component.
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Alerts

    private func showUpToDate() {
        let alert = NSAlert()
        alert.messageText = String(localized: "You’re Up to Date")
        alert.informativeText = String(localized: "Simple Clipboard \(Self.currentVersion) is the latest version.")
        alert.addButton(withTitle: String(localized: "OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Returns whether the user chose to install.
    private func offerUpdate(_ release: Release) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "A New Version of Simple Clipboard Is Available")
        alert.informativeText = String(localized: "Simple Clipboard \(release.version) is available — you have \(Self.currentVersion). Download it and restart to install?")
        alert.addButton(withTitle: String(localized: "Install and Restart"))
        alert.addButton(withTitle: String(localized: "Later"))
        alert.addButton(withTitle: String(localized: "View Release"))

        if let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            alert.accessoryView = Self.notesView(notes)
        }
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return true
        case .alertThirdButtonReturn: NSWorkspace.shared.open(release.htmlURL); return false
        default: return false
        }
    }

    /// The release notes (Markdown rendered inline) in a small scrolling box.
    private static func notesView(_ notes: String) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
        scroll.borderType = .bezelBorder
        guard let text = scroll.documentView as? NSTextView else { return scroll }
        text.isEditable = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 4, height: 6)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let rendered = (try? AttributedString(markdown: notes, options: options)).map { NSMutableAttributedString($0) }
            ?? NSMutableAttributedString(string: notes)
        rendered.addAttributes([.foregroundColor: NSColor.labelColor],
                               range: NSRange(location: 0, length: rendered.length))
        rendered.enumerateAttribute(.font, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
            if value == nil { rendered.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: range) }
        }
        text.textStorage?.setAttributedString(rendered)
        return scroll
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Couldn’t Update Simple Clipboard")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Open Releases Page"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(Self.releasesURL) }
    }

    // MARK: Download & install

    private func install(release: Release, dmg asset: Release.Asset) async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appending(path: "SimpleClipboardUpdate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let dmgURL = workDir.appending(path: asset.name)

        let progress = DownloadProgress(version: release.version)
        showProgress(progress)
        try await download(asset.browserDownloadURL, to: dmgURL, progress: progress)

        progress.phase = .verifying
        let expected = try await expectedSHA256(for: asset, in: release)
        let destination = Bundle.main.bundleURL
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let staged = try await Task.detached(priority: .userInitiated) {
            if let expected { try Self.verifySHA256(of: dmgURL, expected: expected) }
            return try Self.stageApp(from: dmgURL, in: workDir, bundleID: bundleID)
        }.value

        // No write access to the app's folder: hand the image to Finder instead.
        let parent = destination.deletingLastPathComponent().path(percentEncoded: false)
        guard FileManager.default.isWritableFile(atPath: parent),
              FileManager.default.isWritableFile(atPath: destination.path(percentEncoded: false)) else {
            closeProgress()
            NSWorkspace.shared.open(dmgURL)
            return
        }

        progress.phase = .restarting
        try Self.launchSwapScript(staged: staged, destination: destination, workDir: workDir)
        NSApp.terminate(nil)
    }

    private func download(_ url: URL, to destination: URL, progress: DownloadProgress) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = URLSession.shared.downloadTask(with: url) { tempURL, response, error in
                    // The temp file is deleted once this handler returns, so move it now.
                    if let error { continuation.resume(throwing: error); return }
                    guard let tempURL, let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        continuation.resume(throwing: UpdateError.badResponse); return
                    }
                    do {
                        try FileManager.default.moveItem(at: tempURL, to: destination)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                let observation = task.progress.observe(\.fractionCompleted) { p, _ in
                    let fraction = p.fractionCompleted
                    Task { @MainActor in progress.fraction = fraction }
                }
                progress.observation = observation
                downloadTask = task
                task.resume()
            }
        } onCancel: {
            Task { @MainActor in self.downloadTask?.cancel() }
        }
        downloadTask = nil
        progress.observation = nil
    }

    /// The asset's SHA-256: GitHub's `digest`, else the release's matching `.sha256` file.
    /// `nil` when the release carries neither (then only the bundle checks guard the install).
    private func expectedSHA256(for asset: Release.Asset, in release: Release) async throws -> String? {
        if let digest = asset.digest, digest.hasPrefix("sha256:") {
            return String(digest.dropFirst("sha256:".count)).lowercased()
        }
        guard let sumAsset = release.assets.first(where: { $0.name == asset.name + ".sha256" }) else { return nil }
        let (data, _) = try await URLSession.shared.data(from: sumAsset.browserDownloadURL)
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() }
    }

    nonisolated private static func verifySHA256(of file: URL, expected: String) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw UpdateError.checksumMismatch }
    }

    /// Mounts the image, copies its app into `workDir`, unmounts, and checks the copy: same bundle
    /// identifier as this app, and a valid code signature.
    nonisolated private static func stageApp(from dmg: URL, in workDir: URL, bundleID: String) throws -> URL {
        let mountPoint = workDir.appending(path: "mount", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path(percentEncoded: false), "-nobrowse", "-noautoopen",
                                     "-readonly", "-mountpoint", mountPoint.path(percentEncoded: false)])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint.path(percentEncoded: false), "-force"]) }

        let contents = try FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)
        guard let app = contents.first(where: { $0.pathExtension == "app" }),
              Bundle(url: app)?.bundleIdentifier == bundleID else { throw UpdateError.noAppInImage }

        let staged = workDir.appending(path: app.lastPathComponent, directoryHint: .isDirectory)
        try run("/usr/bin/ditto", [app.path(percentEncoded: false), staged.path(percentEncoded: false)])
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path(percentEncoded: false)])
        do {
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path(percentEncoded: false)])
        } catch {
            throw UpdateError.invalidSignature
        }
        return staged
    }

    /// Starts a detached script that waits for this process to quit, swaps the bundle and relaunches.
    /// The old bundle is set aside first and put back if the copy fails. It gives up (leaving the
    /// current app untouched) if the app hasn't quit within a minute.
    private static func launchSwapScript(staged: URL, destination: URL, workDir: URL) throws {
        let script = """
        PID="$1"; NEW="$2"; DEST="$3"; WORK="$4"; BACKUP="$DEST.updating-old"
        i=0
        while kill -0 "$PID" 2>/dev/null; do
          sleep 0.2; i=$((i+1)); [ "$i" -ge 300 ] && exit 1
        done
        rm -rf "$BACKUP"
        if mv "$DEST" "$BACKUP"; then
          if /usr/bin/ditto "$NEW" "$DEST"; then
            rm -rf "$BACKUP"
          else
            rm -rf "$DEST"; mv "$BACKUP" "$DEST"
          fi
        fi
        /usr/bin/open "$DEST"
        rm -rf "$WORK"
        """
        let scriptURL = workDir.appending(path: "install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [scriptURL.path(percentEncoded: false),
                             String(ProcessInfo.processInfo.processIdentifier),
                             staged.path(percentEncoded: false),
                             destination.path(percentEncoded: false),
                             workDir.path(percentEncoded: false)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.toolFailed(URL(filePath: tool).lastPathComponent) }
        return process.terminationStatus
    }

    // MARK: Progress window

    private func showProgress(_ progress: DownloadProgress) {
        let view = UpdateProgressView(progress: progress) { [weak self] in
            self?.downloadTask?.cancel()
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 110),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = String(localized: "Updating Simple Clipboard")
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        progressWindow = window
    }

    private func closeProgress() {
        progressWindow?.close()
        progressWindow = nil
    }
}

// MARK: - Errors

enum UpdateError: LocalizedError {
    case badResponse, noReleases, checksumMismatch, noAppInImage, invalidSignature
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .badResponse: String(localized: "GitHub didn’t return a valid response. Check your internet connection and try again.")
        case .noReleases: String(localized: "No published release was found.")
        case .checksumMismatch: String(localized: "The download is damaged (its checksum doesn’t match). Try again.")
        case .noAppInImage: String(localized: "The downloaded disk image doesn’t contain Simple Clipboard.")
        case .invalidSignature: String(localized: "The downloaded app’s code signature is invalid.")
        case .toolFailed(let tool): String(localized: "Installing the update failed (\(tool)).")
        }
    }
}

// MARK: - Progress UI

@MainActor @Observable
final class DownloadProgress {
    enum Phase { case downloading, verifying, restarting }
    let version: String
    var fraction: Double = 0
    var phase: Phase = .downloading
    @ObservationIgnored var observation: NSKeyValueObservation?

    init(version: String) { self.version = version }
}

private struct UpdateProgressView: View {
    let progress: DownloadProgress
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if progress.phase == .downloading {
                ProgressView(value: progress.fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .disabled(progress.phase != .downloading)
            }
        }
        .padding(18)
        .frame(width: 340)
    }

    private var title: String {
        switch progress.phase {
        case .downloading: String(localized: "Downloading Simple Clipboard \(progress.version)…")
        case .verifying: String(localized: "Verifying…")
        case .restarting: String(localized: "Restarting…")
        }
    }
}
