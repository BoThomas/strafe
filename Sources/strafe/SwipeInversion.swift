import Foundation

/// Whether trackpad swipes fire the opposite Space switch from the gesture's
/// natural direction.
///
/// Some users experience strafe's swipe mapping as inverted relative to the
/// native swipe it replaces (trackpad hardware, natural-scrolling settings,
/// and direction conventions can all differ per machine). This toggle flips
/// the gesture-derived direction just before the engine is asked to switch.
/// Keyboard shortcuts are deliberately unaffected — they name a direction
/// explicitly and have no gesture to be "natural" about.
enum SwipeInversion {
    /// The one `UserDefaults` key this setting uses, mirroring
    /// `TransitionSpeed.storageKey` so the menu-bar app and the CLI cannot
    /// drift apart on either the key or the fallback.
    static let storageKey = "invertSwipeDirection"

    /// `bool(forKey:)` returns `false` for an absent key, which is exactly the
    /// default we want: a fresh install keeps strafe's original mapping.
    static var stored: Bool {
        Preferences.store.bool(forKey: storageKey)
    }

    static func persist(_ inverted: Bool) {
        Preferences.store.set(inverted, forKey: storageKey)
    }
}
