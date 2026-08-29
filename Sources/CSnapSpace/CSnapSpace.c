// CSnapSpace.c — implementation of the synthetic dock-swipe mechanism.
//
// Reverse-engineered from jurplel/InstantSpaceSwitcher (MIT). Every magic
// number here is documented in docs/SPEC.md §1–2. Treat the field indices and
// event-type values as version-fragile (SPEC §7).

#include "CSnapSpace.h"

#include <ApplicationServices/ApplicationServices.h>
#include <CoreGraphics/CGEventTypes.h>
#include <CoreFoundation/CoreFoundation.h>
#include <float.h>
#include <string.h>

// --- Private CGEventField indices (SPEC §1.2) -----------------------------
static const CGEventField kCGSEventTypeField           = (CGEventField)55;   // private CGSEventType selector
static const CGEventField kCGEventGestureHIDType       = (CGEventField)110;  // IOHIDEvent gesture type
static const CGEventField kCGEventGestureSwipeMotion   = (CGEventField)123;  // motion axis (horizontal=1)
static const CGEventField kCGEventGestureSwipeProgress = (CGEventField)124;  // gesture progress (double)
static const CGEventField kCGEventGestureSwipeVelocityX= (CGEventField)129;  // (double)
static const CGEventField kCGEventGestureSwipeVelocityY= (CGEventField)130;  // (double)
static const CGEventField kCGEventGesturePhase         = (CGEventField)132;  // CGSGesturePhase

// --- Type / enum constants (SPEC §1.3) ------------------------------------
static const uint32_t kIOHIDEventTypeDockSwipe = 23;   // written into field 110

enum {
    kCGSEventScrollWheel       = 22,
    kCGSEventZoom              = 28,
    kCGSEventGesture           = 29,
    kCGSEventDockControl       = 30,   // the dock-swipe type we synthesize + intercept
    kCGSEventFluidTouchGesture = 31,
};

typedef CF_ENUM(uint8_t, CGSGesturePhase) {
    kCGSGesturePhaseNone      = 0,
    kCGSGesturePhaseBegan     = 1,
    kCGSGesturePhaseChanged   = 2,
    kCGSGesturePhaseEnded     = 4,
    kCGSGesturePhaseCancelled = 8,
    kCGSGesturePhaseMayBegin  = 128,
};

typedef CF_ENUM(uint16_t, CGGestureMotion) {
    kCGGestureMotionHorizontal = 1,
};

// --- Weak-imported CGS symbols for space topology (SPEC §1.1) -------------
typedef int32_t  CGSConnectionID;
typedef uint64_t CGSSpaceID;
extern CFArrayRef  CGSCopyManagedDisplaySpaces(CGSConnectionID connection, CFStringRef display) __attribute__((weak_import));
extern CFStringRef CGSCopyActiveMenuBarDisplayIdentifier(CGSConnectionID connection) __attribute__((weak_import));
extern CGSConnectionID CGSMainConnectionID(void) __attribute__((weak_import));
extern CGSSpaceID  CGSGetActiveSpace(CGSConnectionID connection) __attribute__((weak_import));

bool snapspace_cgs_available(void) {
    return (&CGSMainConnectionID != NULL) &&
           (&CGSGetActiveSpace != NULL) &&
           (&CGSCopyManagedDisplaySpaces != NULL);
}

// --- Synthesis (SPEC §1.5) ------------------------------------------------
static bool post_dock_swipe(CGSGesturePhase phase, SnapSpaceDirection direction, double velocity) {
    const bool isRight = (direction == SnapSpaceDirectionRight);
    // Empirically, ±FLT_TRUE_MIN used in this way makes switching instant.
    const double progress = isRight ? (double)FLT_TRUE_MIN : -(double)FLT_TRUE_MIN;

    // Velocity of gesture based on speed setting.
    const double vel = isRight ? velocity : -velocity;

    CGEventRef ev = CGEventCreate(NULL);
    if (!ev) { return false; }
    CGEventSetIntegerValueField(ev, kCGSEventTypeField,            kCGSEventDockControl);
    CGEventSetIntegerValueField(ev, kCGEventGestureHIDType,        kIOHIDEventTypeDockSwipe);
    CGEventSetIntegerValueField(ev, kCGEventGesturePhase,          phase);
    CGEventSetDoubleValueField (ev, kCGEventGestureSwipeProgress,  progress);
    CGEventSetIntegerValueField(ev, kCGEventGestureSwipeMotion,    kCGGestureMotionHorizontal);
    CGEventSetDoubleValueField (ev, kCGEventGestureSwipeVelocityX, vel);
    CGEventSetDoubleValueField (ev, kCGEventGestureSwipeVelocityY, vel);
    CGEventPost(kCGSessionEventTap, ev);
    CFRelease(ev);
    return true;
}

bool snapspace_post_switch_gesture(SnapSpaceDirection direction, double velocity) {
    // Send three gesture events--began, changed, and ended.
    // If we only send two then mission control doesn't work.
    return post_dock_swipe(kCGSGesturePhaseBegan,   direction, velocity)
        && post_dock_swipe(kCGSGesturePhaseChanged, direction, velocity)
        && post_dock_swipe(kCGSGesturePhaseEnded,   direction, velocity);
}

// --- Topology (SPEC §6) ---------------------------------------------------
// Read the cursor display's UUID string.
static CFStringRef copy_cursor_display_identifier(void) {
    CGEventRef locEvent = CGEventCreate(NULL);
    if (!locEvent) { return NULL; }
    CGPoint loc = CGEventGetLocation(locEvent);
    CFRelease(locEvent);

    CGDirectDisplayID displays[16];
    uint32_t matching = 0;
    if (CGGetDisplaysWithPoint(loc, 16, displays, &matching) != kCGErrorSuccess || matching == 0) {
        return NULL;
    }
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(displays[0]);
    if (!uuid) { return NULL; }
    CFStringRef str = CFUUIDCreateString(NULL, uuid);
    CFRelease(uuid);
    return str; // caller releases
}

bool snapspace_get_space_info(SnapSpaceInfo *outInfo) {
    if (!outInfo) { return false; }
    if (!snapspace_cgs_available()) { return false; }

    memset(outInfo, 0, sizeof(*outInfo));

    CGSConnectionID conn = CGSMainConnectionID();

    CFStringRef targetDisplay = copy_cursor_display_identifier();
    // Fall back to the menu-bar display identifier if cursor lookup failed.
    if (!targetDisplay && (&CGSCopyActiveMenuBarDisplayIdentifier != NULL)) {
        targetDisplay = CGSCopyActiveMenuBarDisplayIdentifier(conn);
    }

    CFArrayRef displaySpaces = CGSCopyManagedDisplaySpaces(conn, NULL);
    if (!displaySpaces) {
        if (targetDisplay) { CFRelease(targetDisplay); }
        return false;
    }

    CFIndex displayCount = CFArrayGetCount(displaySpaces);
    if (displayCount == 0) {
        if (targetDisplay) { CFRelease(targetDisplay); }
        CFRelease(displaySpaces);
        return false;
    }

    // Pick the matching display dict; if the target isn't found, fall back to
    // the first display in the list (SPEC §6).
    CFDictionaryRef displayDict = NULL;
    if (targetDisplay) {
        for (CFIndex d = 0; d < displayCount; d++) {
            CFDictionaryRef candidate = (CFDictionaryRef)CFArrayGetValueAtIndex(displaySpaces, d);
            if (!candidate) { continue; }
            CFStringRef ident = (CFStringRef)CFDictionaryGetValue(candidate, CFSTR("Display Identifier"));
            if (ident && CFStringCompare(ident, targetDisplay, 0) == kCFCompareEqualTo) {
                displayDict = candidate;
                break;
            }
        }
    }
    if (!displayDict) {
        displayDict = (CFDictionaryRef)CFArrayGetValueAtIndex(displaySpaces, 0);
    }

    bool found = false;
    if (displayDict) {
        CFStringRef displayIdentifier = (CFStringRef)CFDictionaryGetValue(displayDict, CFSTR("Display Identifier"));

        CFArrayRef spaces = (CFArrayRef)CFDictionaryGetValue(displayDict, CFSTR("Spaces"));
        if (spaces) {
            CFIndex count = CFArrayGetCount(spaces);
            outInfo->spaceCount = (unsigned int)count;

            // Determine the current space id for this display.
            CGSSpaceID currentSpaceID = 0;
            CFDictionaryRef currentSpace = (CFDictionaryRef)CFDictionaryGetValue(displayDict, CFSTR("Current Space"));
            if (currentSpace) {
                CFNumberRef id64 = (CFNumberRef)CFDictionaryGetValue(currentSpace, CFSTR("id64"));
                if (id64) { CFNumberGetValue(id64, kCFNumberSInt64Type, &currentSpaceID); }
            }
            if (currentSpaceID == 0) {
                currentSpaceID = CGSGetActiveSpace(conn);
            }

            // Map the current space id to a zero-based index within this display.
            outInfo->currentIndex = 0;
            for (CFIndex s = 0; s < count; s++) {
                CFDictionaryRef spaceDict = (CFDictionaryRef)CFArrayGetValueAtIndex(spaces, s);
                if (!spaceDict) { continue; }
                CFNumberRef idNum = (CFNumberRef)CFDictionaryGetValue(spaceDict, CFSTR("id64"));
                CGSSpaceID sid = 0;
                if (idNum) { CFNumberGetValue(idNum, kCFNumberSInt64Type, &sid); }
                if (sid == currentSpaceID) {
                    outInfo->currentIndex = (unsigned int)s;
                    break;
                }
            }

            if (displayIdentifier) {
                CFStringGetCString(displayIdentifier, outInfo->displayID, sizeof(outInfo->displayID), kCFStringEncodingUTF8);
            }
            found = true;
        }
    }

    if (targetDisplay) { CFRelease(targetDisplay); }
    CFRelease(displaySpaces);
    return found;
}

// --- Event inspection helpers (SPEC §2.2, §2.3) ---------------------------
int64_t snapspace_event_cgs_type(CGEventRef event) {
    return CGEventGetIntegerValueField(event, kCGSEventTypeField);
}
int64_t snapspace_event_hid_type(CGEventRef event) {
    return CGEventGetIntegerValueField(event, kCGEventGestureHIDType);
}
int64_t snapspace_event_swipe_motion(CGEventRef event) {
    return CGEventGetIntegerValueField(event, kCGEventGestureSwipeMotion);
}
int64_t snapspace_event_gesture_phase(CGEventRef event) {
    return CGEventGetIntegerValueField(event, kCGEventGesturePhase);
}
double snapspace_event_swipe_progress(CGEventRef event) {
    return CGEventGetDoubleValueField(event, kCGEventGestureSwipeProgress);
}
double snapspace_event_swipe_velocity_x(CGEventRef event) {
    return CGEventGetDoubleValueField(event, kCGEventGestureSwipeVelocityX);
}
int64_t snapspace_event_source_pid(CGEventRef event) {
    return CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID);
}

// --- Constants (SPEC §1.3) ------------------------------------------------
int64_t snapspace_cgs_event_dock_control(void)    { return kCGSEventDockControl; }
int64_t snapspace_cgs_event_gesture(void)         { return kCGSEventGesture; }
int64_t snapspace_iohid_event_dock_swipe(void)    { return kIOHIDEventTypeDockSwipe; }
int64_t snapspace_gesture_motion_horizontal(void) { return kCGGestureMotionHorizontal; }
int64_t snapspace_gesture_phase_began(void)       { return kCGSGesturePhaseBegan; }
int64_t snapspace_gesture_phase_changed(void)     { return kCGSGesturePhaseChanged; }
int64_t snapspace_gesture_phase_ended(void)       { return kCGSGesturePhaseEnded; }
int64_t snapspace_gesture_phase_cancelled(void)   { return kCGSGesturePhaseCancelled; }

// Raw tap mask (SPEC §2.1): keyDown | keyUp | (1<<29) | (1<<30).
uint64_t snapspace_tap_event_mask(void) {
    return CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp)
        | (1ULL << kCGSEventGesture) | (1ULL << kCGSEventDockControl);
}

// --- Overlay / Exposé detection (SPEC §2.5) -------------------------------
// Heuristic: count Dock-owned windows at layers 18 and 20.
bool snapspace_is_expose_active(void) {
    CFArrayRef windows = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!windows) { return false; }

    int layer18Count = 0;
    int layer20Count = 0;
    CFIndex count = CFArrayGetCount(windows);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef win = (CFDictionaryRef)CFArrayGetValueAtIndex(windows, i);
        if (!win) { continue; }

        CFStringRef owner = (CFStringRef)CFDictionaryGetValue(win, kCGWindowOwnerName);
        if (!owner || CFStringCompare(owner, CFSTR("Dock"), 0) != kCFCompareEqualTo) {
            continue;
        }
        CFNumberRef layerNum = (CFNumberRef)CFDictionaryGetValue(win, kCGWindowLayer);
        if (!layerNum) { continue; }
        int layer = 0;
        CFNumberGetValue(layerNum, kCFNumberIntType, &layer);
        if (layer == 18) { layer18Count++; }
        else if (layer == 20) { layer20Count++; }
    }
    CFRelease(windows);

    // App Exposé: layer18Count > 0 && layer20Count > 0 && layer20Count <= layer18Count.
    // Mission Control: layer18Count > 0 && layer20Count > layer18Count.
    if (layer18Count > 0 && layer20Count > 0 && layer20Count <= layer18Count) { return true; }
    if (layer18Count > 0 && layer20Count > layer18Count) { return true; }
    return false;
}
