import Foundation
import Combine
import CoreAudio
import OSLog

@MainActor
final class AudioRouter: ObservableObject {
    private let tapManager = ProcessTapManager()
    /// All ProcessTapManager work happens on this serial queue. Creating aggregates
    /// and starting devices can block for seconds (Bluetooth wake-up) — doing that
    /// on the main thread froze the UI after every click.
    private let tapQueue = DispatchQueue(label: "com.zzanggi.soundwich.tap", qos: .userInitiated)
    private let log = Logger(subsystem: "com.zzanggi.soundwich", category: "Router")

    let store: RoutingStore

    /// Active (engaged) routes, keyed by bundleID.
    @Published private(set) var activeRoutes: [String: ActiveRouteInfo] = [:]
    /// Routes currently being engaged (bundleID → target outputUID). Engaging can
    /// take 1–2s while a Bluetooth device wakes; the UI shows a spinner meanwhile.
    @Published private(set) var pendingRoutes: [String: String] = [:]
    @Published var lastError: String?

    struct ActiveRouteInfo: Equatable {
        let bundleID: String
        let appName: String
        let pids: Set<pid_t>
        let outputDeviceUID: String
        let outputDeviceName: String
    }

    private var storeForwarder: AnyCancellable?

    init(store: RoutingStore? = nil) {
        self.store = store ?? RoutingStore()
        // The view reads store.routes through this router; forward the store's
        // change events so saved-route edits actually refresh the UI.
        storeForwarder = self.store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// User explicitly sets a route. Persists it and engages immediately
    /// if the app has running processes.
    func setRoute(processes: [AudioProcess], bundleID: String, appName: String, output: AudioDevice) {
        // Re-selecting the device that's already engaged (or being engaged) is a no-op —
        // no point tearing down and rebuilding an identical tap.
        if activeRoutes[bundleID]?.outputDeviceUID == output.uid || pendingRoutes[bundleID] == output.uid {
            return
        }
        if lastError != nil { lastError = nil }
        store.save(.init(
            bundleID: bundleID,
            appName: appName,
            outputDeviceUID: output.uid,
            outputDeviceName: output.name
        ))
        guard !processes.isEmpty else { return }
        pendingRoutes[bundleID] = output.uid
        startTap(bundleID: bundleID, appName: appName, pids: processes.map(\.pid), output: output)
    }

    /// User clears the route — stops the tap and removes the saved preference.
    func clearRoute(bundleID: String) {
        store.remove(bundleID: bundleID)
        pendingRoutes.removeValue(forKey: bundleID)
        if activeRoutes[bundleID] != nil {
            activeRoutes.removeValue(forKey: bundleID)
            let manager = tapManager
            tapQueue.async {
                manager.stopRouting(bundleID: bundleID)
            }
        }
    }

    /// Keep active taps in sync with the live process list.
    /// - App quit → tear down its tap (saved route is kept).
    /// - A process the tap does NOT cover starts playing audio → re-create the tap.
    ///   (Restarting on every PID-set change caused constant heavy restarts with
    ///   browsers, whose helper processes churn all the time.)
    func syncWithProcesses(_ processes: [AudioProcess], outputs: [AudioDevice]) {
        let byBundleID = Dictionary(grouping: processes.filter { $0.bundleID != nil },
                                    by: { $0.bundleID! })

        for (bundleID, route) in activeRoutes {
            let current = byBundleID[bundleID] ?? []

            if current.isEmpty {
                log.info("App quit — stopping route for \(bundleID, privacy: .public)")
                activeRoutes.removeValue(forKey: bundleID)
                let manager = tapManager
                tapQueue.async { manager.stopRouting(bundleID: bundleID) }
                continue
            }

            // Restart only when audio is audibly playing from an uncovered process —
            // that's the only case where we'd actually be missing sound.
            let hasUncoveredAudible = current.contains { $0.isRunningOutput && !route.pids.contains($0.pid) }
            if hasUncoveredAudible {
                guard let output = outputs.first(where: { $0.uid == route.outputDeviceUID }) else { continue }
                log.info("New audible process for \(bundleID, privacy: .public) — restarting tap")
                // Optimistically record the new pid set so the next poll doesn't
                // queue a duplicate restart while this one is still in flight.
                activeRoutes[bundleID] = ActiveRouteInfo(
                    bundleID: bundleID,
                    appName: route.appName,
                    pids: Set(current.map(\.pid)),
                    outputDeviceUID: route.outputDeviceUID,
                    outputDeviceName: route.outputDeviceName
                )
                startTap(bundleID: bundleID, appName: route.appName, pids: current.map(\.pid), output: output)
            }
        }
    }

    func activeRoute(forBundleID bundleID: String) -> ActiveRouteInfo? {
        activeRoutes[bundleID]
    }

    func savedRoute(forBundleID bundleID: String) -> RoutingStore.SavedRoute? {
        store.route(for: bundleID)
    }

    // MARK: - Internal

    private func startTap(bundleID: String, appName: String, pids: [pid_t], output: AudioDevice) {
        let manager = tapManager

        // Watchdog: if the completion below somehow never lands, don't leave the
        // spinner stuck — clear the pending marker and surface it in the log.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.pendingRoutes[bundleID] == output.uid else { return }
            self.log.error("Engagement watchdog fired for \(bundleID, privacy: .public) — completion never arrived")
            self.pendingRoutes.removeValue(forKey: bundleID)
        }

        tapQueue.async { [weak self] in
            // NOTE: completion is delivered via RunLoop.main in .common modes, NOT
            // DispatchQueue.main / Task. While an NSMenu is open the main queue is
            // not serviced (event-tracking runloop mode), so dispatch-based delivery
            // sat queued for as long as the user kept the device list open — the UI
            // showed stale state and then "jumped" when the menu closed. Common-mode
            // runloop blocks DO run during menu tracking.
            do {
                let tap = try manager.startRouting(bundleID: bundleID, pids: pids, toOutputUID: output.uid)
                RunLoop.main.perform(inModes: [.common]) {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.log.info("Engagement finished: \(bundleID, privacy: .public) → \(output.name, privacy: .public)")
                        self.pendingRoutes.removeValue(forKey: bundleID)
                        self.activeRoutes[bundleID] = ActiveRouteInfo(
                            bundleID: bundleID,
                            appName: appName,
                            pids: tap.pids,
                            outputDeviceUID: output.uid,
                            outputDeviceName: output.name
                        )
                    }
                }
            } catch {
                RunLoop.main.perform(inModes: [.common]) {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.log.error("Engagement failed: \(bundleID, privacy: .public) — \(error.localizedDescription, privacy: .public)")
                        self.pendingRoutes.removeValue(forKey: bundleID)
                        self.activeRoutes.removeValue(forKey: bundleID)
                        self.lastError = "\(appName): \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}
