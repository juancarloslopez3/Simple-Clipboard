import AppKit
import SwiftUI

/// About tab (CLAUDE.md §13): app identity, update check, repo link, credits.
/// Sparkle auto-update is stubbed for now — "Check for Updates" opens GitHub Releases.
struct AboutSettingsView: View {
    private let repoURL = URL(string: "https://github.com/juancarloslopez3/simple-clipboard")!
    private let releasesURL = URL(string: "https://github.com/juancarloslopez3/simple-clipboard/releases")!

    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)

            VStack(spacing: 2) {
                Text("Simple Clipboard").font(.title2.bold())
                Text("Version \(version)").font(.callout).foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("Check for Updates…") { NSWorkspace.shared.open(releasesURL) }
                Link("Star on GitHub", destination: repoURL)
                    .buttonStyle(.bordered)
            }

            Divider().padding(.horizontal, 40)

            VStack(spacing: 4) {
                Text("A simple clipboard manager.")
                    .font(.callout)
                Text("Developed by Juan Carlos López.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("© 2026").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
