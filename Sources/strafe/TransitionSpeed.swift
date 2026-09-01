import Foundation
import CStrafe

/// How much animation a swipe-driven Space switch gets.
///
/// **Which axis this is, and why.** There are two plausible ways to slow a
/// synthetic switch down, and only one of them works. The instant path pins
/// progress at ±FLT_TRUE_MIN and fires began/changed/ended back-to-back with a
/// very high velocity (`GestureSwitchEngine.instantVelocity`); the obvious knob
/// is therefore "lower the velocity". That was measured and rejected — see the
/// table below. What actually controls the animation is the **progress ramp**:
/// how far progress travels, over how long, before `ended` lands. A gesture
/// whose progress climbs 0 → 0.35 across ~120 ms with a moderate end velocity
/// is shaped like a human swipe, so the WindowServer runs its standard slide.
///
/// Measured on this hardware (`bench sweep`, n=6 per shape, median ms from post
/// to CGS reporting the new Space — a discriminator, not an animation duration):
///
///     zero-progress flick, v=40     841 ms   switched 5/6   ← unreliable
///     zero-progress flick, v=50     770 ms
///     zero-progress flick, v=60     559 ms
///     zero-progress flick, v=80      77 ms   ← cliff, not a ramp
///     zero-progress flick, v=2000    40 ms   (the shipped instant path)
///     progress ramp,  30 ms          80 ms
///     progress ramp,  60 ms         107 ms
///     progress ramp, 120 ms         171 ms   ≈ macOS's own animated switch
///
/// The velocity axis is neither monotonic-in-a-useful-way nor reliable at the
/// slow end; the ramp axis is evenly spaced and switched 6/6 at every duration.
/// So the presets below are ramp durations.
///
/// 120 ms is deliberately the slowest option: that is already macOS's native
/// speed, and there is no reason for strafe to be *slower* than the thing it
/// replaces. Anyone who wants slower can just turn strafe off.
enum TransitionSpeed: Int, CaseIterable {
    /// The original behaviour: a zero-progress high-velocity flick. No slide.
    case instant = 0
    case quick   = 1
    case smooth  = 2
    /// Indistinguishable from not running strafe at all. Kept as a reference.
    case fullSlide = 3

    /// Menu title. Carries the measured cost so the choice is an informed one
    /// rather than four adjectives.
    var title: String {
        switch self {
        case .instant:   return "Instant (~40 ms)"
        case .quick:     return "Quick (~80 ms)"
        case .smooth:    return "Smooth (~110 ms)"
        case .fullSlide: return "Full slide (~170 ms, macOS default)"
        }
    }

    /// Stable identifier for `strafe speed <name>`. Unlike `title`, this never
    /// changes when the measured timings are re-taken on other hardware.
    var name: String {
        switch self {
        case .instant:   return "instant"
        case .quick:     return "quick"
        case .smooth:    return "smooth"
        case .fullSlide: return "full"
        }
    }

    init?(name: String) {
        guard let match = TransitionSpeed.allCases.first(where: { $0.name == name })
        else { return nil }
        self = match
    }

    /// Ramp duration in milliseconds, or `nil` for the instant flick.
    var rampMilliseconds: Double? {
        switch self {
        case .instant:   return nil
        case .quick:     return 30
        case .smooth:    return 60
        case .fullSlide: return 120
        }
    }

    /// Ramp shape constants, held fixed across the presets so duration is the
    /// only variable. These are the values `bench` validated as producing the
    /// OS's standard slide; peak progress well under 1.0 is enough because the
    /// end velocity is what commits the switch.
    static let rampSteps = 8
    static let rampPeakProgress: Double = 0.35
    /// Moderate end velocity (order 100–400). Large enough for the WindowServer
    /// to complete the switch, small enough that it animates rather than flicks.
    static let rampEndVelocity: Double = 130.0

    static let `default`: TransitionSpeed = .instant

    static func from(rawValue: Int) -> TransitionSpeed {
        TransitionSpeed(rawValue: rawValue) ?? .default
    }

    // MARK: - Persistence

    /// The one `UserDefaults` key this setting uses. Kept here so the menu-bar
    /// app and the CLI cannot drift apart on either the key or the fallback.
    static let storageKey = "transitionSpeed"

    /// The persisted preset. An absent key — a fresh install — means `default`,
    /// so strafe's out-of-the-box behaviour is unchanged by this feature.
    /// `object(forKey:)` rather than `integer(forKey:)` so "never set" is
    /// distinguishable from a stored 0.
    static var stored: TransitionSpeed {
        guard let raw = Preferences.store.object(forKey: storageKey) as? Int else {
            return .default
        }
        return from(rawValue: raw)
    }

    func persist() {
        Preferences.store.set(rawValue, forKey: TransitionSpeed.storageKey)
    }
}
