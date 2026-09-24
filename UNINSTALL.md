# Uninstall

```bash
make uninstall
```

Runs `scripts/uninstall.sh`, which:

1. Stops and removes the LaunchAgent (`launchctl bootout` +
   `~/Library/LaunchAgents/com.snowballboost.agent.plist`).
2. Removes `/Applications/Snowball Boost.app`.
3. Asks for your password (`sudo`) to remove
   `/Library/Audio/Plug-Ins/HAL/SnowballBoost.driver` and restart `coreaudiod`.
4. Asks whether to also delete the saved gain setting (`defaults domain com.snowballboost`) — say
   **y** only if you want the gain to reset to the +12 dB default on a future reinstall.

Nothing else in `/Library/Audio/Plug-Ins/HAL/` is touched — other plug-ins there are left alone.
Apple's own audio configuration (default devices, the Snowball's hardware gain, other devices'
settings) is never modified by install, use, or uninstall.

After uninstalling, `sbboost status` (if you still have the binary around) will show `Feed: NOT
FOUND` and `Boosted: NOT FOUND` — expected, since the driver is gone. The physical Blue Snowball
is unaffected and keeps working normally through Apple's own driver.
