import SwiftUI

@main
struct SoundwichApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarController()
        // Surface the system-audio-recording permission immediately on launch — this is
        // the permission per-app routing needs — instead of mid-task when the user first
        // picks an output device.
        ProcessTapManager.primeAudioCapturePermission()
    }
}
