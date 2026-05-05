# cliPets — implementation notes

Caveats and follow-ups parked during the early phases. Each item names the
phase that introduced it and a target phase to address it.

---

## v2 roadmap

### Sprite artwork needed

v1 uses procedurally-drawn pixel art (CGContext). v2 should replace these with
hand-drawn sprite sheets. All sprites are **32×32 pixels**, displayed at 2× or
3× with nearest-neighbor scaling.

Each species needs the following animation frames:

| Animation | Frames | Description |
|-----------|--------|-------------|
| `idle` | 2 | Normal sitting pose + blink variant (eyes closed/half) |
| `working` | 2 | Ears perked, alert eyes, paws alternating up/down (typing) |
| `writing` | 2 | Focused squint, forward paws alternating (same energy as working) |
| `celebrate` | 4 | Bob up — peak — come down — land (confetti is drawn in code, no need in sprite) |
| `alert` | 3 | Normal → ears wide → settle back (surprise/startle loop) |

**Total per species: 13 frames.**

v1 ships only the **cat** as procedural art. v2 target species (8 total):

- cat *(procedural placeholder exists)*
- dog
- capybara
- duck
- bunny
- bear
- penguin
- pig

Each species also needs a **palette mask** (grayscale PNG, same dimensions as
the sprite sheet) used for recoloring variants without redrawing every frame.
See `Resources/pets/` for the intended layout:

```
Resources/pets/<species>/
├── base.png           # default palette sprite sheet (all frames in a row)
├── palette_mask.png   # grayscale slots for recoloring
├── sheet.json         # frame data: name, x, y, w, h for each frame
└── variants.toml      # named palettes: "orange", "gray", "cosmic", …
```

### Speech bubbles (Phase 5, deferred)

The bubble rendering code exists (`BubbleRenderer.swift`) but is disabled
because system font rendering in a CGContext doesn't look pixel-art. Options
for v2:

- Draw the text as actual pixel-art sprites (one image per message string)
- Use a bitmap pixel font (e.g. Monocraft, Galmuri, Press Start 2P) and
  render at 1px/pt with anti-aliasing fully off
- Ship a tiny hand-drawn font as a sprite sheet and blit characters manually

Bubble trigger mappings (already implemented, just needs re-enabling):

| Hook / State | Bubble text |
|---|---|
| `Stop` (celebrate) | "done! ✨" |
| `Notification` (alert) | "hey!" |
| `PreToolUse` Bash (working) | "running…" |
| `PreToolUse` Write / Edit (writing) | "writing…" |

### More species (Phase 7 extension)

Add dog, capybara, duck, bunny, bear, penguin, pig to `PetCatalog` once
sprite sheets exist. Each species needs its own `SpriteBuilder` drawing
functions (or a sprite-sheet loader to replace the procedural renderer).

### Collection UI in paw menu (Phase 8 extension)

The paw menu panel has a "Collection coming in Phase 7" placeholder. Replace
with a grid view: unlocked variants in color with their name, locked ones as
dark silhouettes with a "?" label.

### Settings panel (Phase 8 extension)

Add to the paw menu panel:
- Pinned pet dropdown (Random / any unlocked variant)
- Toggle: speech bubbles on/off
- Toggle: click-through on pet overlays
- Slider: sprite scale (2×, 3×, 4×)
- Slider: unseen-pet boost (0×–4×)

### Codesign + notarization (Phase 9 extension)

Requires Apple Developer account ($99/year). Once obtained:

```bash
codesign --force --deep --sign "Developer ID Application: ..." \
  --entitlements Installer/cliPets.entitlements \
  /Applications/cliPets.app

xcrun notarytool submit cliPets.zip \
  --apple-id ... --team-id ... --password ... --wait

xcrun stapler staple /Applications/cliPets.app
```

After notarization, users can open the app without the Gatekeeper warning.

### Homebrew cask

```ruby
cask "clipets" do
  version "1.0.0"
  url "https://github.com/doyoojk/cliPets/releases/download/v#{version}/cliPets.zip"
  name "cliPets"
  app "cliPets.app"
  binary "#{appdir}/cliPets.app/Contents/MacOS/clipets"
end
```

### Additional terminal support

Currently supports Ghostty and Terminal.app. Planned:
- iTerm2 (`com.googlecode.iterm2`)
- Alacritty (`org.alacritty`)
- WezTerm (`com.github.wez.wezterm`)

Add each as a new case in `TerminalLocator` / `SupportedTerminal`.

---

## Known issues / tech debt

### CVDisplayLink deprecation (Phase 2)

`CVDisplayLink` is deprecated in macOS 14 in favor of
`NSView.displayLink(target:selector:)`. Still works on macOS 13–15.

- **Fix**: bump minimum to macOS 14 and switch, or add an `#available` branch.

### DispatchQueue hop in display link callback (Phase 2)

The CVDisplayLink callback fires on the CV thread and hops to main via
`DispatchQueue.main.async`. Adds ~1–2 ms latency per tick — imperceptible
in practice.

- **Fix** (if needed): read `CGWindowListCopyWindowInfo` on the CV thread
  (thread-safe), compare against an atomic `lastTerminalFrame`, only dispatch
  to main when the frame actually changed.

### Sprite scaling fuzziness (Phase 1)

32×32 procedural sprites at non-integer scale produce uneven pixel widths.
Hand-drawn sprite sheets at integer scale (e.g. 16×16 @ 3× = 48 pt) fix this.

### Multi-tab in Ghostty (Phase 2)

AX sees Ghostty windows but not individual tabs. Multiple Claude sessions in
tabs of the same Ghostty window share one overlay. Terminal.app is unaffected.

- **Fix**: title-based session matching via OSC 0/2 escape codes so each tab's
  pet maps to its own session.

### Session-to-window binding heuristic (Phase 6)

Pet binds to the focused terminal when the first hook fires. If the user is
focused on a non-terminal app at that moment, the pet may land on the wrong
window.

- **Fix**: shell prelude sets terminal title to `claude:<sessionId>` and we
  match by title. `clipets install-hooks` would inject the prelude into
  `~/.zshrc` / `~/.bashrc`.

### Multi-display support (Phase 2)

`AppDelegate.nsRect(fromAX:)` uses `NSScreen.screens.first`. Should work on
secondary displays (NS coords are unified) but hasn't been tested.

- **Fix**: manual test — drag terminal between displays and confirm pet follows.

---

## Animation state machine — hook-to-animation mapping (Phase 4)

| Hook event | Animation | Feel |
|---|---|---|
| Idle (no recent event) | `idle` | Sitting, slow blink every 3 s |
| `UserPromptSubmit` | `listening` | Eyes half-closed, calm waiting mode |
| `PreToolUse` Bash | `working` | Ears perked up, alert eyes, alternating paw tap |
| `PreToolUse` Write / Edit | `writing` | Focused squint, forward paws typing |
| `Stop` | `celebrate` | Squat → jump → peak → land squish (2 cycles ≈ 2 s) |
| `Notification` | `alert` | Wide-eyed startle hop (3 cycles ≈ 2 s) |
| `SessionStart` | idle | — |
| `SessionEnd` | pet removed | — |

Priority rules: `alert`/`celebrate` (3) always fire; `working`/`writing` (2)
fire unless a one-shot is playing; `listening` (1) only overrides idle.
Looping states time out to idle after 8 s. `alert` loops until any new event.
