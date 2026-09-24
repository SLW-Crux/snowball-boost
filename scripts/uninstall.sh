#!/bin/bash
# Removes the Snowball Boost app, LaunchAgent, and driver. Touches nothing else in
# /Library/Audio/Plug-Ins/HAL and does not modify any other Core Audio device or setting.
set -euo pipefail

AGENT_DST="$HOME/Library/LaunchAgents/com.snowballboost.agent.plist"
APP_DST="/Applications/Snowball Boost.app"
DRIVER_DST="/Library/Audio/Plug-Ins/HAL/SnowballBoost.driver"

echo "Stopping and removing the LaunchAgent..."
launchctl bootout "gui/$(id -u)/com.snowballboost.agent" >/dev/null 2>&1 || true
rm -f "$AGENT_DST"

echo "Removing the app..."
rm -rf "$APP_DST"

if [[ -d "$DRIVER_DST" ]]; then
  echo "Removing the driver (needs sudo)..."
  sudo rm -rf "$DRIVER_DST"
  echo "Restarting coreaudiod..."
  sudo killall coreaudiod || true
else
  echo "Driver not installed — nothing to remove at $DRIVER_DST."
fi

read -r -p "Also delete the saved gain setting (defaults domain com.snowballboost)? [y/N] " answer
if [[ "${answer:-}" =~ ^[Yy]$ ]]; then
  defaults delete com.snowballboost >/dev/null 2>&1 || true
  echo "Removed saved settings."
fi

echo "Uninstall complete."
