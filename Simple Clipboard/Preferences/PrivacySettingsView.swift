import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Privacy preferences (CLAUDE.md §13): an ignored-apps list.
struct PrivacySettingsView: View {
    @State private var ignored: [String] = Pref.ignoredAppBundleIDs

    var body: some View {
        Form {
            Section("Don't record copies from these apps") {
                if ignored.isEmpty {
                    Text("No ignored apps").foregroundStyle(.secondary)
                } else {
                    ForEach(ignored, id: \.self) { bundleID in
                        HStack {
                            Image(nsImage: AppIconResolver.icon(for: bundleID))
                                .resizable().frame(width: 18, height: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(appName(for: bundleID)).font(.body)
                                Text(bundleID).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { remove(bundleID) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                Button("Add App…", action: addApp)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        if !ignored.contains(bundleID) {
            ignored.append(bundleID)
            Pref.ignoredAppBundleIDs = ignored
        }
    }

    private func remove(_ bundleID: String) {
        ignored.removeAll { $0 == bundleID }
        Pref.ignoredAppBundleIDs = ignored
    }
}
