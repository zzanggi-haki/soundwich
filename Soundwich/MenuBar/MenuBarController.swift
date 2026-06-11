import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    /// Watches clicks in other apps so the popover closes when the user clicks
    /// anywhere outside it. `.transient` alone doesn't reliably do this for
    /// LSUIElement menu bar apps.
    private var globalClickMonitor: Any?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        super.init()

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 400, height: 430)
        popover.contentViewController = NSHostingController(rootView: MenuBarRootView())
        popover.delegate = self

        if let button = statusItem.button {
            // Custom sandwich-with-waveform mark (vector PDF). Template-rendered so it
            // adapts to light/dark menu bars automatically.
            let image = NSImage(named: "MenuBarIcon")
            image?.isTemplate = true
            image?.size = NSSize(width: 19, height: 15.2)  // 30×24 PDF, scaled to menu-bar height
            button.image = image
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            installGlobalClickMonitor()
        }
    }

    private func installGlobalClickMonitor() {
        removeGlobalClickMonitor()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.popover.performClose(nil)
            }
        }
    }

    private func removeGlobalClickMonitor() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }

    // MARK: - NSPopoverDelegate

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in
            self.removeGlobalClickMonitor()
        }
    }
}
