import ServiceManagement

/// Registers/unregisters this app as a macOS login item via `SMAppService`.
@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var isEnabled: Bool

    init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Fall through to re-syncing from actual status below regardless of outcome.
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Re-reads the actual system state. Login Items can change outside this app (e.g. directly
    /// in System Settings), so call this whenever the dropdown is shown rather than trusting
    /// whatever was last set in-app.
    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
