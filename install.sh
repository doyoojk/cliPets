#!/bin/bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/cliPets.app"
BUNDLE="$APP/Contents"
AGENT_PLIST="$HOME/Library/LaunchAgents/com.doyoojk.clipets.plist"
CLI_LINK="/usr/local/bin/clipets"

echo "==> Building cliPets (release)..."
cd "$REPO"
swift build -c release --product petd
swift build -c release --product clipets

BUILD="$REPO/.build/release"

echo "==> Assembling $APP (requires sudo for /Applications)..."
sudo rm -rf "$APP"
sudo mkdir -p "$BUNDLE/MacOS" "$BUNDLE/Resources"

sudo cp "$BUILD/petd"    "$BUNDLE/MacOS/petd"
sudo cp "$BUILD/clipets" "$BUNDLE/MacOS/clipets"
sudo cp "$REPO/Installer/Info.plist" "$BUNDLE/Info.plist"

# Copy PawIcon as AppIcon (icns would be ideal; png works for now)
sudo cp "$REPO/Resources/PawIcon.png" "$BUNDLE/Resources/AppIcon.png"

echo "==> Installing LaunchAgent..."
cp "$REPO/Installer/com.doyoojk.clipets.plist" "$AGENT_PLIST"

# Unload any previous instance before loading the new one.
launchctl unload "$AGENT_PLIST" 2>/dev/null || true
launchctl load -w "$AGENT_PLIST"

echo "==> Linking clipets CLI..."
sudo mkdir -p /usr/local/bin
sudo ln -sf "$BUNDLE/MacOS/clipets" "$CLI_LINK"

echo ""
echo "✓ cliPets installed."
echo ""
echo "  The pet daemon is running. Grant Accessibility permission when prompted"
echo "  (System Settings → Privacy & Security → Accessibility → cliPets)."
echo ""
echo "  To wire up Claude Code hooks, run:"
echo "    clipets install-hooks"
echo ""
echo "  To uninstall:"
echo "    bash $REPO/uninstall.sh"
