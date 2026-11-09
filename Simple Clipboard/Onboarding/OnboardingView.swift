import SwiftUI

/// The first-run intro tutorial, hosted by `OnboardingWindow`. Seven pages:
/// welcome (the two panel shortcuts), the optional permissions (Accessibility for the paste
/// shortcuts; Full Disk Access for iPhone copies), looping animated demos of the panel's
/// four hidden gestures — Space preview, Option-click plain-text invert, ⌘-click
/// multi-select and ⌘S save-as-snippet — and an animated
/// wrap-up (a once-only check pop over the title, plus `WrapUpDemo`: the icon landing in
/// a mock menu bar, then ⌘⇧V popping the clipboard panel) whose caption points at
/// Settings › General › "Show Again" to replay the tour.
struct OnboardingView: View {
    /// Called by "Get Started" on the last page; the host closes the window.
    let onFinish: () -> Void

    @State private var page: Int
    /// Drives the slide direction: Continue slides in from the trailing edge, Back reverses it
    /// (new page enters from the leading edge, old page exits trailing) so a step back reads as
    /// going back rather than replaying the forward animation.
    @State private var goingForward = true
    private static let pageCount = 7
    static let permissionsPage = 1

    init(startPage: Int = 0, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        _page = State(initialValue: startPage)
    }

    private var transition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: goingForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: goingForward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Group {
                    switch page {
                    case 0: WelcomePage()
                    case Self.permissionsPage: PermissionsPage()
                    case 2: SpacePreviewPage()
                    case 3: OptionClickPage()
                    case 4: MultiSelectPage()
                    case 5: SaveSnippetPage()
                    default: WrapUpPage()
                    }
                }
                .id(page)
                .transition(transition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 44)
            .padding(.top, 34)   // clears the hidden-titlebar close button
            .clipped()

            footer
        }
        .frame(width: 520, height: 600)
    }

    private var footer: some View {
        ZStack {
            // Dots centered independently of the differing Back/Continue widths.
            HStack(spacing: 7) {
                ForEach(0..<Self.pageCount, id: \.self) { index in
                    Circle()
                        .fill(index == page ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        .frame(width: 7, height: 7)
                }
            }

            HStack {
                Button("Back") {
                    goingForward = false
                    withAnimation(.easeInOut(duration: 0.3)) { page = max(0, page - 1) }
                }
                .opacity(page == 0 ? 0 : 1)
                .disabled(page == 0)

                Spacer()

                Button(page == Self.pageCount - 1 ? String(localized: "Get Started") : String(localized: "Continue")) {
                    if page == Self.pageCount - 1 {
                        onFinish()
                    } else {
                        goingForward = true
                        withAnimation(.easeInOut(duration: 0.3)) { page += 1 }
                    }
                }
                .buttonStyle(.glassProminent)   // the single primary action
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

// MARK: - Page 1 · Welcome

private struct WelcomePage: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 54, weight: .medium))
                .foregroundStyle(.tint)
                .padding(.top, 4)
                .padding(.bottom, 8)
            Text("Welcome to Simple Clipboard")
                .font(.title2.bold())
            Text("Everything you copy is kept, ready to use again.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                ShortcutHint(keys: ["⌘", "⇧", "V"], text: String(localized: "Open your clipboard history anywhere"))
                ShortcutHint(keys: ["⌘", "⇧", "B"], text: String(localized: "Open your saved snippets"))
            }
            Spacer()
            Text("History and snippets are also always available from the menu-bar icon.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }
}

/// A keys-then-label row for the welcome page's shortcut hints.
private struct ShortcutHint: View {
    let keys: [String]
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { KeyCap($0, size: 28) }
            }
            Text(text)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Page 2 · Permissions

/// The two optional permissions: Accessibility for the paste shortcuts and Full
/// Disk Access for iPhone/iPad copies. Each row's Allow opens System Settings with the
/// drag-to-allow guide. Granting Full Disk Access makes System Settings quit and reopen the app,
/// so the tour picks up here again (`RelaunchDestination`).
private struct PermissionsPage: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 50, weight: .medium))
                .foregroundStyle(.tint)
                .padding(.top, 4)
                .padding(.bottom, 8)
            Text("Permissions")
                .font(.title2.bold())
            Text("Simple Clipboard works without them, but each one unlocks an extra.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            VStack(spacing: 0) {
                PermissionRow(permission: .accessibility, relaunchDestination: .onboarding)
                    .padding(14)
                Divider()
                    .padding(.leading, 56)
                PermissionRow(permission: .fullDiskAccess, relaunchDestination: .onboarding)
                    .padding(14)
            }
            .background(.quinary, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
            Spacer()
            Text("Change them anytime in Settings › Privacy.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Page 3 · Space preview

private struct SpacePreviewPage: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("Preview with Space")
                .font(.title2.bold())
                .padding(.top, 4)
            Text("In the clipboard panel, hover an item and press Space to see it in full: documents, spreadsheets, images, PDFs, calendar invites and more.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            SpacePreviewDemo()
            Spacer()
            Text("Hold Space to peek and let go to close, like in Finder. Copied several files? Flip through them with ← →.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Page 4 · Option-click invert

private struct OptionClickPage: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("Copy without formatting")
                .font(.title2.bold())
                .padding(.top, 4)
            Text("Hold ⌥ Option while clicking any item to copy it as plain text instead of its original formatting.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            OptionClickDemo()
            Spacer()
            Text("With “Always paste plain text” setting turned on, ⌥ inverts the other way and copies the original formatting.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Page 5 · ⌘-click multi-select

private struct MultiSelectPage: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("Copy Several Items at Once")
                .font(.title2.bold())
                .padding(.top, 4)
            Text("Hold ⌘ Command and click items in the clipboard panel to pick them. Release ⌘ to copy them all together.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            MultiSelectDemo()
            Spacer()
            Text("⌘-click a folder to pick everything in it, or press Esc to start over.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Page 6 · ⌘S save-as-snippet

private struct SaveSnippetPage: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("Save as a Snippet")
                .font(.title2.bold())
                .padding(.top, 4)
            Text("In the clipboard panel (⌘⇧V), hover an item and press ⌘S to save it as a snippet.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            SaveSnippetDemo()
            Spacer()
            Text("Snippets live in their own panel (⌘⇧B) and never expire, unlike history items.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Page 7 · Wrap-up

private struct WrapUpPage: View {
    /// Drives the check's pop — flipped in `onAppear`, so unlike the demo loops it plays
    /// exactly once each time the page comes on screen.
    @State private var checkShown = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 50, weight: .medium))
                .foregroundStyle(.green)
                .scaleEffect(checkShown ? 1 : 0.3)
                .opacity(checkShown ? 1 : 0)
                .padding(.top, 4)
                .padding(.bottom, 8)
                .onAppear {
                    withAnimation(.spring(duration: 0.5, bounce: 0.45).delay(0.25)) {
                        checkShown = true
                    }
                }
            Text("You're All Set")
                .font(.title2.bold())
            Text("Simple Clipboard now lives in your menu bar and you can open it by pressing ⌘⇧V.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            WrapUpDemo()
            Spacer()
            Text("Watch this tour again anytime: Settings › General › Intro Tutorial › “Show Again”.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }
}
