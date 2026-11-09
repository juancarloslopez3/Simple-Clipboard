import SwiftUI

/// Preferences window: `TabView` with General · Shortcuts · Privacy · About (CLAUDE.md §13).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            ShortcutsSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            PrivacySettingsView()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 500)
    }
}
