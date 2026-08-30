// CStrafe.h — low-level CoreGraphics gesture synthesis + inspection shim.
//
// This C target owns every undocumented magic number and private CGS symbol so
// the Swift side never has to touch @_silgen_name or raw CGEventField indices.
// The mechanism is an independent reimplementation of the technique from
// jurplel/InstantSpaceSwitcher (MIT); see docs/SPEC.md for the field-by-field
// derivation.

#ifndef CSTRAFE_H
#define CSTRAFE_H

#include <stdbool.h>
#include <stdint.h>
#include <ApplicationServices/ApplicationServices.h>

#ifdef __cplusplus
extern "C" {
#endif

// Direction of a single-step space switch.
typedef enum {
    StrafeDirectionLeft  = 0,  // previous space
    StrafeDirectionRight = 1,  // next space
} StrafeDirection;

// Topology for one display, filled by strafe_get_space_info().
typedef struct {
    unsigned int currentIndex;   // zero-based index of the active space on this display
    unsigned int spaceCount;     // number of spaces on this display
    char displayID[128];         // display UUID string, used as the prediction-dictionary key
} StrafeInfo;

// --- Capability check (SPEC §1.1, §6) -------------------------------------
// True iff the weak-imported CGS symbols resolved at load time. When false,
// topology can't be read (bounds guard degrades) but synthesis still works.
bool strafe_cgs_available(void);

// --- Synthesis (SPEC §1.4, §1.5) ------------------------------------------
// Post one instant single-step dock swipe: began -> changed -> ended, all
// immediately with no delay, to kCGSessionEventTap. Returns false only if an
// event could not be created. `velocity` is the gesture speed magnitude
// (default 2000.0 == "instant"); sign is applied internally from `direction`.
bool strafe_post_switch_gesture(StrafeDirection direction, double velocity);

// --- Topology (SPEC §6) ---------------------------------------------------
// Fill `outInfo` for the display under the cursor. Returns false if the CGS
// symbols are unavailable or topology could not be read.
bool strafe_get_space_info(StrafeInfo *outInfo);

// --- Event inspection helpers for the interceptor (SPEC §2.2, §2.3) -------
// These wrap CGEventGet*ValueField with the private field indices so the Swift
// interceptor never hard-codes a magic number.
int64_t strafe_event_cgs_type(CGEventRef event);      // field 55  -> CGSEventType
int64_t strafe_event_hid_type(CGEventRef event);      // field 110 -> IOHIDEventType
int64_t strafe_event_swipe_motion(CGEventRef event);  // field 123 -> motion axis
int64_t strafe_event_gesture_phase(CGEventRef event); // field 132 -> CGSGesturePhase
double  strafe_event_swipe_progress(CGEventRef event);// field 124 -> progress (double)
double  strafe_event_swipe_velocity_x(CGEventRef event); // field 129 -> velocityX (double)
int64_t strafe_event_source_pid(CGEventRef event);    // kCGEventSourceUnixProcessID

// --- Constants the interceptor compares against (SPEC §1.3) ---------------
// Exposed as functions to keep the enum values single-sourced in C.
int64_t strafe_cgs_event_dock_control(void);    // 30
int64_t strafe_cgs_event_gesture(void);         // 29
int64_t strafe_iohid_event_dock_swipe(void);    // 23
int64_t strafe_gesture_motion_horizontal(void); // 1
int64_t strafe_gesture_phase_began(void);       // 1
int64_t strafe_gesture_phase_changed(void);     // 2
int64_t strafe_gesture_phase_ended(void);       // 4
int64_t strafe_gesture_phase_cancelled(void);   // 8

// Raw event mask the tap must register: the two private gesture types by raw
// bit shift (1<<29)|(1<<30). Key events are deliberately NOT masked — see the
// KEY-EVENTS-IN-MASK DETERMINATION at the definition in CStrafe.c.
uint64_t strafe_tap_event_mask(void);

// --- Overlay / Exposé passthrough (SPEC §2.5) -----------------------------
// True when App Exposé or Mission Control is up (Dock windows at layers 18/20).
bool strafe_is_expose_active(void);

#ifdef __cplusplus
}
#endif

#endif /* CSTRAFE_H */
