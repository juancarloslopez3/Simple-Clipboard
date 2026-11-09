import ApplicationServices
import SwiftUI

/// The first-run intro tutorial (CLAUDE.md §16), hosted by `OnboardingWindow`. Five pages:
/// welcome (the two panel shortcuts), the optional Accessibility grant for the paste
/// shortcuts (§12/§14), looping animated demos of the two hidden gestures —
/// Option-click plain-text invert (§12) and ⌘S save-as-snippet (§9) — and an animated
/// wrap-up (a once-only check pop over the title, plus `WrapUpDemo`: the icon landing in
/// a mock menu bar, then ⌘⇧V popping the clipboard panel) whose caption points at
/// Settings › General › "Show Again" to replay the tour.
struct OnboardingView: View {
    /// Called by "Get Started" on the last page; the host closes the window.
    let onFinish: () -> Void

    @State private var page = 0
    /// Drives the slide direction: Continue slides in from the trailing edge, Back reverses it
    /// (new page enters from the leading edge, old page exits trailing) so a step back reads as
    /// going back rather than replaying the forward animation.
    @State private var goingForward = true
    private static let pageCount = 5

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
                    case 1: AccessibilityPage()
                    case 2: OptionClickPage()
                    case 3: SaveSnippetPage()
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
                .buttonStyle(.glassProminent)   // the single primary action (CLAUDE.md §3)
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

// MARK: - Page 2 · Accessibility grant

/// The paste shortcuts (§12/§14) synthesize ⌘V, which needs Accessibility trust. Explicitly
/// optional — plain copying never needs it. Status is live-polled so the checkmark appears
/// as soon as the user flips the toggle in System Settings.
private struct AccessibilityPage: View {
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "accessibility")
                .font(.system(size: 50, weight: .medium))
                .foregroundStyle(.tint)
                .padding(.top, 4)
                .padding(.bottom, 8)
            Text("Accessibility Access")
                .font(.title2.bold())
            Text("The paste shortcuts press ⌘V for you, which needs Accessibility access.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            if trusted {
                Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
            } else {
                VStack(spacing: 8) {
                    Button("Grant Accessibility Access") { requestAccess() }
                    Button("Open System Settings") { openAccessibilityPane() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            Spacer()
            Text("To grant it manually, open System Settings › Privacy & Security › Accessibility and turn on Simple Clipboard.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .task {
            // Live-poll the trust state while the page is up (cancelled with the view).
            while !Task.isCancelled {
                trusted = AXIsProcessTrusted()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Raises the system Accessibility prompt (first time only — afterwards macOS just ignores
    /// it, hence the explicit System Settings link below). Literal key for the same strict-
    /// concurrency reason as `PasteService.ensureAccessibilityTrust` (§12).
    private func requestAccess() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private func openAccessibilityPane() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Page 3 · Option-click invert (§12)

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

// MARK: - Page 4 · ⌘S save-as-snippet (§9)

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

// MARK: - Page 5 · Wrap-up

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
