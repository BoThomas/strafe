import AppKit

// MARK: - Entry point
//
// With CLI args -> headless mode (call the engine directly, print, exit).
// With no args  -> start the menu-bar NSApplication.

/// The engine seam. Swap `StubSwitchEngine()` for `GestureSwitchEngine()`
/// once the real engine lands.
let engine: SwitchEngine = StubSwitchEngine()

let args = Array(CommandLine.arguments.dropFirst())

if args.isEmpty {
    runMenuBarApp(engine: engine)
} else {
    exit(runCLI(args, engine: engine))
}

// MARK: - CLI mode

func runCLI(_ args: [String], engine: SwitchEngine) -> Int32 {
    switch args.first {
    case "switch":
        guard args.count >= 2 else {
            FileHandle.standardError.write(Data("usage: snapspace switch left|right\n".utf8))
            return 2
        }
        let direction: SwitchDirection
        switch args[1] {
        case "left": direction = .left
        case "right": direction = .right
        default:
            FileHandle.standardError.write(Data("unknown direction '\(args[1])' (expected left|right)\n".utf8))
            return 2
        }
        do {
            try engine.switchSpace(direction)
            return 0
        } catch {
            FileHandle.standardError.write(Data("switch failed: \(error)\n".utf8))
            return 1
        }

    case "status":
        // No live tap in CLI mode, so report tap as not running.
        Permissions.printStatus(tapRunning: false)
        return 0

    default:
        FileHandle.standardError.write(Data("""
        snapspace — near-instant macOS Spaces switching

        usage:
          snapspace                     start the menu-bar app
          snapspace switch left|right   switch space once and exit
          snapspace status              print accessibility / tap status

        """.utf8))
        return 2
    }
}

// MARK: - Menu-bar app mode

@MainActor
func runMenuBarApp(engine: SwitchEngine) {
    let app = NSApplication.shared
    // LSUIElement is also set in Info.plist; set it here so running the raw
    // binary (unbundled) still behaves as an accessory with no dock icon.
    app.setActivationPolicy(.accessory)

    let delegate = AppDelegate(engine: engine)
    app.delegate = delegate
    app.run()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine: SwitchEngine
    private var interceptor: SwipeInterceptor!
    private var hotkeys: HotkeyManager!
    private var statusItem: StatusItemController!

    init(engine: SwitchEngine) {
        self.engine = engine
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prompt for accessibility up front so the tap can be created.
        Permissions.checkAccessibility(prompt: true)

        interceptor = SwipeInterceptor(engine: engine)
        statusItem = StatusItemController(interceptor: interceptor)

        hotkeys = HotkeyManager(engine: engine)
        hotkeys.register()

        interceptor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        interceptor?.teardown()
        hotkeys?.unregister()
    }
}
