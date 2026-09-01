import AppKit

/// The menu-bar controller. Owns the `NSStatusItem` and wires its menu to the
/// interceptor / permission state. LSUIElement is set in the bundled
/// Info.plist so there is no dock icon.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let interceptor: SwipeInterceptor
    private let engine: GestureSwitchEngine?

    private let toggleItem = NSMenuItem(
        title: "Enable", action: #selector(toggleEnabled), keyEquivalent: ""
    )
    private let speedItem = NSMenuItem(
        title: "Transition speed", action: nil, keyEquivalent: ""
    )
    private var speedItems: [NSMenuItem] = []
    private let accessibilityItem = NSMenuItem(
        title: "Accessibility granted: —", action: nil, keyEquivalent: ""
    )

    init(interceptor: SwipeInterceptor, engine: GestureSwitchEngine? = nil) {
        self.interceptor = interceptor
        self.engine = engine
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "rectangle.on.rectangle",
                accessibilityDescription: "strafe"
            )
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self

        toggleItem.target = self
        accessibilityItem.isEnabled = false

        engine?.setTransitionSpeed(TransitionSpeed.stored)

        menu.addItem(toggleItem)
        buildSpeedSubmenu(into: menu)
        menu.addItem(accessibilityItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit strafe", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        refresh()
    }

    /// The "Transition speed" submenu: one checkable item per preset.
    ///
    /// Hidden entirely when there is no real engine (stub engine / no
    /// Accessibility), because nothing it offers would take effect.
    private func buildSpeedSubmenu(into menu: NSMenu) {
        guard engine != nil else { return }

        let submenu = NSMenu()
        for speed in TransitionSpeed.allCases {
            let item = NSMenuItem(
                title: speed.title, action: #selector(selectSpeed(_:)), keyEquivalent: ""
            )
            item.target = self
            item.tag = speed.rawValue
            submenu.addItem(item)
            speedItems.append(item)
        }

        speedItem.submenu = submenu
        menu.addItem(speedItem)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        // Toggle interception. The tap stays alive (so it can re-enable itself
        // after a system auto-disable); `overrideEnabled` gates whether real
        // swipes are actually suppressed and replaced (SPEC §2.2).
        interceptor.overrideEnabled.toggle()
        if interceptor.overrideEnabled && !interceptor.isRunning {
            interceptor.start()
        }
        refresh()
    }

    /// Pick a transition speed. Persisted so the choice survives a relaunch.
    @objc private func selectSpeed(_ sender: NSMenuItem) {
        let speed = TransitionSpeed.from(rawValue: sender.tag)
        engine?.setTransitionSpeed(speed)
        speed.persist()
        refresh()
    }

    @objc private func quit() {
        interceptor.teardown()
        NSApp.terminate(nil)
    }

    // MARK: - State

    private func refresh() {
        toggleItem.title = interceptor.overrideEnabled ? "Disable" : "Enable"
        if let engine {
            let current = engine.transitionSpeed
            speedItem.title = "Transition speed: \(current.title)"
            for item in speedItems { item.state = item.tag == current.rawValue ? .on : .off }
        }
        let granted = Permissions.isAccessibilityGranted
        accessibilityItem.title = "Accessibility granted: \(granted ? "yes" : "no")"
    }
}
