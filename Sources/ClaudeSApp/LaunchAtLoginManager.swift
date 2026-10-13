import ServiceManagement

/// Toggles starting the app automatically at macOS login.
///
/// Uses `SMAppService` (ServiceManagement, macOS 13+), Apple's current API —
/// the old `SMLoginItemSetEnabled` is deprecated. Requires the process to
/// run from inside a registered `.app` bundle (associated with a Login Items
/// helper or the bundle's own main executable); running loose via
/// `swift run`/a standalone binary, `register()` fails. Real validation depends on
/// the `.app` packaging (see specs/05-app-status-bar).
enum LaunchAtLoginManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard SMAppService.mainApp.status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard SMAppService.mainApp.status == .enabled else { return }
            try SMAppService.mainApp.unregister()
        }
    }
}
