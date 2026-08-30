import Foundation
import CStrafe

/// The direction to move between macOS Spaces.
enum SwitchDirection {
    case left
    case right

    var cDirection: StrafeDirection {
        self == .left ? StrafeDirectionLeft : StrafeDirectionRight
    }
}

/// Error surfaced when a synthetic switch could not be produced.
enum SwitchEngineError: Error {
    /// The bounds guard blocked a swipe past the first/last space (SPEC §2.4).
    case atEdge
    /// `CGEventCreate` failed — no event could be posted.
    case postFailed
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

/// No-op engine used during development, tests, and dry runs. Logs the
/// requested switch and returns. Kept around as a safe stand-in for the real
/// engine (e.g. when Accessibility isn't granted, or in unit tests).
struct StubSwitchEngine: SwitchEngine {
    func switchSpace(_ direction: SwitchDirection) throws {
        let arrow = direction == .left ? "←" : "→"
        FileHandle.standardError.write(
            Data("[StubSwitchEngine] switchSpace(\(arrow) \(direction))\n".utf8)
        )
    }
}

/// The real engine: posts a synthetic high-velocity dock-swipe gesture (SPEC
/// §1) to jump to the neighboring Space instantly.
///
/// Concurrency: `switchSpace` may be called from the main actor (hotkeys, CLI)
/// or from the event-tap run loop (the interceptor). All mutable prediction
/// state is guarded by an `NSLock`, so the type is safe to share across those
/// contexts; the actual CGEvent posting (`strafe_post_switch_gesture`) is a
/// stateless C call.
final class GestureSwitchEngine: SwitchEngine, @unchecked Sendable {
    /// Gesture velocity magnitude. 2000.0 is the "Instant" preset — the only
    /// value that truly skips the slide animation (SPEC §1.4, §5). Lower values
    /// keep a (shortened) animation.
    static let instantVelocity: Double = 2000.0

    private let velocity: Double

    /// Per-display predicted current-space index, keyed by display UUID
    /// (SPEC §2.4). Avoids rebounding off the laggy live active-space query.
    private let lock = NSLock()
    private var predictions: [String: UInt32] = [:]

    init(velocity: Double = GestureSwitchEngine.instantVelocity) {
        self.velocity = velocity
    }

    /// Whether the private CGS topology symbols resolved (SPEC §1.1, §6).
    var cgsAvailable: Bool { strafe_cgs_available() }

    func switchSpace(_ direction: SwitchDirection) throws {
        // Read live topology once. If CGS symbols are unavailable we can't do
        // bounds/prediction bookkeeping — fall back to posting unconditionally.
        var info = StrafeInfo()
        let haveInfo = strafe_get_space_info(&info)

        if haveInfo {
            let displayID = withUnsafeBytes(of: info.displayID) { raw -> String in
                let ptr = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
                return String(cString: ptr)
            }

            lock.lock()
            let current = predictions[displayID] ?? info.currentIndex

            // Bounds guard (SPEC §2.4): never swipe past the first/last space.
            if direction == .left {
                if current == 0 { lock.unlock(); throw SwitchEngineError.atEdge }
            } else {
                if current + 1 >= info.spaceCount { lock.unlock(); throw SwitchEngineError.atEdge }
            }

            let target: UInt32 = direction == .left ? current - 1 : current + 1
            lock.unlock()

            guard strafe_post_switch_gesture(direction.cDirection, velocity) else {
                throw SwitchEngineError.postFailed
            }

            // Advance the optimistic prediction only after a successful post.
            lock.lock()
            predictions[displayID] = target
            lock.unlock()
        } else {
            guard strafe_post_switch_gesture(direction.cDirection, velocity) else {
                throw SwitchEngineError.postFailed
            }
        }
    }

    /// Reset all predictions to live CGS data. Call on
    /// `NSWorkspace.activeSpaceDidChangeNotification` (SPEC §2.4, §5) so rapid
    /// repeated swipes don't overshoot bounds or snap back off a stale index.
    func resetPredictions() {
        lock.lock()
        predictions.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
