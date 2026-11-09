import SwiftUI

// MARK: - Key cap

/// A small keyboard key cap used across the tutorial (shortcut hints + animated demos);
/// `pressed` renders the accent "held down" state.
struct KeyCap: View {
    private let label: String
    private let size: CGFloat
    private let pressed: Bool

    init(_ label: String, size: CGFloat = 30, pressed: Bool = false) {
        self.label = label
        self.size = size
        self.pressed = pressed
    }

    var body: some View {
        Text(label)
            .font(.system(size: size * 0.48, weight: .medium, design: .rounded))
            .foregroundStyle(pressed ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 7)
            .frame(minWidth: size)
            .frame(height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.25)
                    .fill(pressed ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.25)
                    .strokeBorder(.quaternary)
            )
            .offset(y: pressed ? 1.5 : 0)
    }
}

// MARK: - Option-click demo (§12)

/// Looping animation for the Option-click plain-text invert (CLAUDE.md §12/§16), staged like the
/// ⌘S demo's mock panel: the cursor hovers a rich-text row, ⌥ goes down and the panel's real
/// "Copy as plain text" hint strip (§12) slides in over the footer, the row is clicked, and the
/// text is then pasted into a mock document with its formatting stripped.
struct OptionClickDemo: View {
    /// 0 idle → 1 cursor hovers the rich row → 2 ⌥ pressed (hint strip in) → 3 click →
    /// 4 ⌘V appears at rest (gray) → 5 ⌘V presses (blue) → 6 pasted plain into the document →
    /// back to 0. Advanced by the `.task` loop below.
    @State private var phase = 0

    private var rowHovered: Bool { (1...6).contains(phase) }
    private var optionHeld: Bool { phase == 2 || phase == 3 }
    private var rowClicked: Bool { phase == 3 }
    /// ⌘V caps appear gray first, press blue, then release as the text lands.
    private var pasteKeysShown: Bool { (4...6).contains(phase) }
    private var pasteKeysPressed: Bool { phase == 5 }
    private var pasted: Bool { phase == 6 }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                mockPanel
                cursor
            }
            pasteDocument
            gestureCaption
        }
        .task { await runLoop() }
    }

    private var mockPanel: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                Text("Search")
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(.quinary))
            .padding(.bottom, 4)

            row(icon: "link", text: Text("apple.com/keynote"), hovered: false)
            row(icon: "doc.richtext", text: formattedSample, hovered: rowHovered)
            row(icon: "text.alignleft", text: Text("Standup moved to 9:30"), hovered: false)

            Divider()
                .padding(.top, 4)
            HStack {
                Text("Clear History")
                Spacer(minLength: 0)
                Text("Main Window")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.top, 5)
        }
        .padding(10)
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 14).fill(.quinary))
        // The ⌥ hint slides in over the footer, then the whole panel clips to its shape so the
        // strip's slide-from-bottom edge never pokes past the rounded corners.
        .overlay(alignment: .bottom) { optionHint }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
    }

    private func row(icon: String, text: Text, hovered: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            text
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovered ? AnyShapeStyle(Color.accentColor.opacity(rowClicked ? 0.3 : 0.16)) : AnyShapeStyle(.clear))
        )
        .scaleEffect(hovered && rowClicked ? 0.98 : 1)
    }

    /// The panel's real ⌥ hint strip (`PanelOptionHint`, §12), recreated for the mock panel.
    private var optionHint: some View {
        ZStack {
            if optionHeld {
                HStack(spacing: 6) {
                    Image(systemName: "option")
                    Text("Copy as plain text")
                    Spacer(minLength: 0)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.tint)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.tint.opacity(0.12))
                .background(.background)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var cursor: some View {
        Image(systemName: "cursorarrow")
            .font(.system(size: 20))
            .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            .offset(x: rowHovered ? 78 : 170, y: rowHovered ? 8 : 95)
            .scaleEffect(rowClicked ? 0.82 : 1, anchor: .topLeading)
    }

    /// Where the copied text lands: a mock document that receives the paste — the bold, colored
    /// row content arrives as plain text. Fixed-height label slot so the layout never jumps.
    private var pasteDocument: some View {
        VStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 7) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: 150, height: 7)
                HStack(spacing: 3) {
                    if pasted {
                        plainSample
                            .font(.callout)
                            .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
                    }
                    // Insertion point — sits at the line start, then trails the pasted text.
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.tint)
                        .frame(width: 2, height: 15)
                }
                .frame(height: 16)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(width: 320, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))

            ZStack {
                if pasted {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Pasted as plain text")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                }
            }
            .frame(height: 16)
        }
    }

    /// The gesture being demonstrated, tracking the loop: hold ⌥ and click, then ⌘V (rendered
    /// "held down" while pressing, like the ⌘S demo's caps) pastes plain.
    private var gestureCaption: some View {
        HStack(spacing: 6) {
            if pasteKeysShown {
                KeyCap("⌘", size: 26, pressed: pasteKeysPressed)
                KeyCap("V", size: 26, pressed: pasteKeysPressed)
                Text("pastes it without formatting")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                KeyCap("⌥", size: 26, pressed: optionHeld)
                Text("+")
                    .foregroundStyle(.secondary)
                Image(systemName: "cursorarrow.click")
                    .foregroundStyle(.secondary)
                Text("copies as plain text")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 28)
    }

    private var formattedSample: Text {
        Text("Launch is \(Text("confirmed").bold().foregroundStyle(.orange)) 🚀")
    }

    private var plainSample: Text {
        Text("Launch is confirmed 🚀")
    }

    private func runLoop() async {
        let steps: [(next: Int, delay: Double)] = [
            (1, 1.0),   // cursor moves onto the rich-text row
            (2, 0.9),   // ⌥ goes down — hint strip slides in
            (3, 1.6),   // click while ⌥ held
            (4, 0.9),   // ⌘V caps appear, at rest
            (5, 0.8),   // …press down (blue)
            (6, 0.5),   // …and the text pastes plain into the document
            (0, 2.6),   // reset
        ]
        while !Task.isCancelled {
            for step in steps {
                try? await Task.sleep(for: .seconds(step.delay))
                if Task.isCancelled { return }
                withAnimation(.spring(duration: 0.4)) { phase = step.next }
            }
        }
    }
}

// MARK: - ⌘S save-as-snippet demo (§9)

/// Looping animation for the panel's ⌘S gesture (CLAUDE.md §9/§16): the cursor hovers a row
/// in a mock history panel, ⌘S presses, and the "Save as Snippet" card pops over it.
struct SaveSnippetDemo: View {
    /// 0 idle → 1 hover the middle row → 2 ⌘S pressed → 3 saved card shown → back to 0.
    @State private var phase = 0

    private var rowHovered: Bool { phase >= 1 }
    private var keysPressed: Bool { phase == 2 }

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                mockPanel
                if phase == 3 {
                    savedCard
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
                cursor
            }
            keysCaption
        }
        .task { await runLoop() }
    }

    private var mockPanel: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                Text("Search")
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(.quinary))
            .padding(.bottom, 4)

            row(icon: "link", text: "apple.com/keynote", hovered: false)
            row(icon: "text.alignleft", text: String(localized: "Standup moved to 9:30 tomorrow"), hovered: rowHovered)
            row(icon: "chevron.left.forwardslash.chevron.right", text: "let total = items.reduce(0, +)", hovered: false)

            Divider()
                .padding(.top, 4)
            HStack {
                Text("Clear History")
                Spacer(minLength: 0)
                Text("Main Window")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.top, 5)
        }
        .padding(10)
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 14).fill(.quinary))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
    }

    private func row(icon: String, text: String, hovered: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(text)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovered ? AnyShapeStyle(Color.accentColor.opacity(0.16)) : AnyShapeStyle(.clear))
        )
    }

    private var savedCard: some View {
        VStack(spacing: 6) {
            Image(systemName: "bookmark.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("Saved as Snippet")
                .font(.headline)
            Text("Pick a title and folder")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }

    private var cursor: some View {
        Image(systemName: "cursorarrow")
            .font(.system(size: 20))
            .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            .offset(x: rowHovered ? 70 : 170, y: rowHovered ? 12 : 90)
    }

    private var keysCaption: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                KeyCap("⌘", size: 28, pressed: keysPressed)
                KeyCap("S", size: 28, pressed: keysPressed)
            }
            Text("while hovering an item")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func runLoop() async {
        let steps: [(next: Int, delay: Double)] = [
            (1, 1.2),   // cursor moves onto the row
            (2, 1.0),   // ⌘S goes down
            (3, 0.6),   // save card pops
            (0, 2.4),   // reset
        ]
        while !Task.isCancelled {
            for step in steps {
                try? await Task.sleep(for: .seconds(step.delay))
                if Task.isCancelled { return }
                withAnimation(.spring(duration: 0.4)) { phase = step.next }
            }
        }
    }
}

// MARK: - Wrap-up menu-bar demo (§16)

/// Looping animation for the wrap-up page (CLAUDE.md §16): the Simple Clipboard icon pops
/// into a mock menu bar with a little sparkle burst, then ⌘⇧V presses and the floating
/// clipboard panel (§9) pops in beneath it — where the app lives, and how to summon it.
/// No cursor; the page's once-only check pop above the title carries the "done" beat.
struct WrapUpDemo: View {
    /// 0 idle (bare menu bar) → 1 icon pops in (+ sparkles) → 2 settled (sparkles fade,
    /// icon stays) → 3 ⌘⇧V presses → 4 panel pops in (keys release) → back to 0.
    /// Advanced by the `.task` loop below.
    @State private var phase = 0

    private var iconShown: Bool { phase >= 1 }
    private var sparkling: Bool { phase == 1 }
    private var keysPressed: Bool { phase == 3 }
    private var panelShown: Bool { phase == 4 }

    var body: some View {
        VStack(spacing: 14) {
            menuBar
            keysCaption
            // Fixed slot the panel pops into, so the bar and key caps never move.
            ZStack {
                if panelShown {
                    mockPanel
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .frame(width: 320, height: 172)
        }
        .task { await runLoop() }
    }

    private var menuBar: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 0)
            statusIcon
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text("Tue 9:41")
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(width: 320, height: 28)
        .background(RoundedRectangle(cornerRadius: 9).fill(.quinary))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary))
    }

    /// Our status item. Hidden at scale ~0 (keeping its layout slot so the bar never jumps),
    /// it pops in on phase 1.
    private var statusIcon: some View {
        Image(systemName: "doc.on.clipboard.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 24, height: 22)
            .scaleEffect(iconShown ? 1 : 0.1)
            .opacity(iconShown ? 1 : 0)
            .overlay { sparkles }
    }

    /// A brief burst around the icon as it lands in the bar.
    private var sparkles: some View {
        ZStack {
            if sparkling {
                sparkle(size: 9, x: -14, y: -9)
                sparkle(size: 6, x: 15, y: -6)
                sparkle(size: 7, x: -9, y: 13)
            }
        }
        .allowsHitTesting(false)
    }

    private func sparkle(size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Image(systemName: "sparkle")
            .font(.system(size: size))
            .foregroundStyle(.tint)
            .offset(x: x, y: y)
            .transition(.scale(scale: 0.2).combined(with: .opacity))
    }

    /// The floating clipboard panel (§9) — the same mock the gesture demos use, with a soft
    /// shadow since this one *arrives* and should read as floating over everything.
    private var mockPanel: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                Text("Search")
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(.quinary))
            .padding(.bottom, 4)

            panelRow(icon: "text.alignleft", text: String(localized: "Standup moved to 9:30 tomorrow"))
            panelRow(icon: "link", text: "apple.com/keynote")
            panelRow(icon: "chevron.left.forwardslash.chevron.right", text: "let total = items.reduce(0, +)")

            Divider()
                .padding(.top, 4)
            HStack {
                Text("Clear History")
                Spacer(minLength: 0)
                Text("Main Window")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.top, 5)
        }
        .padding(10)
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 14).fill(.quinary))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
    }

    private func panelRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(text)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    private var keysCaption: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                KeyCap("⌘", size: 26, pressed: keysPressed)
                KeyCap("⇧", size: 26, pressed: keysPressed)
                KeyCap("V", size: 26, pressed: keysPressed)
            }
            Text("opens your clipboard history")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func runLoop() async {
        let steps: [(next: Int, delay: Double)] = [
            (1, 1.0),   // the icon lands in the menu bar
            (2, 1.4),   // sparkles fade, the icon stays put
            (3, 1.2),   // ⌘⇧V goes down
            (4, 0.5),   // …and the panel pops in, keys release
            (0, 3.2),   // reset
        ]
        while !Task.isCancelled {
            for step in steps {
                try? await Task.sleep(for: .seconds(step.delay))
                if Task.isCancelled { return }
                withAnimation(.spring(duration: 0.4)) { phase = step.next }
            }
        }
    }
}
