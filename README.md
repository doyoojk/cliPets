# cliPets

Pixel-art pets that sit above your terminal and react to Claude Code activity in real time.

Each time Claude runs a tool, finishes a task, or needs your attention, your pet wakes up and animates. Idle between prompts, typing when Claude works, celebrating when a task completes.

---

## Requirements

- macOS 13 or later
- [Claude Code](https://claude.ai/code) CLI
- Ghostty or Terminal.app (more terminals coming in v2)

---

## Installation

### 1. Clone and install

```bash
git clone https://github.com/doyoojk/cliPets.git
cd cliPets
bash install.sh
```

The script will:
- Build `petd` (the background daemon) and `clipets` (the CLI) in release mode
- Copy the app to `/Applications/cliPets.app`
- Install a LaunchAgent so `petd` starts at login
- Symlink `clipets` to `/usr/local/bin/clipets`

### 2. Grant Accessibility permission

cliPets needs Accessibility access to track terminal window positions.

Open **System Settings → Privacy & Security → Accessibility** and enable **cliPets**.

If the prompt doesn't appear automatically, open `/Applications/cliPets.app` once from Finder.

### 3. Wire up Claude Code hooks

```bash
clipets install-hooks
```

This adds hook entries to `~/.claude/settings.json` so Claude Code notifies cliPets on every tool use, stop, and notification event.

---

## Usage

Once installed, everything runs automatically:

- **Start a Claude session** in Ghostty or Terminal.app — your pet appears above the window
- **Drag** the floating paw icon to reposition it anywhere on screen
- **Click** the paw icon to open the status panel
- **Cmd-click** the paw icon to hide/show all pets
- **Right-click** the paw icon for a quick context menu

### CLI

```bash
clipets test [animation]   # preview an animation on all active pets
clipets install-hooks      # add hooks to ~/.claude/settings.json
clipets notify             # (called by hooks automatically — not for manual use)
```

Available animations: `celebrate`, `alert`, `working`, `writing`, `listening`, `idle`

### Logs

```
tail -f /tmp/clipets.log
```

---

## Uninstall

```bash
bash uninstall.sh
```

Stops the daemon, removes the LaunchAgent, deletes `/Applications/cliPets.app`, and removes the `clipets` symlink.

---

## How it works

```
Claude Code hook  ──stdin JSON──▶  clipets CLI  ──unix socket──▶  petd daemon
                                                                       │
                                                              AX window tracker
                                                              Overlay windows
                                                              Animator
                                                              Paw menu
```

- **`petd`** — long-running daemon. Tracks terminal windows via the macOS Accessibility API, renders transparent overlay windows above them, drives sprite animation, and manages the floating paw menu.
- **`clipets`** — tiny CLI binary called by Claude Code hooks. Reads the hook JSON from stdin and forwards it to `petd` over a unix socket at `~/.clipets/clipets.sock`. Exits immediately so hooks stay fast.

---

## Pet variants

v1 ships with 9 cat color variants unlocked through use:

| Variant | Rarity |
|---------|--------|
| Orange Cat | Common |
| Gray Cat | Common |
| White Cat | Common |
| Black Cat | Uncommon |
| Tabby Cat | Uncommon |
| Cream Cat | Uncommon |
| Cosmic Cat | Rare |
| Golden Cat | Rare |
| Rainbow Cat | Mythic |

Each new Claude session rolls a random variant, weighted toward ones you haven't seen yet. Unlocks are saved to `~/.clipets/collection.json`.

---

## Troubleshooting

**Pet doesn't appear**
- Check Accessibility permission is granted
- Run `pgrep petd` — if empty, start manually: `open /Applications/cliPets.app`
- Check logs: `tail -f /tmp/clipets.log`

**Pet attaches to the wrong terminal window**
- Make sure your terminal is focused when you run `claude`
- The pet binds to the focused terminal the moment the first hook fires

**"clipets: petd not running"**
- `petd` isn't running. Start it: `open /Applications/cliPets.app`
