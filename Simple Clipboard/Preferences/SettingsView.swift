import SwiftUI

/// Preferences window: `TabView` with General · Shortcuts · Privacy · Storage · About.
struct SettingsView: View {
    @Environment(SettingsRoute.self) private var route
    @State private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ShortcutsSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag(SettingsTab.shortcuts)
            PrivacySettingsView()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
                .tag(SettingsTab.privacy)
            StorageSettingsView()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
                .tag(SettingsTab.storage)
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        // One fixed size for every tab: otherwise each tab sizes the window to its own content and
        // the window jumps on every tab switch. The forms scroll whatever doesn't fit (Storage's lists).
        .frame(width: 500, height: 640)
        .onAppear(perform: takePendingTab)
        .onChange(of: route.pendingTab) { takePendingTab() }
    }

    private func takePendingTab() {
        guard let pending = route.pendingTab else { return }
        route.pendingTab = nil
        tab = pending
    }
}

enum SettingsTab: Hashable {
    case general, shortcuts, privacy, storage, about
}

/// Lets launch code open Settings on a given tab (`AppModel`, after a Full Disk Access grant
/// relaunched the app from the Privacy tab). Injected into the Settings scene via `.environment`.
@MainActor
@Observable
final class SettingsRoute {
    /// Taken (and cleared) by `SettingsView` when it appears.
    var pendingTab: SettingsTab?
}
