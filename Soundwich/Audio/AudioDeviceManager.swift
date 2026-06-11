import Foundation
import AppKit
import CoreAudio
import Combine
import OSLog

@MainActor
final class AudioDeviceManager: ObservableObject {
    @Published private(set) var outputDevices: [AudioDevice] = []

    private let log = Logger(subsystem: "com.zzanggi.soundwich", category: "Devices")
    private var defaultOutputListenerInstalled = false
    private var deviceListListenerInstalled = false
    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?

    private var pollTimer: Timer?
    /// See AudioProcessManager — publishing while an AppKit menu is tracking
    /// makes menu animations stutter, so refreshes pause during tracking.
    /// Time-capped so a missed didEndTracking can never freeze updates forever.
    private var menuTrackingSince: Date?

    private var menuIsBlocking: Bool {
        guard let since = menuTrackingSince else { return false }
        return Date().timeIntervalSince(since) < 15
    }

    init() {
        installListeners()
        installMenuTrackingObservers()
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
                self?.menuTrackingSince = nil
                try? await Task.sleep(for: .milliseconds(300))
                await self?.refresh()
            }
        }
    }

    /// Polling fallback: see AudioProcessManager for rationale.
    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Whichever device is currently the system default output.
    var defaultOutput: AudioDevice? {
        outputDevices.first(where: { $0.isDefault })
    }

    func refresh() async {
        guard !menuIsBlocking else { return }
        // CoreAudio reads happen off the main thread; only the publish hops back.
        let devices = await Task.detached(priority: .utility) {
            Self.fetchOutputDevices()
        }.value
        guard !menuIsBlocking else { return }
        if self.outputDevices != devices {
            self.outputDevices = devices
        }
    }

    /// Set this device as the macOS system default output.
    /// Runs off-main: the property write can block while the device spins up
    /// (Bluetooth especially), which would freeze the UI mid-click.
    func setDefaultOutput(_ device: AudioDevice) {
        // Re-selecting the current default is a no-op.
        guard !device.isDefault else { return }
        let deviceID = device.id
        let logCopy = log
        Task.detached(priority: .userInitiated) { [weak self] in
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var newID = deviceID
            let status = AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0, nil,
                UInt32(MemoryLayout<AudioDeviceID>.size),
                &newID
            )
            if status != noErr {
                logCopy.error("Failed to set default output device: \(status)")
            }
            await self?.refresh()
        }
    }

    // MARK: - Listeners

    private func installListeners() {
        installDefaultOutputListener()
        installDeviceListListener()
    }

    private func installDefaultOutputListener() {
        guard !defaultOutputListenerInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in await self?.refresh() }
        }
        // CoreAudio does not retain listener blocks — we must hold the reference ourselves.
        defaultOutputListenerBlock = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        if status == noErr {
            defaultOutputListenerInstalled = true
        } else {
            log.error("Failed to install default-output listener: \(status)")
            defaultOutputListenerBlock = nil
        }
    }

    private func installDeviceListListener() {
        guard !deviceListListenerInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in await self?.refresh() }
        }
        deviceListListenerBlock = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        if status == noErr {
            deviceListListenerInstalled = true
        } else {
            log.error("Failed to install device-list listener: \(status)")
            deviceListListenerBlock = nil
        }
    }

    // MARK: - CoreAudio helpers

    private nonisolated static func fetchOutputDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard status == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        )
        guard status == noErr else { return [] }

        let defaultID = defaultOutputDeviceID()

        return ids.compactMap { id -> AudioDevice? in
            guard hasOutputStreams(deviceID: id) else { return nil }
            let name = stringProperty(deviceID: id, selector: kAudioObjectPropertyName) ?? "Unknown"
            let uid = stringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceUID) ?? ""
            // Hide our own internal aggregate devices (one per active routing).
            if uid.hasPrefix("com.zzanggi.soundwich.aggregate.") { return nil }
            if name.hasPrefix("Soundwich-") { return nil }
            return AudioDevice(
                id: id,
                uid: uid,
                name: name,
                isDefault: id == defaultID,
                hasOutput: true
            )
        }
    }

    private nonisolated static func defaultOutputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return deviceID
    }

    private nonisolated static func hasOutputStreams(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        return status == noErr && size > 0
    }

    private nonisolated static func stringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfString: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &cfString) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return cfString as String
    }
}
