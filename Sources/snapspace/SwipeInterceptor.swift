import CoreGraphics
import Foundation

/// Owns the lifecycle of a `CGEventTap` that will (eventually) detect
/// trackpad swipe gestures and translate them into Space switches.
///
/// Gesture-detection logic is intentionally stubbed for now — see the TODO in
/// `handle(proxy:type:event:)`. This class exists so the tap create / enable /
/// disable / teardown machinery (including auto re-enable on timeout) is in
/// place and compiling before the real detection lands.
final class SwipeInterceptor {
    private let engine: SwitchEngine
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Whether the tap is currently created and enabled.
    private(set) var isRunning: Bool = false

    init(engine: SwitchEngine) {
        self.engine = engine
    }

    // MARK: - Lifecycle

    /// Create the tap and add it to the current run loop. No-op if already running.
    func start() {
        guard eventTap == nil else {
            enable()
            return
        }

        // We listen for the gesture-bearing events. Detection is a TODO, so we
        // pass a broad-ish mask now; narrow it once detection is implemented.
        let mask: CGEventMask =
            (1 << CGEventType.scrollWheel.rawValue)

        // Trampoline `self` through the tap's userInfo pointer.
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let interceptor = Unmanaged<SwipeInterceptor>
                    .fromOpaque(refcon).takeUnretainedValue()
                return interceptor.handle(proxy: proxy, type: type, event: event)
            },
            userInfo: userInfo
        ) else {
            FileHandle.standardError.write(
                Data("[SwipeInterceptor] failed to create event tap (accessibility not granted?)\n".utf8)
            )
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)

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

    /// Fully remove the tap from the run loop and release it.
    func teardown() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        isRunning = false
    }

    // MARK: - Callback

    private func handle(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // The system disables a tap that takes too long or after certain
        // input events. Re-enable it so we keep receiving events.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            enable()
            return Unmanaged.passUnretained(event)
        }

        // TODO: Gesture detection lives here.
        //
        // Accumulate scroll/gesture phase + velocity, decide whether the user
        // is performing a horizontal three/four-finger swipe, and on a
        // committed swipe call:
        //
        //     try? engine.switchSpace(.left)  // or .right
        //
        // and return `nil` to swallow the originating event. For now we pass
        // every event through untouched.
        _ = engine
        return Unmanaged.passUnretained(event)
    }
}
