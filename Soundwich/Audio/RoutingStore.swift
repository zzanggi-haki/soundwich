import Foundation
import Combine
import OSLog

/// Persists the user's per-app routing preferences as `bundleID → SavedRoute`.
/// The mapping is keyed by bundleID (stable across launches), not PID.
@MainActor
final class RoutingStore: ObservableObject {
    struct SavedRoute: Codable, Equatable {
        let bundleID: String
        let appName: String          // last seen display name, used when the app isn't running
        let outputDeviceUID: String
        let outputDeviceName: String // last seen display name of the device
    }

    @Published private(set) var routes: [String: SavedRoute] = [:]

    private let defaults: UserDefaults
    private let key = "com.zzanggi.soundwich.routes.v1"
    private let log = Logger(subsystem: "com.zzanggi.soundwich", category: "RoutingStore")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        cleanUpHelperBundleIDs()
    }

    /// Older builds saved routes under helper bundle IDs like `com.google.Chrome.helper`.
    /// New code canonicalizes to the parent (`com.google.Chrome`), so the helper entries
    /// become orphans that can never match. Strip them on launch.
    private func cleanUpHelperBundleIDs() {
        let stale = routes.keys.filter { $0.contains(".helper") || $0 == "com.apple.WebKit.WebContent" || $0 == "org.mozilla.plugincontainer" }
        guard !stale.isEmpty else { return }
        for key in stale {
            routes.removeValue(forKey: key)
            log.info("Removed orphan helper route: \(key)")
        }
        persist()
    }

    func save(_ route: SavedRoute) {
        routes[route.bundleID] = route
        persist()
    }

    func remove(bundleID: String) {
        routes.removeValue(forKey: bundleID)
        persist()
    }

    func route(for bundleID: String) -> SavedRoute? {
        routes[bundleID]
    }

    private func load() {
        guard let data = defaults.data(forKey: key) else { return }
        do {
            let decoded = try JSONDecoder().decode([String: SavedRoute].self, from: data)
            self.routes = decoded
            log.info("Loaded \(decoded.count) saved route(s)")
        } catch {
            log.error("Failed to load saved routes: \(error.localizedDescription)")
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(routes)
            defaults.set(data, forKey: key)
        } catch {
            log.error("Failed to persist routes: \(error.localizedDescription)")
        }
    }
}
