import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp`. The OS state is the source
/// of truth; the `openAtLogin` pref is reconciled to it at launch.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("LaunchAtLogin toggle failed: \(error.localizedDescription)")
        }
    }

    /// Reconcile the stored preference with the real OS state.
    static func syncFromSystem() {
        UserDefaults.standard.set(isEnabled, forKey: Pref.Key.openAtLogin)
    }
}
