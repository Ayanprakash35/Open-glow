import ServiceManagement
import os

/// Launch at login through `SMAppService.mainApp`, which registers this app bundle itself as a
/// login item. The system's record is the only source of truth — the user can remove the item in
/// System Settings › General › Login Items at any time — so nothing is cached here.
@MainActor
enum LaunchAtLogin {
    enum State: Equatable {
        case enabled
        case disabled
        /// Registered, but macOS wants the user to allow it in Login Items first.
        case requiresApproval
    }

    private static let logger = Logger(subsystem: "com.openglow.app", category: "LaunchAtLogin")

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        default: .disabled
        }
    }

    /// Registers or unregisters the login item. Returns an error message to show, or nil.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            logger.error("Launch at login \(enabled ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
