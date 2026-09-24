#!/bin/bash
# Installs the Snowball Boost driver (and, unless --driver-only, the app + LaunchAgent).
# Requires sudo for the driver copy into /Library/Audio/Plug-Ins/HAL and to restart coreaudiod.
set -euo pipefail
cd "$(dirname "$0")/.."

DRIVER_SRC="build/SnowballBoost.driver"
DRIVER_DST="/Library/Audio/Plug-Ins/HAL/SnowballBoost.driver"
APP_SRC="build/SnowballBoost.app"
APP_DST="/Applications/Snowball Boost.app"
AGENT_SRC="Resources/com.snowballboost.agent.plist"
AGENT_DST="$HOME/Library/LaunchAgents/com.snowballboost.agent.plist"

install_driver() {
  if [[ ! -d "$DRIVER_SRC" ]]; then
    echo "error: $DRIVER_SRC not built — run 'make driver' first." >&2
    exit 1
  fi
  echo "Installing driver to $DRIVER_DST (needs sudo)..."
  sudo rm -rf "$DRIVER_DST"
  sudo cp -R "$DRIVER_SRC" "$DRIVER_DST"
  sudo chown -R root:wheel "$DRIVER_DST"
  echo "Restarting coreaudiod so it picks up the driver..."
  sudo killall coreaudiod || true
  sleep 1
}

if [[ "${1:-}" == "--driver-only" ]]; then
  install_driver
  echo "Driver install complete."
  exit 0
fi

if [[ ! -d "$APP_SRC" ]]; then
  echo "error: $APP_SRC not built — run 'make app' first." >&2
  exit 1
fi

install_driver

echo "Installing app to $APP_DST..."
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

echo "Installing LaunchAgent..."
mkdir -p "$HOME/Library/LaunchAgents"
sed "s#__APP_PATH__#$APP_DST/Contents/MacOS/SnowballBoostApp#" "$AGENT_SRC" > "$AGENT_DST"

launchctl bootout "gui/$(id -u)/com.snowballboost.agent" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$AGENT_DST"
launchctl enable "gui/$(id -u)/com.snowballboost.agent"
launchctl kickstart -k "gui/$(id -u)/com.snowballboost.agent"

echo
echo "Install complete. Current status:"
.build/release/sbboost status || true
