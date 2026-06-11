import Foundation
import CoreAudio

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isDefault: Bool
    let hasOutput: Bool
}
