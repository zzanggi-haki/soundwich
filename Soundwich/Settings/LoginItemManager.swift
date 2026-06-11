import Foundation
import ServiceManagement
import OSLog

/// Wraps `SMAppService.mainApp` to toggle "launch at login" for Soundwich.
@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var isEnabled: Bool = false
    @Published var lastError: String?

    private let log = Logger(subsystem: "com.zzanggi.soundwich", category: "LoginItem")

    init() {
        refresh()
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("Failed to \(enabled ? "register" : "unregister") login item: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        refresh()
    }
}
