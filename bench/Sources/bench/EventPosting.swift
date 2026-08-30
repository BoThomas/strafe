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

    /// Post a synthetic Ctrl+Arrow keyDown+keyUp to the HID event tap — the
    /// default macOS "Move left/right a space" Mission Control shortcut. This
    /// reproduces the user-visible ANIMATED native switch (same transition as a
    /// real swipe), which is exactly what we want to measure against strafe.
    ///
    /// Posted to `.cghidEventTap` so it enters as though from the keyboard HID,
    /// ahead of the session tap, the way a real keypress would.
    static func postNativeSwitch(_ direction: SwitchDirection) {
        let keyCode = direction == .left ? kVKLeftArrow : kVKRightArrow
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = .maskControl
        up.flags = .maskControl
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
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
