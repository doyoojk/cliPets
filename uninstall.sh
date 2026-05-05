#!/bin/bash
set -euo pipefail

AGENT_PLIST="$HOME/Library/LaunchAgents/com.doyoojk.clipets.plist"
APP="/Applications/cliPets.app"
CLI_LINK="/usr/local/bin/clipets"

echo "==> Stopping cliPets daemon..."
launchctl unload "$AGENT_PLIST" 2>/dev/null || true

echo "==> Removing files..."
rm -f "$AGENT_PLIST"
sudo rm -rf "$APP"
sudo rm -f "$CLI_LINK"

echo "✓ cliPets uninstalled."
