import AppKit
import ApplicationServices
import SwiftUI

// MARK: - Permissions

/// The two optional macOS privacy permissions: Accessibility, so the paste
/// shortcuts can press ⌘V, and Full Disk Access, so iPhone/iPad copies can be read
/// (`FullDiskAccess`). Copying and the panels work without either.
enum Permission: CaseIterable, Identifiable {
    case accessibility
    case fullDiskAccess

    var id: Self { self }

    var title: String {
        switch self {
        case .accessibility: String(localized: "Accessibility")
        case .fullDiskAccess: String(localized: "Full Disk Access")
        }
    }

    /// What the permission unlocks, shown under the title in `PermissionRow`.
    var purpose: String {
        switch self {
        case .accessibility: String(localized: "Lets the paste shortcuts press ⌘V for you.")
        case .fullDiskAccess: String(localized: "Lets your history keep photos and files copied on an iPhone or iPad.")
        }
    }

    var systemImage: String {
        switch self {
        case .accessibility: "accessibility"
        case .fullDiskAccess: "internaldrive.fill"
        }
    }

    var tint: Color {
        switch self {
        case .accessibility: .blue
        case .fullDiskAccess: .indigo
        }
    }

    /// Accessibility flips live; Full Disk Access only once the app reopens (`FullDiskAccess`).
    var isGranted: Bool {
        switch self {
        case .accessibility: AXIsProcessTrusted()
        case .fullDiskAccess: FullDiskAccess.isGranted
        }
    }

    /// The matching list in System Settings › Privacy & Security.
    var settingsURL: URL? {
        switch self {
        case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .fullDiskAccess: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        }
    }

    /// The service `tccutil` names the list by.
    fileprivate var tccService: String {
        switch self {
        case .accessibility: "Accessibility"
        case .fullDiskAccess: "SystemPolicyAllFiles"
        }
    }

    /// The guide's second line, under "Drag … to the list above".
    fileprivate var dropHint: String {
        switch self {
        case .accessibility: String(localized: "Dropping it there allows Accessibility.")
        case .fullDiskAccess: String(localized: "Dropping it there allows Full Disk Access.")
        }
    }

    fileprivate var grantedTitle: String {
        switch self {
        case .accessibility: String(localized: "Accessibility allowed")
        case .fullDiskAccess: String(localized: "Full Disk Access allowed")
        }
    }

    /// The success state's second line: what's left to do in System Settings.
    fileprivate var grantedHint: String {
        switch self {
        case .accessibility: String(localized: "You can close System Settings.")
        case .fullDiskAccess: String(localized: "Choose “Quit & Reopen” to finish.")
        }
    }

    /// Full Disk Access only takes effect once the app reopens, which System Settings offers
    /// right after the grant.
    fileprivate var appliesAfterRelaunch: Bool { self == .fullDiskAccess }
}

// MARK: - Stale list entries

extension Permission {
    /// The permissions whose list entry `removeStaleEntry` already cleared this launch.
    @MainActor private static var clearedThisLaunch: Set<Permission> = []

    /// Takes the app out of this permission's System Settings list while access isn't coming
    /// through, so the list never shows an old copy of it. The app is ad-hoc signed, so the entry
    /// only matches the build it was granted to: after a rebuild or an update (or when the
    /// /Applications copy holds it) it can stay switched on and still deny access. With it gone,
    /// the next grant goes to the running copy. At most once per permission each launch, because
    /// Full Disk Access reads as off until the app reopens and a grant made since must stay.
    /// `tccutil` may remove an app's entries without an admin password.
    @MainActor func removeStaleEntry() async {
        guard !isGranted, !Self.clearedThisLaunch.contains(self),
              let bundleID = Bundle.main.bundleIdentifier else { return }
        Self.clearedThisLaunch.insert(self)
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/tccutil")
            process.arguments = ["reset", tccService, bundleID]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { continuation.resume() }
        }
    }
}

// MARK: - Drag-to-allow guide

/// The floating "drag the app into the list" helper every Allow button opens alongside System
/// Settings. There's no API to grant either permission, and Full Disk Access
/// doesn't even list the app until it's added, but both lists accept an app dropped onto them —
/// so the panel offers our own bundle as a drag source, parked just outside the System Settings
/// window (below it, else beside or above it). It follows that window, shows only while System
/// Settings is frontmost, and goes away once the permission comes through, System Settings closes,
/// or the user clicks ✕.
@MainActor
final class PermissionGuide {
    static let shared = PermissionGuide()

    private let state = PermissionGuideState()
    private var panel: NSPanel?
    /// The window-following loop while the guide is up, then the short success hold.
    private var tracker: Task<Void, Never>?
    /// Our window the user started from (intro tour, Settings), brought back after a grant.
    private weak var returnWindow: NSWindow?
    /// The guide's size in each placement, for the current permission (`size(for:)`).
    private var sizes: [GuidePlacement: CGSize] = [:]

    private static let settingsBundleID = "com.apple.systempreferences"
    /// Roughly System Settings' sidebar width, so the guide centers on the pane holding the list.
    private static let sidebarWidth: CGFloat = 230
    private static let gap: CGFloat = 12

    private init() {}

    /// Opens the permission's System Settings list, cleared of any old copy of the app first
    /// (`Permission.removeStaleEntry`), and shows the guide under it. Calling it again while the
    /// guide is up just retargets it.
    func show(_ permission: Permission) {
        Task {
            await permission.removeStaleEntry()
            if let url = permission.settingsURL { NSWorkspace.shared.open(url) }
        }
        returnWindow = NSApp.keyWindow
        state.permission = permission
        state.granted = false
        sizes = [:]

        if panel == nil {
            let panel = makePanel()
            // Stays hidden until System Settings' window shows up to park under.
            panel.alphaValue = 0
            self.panel = panel
        }
        track(permission)
    }

    func dismiss() {
        tracker?.cancel()
        tracker = nil
        guard let panel else { return }
        self.panel = nil
        panel.animator().alphaValue = 0
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            panel.orderOut(nil)
        }
    }

    /// Polls System Settings' window (there's no notification for another app's window moving)
    /// and the permission. Gives System Settings 15 s to open, and treats its window being gone
    /// for over a second afterwards as closed.
    private func track(_ permission: Permission) {
        tracker?.cancel()
        tracker = Task {
            let clock = ContinuousClock()
            var lastSeen: ContinuousClock.Instant?
            let opened = clock.now
            var tick = 0
            while !Task.isCancelled {
                if tick % 10 == 0, permission.isGranted {
                    finish()
                    return
                }
                if let frame = Self.settingsWindowFrame() {
                    lastSeen = clock.now
                    place(outside: frame)
                    setVisible(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.settingsBundleID)
                } else {
                    setVisible(false)
                    let gone = lastSeen.map { clock.now - $0 > .seconds(1) } ?? (clock.now - opened > .seconds(15))
                    if gone {
                        dismiss()
                        return
                    }
                }
                tick += 1
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Flips the guide to its success state, holds it briefly, then returns the user to the window
    /// they came from — except after Full Disk Access, where System Settings is asking to reopen
    /// the app and must stay in front.
    private func finish() {
        state.granted = true
        let returnsToWindow = !state.permission.appliesAfterRelaunch
        tracker = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            dismiss()
            if returnsToWindow, let returnWindow, returnWindow.isVisible {
                NSApp.activate(ignoringOtherApps: true)
                returnWindow.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func setVisible(_ visible: Bool) {
        guard let panel else { return }
        if visible, !panel.isVisible || panel.alphaValue < 1 {
            panel.orderFrontRegardless()
            panel.animator().alphaValue = 1
        } else if !visible, panel.isVisible {
            panel.orderOut(nil)
        }
    }

    /// Parks the guide just outside System Settings' window: below it if there's room on screen,
    /// else beside or above it. When the window leaves no room anywhere, it takes the spot that
    /// covers the window least.
    private func place(outside cgFrame: CGRect) {
        guard let panel, let primary = NSScreen.screens.first else { return }
        // CoreGraphics window bounds are top-left based on the primary display; AppKit's are bottom-left.
        let window = CGRect(x: cgFrame.minX, y: primary.frame.maxY - cgFrame.maxY,
                            width: cgFrame.width, height: cgFrame.height)
        let screen = (NSScreen.screens.first { $0.frame.intersects(window) } ?? primary).visibleFrame
        let visible = screen.insetBy(dx: Self.gap, dy: Self.gap)

        let candidates = GuidePlacement.allCases.map { ($0, frame(for: $0, outside: window, within: visible)) }
        let fitting = candidates.first { visible.contains($0.1) && !$0.1.intersects(window) }
        let fallback = candidates
            .map { ($0.0, Self.clamp($0.1, into: visible)) }
            .min { $0.1.intersection(window).area < $1.1.intersection(window).area }
        guard let (placement, frame) = fitting ?? fallback else { return }

        if state.placement != placement { state.placement = placement }
        let rounded = CGRect(x: frame.minX.rounded(), y: frame.minY.rounded(), width: frame.width, height: frame.height)
        if panel.frame != rounded { panel.setFrame(rounded, display: true) }
    }

    /// Where the guide goes in `placement`: against that side of the window, slid along it to stay
    /// on screen (but never across it — the fit check above decides that).
    private func frame(for placement: GuidePlacement, outside window: CGRect, within visible: CGRect) -> CGRect {
        let size = size(for: placement)
        var origin: CGPoint
        switch placement {
        case .below, .above:
            // Centered on the detail pane, where the list is.
            let paneMinX = window.minX + min(Self.sidebarWidth, window.width / 3)
            origin = CGPoint(x: (paneMinX + window.maxX - size.width) / 2,
                             y: placement == .below ? window.minY - Self.gap - size.height : window.maxY + Self.gap)
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        case .right, .left:
            origin = CGPoint(x: placement == .right ? window.maxX + Self.gap : window.minX - Self.gap - size.width,
                             y: window.midY - size.height / 2)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        return CGRect(origin: origin, size: size)
    }

    private static func clamp(_ frame: CGRect, into visible: CGRect) -> CGRect {
        var frame = frame
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        return frame
    }

    /// The guide's size laid out for `placement` (the beside placements use a narrower, stacked
    /// layout), measured off screen once per permission.
    private func size(for placement: GuidePlacement) -> CGSize {
        if let size = sizes[placement] { return size }
        let probe = PermissionGuideState()
        probe.permission = state.permission
        probe.placement = placement
        let size = NSHostingView(rootView: PermissionGuideView(state: probe, onClose: {})).fittingSize
        sizes[placement] = size
        return size
    }

    /// System Settings' main window in CoreGraphics coordinates, or nil while it isn't on screen.
    /// Bounds and owners of other apps' windows need no Screen Recording permission.
    private static func settingsWindowFrame() -> CGRect? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID).first?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        // The largest normal-level window: its sheets and the authentication prompt are smaller.
        return windows
            .filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } }
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // System Settings, not us, is the active app the whole time the guide is up.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // The icon's hover effect follows the pointer.
        panel.acceptsMouseMovedEvents = true
        let host = FirstMouseHostingView(rootView: PermissionGuideView(state: state) { [weak self] in
            self?.dismiss()
        })
        panel.contentView = host
        return panel
    }
}

@MainActor
@Observable
private final class PermissionGuideState {
    var permission: Permission = .accessibility
    var placement: GuidePlacement = .below
    var granted = false
}

/// Where the guide sits relative to System Settings' window, in order of preference. The arrow
/// and wording point back at the window.
private enum GuidePlacement: CaseIterable {
    case below, right, left, above

    /// Beside the window there's rarely room for the wide layout, so the guide stacks up instead.
    var isBeside: Bool { self == .right || self == .left }

    var title: LocalizedStringKey {
        switch self {
        case .below: "Drag \(appDisplayName) to the list above"
        case .right: "Drag \(appDisplayName) to the list on the left"
        case .left: "Drag \(appDisplayName) to the list on the right"
        case .above: "Drag \(appDisplayName) to the list below"
        }
    }

    var arrowSymbol: String {
        switch self {
        case .below: "arrow.up"
        case .right: "arrow.left"
        case .left: "arrow.right"
        case .above: "arrow.down"
        }
    }

    /// How far the arrow bobs toward the window.
    var nudge: CGSize {
        switch self {
        case .below: CGSize(width: 0, height: -5)
        case .right: CGSize(width: -5, height: 0)
        case .left: CGSize(width: 5, height: 0)
        case .above: CGSize(width: 0, height: 5)
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

/// The guide never becomes key (that would activate us over System Settings), so its clicks
/// arrive as first mouse in an inactive window — accept them instead of swallowing them.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Guide content

/// Below or above the window: app icon to drag · "Drag Simple Clipboard to the list above ↑" · ✕.
/// Beside it: the same pieces stacked, with the arrow on the side facing the window. The text
/// swaps for a checkmark once access comes through; both share one frame so the size holds.
private struct PermissionGuideView: View {
    let state: PermissionGuideState
    let onClose: () -> Void

    var body: some View {
        Group {
            if state.placement.isBeside {
                HStack(spacing: 14) {
                    if state.placement == .right { BobbingArrow(placement: state.placement, font: .title.weight(.bold)) }
                    VStack(spacing: 12) {
                        DraggableAppIcon()
                        message(centered: true)
                            .frame(width: 210)
                    }
                    if state.placement == .left { BobbingArrow(placement: state.placement, font: .title.weight(.bold)) }
                }
                .padding(.horizontal, 22)
                .padding(.top, 22)
                .padding(.bottom, 20)
                .overlay(alignment: .topTrailing) { closeButton.padding(10) }
            } else {
                HStack(spacing: 18) {
                    DraggableAppIcon()
                    message(centered: false)
                    Spacer(minLength: 8)
                    closeButton
                }
                .padding(.leading, 18)
                .padding(.trailing, 20)
                .padding(.vertical, 16)
            }
        }
        .fixedSize()
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }

    private func message(centered: Bool) -> some View {
        let alignment: HorizontalAlignment = centered ? .center : .leading
        let textAlignment: TextAlignment = centered ? .center : .leading
        return ZStack(alignment: Alignment(horizontal: alignment, vertical: .center)) {
            VStack(alignment: alignment, spacing: 4) {
                if centered {
                    Text(state.placement.title)
                        .font(.title3.bold())
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(state.placement.title)
                            .font(.title3.bold())
                        BobbingArrow(placement: state.placement, font: .title3.weight(.bold))
                    }
                }
                Text(state.permission.dropHint)
                    .foregroundStyle(.secondary)
            }
            .opacity(state.granted ? 0 : 1)

            VStack(alignment: alignment, spacing: 4) {
                Label(state.permission.grantedTitle, systemImage: "checkmark.circle.fill")
                    .font(.title3.bold())
                    .foregroundStyle(.green)
                Text(state.permission.grantedHint)
                    .foregroundStyle(.secondary)
            }
            .opacity(state.granted ? 1 : 0)
            .scaleEffect(state.granted ? 1 : 0.9, anchor: centered ? .center : .leading)
        }
        .multilineTextAlignment(textAlignment)
        .fixedSize(horizontal: !centered, vertical: true)
        .animation(.spring(duration: 0.4, bounce: 0.3), value: state.granted)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(.quaternary, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}

/// The name System Settings lists the app under.
private var appDisplayName: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Simple Clipboard"
}

/// The arrow toward System Settings' list, bobbing toward it for as long as the guide is up.
private struct BobbingArrow: View {
    let placement: GuidePlacement
    let font: Font
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: placement.arrowSymbol)
            .font(font)
            .foregroundStyle(.tint)
            .phaseAnimator(reduceMotion ? [false] : [false, true]) { arrow, nudged in
                arrow.offset(nudged ? placement.nudge : CGSize(width: -placement.nudge.width / 5, height: -placement.nudge.height / 5))
            } animation: { _ in
                .easeInOut(duration: 0.55)
            }
    }
}

/// The app icon and name — the drag source. Hovering lifts the icon and tilts it under the
/// pointer, with a soft highlight that follows it (no tilt with Reduce Motion); while it's being
/// dragged the original dims.
private struct DraggableAppIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the pointer is over the icon (unit coordinates, top-left origin) while hovering it.
    @State private var pointer: UnitPoint?
    @State private var dragging = false

    private var lifted: Bool { pointer != nil && !dragging }

    /// −1…1 per axis from the icon's center; the side under the pointer tips away from the viewer.
    private var tilt: CGSize {
        guard let pointer, lifted, !reduceMotion else { return .zero }
        return CGSize(width: (pointer.x - 0.5) * 2, height: (pointer.y - 0.5) * 2)
    }

    var body: some View {
        let icon = NSApp.applicationIconImage ?? NSImage()
        VStack(spacing: 5) {
            Image(nsImage: icon)
                .resizable()
                .overlay {
                    RadialGradient(colors: [.white.opacity(0.45), .white.opacity(0)],
                                   center: pointer ?? .center, startRadius: 0, endRadius: 36)
                        .blendMode(.plusLighter)
                        .mask(Image(nsImage: icon).resizable())
                        .opacity(lifted ? 1 : 0)
                }
                .frame(width: 54, height: 54)
                .rotation3DEffect(.degrees(tilt.width * 14), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                .rotation3DEffect(.degrees(-tilt.height * 14), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
                .scaleEffect(lifted ? 1.1 : 1)
                .shadow(color: .black.opacity(lifted ? 0.3 : 0.12), radius: lifted ? 10 : 3, y: lifted ? 7 : 2)
                .opacity(dragging ? 0.4 : 1)
                // After the effects, so the AppKit view keeps the icon's plain, untransformed frame.
                .overlay {
                    AppDragSource { pointer = $0 } onDrag: { dragging = $0 }
                        .padding(-6)
                }
            Text(appDisplayName)
                .font(.system(size: 11, weight: .semibold))
                .fixedSize()
        }
        .animation(.spring(duration: 0.35, bounce: 0.3), value: pointer)
        .animation(.easeOut(duration: 0.15), value: dragging)
    }
}

/// AppKit drag source over the icon: hands the drag our own bundle URL, exactly as Finder would.
/// Its hover tracking runs in AppKit too, since SwiftUI's doesn't fire while another app is active.
private struct AppDragSource: NSViewRepresentable {
    /// The pointer's position in unit coordinates (top-left origin) while over the icon, else nil.
    let onHover: (UnitPoint?) -> Void
    let onDrag: (Bool) -> Void

    func makeNSView(context: Context) -> AppDragSourceView {
        AppDragSourceView()
    }

    func updateNSView(_ view: AppDragSourceView, context: Context) {
        view.onHover = onHover
        view.onDrag = onDrag
    }
}

private final class AppDragSourceView: NSView, NSDraggingSource {
    var onHover: ((UnitPoint?) -> Void)?
    var onDrag: ((Bool) -> Void)?
    private var pressEvent: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(unitPoint(of: event.locationInWindow)) }
    override func mouseMoved(with event: NSEvent) { onHover?(unitPoint(of: event.locationInWindow)) }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }

    /// A window point in unit coordinates of this view, flipped to SwiftUI's top-left origin.
    private func unitPoint(of windowPoint: NSPoint) -> UnitPoint? {
        let point = convert(windowPoint, from: nil)
        guard bounds.contains(point), bounds.width > 0, bounds.height > 0 else { return nil }
        let y = point.y / bounds.height
        return UnitPoint(x: point.x / bounds.width, y: isFlipped ? y : 1 - y)
    }

    override func mouseDown(with event: NSEvent) { pressEvent = event }

    override func mouseDragged(with event: NSEvent) {
        guard let pressEvent else { return }
        self.pressEvent = nil
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        let point = convert(pressEvent.locationInWindow, from: nil)
        let side: CGFloat = 64
        item.setDraggingFrame(NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side),
                              contents: NSApp.applicationIconImage)
        beginDraggingSession(with: [item], event: pressEvent, source: self)
        onDrag?(true)
    }

    override func mouseUp(with event: NSEvent) { pressEvent = nil }

    /// Copy only: dropped on Finder by mistake, that copies the app rather than moving the running one.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDrag?(false)
        // Enter/exit events don't arrive mid-drag, so re-check where the pointer ended up.
        if let window {
            onHover?(unitPoint(of: window.mouseLocationOutsideOfEventStream))
        }
    }
}
