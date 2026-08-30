# strafe

When you swipe between macOS Spaces with three fingers, the system plays a
slide animation and queues your input until the transition finishes — roughly
half a second of dead time on every switch, during which clicks and keystrokes
go nowhere. strafe removes that dead time. It intercepts the swipe and jumps
straight to the neighboring Space, so the switch is instant and the new Space is
interactive immediately.

It runs as a menu-bar accessory (no Dock icon), works with your normal 3-finger
swipe, and adds keyboard shortcuts and a small CLI.

## Credit

The instant space-switching technique strafe uses — synthesizing a
high-velocity Dock-swipe `CGEvent` with near-zero progress, and intercepting
your real trackpad swipe with an active event tap — was invented and first
implemented by **jurplel** in
[InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher) (MIT).
The concept and the original implementation are entirely jurplel's work. strafe
is an independent reimplementation of that idea; if you want the original, go
give InstantSpaceSwitcher a star. See [LICENSE](LICENSE) for the full
acknowledgment and their copyright notice.

## Install

strafe is distributed as source only — there is no prebuilt binary to trust.
You build the code you can read.

```bash
git clone https://github.com/rileycx/strafe strafe && cd strafe
./Scripts/bundle.sh
```

This builds a release binary and assembles `build/strafe.app` (ad-hoc signed).
Then:

1. Drag `build/strafe.app` to `/Applications`.
2. Launch it. It will prompt for Accessibility permission.
3. Grant it in **System Settings › Privacy & Security › Accessibility**.

The app is about 1,080 lines of Swift and C with no third-party dependencies —
`swift build` finishes in seconds and you can read the whole thing. See
[SECURITY.md](SECURITY.md).


## Usage

- **3-finger swipe** — just works once strafe is running and has Accessibility.
  Swipe left/right between Spaces and the switch is instant.
- **Keyboard** — `ctrl`+`opt`+`←` and `ctrl`+`opt`+`→` switch Spaces.
- **Menu bar** — click the strafe icon to enable/disable interception or check
  whether Accessibility has been granted.
- **CLI:**

  ```
  strafe switch left|right   # switch once and exit
  strafe status              # print accessibility / tap status
  strafe                     # start the menu-bar app
  ```

## Permissions

strafe needs **Accessibility** permission, and only that. macOS requires it to
create an *active* event tap — the kind that can suppress the slow animated
swipe and replace it with the instant one.

The tap sees only trackpad gesture and dock-control events. It does **not** see
keystrokes: the event mask excludes key events entirely, and strafe has no
network, telemetry, file access, or subprocess code. Every one of those claims
is grep-verifiable — see [SECURITY.md](SECURITY.md) for the exact file and line
pointers.

To revoke: **System Settings › Privacy & Security › Accessibility**, and toggle
strafe off (or remove it from the list).

## Uninstall

1. Quit strafe from its menu-bar menu.
2. Delete `strafe.app`.
3. Remove its entry from **System Settings › Privacy & Security ›
   Accessibility**.

That's everything. strafe writes no preferences, caches, or other files — there
is nothing else to clean up.

## How it works

macOS generates a "Dock swipe" event for a real 3-finger horizontal swipe.
strafe posts a synthetic one with an artificially near-zero *progress* and a
very high *velocity*. The high velocity makes the WindowServer treat the gesture
as a flick and skip the slide animation, jumping instantly to the neighboring
Space. At the same time an active event tap suppresses your real swipe so the OS
never runs its own animated version. For the field-by-field derivation, read
[docs/SPEC.md](docs/SPEC.md).

## Requirements

- macOS 15 or newer
- Apple Silicon (that is what strafe is built and tested on)

## License

MIT — Copyright (c) 2026 Riley Hennigh. See [LICENSE](LICENSE), which also
carries the acknowledgment and MIT notice for jurplel's InstantSpaceSwitcher.
