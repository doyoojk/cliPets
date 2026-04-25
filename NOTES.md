# cliPets — implementation notes

Caveats and follow-ups parked during the early phases. Each item names the
phase that introduced it and a target phase to address it.

## CVDisplayLink deprecation (Phase 2)

`CVDisplayLink` is deprecated in macOS 14 in favor of
`NSView.displayLink(target:selector:)`. The deprecated API still works on
macOS 13–15 and we use it for frame-rate-locked overlay positioning.

- **Target**: Phase 9. Either bump the minimum to macOS 14 and switch, or
  add an `#available(macOS 14, *)` branch and keep `CVDisplayLink` as a
  fallback for macOS 13.

## DispatchQueue.main.async hop in display link callback (Phase 2)

The CVDisplayLink callback fires on the CV thread, then we
`DispatchQueue.main.async` to call AppKit. This adds ~1–2 ms of latency per
tick. Imperceptible in practice but the obvious place to look if drag lock
ever feels loose again.

- **Target**: only if needed. The fix is to do the
  `CGWindowListCopyWindowInfo` read on the CV thread (it's thread-safe),
  compare against a thread-safe `lastTerminalFrame` (atomic via
  `OSAllocatedUnfairLock`), and only dispatch to main when the frame
  actually changed.

## TCC permission flicker on rebuilds (Phase 2)

`swift run petd` produces a fresh binary at `.build/…` each rebuild. macOS
TCC sometimes re-prompts for Accessibility permission because the binary's
identity changed.

- **Target**: Phase 9. A signed `.app` bundle has a stable code signature,
  so TCC recognizes it across rebuilds. Eliminates the re-prompt entirely.
- **Dev workaround**: `codesign --force --deep --sign - .build/debug/petd`
  after each build gives a stable ad-hoc identity.

## Sprite scaling fuzziness (Phase 1)

The 32×32 procedural cat renders at 1.5× (48 pt) with nearest-neighbor.
Non-integer scaling produces uneven pixel widths — visibly fuzzy if you
look closely.

- **Target**: Phase 7. Real sprite sheets ship at integer scales
  (16×16 source @ 3× = 48 pt, or 32×32 @ 2× = 64 pt). Crisp by default.

## Multi-tab in Ghostty (Phase 2)

AX sees Ghostty windows but not individual tabs. If multiple Claude
sessions run in tabs of the same Ghostty window, they share one overlay.

- **Target**: Phase 6. Title-based session matching via OSC 0/2 escape
  ( shell prelude sets the tab title to `claude:<sessionId>`) gets us
  partial coverage. Full per-tab tracking likely needs Ghostty
  cooperation. Terminal.app is unaffected — each tab is its own
  `AXWindow`.

## Z-order delay on terminal activation (Phase 2)

When you click back into the terminal after using another app, there's a
~16 ms window where the pet still sits behind the terminal before our
activation handler re-orders it above. Imperceptible in practice.

- **Target**: only if it ever surfaces as a perceptible glitch. Fix is to
  observe `kAXFocusedUIElementChangedNotification` and re-order earlier in
  the activation pipeline.

## clipets symlink in /opt/homebrew/bin (Phase 3)

Dev shortcut: `/opt/homebrew/bin/clipets` is a symlink to
`~/Code/cliPets/.build/debug/clipets` so Claude Code hooks can use the
short name. The symlink is fine across debug rebuilds (same path) but
goes stale on a release build (`.build/release/clipets`).

- **Target**: Phase 9. Signed `.app` bundle installs the CLI at a
  stable path (e.g., `/Applications/cliPets.app/Contents/MacOS/clipets`)
  and the install step manages the symlink. After that, this manual
  symlink should be removed in favor of the packaged install.

## Multi-display sanity check (Phase 2)

`AppDelegate.nsRect(fromAX:)` uses `NSScreen.screens.first` (the screen at
origin (0,0), i.e., the primary). Should work on a secondary display
because NS coords are unified with the primary at origin, but it's never
been exercised. Worth a sanity check when dragging the terminal between
displays.

- **Target**: a quick manual test before Phase 9 packaging.
