import ServiceManagement

/// Start-at-login through the system login item for the app bundle. Only works from a real
/// .app (not `swift run`), so the menu hides the switch when it is unavailable.
enum LaunchAtLogin {
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Inverterly: could not change the login item: \(error.localizedDescription)")
        }
    }
}
