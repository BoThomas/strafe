import Foundation

/// The direction to move between macOS Spaces.
enum SwitchDirection {
    case left
    case right
}

/// Abstraction over the mechanism that actually moves between Spaces.
///
/// The real implementation (`GestureSwitchEngine`) posts synthetic
/// high-velocity dock-swipe gestures and is being specced separately.
/// Everything in this app is built against this protocol so the engine
/// can be swapped in without touching call sites.
protocol SwitchEngine {
    func switchSpace(_ direction: SwitchDirection) throws
}

/// No-op engine used during development. Logs the requested switch and returns.
/// Replace with `GestureSwitchEngine` once the gesture engine lands.
struct StubSwitchEngine: SwitchEngine {
    func switchSpace(_ direction: SwitchDirection) throws {
        let arrow = direction == .left ? "←" : "→"
        FileHandle.standardError.write(
            Data("[StubSwitchEngine] switchSpace(\(arrow) \(direction))\n".utf8)
        )
    }
}
