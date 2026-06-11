import Foundation
import CoreAudio
import AudioToolbox
import OSLog

/// Wraps the CoreAudio Process Tap API (macOS 14.2+) to route an app's audio
/// to a chosen output device via a private aggregate device.
///
/// Routing is keyed by bundleID and taps ALL of the app's processes at once.
/// This matters for browsers: Chrome/Safari play audio from helper processes,
/// and which helper owns the audio stream can change between page loads —
/// tapping a single PID would silently miss the real audio source.
///
/// Pipeline:
///   PIDs → AudioObjectIDs → CATapDescription → tap object
///   tap + output device → private aggregate device
///   aggregate device IOProc: copy input (tap) buffers → output buffers
final class ProcessTapManager {
    private let log = Logger(subsystem: "com.zzanggi.soundwich", category: "ProcessTap")

    struct ActiveTap {
        let bundleID: String
        let pids: Set<pid_t>
        let tapID: AUAudioObjectID
        let aggregateID: AudioObjectID
        let ioProcID: AudioDeviceIOProcID
        let outputUID: String
    }

    private var activeTaps: [String: ActiveTap] = [:]

    @discardableResult
    func startRouting(bundleID: String, pids: [pid_t], toOutputUID outputUID: String) throws -> ActiveTap {
        log.info("startRouting: \(bundleID, privacy: .public) pids=\(pids) → \(outputUID, privacy: .public)")
        if activeTaps[bundleID] != nil {
            log.info("Routing for \(bundleID, privacy: .public) already active — restarting")
            stopRouting(bundleID: bundleID)
        }

        // 1. PIDs → process object IDs. Tap every process of the app; skip ones that
        //    CoreAudio doesn't know about, but require at least one match.
        var processObjectIDs: [AudioObjectID] = []
        for pid in pids {
            if let objectID = try? translatePIDToProcessObject(pid) {
                processObjectIDs.append(objectID)
            } else {
                log.info("PID \(pid) has no process object — skipped")
            }
        }
        guard !processObjectIDs.isEmpty else {
            throw RoutingError.pidTranslationFailed(noErr)
        }
        log.info("Tapping \(processObjectIDs.count) process object(s) for \(bundleID, privacy: .public)")

        // 2. Build tap description over all processes
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = CATapMuteBehavior(rawValue: 2) ?? CATapMuteBehavior(rawValue: 0)!  // mutedWhenTapped = 2
        tapDescription.name = "Soundwich Tap (\(bundleID))"
        tapDescription.isPrivate = true

        // 3. Create the tap
        var tapID: AUAudioObjectID = 0
        var status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard status == noErr, tapID != 0 else {
            throw RoutingError.tapCreationFailed(status)
        }
        log.info("Created tap object: \(tapID)")

        // 4. Read tap UID
        let tapUID = try readStringProperty(objectID: tapID, selector: kAudioTapPropertyUID)

        // 5. Aggregate device wrapping tap + output
        let aggregateUID = "com.zzanggi.soundwich.aggregate.\(Int(Date().timeIntervalSince1970))"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Soundwich Router",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: 1
                ]
            ]
        ]

        var aggregateID: AudioObjectID = 0
        status = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregateID
        )
        guard status == noErr, aggregateID != 0 else {
            AudioHardwareDestroyProcessTap(tapID)
            throw RoutingError.aggregateCreationFailed(status)
        }
        log.info("Created aggregate device: \(aggregateID)")

        // 6. IOProc that copies tap input → device output
        var ioProcID: AudioDeviceIOProcID?
        let logCopy = log
        let labelCopy = bundleID
        let counter = IOProcCounter()
        let ramp = FadeRamp()  // short fade-in to suppress the connection "pop"
        status = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            aggregateID,
            nil
        ) { _, inputData, _, outputData, _ in
            let inputList = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inputData)
            )
            let outputList = UnsafeMutableAudioBufferListPointer(outputData)
            let count = min(inputList.count, outputList.count)
            var totalBytes: UInt32 = 0

            // Fade-in: ramp gain 0→1 over the first ~80ms of routing. Tap streams are
            // 32-bit float, so we scale samples on the first buffers, then fall back to
            // a plain memcpy once the ramp completes (zero per-sample cost thereafter).
            let rampBase = ramp.position
            var framesAdvanced = 0

            for i in 0..<count {
                let inBuffer = inputList[i]
                var outBuffer = outputList[i]
                let bytes = min(inBuffer.mDataByteSize, outBuffer.mDataByteSize)
                guard bytes > 0, let src = inBuffer.mData, let dst = outBuffer.mData else {
                    if let dst = outBuffer.mData { memset(dst, 0, Int(outBuffer.mDataByteSize)) }
                    continue
                }
                let sampleCount = Int(bytes) / MemoryLayout<Float>.size
                if rampBase >= ramp.length {
                    memcpy(dst, src, Int(bytes))            // ramp done — fast path
                } else {
                    let s = src.assumingMemoryBound(to: Float.self)
                    let d = dst.assumingMemoryBound(to: Float.self)
                    let len = Float(ramp.length)
                    for j in 0..<sampleCount {
                        let g = Float(min(ramp.length, rampBase + j)) / len
                        d[j] = s[j] * g
                    }
                }
                if i == 0 { framesAdvanced = sampleCount }
                totalBytes &+= bytes
            }
            ramp.position = min(ramp.length, rampBase + framesAdvanced)

            // Log once per second to confirm audio is actually flowing through the tap.
            if counter.tick(bytes: totalBytes) {
                logCopy.info("IOProc[\(labelCopy, privacy: .public)] active: \(counter.callsPerSecond) calls/s, \(counter.bytesPerSecond) bytes/s")
            }
        }

        guard status == noErr, let procID = ioProcID else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw RoutingError.ioProcCreationFailed(status)
        }

        // 7. Wake the destination device. Bluetooth speakers that aren't the system
        // default sit in standby; nudge them before starting the aggregate.
        if let destinationID = Self.deviceID(forUID: outputUID) {
            let wakeStatus = AudioDeviceStart(destinationID, nil)
            log.info("Pre-wake AudioDeviceStart on dest device \(destinationID) → \(wakeStatus)")
        }

        // 8. Start the aggregate device
        status = AudioDeviceStart(aggregateID, procID)
        log.info("AudioDeviceStart on aggregate \(aggregateID) → \(status)")
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw RoutingError.deviceStartFailed(status)
        }

        let active = ActiveTap(
            bundleID: bundleID,
            pids: Set(pids),
            tapID: tapID,
            aggregateID: aggregateID,
            ioProcID: procID,
            outputUID: outputUID
        )
        activeTaps[bundleID] = active
        log.info("Routing active: \(bundleID, privacy: .public) → \(outputUID, privacy: .public)")
        return active
    }

    func stopRouting(bundleID: String) {
        guard let tap = activeTaps.removeValue(forKey: bundleID) else { return }
        AudioDeviceStop(tap.aggregateID, tap.ioProcID)
        AudioDeviceDestroyIOProcID(tap.aggregateID, tap.ioProcID)
        AudioHardwareDestroyAggregateDevice(tap.aggregateID)
        AudioHardwareDestroyProcessTap(tap.tapID)
        // Release the wake-up reference on the destination device.
        if let destinationID = Self.deviceID(forUID: tap.outputUID) {
            AudioDeviceStop(destinationID, nil)
        }
        log.info("Routing stopped: \(tap.bundleID, privacy: .public)")
    }

    func stopAll() {
        for bundleID in Array(activeTaps.keys) {
            stopRouting(bundleID: bundleID)
        }
    }

    func activeTap(for bundleID: String) -> ActiveTap? { activeTaps[bundleID] }

    // MARK: - Helpers

    private func translatePIDToProcessObject(_ pid: pid_t) throws -> AudioObjectID {
        var pidValue = pid
        var processObjectID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pidValue,
            &size,
            &processObjectID
        )
        guard status == noErr, processObjectID != 0 else {
            throw RoutingError.pidTranslationFailed(status)
        }
        return processObjectID
    }

    /// Resolve a device UID to its AudioDeviceID by scanning the device list.
    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return nil
        }
        for id in ids {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cf: CFString = "" as CFString
            var s = UInt32(MemoryLayout<CFString>.size)
            let st = withUnsafeMutablePointer(to: &cf) { ptr in
                AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &s, ptr)
            }
            if st == noErr, (cf as String) == uid {
                return id
            }
        }
        return nil
    }

    private func readStringProperty(objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
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
        guard status == noErr else {
            throw RoutingError.propertyReadFailed(status)
        }
        return cfString as String
    }

    /// Fade-in ramp state for the IOProc. Only the realtime audio thread touches
    /// `position`, so no locking is needed. `length` is in samples — ~80ms at 48 kHz
    /// stereo (interleaved) is roughly 48000 * 0.08 * 2 ≈ 7680.
    final class FadeRamp: @unchecked Sendable {
        let length: Int = 7680
        var position: Int = 0
    }

    /// Tiny thread-safe counter that aggregates IOProc invocations and reports once per second.
    /// Used purely for debugging — confirms that the aggregate device's I/O loop is actually firing.
    final class IOProcCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: Int = 0
        private var bytes: UInt64 = 0
        private var lastReportAt: TimeInterval = 0
        private(set) var callsPerSecond: Int = 0
        private(set) var bytesPerSecond: UInt64 = 0

        func tick(bytes: UInt32) -> Bool {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            self.bytes &+= UInt64(bytes)
            let now = CFAbsoluteTimeGetCurrent()
            if lastReportAt == 0 { lastReportAt = now; return false }
            if now - lastReportAt >= 1.0 {
                callsPerSecond = calls
                bytesPerSecond = self.bytes
                calls = 0
                self.bytes = 0
                lastReportAt = now
                return true
            }
            return false
        }
    }

    enum RoutingError: LocalizedError {
        case pidTranslationFailed(OSStatus)
        case tapCreationFailed(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case ioProcCreationFailed(OSStatus)
        case deviceStartFailed(OSStatus)
        case propertyReadFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .pidTranslationFailed(let s):    return "PID 변환 실패 (status \(s))"
            case .tapCreationFailed(let s):       return "Process Tap 생성 실패 (status \(s))"
            case .aggregateCreationFailed(let s): return "Aggregate Device 생성 실패 (status \(s))"
            case .ioProcCreationFailed(let s):    return "IOProc 등록 실패 (status \(s))"
            case .deviceStartFailed(let s):       return "디바이스 시작 실패 (status \(s))"
            case .propertyReadFailed(let s):      return "CoreAudio 속성 읽기 실패 (status \(s))"
            }
        }
    }
}
