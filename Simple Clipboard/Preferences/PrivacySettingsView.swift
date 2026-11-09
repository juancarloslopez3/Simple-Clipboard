import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Privacy preferences: the optional permissions (`Permission`) with their live
/// status, and an ignored-apps list.
struct PrivacySettingsView: View {
    @State private var ignored: [String] = Pref.ignoredAppBundleIDs

    var body: some View {
        Form {
            // The iPhone-copy alert can be silenced for good, so the way to Full Disk Access lives here too.
            Section {
                ForEach(Permission.allCases) { PermissionRow(permission: $0, relaunchDestination: .privacySettings) }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Both are optional: copying and the clipboard panels work without them. Full Disk Access takes effect once Simple Clipboard reopens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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

/// One permission in Settings › Privacy and the intro tour: a System
/// Settings-style icon tile, what it unlocks, and either an Allowed badge or an Allow button that
/// opens System Settings with the drag-to-allow guide (`PermissionGuide`). Polls its own status,
/// so it turns green as soon as access comes through.
struct PermissionRow: View {
    let permission: Permission
    /// Where to reopen after a Full Disk Access grant relaunches the app: this row's window.
    let relaunchDestination: RelaunchDestination

    @State private var granted: Bool

    init(permission: Permission, relaunchDestination: RelaunchDestination) {
        self.permission = permission
        self.relaunchDestination = relaunchDestination
        _granted = State(initialValue: permission.isGranted)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: permission.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(permission.tint.gradient, in: .rect(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                Text(permission.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if granted {
                Label("Allowed", systemImage: "checkmark")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.green.opacity(0.15), in: .capsule)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                Button("Allow") {
                    if permission == .fullDiskAccess { Pref.relaunchDestination = relaunchDestination }
                    PermissionGuide.shared.show(permission)
                }
                .transition(.opacity)
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.4), value: granted)
        .task {
            // Live-poll while on screen (cancelled with the view).
            while !Task.isCancelled {
                granted = permission.isGranted
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
