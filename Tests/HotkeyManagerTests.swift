import AppKit

// Compile the production manager with an isolated preferences domain and
// replacement Carbon registration functions. No real shortcuts are captured.
enum Preferences {
    static let domain = CommandLine.arguments[1]
    nonisolated(unsafe) static let store = UserDefaults(suiteName: domain)!
}
enum SwitchDirection { case left, right }
protocol SwitchEngine { func switchSpace(_ direction: SwitchDirection) throws }
struct TestEngine: SwitchEngine {
    func switchSpace(_ direction: SwitchDirection) throws {
        preconditionFailure("No keyboard events should be delivered during these tests")
    }
}
@_silgen_name("test_active_hotkeys") private func activeHotkeys() -> UInt32
@_silgen_name("test_registration_count") private func registrationCount() -> UInt32

@main struct HotkeyManagerTests {
    @MainActor static func main() {
        let mode = CommandLine.arguments[2]
        if mode == "on" || mode == "off" {
            HotkeyManager.persist(enabled: mode == "on")
            return
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let manager = HotkeyManager(engine: TestEngine())
        manager.start()
        defer { manager.stop() }
        if mode == "selftest" {
            precondition(HotkeyManager.enabled && activeHotkeys() == 2)
            manager.start()
            manager.applyStoredState()
            manager.applyStoredState()
            precondition(activeHotkeys() == 2 && registrationCount() == 2)
            HotkeyManager.persist(enabled: false)
            manager.applyStoredState()
            precondition(activeHotkeys() == 0)
            manager.applyStoredState()
            precondition(activeHotkeys() == 0)
            HotkeyManager.persist(enabled: true)
            manager.applyStoredState()
            precondition(activeHotkeys() == 2 && registrationCount() == 4)
            manager.stop()
            precondition(activeHotkeys() == 0)
            manager.start()
            precondition(activeHotkeys() == 2)
            print("PASS: default, repeated enable/disable, and restart")
            return
        }
        precondition(mode == "listen")
        var previous = activeHotkeys()
        print("ACTIVE \(previous)"); fflush(stdout)
        let deadline = Date(timeIntervalSinceNow: 12)
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in }
        RunLoop.main.add(timer, forMode: .default)
        defer { timer.invalidate() }
        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            let current = activeHotkeys()
            if current != previous {
                print("ACTIVE \(current)"); fflush(stdout)
                previous = current
            }
        }
    }
}
