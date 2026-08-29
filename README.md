# SnapSpace

SnapSpace is a macOS menu-bar utility that makes switching between Spaces near-instant by posting synthetic high-velocity dock-swipe gestures. It runs as an accessory app (no dock icon), with global hotkeys (ctrl+opt+left / ctrl+opt+right) and a status-bar menu to enable/disable it and check permission state. A headless CLI mode is also available (`snapspace switch left|right`, `snapspace status`).

## Building

This is a SwiftPM executable package (no Xcode project). Build and run the raw binary during development with `swift build` and `swift run snapspace`. To produce a signed, distributable `SnapSpace.app` (LSUIElement, bundle id `dev.riley.snapspace`, ad-hoc signed), run `./Scripts/bundle.sh` — it builds a release arm64 binary, assembles the bundle under `build/SnapSpace.app`, and prints the final app path. Requires Xcode 26.6 / Swift 6.3 on Apple Silicon; minimum deployment target is macOS 15.

## Permissions

Posting gestures and running the event tap requires Accessibility permission (System Settings › Privacy & Security › Accessibility). The app prompts for this on first launch, and the menu shows whether it has been granted; `snapspace status` prints the same readout from the command line (including whether the private CoreGraphicsServices symbols resolved). The real gesture engine (`GestureSwitchEngine`) sits behind the `SwitchEngine` protocol; a logging `StubSwitchEngine` is kept alongside it for tests and dry runs.

## Credits

The core switching mechanism — synthesizing a high-velocity Dock-swipe `CGEvent` with near-zero progress, posting the began→changed→ended sequence, and intercepting/suppressing the user's real swipe via an active session event tap — is derived from [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher) by jurplel (MIT License, Copyright © 2026 jurplel), which served as the reference implementation for SnapSpace's low-level `CSnapSpace` shim.
