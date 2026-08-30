import CoreGraphics
import Foundation
import CStrafe

/// Low-level synthetic event posting for the harness: the native Mission Control
/// keyboard switch and the probe left-clicks. Kept separate from the strafe
/// switch (which goes through `GestureSwitchEngine` / `strafe_post_switch_gesture`)
/// so the two "trigger" paths are obviously distinct in the measurement code.
enum EventPosting {
    /// Virtual key codes for the arrow keys (from Carbon `Events.h`).
    private static let kVKLeftArrow: CGKeyCode = 0x7B
    private static let kVKRightArrow: CGKeyCode = 0x7C
    /// Virtual key code for the left Control key (Carbon `Events.h`).
    private static let kVKControl: CGKeyCode = 0x3B

    /// Post a synthetic Ctrl+Arrow to trigger the default macOS "Move left/right
    /// a space" Mission Control shortcut. This reproduces the user-visible
    /// ANIMATED native switch (same transition as a real swipe), which is exactly
    /// what we want to measure against strafe.
    ///
    /// IMPORTANT (two things that were both wrong / fragile):
    ///
    /// 1. TAP LOCATION. The old code posted to `.cghidEventTap`; on this machine
    ///    that was a complete no-op — no `activeSpaceDidChange` ever fired and
    ///    every native right-trial timed out with all clicks landing on the source
    ///    window (we never left the space). The strafe path works because CStrafe
    ///    posts its gesture to `kCGSessionEventTap` (see CStrafe.c). We match that:
    ///    session-tap key events reach the WindowServer hotkey matcher that the
    ///    HID-tap path did not drive here.
    ///
    /// 2. MODIFIER STATE. The WindowServer hotkey matcher tracks the real
    ///    modifier-KEY state, not just the `.flags` on a lone arrow event. So we
    ///    press Control as an actual key first, send the arrow down/up carrying
    ///    the control flag, then release Control — the exact sequence a real
    ///    Ctrl+Arrow chord produces.
    ///
    /// This reproduces the user-visible ANIMATED native Mission Control switch,
    /// which is what we measure against strafe.
    static func postNativeSwitch(_ direction: SwitchDirection) {
        let keyCode = direction == .left ? kVKLeftArrow : kVKRightArrow
        let source = CGEventSource(stateID: .hidSystemState)
        let tap: CGEventTapLocation = .cgSessionEventTap

        // Control key DOWN (modifier press).
        guard let ctrlDown = CGEvent(
            keyboardEventSource: source, virtualKey: kVKControl, keyDown: true)
        else { return }
        ctrlDown.flags = .maskControl
        ctrlDown.post(tap: tap)

        // Arrow DOWN then UP, both carrying the control flag so the chord matches.
        if let arrowDown = CGEvent(
            keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            arrowDown.flags = .maskControl
            arrowDown.post(tap: tap)
        }
        if let arrowUp = CGEvent(
            keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            arrowUp.flags = .maskControl
            arrowUp.post(tap: tap)
        }

        // Control key UP (modifier release).
        if let ctrlUp = CGEvent(
            keyboardEventSource: source, virtualKey: kVKControl, keyDown: false) {
            ctrlUp.flags = []
            ctrlUp.post(tap: tap)
        }
    }

    /// Post one left-click (mouseDown+mouseUp pair) at a global CG point. Used as
    /// the interactivity probe: we spam these at the destination screen center
    /// and the destination window records when the first one is delivered.
    ///
    /// Reuses a single `CGEventSource`; the two events per call are unavoidable
    /// allocations, but the probe cadence (every 4 ms) makes that negligible and
    /// correctness (a real, deliverable click) matters more here.
    static func postProbeClick(at point: CGPoint, source: CGEventSource?) {
        guard let down = CGEvent(
            mouseEventSource: source, mouseType: .leftMouseDown,
            mouseCursorPosition: point, mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: source, mouseType: .leftMouseUp,
            mouseCursorPosition: point, mouseButton: .left
        ) else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
