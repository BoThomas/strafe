import CoreGraphics
import Foundation
import CSnapSpace

/// Owns the `CGEventTap` that detects the user's real 3-finger horizontal
/// space-swipe, suppresses it, and fires the engine's instant switch instead
/// (SPEC §2).
///
/// Concurrency: the tap source is installed on the **main** run loop in
/// `kCFRunLoopCommonModes` (SPEC §2.1), so `eventTapCallback` always runs on
/// the main thread. All mutable state (`swipeTracking`, `swipeFired`,
/// `isRunning`) is therefore touched only from that single run loop and needs
/// no locking. The class is `@unchecked Sendable` because the C callback
/// reaches it through an opaque pointer; that confinement invariant is what
/// makes the unchecked conformance sound.
final class SwipeInterceptor: @unchecked Sendable {
    private let engine: SwitchEngine
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Whether the tap is currently created and enabled.
    private(set) var isRunning: Bool = false

    /// Whether interception is active. When false the callback passes every
    /// event through untouched (SPEC §2.2: "only acts when swipeOverrideEnabled").
    var overrideEnabled: Bool = true

    // MARK: - State machine (SPEC §2.3). Main-run-loop confined.
    private var swipeTracking = false
    private var swipeFired = false

    init(engine: SwitchEngine) {
        self.engine = engine
    }

    // MARK: - Lifecycle

    /// Create the tap and add it to the main run loop. No-op if already running.
    func start() {
        guard eventTap == nil else {
            enable()
            return
        }

        // SPEC §2.1: keyDown | keyUp | (1<<29) | (1<<30), sourced from C so the
        // raw private type bits are single-sourced with the synthesizer.
        let mask = CGEventMask(snapspace_tap_event_mask())

        // Trampoline `self` through the tap's userInfo pointer.
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,          // SPEC §2.1: same location as posting
            place: .headInsertEventTap,       // head of the chain: see events before WindowServer
            options: .defaultTap,             // active tap: returning nil suppresses
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let interceptor = Unmanaged<SwipeInterceptor>
                    .fromOpaque(refcon).takeUnretainedValue()
                return interceptor.handle(type: type, event: event)
            },
            userInfo: userInfo
        ) else {
            FileHandle.standardError.write(
                Data("[SwipeInterceptor] failed to create event tap (accessibility not granted?)\n".utf8)
            )
            return
        }

        // SPEC §2.1: source added to the MAIN run loop in common modes.
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        self.eventTap = tap
        self.runLoopSource = source
        enable()
    }

    /// Enable the tap if it exists.
    func enable() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        isRunning = true
    }

    /// Disable the tap without tearing it down (can be re-enabled cheaply).
    func disable() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: false)
        isRunning = false
    }

    /// Fully remove the tap from the main run loop and release it.
    func teardown() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        isRunning = false
        swipeTracking = false
        swipeFired = false
    }

    // MARK: - Callback (runs on the main run loop)

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passthrough = Unmanaged.passUnretained(event)

        // SPEC §2.3 / §7.5: the system auto-disables the tap on timeout or
        // heavy user input. Re-enable and pass the event through, else the
        // override silently dies.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return passthrough
        }

        // Only act when interception is on (SPEC §2.2).
        guard overrideEnabled else { return passthrough }

        // Read the private CGSEventType (field 55). We only care about the
        // dock-control swipe and its companion gesture events.
        let cgsType = snapspace_event_cgs_type(event)
        let dockControl = snapspace_cgs_event_dock_control()
        let gesture = snapspace_cgs_event_gesture()

        guard cgsType == dockControl || cgsType == gesture else {
            return passthrough
        }

        // SPEC §2.2 step 3: real HID gestures originate in the kernel with
        // source pid == 0. Synthetic events (ours + any other app's) have a
        // nonzero pid — pass them through so we don't re-trap our own posts.
        if snapspace_event_source_pid(event) != 0 {
            return passthrough
        }

        // Companion gesture events (type 29) are dropped while tracking (SPEC §2.3).
        if cgsType == gesture {
            return swipeTracking ? nil : passthrough
        }

        // From here: a real (pid 0) dock-control event.
        // SPEC §2.2 step 4: require a horizontal dock swipe; anything else
        // (vertical / App Exposé) passes through untouched.
        guard snapspace_event_hid_type(event) == snapspace_iohid_event_dock_swipe(),
              snapspace_event_swipe_motion(event) == snapspace_gesture_motion_horizontal()
        else {
            return passthrough
        }

        // SPEC §2.3 state machine, driven by the gesture phase (field 132).
        let phase = snapspace_event_gesture_phase(event)

        if phase == snapspace_gesture_phase_began() {
            // Let real gestures through while an overlay (Exposé) is up (SPEC §2.5).
            if snapspace_is_expose_active() { return passthrough }
            swipeTracking = true
            swipeFired = false
            return nil  // SUPPRESS the real 'began'

        } else if phase == snapspace_gesture_phase_changed() {
            guard swipeTracking else { return passthrough }
            if !swipeFired {
                let progress = snapspace_event_swipe_progress(event)
                if progress != 0.0 {
                    // Direction is the sign of progress; fire as soon as known.
                    let dir: SwitchDirection = progress > 0 ? .right : .left
                    swipeFired = true
                    try? engine.switchSpace(dir)
                }
            }
            return nil  // SUPPRESS

        } else if phase == snapspace_gesture_phase_ended() {
            guard swipeTracking else { return passthrough }
            if !swipeFired {
                // Fallback: derive direction from the end velocity's sign.
                let velocity = snapspace_event_swipe_velocity_x(event)
                if velocity != 0.0 {
                    let dir: SwitchDirection = velocity > 0 ? .right : .left
                    swipeFired = true
                    try? engine.switchSpace(dir)
                }
            }
            swipeTracking = false
            swipeFired = false
            return nil  // SUPPRESS

        } else if phase == snapspace_gesture_phase_cancelled() {
            swipeTracking = false
            swipeFired = false
            return nil

        } else {
            // Any other phase (mayBegin/none): suppress only while tracking.
            return swipeTracking ? nil : passthrough
        }
    }
}
