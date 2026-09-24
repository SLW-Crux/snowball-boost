# Snowball Boost

A macOS virtual microphone for the Blue Snowball iCE: clean digital gain (+12 dB default) and a
transparent peak limiter, published as a normal Core Audio input device named
**"Snowball Boosted"** — selectable in Zoom, Teams, QuickTime, Voice Memos, browsers, and any
other app that lists Core Audio input devices.

Apple frameworks + code written in this repo only. No third-party dependencies, no network code,
no kernel extension, no SIP changes. See [ARCHITECTURE.md](ARCHITECTURE.md) for why.

> Not affiliated with, endorsed by, or sponsored by Logitech or Blue Microphones. "Blue Snowball"
> is their trademark, used here only to describe hardware compatibility.

## Requirements

- Apple Silicon Mac, macOS 15 or later (developed and tested on macOS 27).
- A Blue Snowball iCE (USB, VID `0x0D8C` / PID `0x0005`) — the plain (non-iCE) Snowball isn't the
  same device and isn't what this was built/tested against.
- Xcode (for the Swift/Clang toolchain — no Xcode project is opened, everything builds from the
  command line). No other dependencies: no Homebrew, no CocoaPods, nothing downloaded at build time.

## Quick Start

```bash
make               # build DSP + core + driver + app + CLI, run swift test
make install       # builds again, then installs driver + app + LaunchAgent (asks for your
                    # password partway through — see "What sudo is for" below)
```

**Don't prefix `make install`/`make install-driver` with `sudo`** — the script escalates
internally only where it needs to; see [BUILD.md](BUILD.md) for why the whole command can't run as
root.

Then select **"Snowball Boosted"** as the microphone in your app of choice (or in
System Settings → Sound → Input). The first time anything actually opens it, macOS will ask
**"Snowball Boost would like to access the microphone"** — click **Allow** (this is standard
mic-permission (TCC) behavior, not anything unusual to this project).

Gain defaults to +12 dB; change it from the menu-bar app (small mic icon in the menu bar) or
`sbboost gain <0|6|9|12|15|18>`. +12 dB suits a normal ~30 cm speaking distance; if you're further
away (say ~70 cm), +18 dB is a reasonable starting point — the built-in limiter keeps it from
clipping even if you get loud.

**What `sudo` is for**: only copying the driver into `/Library/Audio/Plug-Ins/HAL/` and restarting
`coreaudiod` so it loads it. Nothing else needs elevated privileges.

Full walkthrough: [INSTALL.md](INSTALL.md). Build details: [BUILD.md](BUILD.md). Uninstalling:
[UNINSTALL.md](UNINSTALL.md). Problems: [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## What's in the repo

| Path | What |
|---|---|
| `Sources/BoostDSP` | RT-safe C gain + lookahead peak limiter kernel |
| `Sources/SnowballCore` | Swift: device discovery, the boost engine, settings, meters |
| `Sources/sbboost` | CLI: `status`, `gain`, `diagnose`, `bench` |
| `Sources/SnowballBoostApp` | SwiftUI menu-bar app (gain picker, live meters) |
| `Driver/` | The `AudioServerPlugIn` C driver (`SnowballBoost.driver`) |
| `Tests/` | `swift test` — DSP math + device-matching logic |
| `scripts/` | `preflight.sh` (read-only checks), `install.sh`, `uninstall.sh` |

## Verified on this Mac

```
$ sbboost bench --seconds 10
A) Raw Snowball        RMS: -59.3 dBFS   Peak: -38.4 dBFS   Clipped: 0
B) Snowball Boosted    RMS: -47.3 dBFS   Peak: -27.4 dBFS   Clipped: 0
Effective gain (B RMS - A RMS): 12.0 dB  (configured: +12 dB)
Estimated B-vs-A latency: 3.9 ms
```

Also confirmed: recovers cleanly from `coreaudiod` restarts, unplugging/replugging the Snowball,
app crashes (the LaunchAgent restarts it), and sleep/wake.

## License

[MIT](LICENSE).
