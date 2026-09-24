# Install

## Prerequisites

- The Blue Snowball plugged in (Apple's own USB Audio driver handles it — nothing to install for
  that part).
- Xcode 27 selected (`xcode-select -p` → `/Applications/Xcode.app/Contents/Developer`). Run
  `bash scripts/preflight.sh` to confirm.

## Steps

```bash
make            # builds + tests everything, installs nothing yet
make install    # builds again (fast — incremental), then installs
```

`make install` will:

1. Build and sign the driver, app, and CLI as **you** (not root — see BUILD.md for why that
   matters).
2. Ask for your **login password** (a `sudo` prompt in Terminal) — this is only for copying
   `SnowballBoost.driver` into `/Library/Audio/Plug-Ins/HAL/` and restarting `coreaudiod` so it
   loads the driver. Nothing else needs `sudo`.
3. Copy the app to `/Applications/Snowball Boost.app`.
4. Install and start the LaunchAgent (`~/Library/LaunchAgents/com.snowballboost.agent.plist`) so
   the app runs at login from now on.
5. Print `sbboost status` so you can see the result immediately.

## Prompts you'll see

- **Terminal password prompt** — for the `sudo` steps above. This is macOS asking for *your*
  account password, not anything driver-specific.
- **"Snowball Boost would like to access the microphone"** — appears the first time the app
  actually tries to capture audio (which only happens once something has "Snowball Boosted"
  selected as its input — the app doesn't touch the mic just from being installed/running). Click
  **Allow**. If you run `sbboost diagnose`/`bench` from Terminal, a similar prompt appears for
  Terminal (or whatever process is running the CLI) the first time too.
- **"Background item added: Snowball Boost"** — a one-time macOS notice about the LaunchAgent.
  Leave it enabled; this is how the app starts automatically at login.

If you don't see the microphone prompt right away, it's likely because nothing has selected
"Snowball Boosted" as an input yet — open Voice Memos, QuickTime, or run `sbboost diagnose` to
trigger it.

## Only the driver, no app

```bash
make install-driver
```

Useful for testing the driver in isolation (Core Audio device enumeration, `sbboost status`)
without running the menu-bar app or LaunchAgent yet.

## Verifying it worked

```bash
sbboost status
```

Should show `Snowball: present`, `Feed: present (hidden)`, `Boosted: present`, and eventually
`Agent: loaded`. `system_profiler SPAudioDataType` should list "Snowball Boosted" (1 input,
0 output) — the hidden Feed device won't appear there by design.
