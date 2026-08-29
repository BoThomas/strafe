import AppKit

/// The menu-bar controller. Owns the `NSStatusItem` and wires its menu to the
/// interceptor / permission state. LSUIElement is set in the bundled
/// Info.plist so there is no dock icon.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let interceptor: SwipeInterceptor

    private let toggleItem = NSMenuItem(
        title: "Enable", action: #selector(toggleEnabled), keyEquivalent: ""
    )
    private let accessibilityItem = NSMenuItem(
        title: "Accessibility granted: —", action: nil, keyEquivalent: ""
    )

    init(interceptor: SwipeInterceptor) {
        self.interceptor = interceptor
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "rectangle.on.rectangle",
                accessibilityDescription: "SnapSpace"
            )
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self

        toggleItem.target = self
        accessibilityItem.isEnabled = false

        menu.addItem(toggleItem)
        menu.addItem(accessibilityItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit SnapSpace", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        refresh()
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        if interceptor.isRunning {
            interceptor.disable()
        } else {
            interceptor.start()
        }
        refresh()
    }

    @objc private func quit() {
        interceptor.teardown()
        NSApp.terminate(nil)
    }

    // MARK: - State

    private func refresh() {
        toggleItem.title = interceptor.isRunning ? "Disable" : "Enable"
        let granted = Permissions.isAccessibilityGranted
        accessibilityItem.title = "Accessibility granted: \(granted ? "yes" : "no")"
    }
}
