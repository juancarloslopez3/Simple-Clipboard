import SwiftUI

/// Drives the main window's transient copy confirmation toast, shared by the
/// history pane (`ClipboardListView`) and the snippets pane (`SnippetsListView`). Owns the
/// shown flag, the message and a monotonic token so rapid successive copies each keep the
/// toast up for its full duration instead of an earlier timer hiding a later one.
@MainActor
@Observable
final class CopyToast {
    private(set) var isShown = false
    private(set) var message = String(localized: "Copied")
    private var token = 0

    /// Flash the toast with `message`, restarting the ~1 s auto-dismiss. The message spells
    /// out the plain-text mode only when it differs from the default — a plain default
    /// copy just reads "Copied".
    func flash(_ message: String = String(localized: "Copied")) {
        self.message = message
        token += 1
        let current = token
        isShown = true
        Task {
            try? await Task.sleep(for: .seconds(1))
            if current == token { isShown = false }
        }
    }
}

extension View {
    /// Overlays the bottom-center copy toast driven by `toast`.
    func copyToast(_ toast: CopyToast) -> some View {
        overlay(alignment: .bottom) {
            if toast.isShown {
                CopiedToast(message: toast.message)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: toast.isShown)
    }
}

/// Brief copy confirmation shown after a copy in the main window. `message`
/// spells out the plain-text mode when it differs from the default. Standard content
/// — never glass.
struct CopiedToast: View {
    let message: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
                .font(.callout.weight(.medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .capsule)
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(radius: 8, y: 3)
    }
}
