# Troubleshooting

Start with `sbboost status` — it reports Snowball/Feed/Boosted presence, the LaunchAgent state,
and the current gain in one shot, and most of the sections below start from reading its output.

## Snowball detected but "Snowball Boosted" not visible

`sbboost status` shows `Snowball: present` but `Boosted: NOT FOUND`.

- Confirm the driver is actually installed: `ls /Library/Audio/Plug-Ins/HAL/SnowballBoost.driver`.
  If missing, run `make install-driver` (see INSTALL.md).
- If it's installed but still not showing, `coreaudiod` may not have picked it up. Restart it:
  `sudo killall coreaudiod`, wait a couple of seconds, check `sbboost status` again.
- Check the driver's own signature is intact:
  `codesign --verify --verbose=2 /Library/Audio/Plug-Ins/HAL/SnowballBoost.driver`. If it fails,
  reinstall (`make install-driver` rebuilds and re-signs before copying).
- Look for the load attempt in the log:
  `log show --predicate 'process == "coreaudiod"' --last 2m | grep -i snowball` — a successful
  load shows `Attempting to load: SnowballBoost.driver` followed by
  `Creating remote driver service` with no `Caught exception trying to create plugin` after it.

## "Snowball Boosted" visible but silent

`sbboost status` shows `Boosted: present` and `running somewhere: yes` (something has it open),
but you hear nothing.

- Check the physical Snowball isn't muted at the OS level and is set as its own input source:
  `sbboost status` prints its `HW input gain`; if the Snowball itself reports 0 samples, the
  problem is upstream of this project entirely (cable, USB port, or the mic itself).
- Run `sbboost diagnose --seconds 5` while speaking normally. If `Raw Snowball` shows real RMS/peak
  but `Snowball Boosted` shows `-180.0 dBFS` (digital silence), the app's engine likely hasn't
  built its internal aggregate device yet — this can take a couple of seconds after something
  first selects Boosted (the engine polls at ~1 Hz). Wait a few seconds and try again.
- Confirm the app is actually running: `ps aux | grep SnowballBoostApp`. If not,
  `launchctl print gui/$(id -u)/com.snowballboost.agent` should show `state = running`; if it
  doesn't, see "LaunchAgent problems" below.
- Confirm microphone permission was actually granted — see "Microphone permissions" below.

## Level is very low

- Check the configured gain: `sbboost status` prints `Gain: +N dB`. Raise it:
  `sbboost gain 18` (or pick from the menu-bar app). Allowed values: 0, 6, 9, 12, 15, 18.
- Run `sbboost bench --seconds 10` while speaking at your normal distance and check "Effective
  gain (B RMS - A RMS)" — it should closely match the configured value. If it doesn't, something
  is wrong with the signal path (file a note with the `bench-out/*.wav` files attached for
  comparison).
- Distance still matters — +18 dB helps, but the original hardware constraint (weak signal at
  30 cm) isn't magic to fix; move a little closer if quiet in a loud room.

## Clipping / distortion

By design the limiter should make this impossible below relatively extreme signal levels — the
ceiling is fixed at −1 dBFS regardless of gain setting.

- Run `sbboost diagnose` and check "Clipped samples" — it should always read 0. If it's non-zero,
  that's a bug: please note the gain setting, what you were doing (specific loud sound?), and file
  it rather than working around it.
- If audio sounds distorted but `diagnose` reports 0 clipped samples on Boosted, the distortion is
  likely happening *before* this project sees the signal — e.g. the physical Snowball's own
  hardware gain is set too high and clipping at the source. `sbboost status` shows the current HW
  gain; lower it in Audio MIDI Setup if it's near its +10 dB ceiling.

## Sample-rate mismatch

"Snowball Boosted" advertises both 44.1 kHz and 48 kHz. The app's own capture pipeline always runs
its internal aggregate at 48 kHz (see ARCHITECTURE.md's noted V1 simplification). If a client app
selects 44.1 kHz on Boosted while the engine's aggregate is running at 48 kHz, you'll get
mistimed/pitch-shifted audio (not silence, not a crash) rather than clean 44.1 kHz output.
Workaround: set the client app (or System Settings → Sound → Input's format, if exposed) to
48 kHz, which matches what the engine actually produces.

## Device disappears after sleep

Shouldn't happen — sleep/wake was tested and `coreaudiod` didn't even restart across the cycle in
that test. If it does happen on your Mac: `sbboost status`, and if Boosted is missing, try
`sudo killall coreaudiod` first (cheap, restarts the HAL plug-in host) before reinstalling
anything.

## Microphone permissions

Two *separate* TCC grants matter here, for two different processes:

- **"Snowball Boost"** (the app, bundle id `com.snowballboost.app`) — needed for the app to
  actually capture from the Snowball and produce boosted audio. Check/grant in
  System Settings → Privacy & Security → Microphone. It only prompts the first time the app
  actually tries to open the mic, which only happens once something has "Snowball Boosted"
  selected as an input — installing the app alone doesn't trigger it.
- **Terminal (or whatever runs `sbboost`)** — needed for `sbboost diagnose`/`bench`, which open the
  raw Snowball directly. Same Privacy & Security → Microphone list, separate entry.

If you rebuilt with a *different* signing identity than before, macOS may treat the binary as a
new program and re-prompt (or worse, silently deny) — a stable signing identity across rebuilds
avoids this (see BUILD.md). If a permission got stuck in a bad state,
`tccutil reset Microphone com.snowballboost.app` clears it and you'll be re-prompted.

## LaunchAgent / service problems

- `launchctl print gui/$(id -u)/com.snowballboost.agent` — should show `state = running`. If it
  says `not found`, the agent isn't installed: `make install` (not `install-driver`) installs it.
- If the app crashes, the LaunchAgent's `KeepAlive.SuccessfulExit = false` restarts it
  automatically (tested — see `docs/PROGRESS.md`). If it's stuck in a crash loop instead of
  recovering, check Console.app / `~/Library/Logs/DiagnosticReports/` for a crash report.
- Quitting the app from its menu ("Quit") is a clean exit and the LaunchAgent will **not**
  auto-restart it (`SuccessfulExit = false` only restarts on *unclean* exits) — it comes back at
  next login, or run it manually:
  `open "/Applications/Snowball Boost.app"`.
- To fully reset: `make uninstall` then `make install`.
