import Foundation
import AppKit
import CoreAudio
import Combine
import OSLog

@MainActor
final class AudioProcessManager: ObservableObject {
    @Published private(set) var processes: [AudioProcess] = []

    private let log = Logger(subsystem: "com.zzanggi.soundwich", category: "ProcessList")
    private var perProcessListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var processListListenerBlock: AudioObjectPropertyListenerBlock?
    private var listListenerInstalled = false
    /// Icons are shared NSImage references from NSRunningApplication — cached per PID
    /// so SwiftUI never re-fetches them.
    private var iconCache: [pid_t: NSImage] = [:]
    private var started = false
    private var pollTimer: Timer?
    private var refreshInFlight = false
    /// Set while an AppKit menu is tracking. Publishing list changes mid-tracking
    /// rebuilds the menu's host view and makes open/close animations stutter,
    /// so refreshes are deferred for the duration and flushed right after.
    private var menuTrackingSince: Date?

    /// Safety-capped: if a didEndTracking notification is ever missed, a stale flag
    /// must not freeze updates forever (this manifested as "unplugged headphones
    /// don't disappear until the next menu interaction").
    private var menuIsBlocking: Bool {
        guard let since = menuTrackingSince else { return false }
        return Date().timeIntervalSince(since) < 15
    }

    init() {}

    func start() {
        guard !started else { return }
        started = true
        installProcessListListener()
        installMenuTrackingObservers()
        refresh()
        startPolling()
    }

    private func installMenuTrackingObservers() {
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.menuTrackingSince = Date() }
        }
        NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.menuTrackingSince = nil
                // Catch up on anything deferred while the menu was open —
                // slight delay so the close animation finishes first.
                try? await Task.sleep(for: .milliseconds(300))
                self.refresh()
            }
        }
    }

    /// Kicks off a refresh. ALL CoreAudio property reads and NSWorkspace enumeration
    /// happen off the main thread — doing this work on the main thread every poll is
    /// what made menu tracking stutter. Only the final publish hops back to main.
    func refresh() {
        guard !refreshInFlight, !menuIsBlocking else { return }
        refreshInFlight = true
        let existingIcons = iconCache
        Task.detached(priority: .utility) { [weak self] in
            let result = Self.fetchProcesses(existingIcons: existingIcons)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.refreshInFlight = false
                // A menu may have opened while the fetch was in flight — don't
                // publish mid-tracking; the didEndTracking observer will catch up.
                guard !self.menuIsBlocking else { return }
                self.iconCache = result.icons
                if self.processes != result.processes {
                    self.processes = result.processes
                }
                self.installPerProcessListeners(for: result.objectIDs)
            }
        }
    }

    /// Polling fallback: CoreAudio property listeners aren't always reliable —
    /// especially for the process-list change notification. A 2-second poll keeps
    /// the UI in sync even if the listener silently stops firing.
    ///
    /// Scheduled on `.common` run loop mode so it keeps firing while menus are open;
    /// the actual work runs off-main (see `refresh`), so it can't cause jank.
    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // MARK: - Background fetch

    private struct FetchResult {
        let processes: [AudioProcess]
        let icons: [pid_t: NSImage]
        let objectIDs: [AudioObjectID]
    }

    private nonisolated static func fetchProcesses(existingIcons: [pid_t: NSImage]) -> FetchResult {
        let ids = fetchProcessObjectIDs()
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let workspaceApps = NSWorkspace.shared.runningApplications
        // NSWorkspace can transiently report two entries with the same PID (during app
        // launch/quit, or PID reuse). `Dictionary(uniqueKeysWithValues:)` TRAPS on a
        // duplicate key — which crashed the whole app mid-use. Tolerate dupes by keeping
        // the first occurrence.
        let appsByPID = Dictionary(
            workspaceApps.map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var icons = existingIcons
        var livePIDs = Set<pid_t>()

        let newProcesses: [AudioProcess] = ids.compactMap { objectID in
            guard let pid = uintProperty(objectID, kAudioProcessPropertyPID).map({ pid_t($0) }) else {
                return nil
            }
            // Hide ourselves — Soundwich is always "playing" by virtue of running the IOProc.
            guard pid != selfPID else { return nil }
            let bundleID = stringProperty(objectID, kAudioProcessPropertyBundleID)
            let isRunningOutput = (uintProperty(objectID, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0

            let workspaceApp = appsByPID[pid]

            // Helper processes (Chrome's audio is played by "Google Chrome Helper",
            // Safari/WebKit by "WebContent", …) adopt the parent app's name/icon.
            let parentApp = resolveParentApp(forBundleID: bundleID, workspaceApps: workspaceApps)

            // Filter: keep only Dock apps OR anything currently playing audio.
            let isDockApp = (parentApp ?? workspaceApp)?.activationPolicy == .regular
            guard isDockApp || isRunningOutput else { return nil }

            let displayApp = parentApp ?? workspaceApp
            let name = displayApp?.localizedName
                ?? bundleID.flatMap { $0.split(separator: ".").last.map(String.init) }
                ?? "PID \(pid)"

            livePIDs.insert(pid)
            let icon: NSImage?
            if let cached = icons[pid] {
                icon = cached
            } else if let appIcon = displayApp?.icon {
                // NSRunningApplication.icon is already a lazily-rendered shared image;
                // no resizing/encoding needed — SwiftUI scales it at render time.
                icon = appIcon
                icons[pid] = appIcon
            } else {
                icon = nil
            }

            // Use the parent's bundleID for persistence so different helper sessions
            // of the same browser map to the same saved route.
            let canonicalBundleID = parentApp?.bundleIdentifier ?? bundleID

            return AudioProcess(
                audioObjectID: objectID,
                pid: pid,
                bundleID: canonicalBundleID,
                name: name,
                icon: icon,
                isRunningOutput: isRunningOutput
            )
        }

        let sorted = newProcesses.sorted { lhs, rhs in
            if lhs.isRunningOutput != rhs.isRunningOutput {
                return lhs.isRunningOutput && !rhs.isRunningOutput
            }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }

        // Drop cached icons for processes that no longer exist.
        icons = icons.filter { livePIDs.contains($0.key) }

        return FetchResult(processes: sorted, icons: icons, objectIDs: ids)
    }

    /// Map known helper bundleIDs back to their parent app's NSRunningApplication.
    private nonisolated static func resolveParentApp(forBundleID bundleID: String?, workspaceApps: [NSRunningApplication]) -> NSRunningApplication? {
        guard let bundleID else { return nil }
        let parentBundleID: String?

        if bundleID.hasSuffix(".helper") || bundleID.range(of: ".helper.", options: .literal) != nil {
            if let range = bundleID.range(of: ".helper") {
                parentBundleID = String(bundleID[..<range.lowerBound])
            } else {
                parentBundleID = nil
            }
        } else if bundleID == "com.apple.WebKit.WebContent" || bundleID == "com.apple.WebKit.GPU" {
            parentBundleID = "com.apple.Safari"
        } else if bundleID == "org.mozilla.plugincontainer" {
            parentBundleID = "org.mozilla.firefox"
        } else {
            parentBundleID = nil
        }

        guard let parentBundleID else { return nil }
        return workspaceApps.first(where: { $0.bundleIdentifier == parentBundleID })
    }

    // MARK: - Property listeners

    private func installProcessListListener() {
        guard !listListenerInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        // CoreAudio does NOT retain listener blocks — hold the reference ourselves.
        processListListenerBlock = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        if status == noErr {
            listListenerInstalled = true
        } else {
            log.error("Failed to install process list listener: \(status)")
            processListListenerBlock = nil
        }
    }

    private func installPerProcessListeners(for ids: [AudioObjectID]) {
        let current = Set(ids)
        let known = Set(perProcessListeners.keys)

        for stale in known.subtracting(current) {
            perProcessListeners.removeValue(forKey: stale)
        }

        for newID in current.subtracting(known) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
            let status = AudioObjectAddPropertyListenerBlock(
                newID,
                &address,
                DispatchQueue.main,
                block
            )
            if status == noErr {
                perProcessListeners[newID] = block
            }
        }
    }

    // MARK: - Property helpers

    private nonisolated static func fetchProcessObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        )
        guard status == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        )
        return status == noErr ? ids : []
    }

    private nonisolated static func uintProperty(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private nonisolated static func stringProperty(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfString: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &cfString) { ptr -> OSStatus in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        let result = cfString as String
        return result.isEmpty ? nil : result
    }
}
