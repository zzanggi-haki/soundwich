import Foundation
import AppKit
import CoreAudio

struct AudioProcess: Identifiable, Hashable {
    let audioObjectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let name: String
    /// Pre-rendered 32×32 icon, cached by AudioProcessManager. Stored as the
    /// decoded NSImage (a cheap class reference) so rendering never re-decodes data.
    let icon: NSImage?
    let isRunningOutput: Bool

    var id: AudioObjectID { audioObjectID }

    static func == (lhs: AudioProcess, rhs: AudioProcess) -> Bool {
        lhs.audioObjectID == rhs.audioObjectID
            && lhs.isRunningOutput == rhs.isRunningOutput
            && lhs.name == rhs.name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(audioObjectID)
    }
}
