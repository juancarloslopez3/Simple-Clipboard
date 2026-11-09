import SwiftUI

// MARK: - Key cap

/// A small keyboard key cap used across the tutorial (shortcut hints + animated demos);
/// `pressed` renders the accent "held down" state. `minWidth` stretches a cap past its square
/// default, for the space bar.
struct KeyCap: View {
    private let label: String
    private let size: CGFloat
    private let pressed: Bool
    private let minWidth: CGFloat?

    init(_ label: String, size: CGFloat = 30, pressed: Bool = false, minWidth: CGFloat? = nil) {
        self.label = label
        self.size = size
        self.pressed = pressed
        self.minWidth = minWidth
    }

    var body: some View {
        Text(label)
            .font(.system(size: size * 0.48, weight: .medium, design: .rounded))
            .foregroundStyle(pressed ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 7)
            .frame(minWidth: minWidth ?? size)
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

// MARK: - Mock panel

/// The floating clipboard panel as the demos draw it: the search field, the caller's rows and
/// the footer, on the panel's rounded backing. Each demo adds its own overlays, border and shadow.
struct MockPanel<Rows: View>: View {
    private let rows: Rows

    init(@ViewBuilder rows: () -> Rows) {
        self.rows = rows()
    }

    var body: some View {
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

            rows

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
    }
}

/// One history row in `MockPanel`: the type glyph and a line of content, on an accent wash at
/// `highlight` opacity while it's hovered, clicked or selected (0 for none).
struct MockPanelRow: View {
    let icon: String
    let text: Text
    var highlight: Double = 0

    var body: some View {
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
                .fill(highlight > 0 ? AnyShapeStyle(Color.accentColor.opacity(highlight)) : AnyShapeStyle(.clear))
        )
    }
}

// MARK: - Space preview demo

/// Looping animation for the panel's Space preview: the cursor hovers a copied Word
/// document, a tap of Space pops the Quick Look card over the panel with the document's page in
/// it, and a second tap closes it again.
struct SpacePreviewDemo: View {
    /// 0 idle → 1 cursor hovers the document row → 2 Space down, the preview pops in →
    /// 3 Space up (a tap, so it stays open) → 4 Space down again, the preview closes →
    /// 5 Space up → back to 0. Advanced by the `.task` loop below.
    @State private var phase = 0

    private var rowHovered: Bool { phase >= 1 }
    private var spacePressed: Bool { phase == 2 || phase == 4 }
    private var previewShown: Bool { phase == 2 || phase == 3 }

    private static let fileName = String(localized: "Q3 Report.docx")

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                mockPanel
                cursor
            }
            keysCaption
        }
        .task { await runLoop() }
    }

    private var mockPanel: some View {
        MockPanel {
            MockPanelRow(icon: "link", text: Text(verbatim: "apple.com/keynote"))
            MockPanelRow(icon: "doc", text: Text(Self.fileName), highlight: rowHovered ? 0.16 : 0)
            MockPanelRow(icon: "text.alignleft", text: Text("Standup moved to 9:30 tomorrow"))
            MockPanelRow(icon: "chevron.left.forwardslash.chevron.right", text: Text(verbatim: "let total = items.reduce(0, +)"))
        }
        // The preview covers the panel like the real one (`ClipboardPreviewOverlay`); the clip
        // keeps the dimmed backdrop inside the rounded corners.
        .overlay { previewOverlay }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
    }

    private var previewOverlay: some View {
        ZStack {
            if previewShown {
                Rectangle()
                    .fill(.black.opacity(0.18))
                    .transition(.opacity)
                previewCard
                    .padding(8)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
    }

    /// The Quick Look card (`ClipboardPreviewCard`) in miniature: ⓧ · icon · name and type,
    /// over the document's first page.
    private var previewCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 0) {
                    Text(Self.fileName)
                        .font(.caption.weight(.semibold))
                    Text("Word document")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            documentPage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }

    /// The document's first page as the preview renders it: a headline, body text and a chart. White
    /// in dark mode too, like a real page.
    private var documentPage: some View {
        VStack(alignment: .leading, spacing: 5) {
            Capsule()
                .fill(.black.opacity(0.75))
                .frame(width: 56, height: 5)
                .padding(.bottom, 2)
            textLine(78)
            textLine(72)
            textLine(76)
            textLine(44)
            HStack(alignment: .bottom, spacing: 6) {
                chartBar(12, .blue.opacity(0.45))
                chartBar(20, .blue.opacity(0.6))
                chartBar(16, .blue.opacity(0.45))
                chartBar(28, .orange)
            }
            .padding(.vertical, 5)
            textLine(74)
            textLine(60)
        }
        .padding(11)
        .frame(width: 104, height: 134, alignment: .topLeading)
        .background(.white, in: .rect(cornerRadius: 2))
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
    }

    private func textLine(_ width: CGFloat) -> some View {
        Capsule()
            .fill(.black.opacity(0.2))
            .frame(width: width, height: 3)
    }

    private func chartBar(_ height: CGFloat, _ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(color)
            .frame(width: 12, height: height)
    }

    private var cursor: some View {
        Image(systemName: "cursorarrow")
            .font(.system(size: 20))
            .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            .offset(x: rowHovered ? 66 : 170, y: rowHovered ? -12 : 110)
    }

    private var keysCaption: some View {
        HStack(spacing: 8) {
            KeyCap(String(localized: "space"), size: 28, pressed: spacePressed, minWidth: 96)
            Text("while hovering an item")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func runLoop() async {
        let steps: [(next: Int, delay: Double)] = [
            (1, 1.0),   // cursor moves onto the document row
            (2, 1.0),   // Space goes down — the preview pops in
            (3, 0.25),  // …and comes straight back up: a tap, so the preview stays
            (4, 2.6),   // Space again — the preview closes
            (5, 0.25),  // …key up
            (0, 1.4),   // reset
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

// MARK: - Option-click demo

/// Looping animation for the Option-click plain-text invert, staged like the
/// ⌘S demo's mock panel: the cursor hovers a rich-text row, ⌥ goes down and the panel's real
/// "Copy as plain text" hint strip slides in over the footer, the row is clicked, and the
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
        MockPanel {
            MockPanelRow(icon: "link", text: Text("apple.com/keynote"))
            MockPanelRow(icon: "doc.richtext", text: formattedSample,
                         highlight: rowHovered ? (rowClicked ? 0.3 : 0.16) : 0)
                .scaleEffect(rowHovered && rowClicked ? 0.98 : 1)
            MockPanelRow(icon: "text.alignleft", text: Text("Standup moved to 9:30"))
        }
        // The ⌥ hint slides in over the footer, then the whole panel clips to its shape so the
        // strip's slide-from-bottom edge never pokes past the rounded corners.
        .overlay(alignment: .bottom) { optionHint }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
    }

    /// The panel's real ⌥ hint strip (`PanelOptionHint`), recreated for the mock panel.
    private var optionHint: some View {
        ZStack {
            if optionHeld {
                HStack(spacing: 6) {
                    Image(systemName: "option")
                    Text("Copy as plain text")
                    Spacer(minLength: 0)
                }
                .modifier(HintStripStyle())
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

// MARK: - ⌘-click multi-select demo

/// Looping animation for the panel's ⌘-click multi-select: ⌘ goes down and the
/// panel's real ⌘ hint strip (`PanelSelectionHint`) slides in, two rows are clicked — the lower one
/// first — and releasing ⌘ copies both, so ⌘V pastes them into a mock document in pick order.
struct MultiSelectDemo: View {
    /// 0 idle → 1 ⌘ down (hint strip in) → 2 cursor onto the middle row → 3 click it →
    /// 4 cursor onto the top row → 5 click it → 6 ⌘ released (both copied, the selection clears) →
    /// 7 ⌘V appears at rest → 8 ⌘V presses → 9 both pasted, in pick order → back to 0.
    /// Advanced by the `.task` loop below.
    @State private var phase = 0

    private var commandHeld: Bool { (1...5).contains(phase) }
    /// Picked first: the middle row.
    private var standupSelected: Bool { (3...5).contains(phase) }
    /// Picked second: the top row.
    private var linkSelected: Bool { phase == 5 }
    private var selectedCount: Int { (standupSelected ? 1 : 0) + (linkSelected ? 1 : 0) }
    private var pasteKeysShown: Bool { (7...9).contains(phase) }
    private var pasteKeysPressed: Bool { phase == 8 }
    private var pasted: Bool { phase == 9 }

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
        MockPanel {
            MockPanelRow(icon: "link", text: Text(verbatim: "apple.com/keynote"),
                         highlight: highlight(hovered: phase == 4, clicked: phase == 5, selected: linkSelected))
                .scaleEffect(phase == 5 ? 0.98 : 1)
            MockPanelRow(icon: "text.alignleft", text: Text("Standup moved to 9:30 tomorrow"),
                         highlight: highlight(hovered: phase == 2, clicked: phase == 3, selected: standupSelected))
                .scaleEffect(phase == 3 ? 0.98 : 1)
            MockPanelRow(icon: "chevron.left.forwardslash.chevron.right", text: Text(verbatim: "let total = items.reduce(0, +)"))
        }
        // The ⌘ hint slides in over the footer, clipped to the panel like the ⌥ demo's.
        .overlay(alignment: .bottom) { selectionHint }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
    }

    /// A selected row keeps the hover wash after the cursor moves on, as in the panel.
    private func highlight(hovered: Bool, clicked: Bool, selected: Bool) -> Double {
        if clicked { return 0.3 }
        return hovered || selected ? 0.16 : 0
    }

    /// The panel's real ⌘ hint strip (`PanelSelectionHint`), recreated for the mock panel.
    private var selectionHint: some View {
        ZStack {
            if commandHeld {
                HStack(spacing: 6) {
                    Image(systemName: "command")
                    Text(hintLabel)
                    Spacer(minLength: 0)
                    if selectedCount > 0 {
                        Text("Esc to clear")
                    }
                }
                .modifier(HintStripStyle())
                .background(.background)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var hintLabel: String {
        switch selectedCount {
        case 0: String(localized: "Click items or folders to select them")
        case 1: String(localized: "Release to copy 1 item")
        case let count: String(localized: "Release to copy \(count) items")
        }
    }

    private var cursor: some View {
        let target: CGPoint = switch phase {
        case 2, 3: CGPoint(x: 118, y: 8)     // the middle row, past its text
        case 4, 5: CGPoint(x: 64, y: -26)    // the top row
        default: CGPoint(x: 170, y: 95)      // resting beside the panel
        }
        return Image(systemName: "cursorarrow")
            .font(.system(size: 20))
            .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            .offset(x: target.x, y: target.y)
            .scaleEffect(phase == 3 || phase == 5 ? 0.82 : 1, anchor: .topLeading)
    }

    /// Where the copied rows land: a mock document that receives the paste, each row its own
    /// paragraph in the order picked (not list order). Fixed-height slots so the layout never jumps.
    private var pasteDocument: some View {
        VStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 7) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: 150, height: 7)
                VStack(alignment: .leading, spacing: 6) {
                    if pasted {
                        Text("Standup moved to 9:30 tomorrow")
                            .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
                    }
                    HStack(spacing: 3) {
                        if pasted {
                            Text(verbatim: "apple.com/keynote")
                                .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
                        }
                        // Insertion point — sits at the start, then trails the pasted text.
                        RoundedRectangle(cornerRadius: 1)
                            .fill(.tint)
                            .frame(width: 2, height: 15)
                    }
                }
                .font(.callout)
                .frame(height: 38, alignment: .topLeading)
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
                        Text("Pasted in the order you picked them")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                }
            }
            .frame(height: 16)
        }
    }

    /// The gesture being demonstrated, tracking the loop: hold ⌘ and click, then ⌘V pastes it all.
    private var gestureCaption: some View {
        HStack(spacing: 6) {
            if pasteKeysShown {
                KeyCap("⌘", size: 26, pressed: pasteKeysPressed)
                KeyCap("V", size: 26, pressed: pasteKeysPressed)
                Text("pastes them all")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                KeyCap("⌘", size: 26, pressed: commandHeld)
                Text("+")
                    .foregroundStyle(.secondary)
                Image(systemName: "cursorarrow.click")
                    .foregroundStyle(.secondary)
                Text("selects items")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 28)
    }

    private func runLoop() async {
        let steps: [(next: Int, delay: Double)] = [
            (1, 1.0),   // ⌘ goes down — the hint strip slides in
            (2, 0.9),   // cursor onto the middle row
            (3, 0.7),   // click: picked first
            (4, 0.5),   // cursor up to the top row
            (5, 0.7),   // click: picked second
            (6, 1.2),   // ⌘ released — both copied, the selection clears
            (7, 0.8),   // ⌘V caps appear, at rest
            (8, 0.8),   // …press down
            (9, 0.5),   // …and both land in the document, in pick order
            (0, 2.8),   // reset
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

// MARK: - ⌘S save-as-snippet demo

/// Looping animation for the panel's ⌘S gesture: the cursor hovers a row
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
        MockPanel {
            MockPanelRow(icon: "link", text: Text(verbatim: "apple.com/keynote"))
            MockPanelRow(icon: "text.alignleft", text: Text("Standup moved to 9:30 tomorrow"),
                         highlight: rowHovered ? 0.16 : 0)
            MockPanelRow(icon: "chevron.left.forwardslash.chevron.right", text: Text(verbatim: "let total = items.reduce(0, +)"))
        }
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
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

// MARK: - Wrap-up menu-bar demo

/// Looping animation for the wrap-up page: the Simple Clipboard icon pops
/// into a mock menu bar with a little sparkle burst, then ⌘⇧V presses and the floating
/// clipboard panel pops in beneath it — where the app lives, and how to summon it.
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

    /// The floating clipboard panel — the same mock the gesture demos use, with a soft
    /// shadow since this one *arrives* and should read as floating over everything.
    private var mockPanel: some View {
        MockPanel {
            MockPanelRow(icon: "text.alignleft", text: Text("Standup moved to 9:30 tomorrow"))
            MockPanelRow(icon: "link", text: Text(verbatim: "apple.com/keynote"))
            MockPanelRow(icon: "chevron.left.forwardslash.chevron.right", text: Text(verbatim: "let total = items.reduce(0, +)"))
        }
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
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
