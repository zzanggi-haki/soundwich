import SwiftUI
import AppKit

/// Native NSPopUpButton wrapper for picking an output device.
///
/// SwiftUI's `Menu` rebuilds its AppKit menu from the SwiftUI hierarchy on every
/// open, which makes the dropdown visibly stutter inside a popover. NSPopUpButton
/// is the same control System Settings uses — instant open, uniform sizing,
/// built-in tail truncation.
struct DevicePopUpButton: NSViewRepresentable {
    let devices: [AudioDevice]
    let selectedUID: String?
    let placeholder: String
    let showClear: Bool
    let onSelect: (AudioDevice) -> Void
    let onClear: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .regular
        button.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        button.lineBreakMode = .byTruncatingTail
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self

        // Rebuilding the NSMenu on every SwiftUI render makes opening the popup
        // stutter (and can glitch a menu that is currently open). Only rebuild when
        // the actual content changed; otherwise just sync the selection.
        let hasValidSelection = selectedUID != nil && devices.contains { $0.uid == selectedUID }
        let signature = devices.map { "\($0.uid)|\($0.name)" }.joined(separator: ",")
            + "#\(showClear)#\(placeholder)#\(hasValidSelection)"

        if context.coordinator.menuSignature != signature {
            context.coordinator.menuSignature = signature
            rebuildMenu(button, coordinator: context.coordinator, hasValidSelection: hasValidSelection)
        }

        applySelection(button)
    }

    private func rebuildMenu(_ button: NSPopUpButton, coordinator: Coordinator, hasValidSelection: Bool) {
        let menu = NSMenu()

        if !hasValidSelection {
            // Placeholder shown as the button title until something is picked.
            let item = NSMenuItem(title: placeholder, action: nil, keyEquivalent: "")
            item.tag = -2
            item.isEnabled = false
            menu.addItem(item)
        }

        for (index, device) in devices.enumerated() {
            let item = NSMenuItem(title: device.name,
                                  action: #selector(Coordinator.didSelect(_:)),
                                  keyEquivalent: "")
            item.target = coordinator
            item.tag = index
            menu.addItem(item)
        }

        if showClear {
            menu.addItem(.separator())
            let clear = NSMenuItem(title: "제어 해제",
                                   action: #selector(Coordinator.didSelect(_:)),
                                   keyEquivalent: "")
            clear.target = coordinator
            clear.tag = -1
            menu.addItem(clear)
        }

        button.menu = menu
    }

    private func applySelection(_ button: NSPopUpButton) {
        if let selectedUID,
           let index = devices.firstIndex(where: { $0.uid == selectedUID }),
           let item = button.menu?.items.first(where: { $0.tag == index }) {
            if button.selectedItem !== item {
                button.select(item)
            }
        } else if button.indexOfSelectedItem != 0 {
            button.selectItem(at: 0) // placeholder
        }
    }

    final class Coordinator: NSObject {
        var parent: DevicePopUpButton
        var menuSignature: String?

        init(_ parent: DevicePopUpButton) {
            self.parent = parent
        }

        @objc func didSelect(_ sender: NSMenuItem) {
            if sender.tag == -1 {
                parent.onClear()
            } else if sender.tag >= 0, sender.tag < parent.devices.count {
                parent.onSelect(parent.devices[sender.tag])
            }
        }
    }
}
