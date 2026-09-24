# Snowball Boost — Implementation Plan

## Context
Blue Snowball iCE (A00122) too quiet even near max HW gain. Want clean digital gain (+12 dB default)
+ transparent peak limiter, exposed as virtual input **"Snowball Boosted"** usable by any Core Audio app.
Keep Apple USB driver. No kext, no SIP change, no network, no deps. Started from an empty repo.

Measured on the reference development Mac (macOS 27.0 / Xcode 27.0 / Swift 6.4 / arm64 / SIP
enabled) — your own numbers will differ per unit/Mac; use `sbboost status` to get yours:
- Snowball UID: unique per physical unit + USB port history, format
  `AppleUSBAudioEngine:BLUE MICROPHONE:Blue Snowball:<serial>:<n>`
- ModelUID `Blue Snowball :0D8C:0005` → USB VID 0x0D8C / PID 0x0005, transport `usb ` (this part
  is generic — same for every Snowball iCE)
- 1 input stream, Int16 mono, 48 kHz (also 44.1k…8k); buffer 512, latency 74, safety offset 74
- HW input gain on master element: roughly −8…+10 dB range, varies slightly per unit
- Identities: any Apple Development or Developer ID certificate works; ad-hoc (`-`) is the
  project default, override locally via `Makefile.local`
- SDK scan: no macOS 26/27 user-space virtual-device API (only process-tap additions + `kAudioDevicePropertySuggestedReferenceDevice`)

User decisions: scoped **only** to the recognised Snowball (no device picker), auto-loaded; on-demand
capture; sign with Apple Development cert (ad-hoc fallback). Control-UI question answered with
"only for this recognised USB mic… auto loaded" → interpreted as: hard-wired to VID 0D8C/PID 0005,
"Snowball Boosted" published only while that mic is attached, everything starts at login with no
manual step. Tiny menu-bar app kept because spec requires gain select + live meters; it has no
device selection.

Research findings (cite in ARCHITECTURE.md):
- AudioServerPlugIn.h (macOS 27 SDK): plug-in "may not make any calls to the client HAL API"; sandboxed.
- AudioDriverKit = physical devices only; Apple DTS: entitlements not granted for virtual drivers
  (developer.apple.com/forums/thread/775341, /682035).
- Process taps capture process output only; cannot publish a mic.
- No new macOS 26/27 device-creation API (SDK headers + WWDC25/26 notes).
- BlackHole = single-file C AudioServerPlugIn, host-time clock (mach_absolute_time, 16384-frame period),
  loopback ring, optional hidden 2nd device; **GPL-3 → study only, copy nothing.** Base driver on
  Apple's "Creating an Audio Server Driver Plug-in" sample structure (permissive license — verify
  LICENSE.txt in zip) / header contract.
- Hidden device reachable via `kAudioHardwarePropertyTranslateUIDToDevice`; set
  `kAudioSubDeviceDriftCompensationKey=1` explicitly on virtual subdevice; use IOProc directly (not
  AVAudioEngine) on aggregates.
- TCC: hardened runtime requires `com.apple.security.device.audio-input` entitlement or mic is
  silently denied; app bundle needs NSMicrophoneUsageDescription; stable signing identity avoids
  stale TCC records (`tccutil reset Microphone com.snowballboost.app` fixes).
- HAL plug-in signing: no documented load-time requirement; arm64 needs ≥ ad-hoc; factory symbol
  must be exported (`visibility("default")`). Notarization only for distribution.
- `launchctl kickstart system/com.apple.audio.coreaudiod` now "Operation not permitted" →
  use `sudo killall coreaudiod`.

## Architecture (to be written into ARCHITECTURE.md first)

```
Blue Snowball (Apple USB Audio)
      │  (HAL client IO — only a normal process may do this)
      ▼
SnowballBoost.app  (LSUIElement menu-bar app, started at login by LaunchAgent, KeepAlive on crash)
  private aggregate device: [Snowball = clock main] + [SB Feed, drift-compensated]
  single IOProc:  Float32 in → gain (smoothed) → lookahead peak limiter → Float32 out
      │
      ▼
SnowballBoost.driver  (AudioServerPlugIn in /Library/Audio/Plug-Ins/HAL, runs in coreaudiod helper)
  device A "Snowball Boost Feed"  — hidden (kAudioDevicePropertyIsHidden), 1 output stream
  device B "Snowball Boosted"     — visible, 1 input stream, mono Float32, 48k/44.1k
  A.output → shared in-plugin ring buffer → B.input ; both devices share one host-time clock
      │
      ▼
Zoom / Teams / QuickTime / Voice Memos / browsers / ChatGPT
```

Why (ARCHITECTURE.md will expand, with rejected alternatives):
- HAL plug-in is the only supported, SIP-compatible way to publish an arbitrary virtual Core Audio
  device. AudioServerPlugIn.h explicitly forbids plug-ins calling the client HAL API → the plug-in
  **cannot** read the Snowball itself → companion user process is required (as user anticipated).
- AudioDriverKit rejected: dext for real hardware, needs Apple-granted DriverKit entitlements +
  system-extension approval; would replace/compete with Apple's USB driver.
- Process taps rejected: capture process *output*, cannot create an input device.
- Kext / SIP changes rejected: unnecessary.
- Two devices (hidden feed + visible input) instead of BlackHole's single loopback device: Boosted
  shows as a pure 1-in/0-out microphone (no bogus speaker entry in Zoom/Sound settings), and
  `kAudioDevicePropertyDeviceIsRunningSomewhere` on Boosted reflects only real consumers → enables
  on-demand capture.
- Private aggregate + HAL drift compensation instead of own resampler: Snowball USB clock ≠ host clock;
  Apple's aggregate solves drift with zero custom code, one IOProc, minimal latency.
- Shared-memory/XPC between app and driver rejected: needs AudioServerPlugIn_MachServices, custom IPC,
  more code; normal HAL IO to a hidden device achieves same with none.
- BlackHole studied for structure only (GPL-3) — driver written fresh from Apple's NullAudio/
  AudioServerPlugIn.h contract; no BlackHole code copied.

Fallback if hidden device can't be an aggregate subdevice (verify in step 8): make Feed visible but
`DeviceCanBeDefaultDevice/SystemDevice = false`, named "Snowball Boost (internal)".

## Repository layout
```
SnowBallBoost/
  README.md ARCHITECTURE.md BUILD.md INSTALL.md UNINSTALL.md TROUBLESHOOTING.md
  Makefile                      # build / test / sign / install / uninstall entry points
  Package.swift                 # SwiftPM: BoostDSP (C), SnowballCore, app exe, sbboost CLI, tests
  Driver/
    SnowballBoostDriver.c       # AudioServerPlugIn (C, ~1000 lines, NullAudio-style)
    Info.plist                  # CFPlugInFactories, bundle id com.snowballboost.driver
  Sources/
    BoostDSP/  boost_dsp.c, include/boost_dsp.h        # RT-safe C kernel (gain + limiter + meters)
    SnowballCore/                                       # Swift, shared by app + CLI
      CoreAudioHelpers.swift    # typed property get/set/listen wrappers
      DeviceLocator.swift       # Snowball match (transport USB + ModelUID suffix ":0D8C:0005"),
                                #   deterministic pick = sort by UID, first; optional pinned UID
      BoostEngine.swift         # state machine, aggregate build/teardown, IOProc, listeners
      Settings.swift            # gain persisted (UserDefaults suite com.snowballboost) + Darwin notify
      Meters.swift              # lock-free (Synchronization.Atomic) peak/RMS/GR snapshot
    SnowballBoostApp/  App.swift MenuView.swift       # SwiftUI MenuBarExtra
    sbboost/  main.swift                               # CLI: status | gain N | diagnose | bench
  Resources/  App-Info.plist (NSMicrophoneUsageDescription, LSUIElement), com.snowballboost.agent.plist
  scripts/  install.sh uninstall.sh sign.sh
  Tests/BoostDSPTests/  DSPTests.swift  (+ Tests/SnowballCoreTests for locator matching)
```
No Xcode project (hand-authored pbxproj is fragile); SwiftPM + Makefile + clang for the driver bundle.

## Component details

### Driver (C AudioServerPlugIn)
- Objects: PlugIn(1), DeviceFeed, StreamFeedOut, DeviceBoosted, StreamBoostedIn. No volume/mute controls.
- Formats: Float32 packed mono, rates {44100, 48000}; default 48000. One shared nominal rate for both
  devices (change via RequestDeviceConfigurationChange on both).
- Clock: shared anchor host time; ZeroTimeStamp period = ring size (16384 frames); same timeline for both
  devices so sample times align. Latency 0, SafetyOffset small (e.g. 0), buffer range 32…4096.
- Ring: 16384-frame Float32, indexed by absolute sample time. Feed WriteMix writes at output sample time;
  Boosted ReadInput reads at input sample time; unread/stale regions zeroed so stopped feed = silence
  (never stale loop).
- Visibility of Boosted gated on Snowball presence: IOKit matching notification for USB
  idVendor 0x0D8C / idProduct 0x0005 inside plug-in (IOKit matching expected to be permitted in the
  sandbox — verify at step 7); adds/removes Boosted from plug-in device list via PropertiesChanged.
  If IOKit notify setup fails → Boosted always visible (logged via os_log). *(Implements "only for
  this recognised mic".)*
- Info.plist: no MachServices/Network keys needed. Pure host-time clock → Apple Silicon safe.
  Factory function exported with `__attribute__((visibility("default")))`.
- UIDs: `com.snowballboost.feed`, `com.snowballboost.boosted`; model UID `com.snowballboost.model`.

### DSP kernel (C, RT-safe, no allocation after init)
- Input already Float32 (HAL converts Int16→Float32 for IOProc); kernel also exposes int16→float helper
  for tests (÷32768, symmetric handling).
- Gain: `mult = powf(10, dB/20)`; allowed set {0,6,9,12,15,18}; default 12. Per-sample linear ramp over
  ~20 ms on change (no zipper).
- Limiter: ceiling −1 dBFS; lookahead L = 48 samples (1 ms @48k); required gain r[n]=min(1,ceil/|x|);
  sliding-min over L, smoothed attack via moving-average over L (reaches target by the peak), release
  one-pole ~150 ms, audio delayed L samples; final hard clamp to ceiling as guarantee. NaN/Inf input
  sanitized to 0 before processing (and state reset if it ever went non-finite).
- Meters per block: in peak/sum², out peak/sum², max gain reduction, limited-sample count → atomics.

### Engine (Swift, runs inside menu-bar app)
- States: `noDriver`, `noSnowball`, `idle` (ready, no consumer), `running`, `error(msg)`.
- Listens: system device list; Snowball `DeviceIsAlive`, `NominalSampleRate`; Boosted
  `DeviceIsRunningSomewhere` + `NominalSampleRate`; `IOStoppedAbnormally`; NSWorkspace wake.
  All on one serial queue, 250 ms debounce → `reconcile()`.
- `reconcile()`: if Boosted running somewhere && Snowball && Feed present → build private aggregate
  (main = Snowball, Feed drift-comp on), set aggregate rate = Boosted's rate (Snowball supports 44.1/48),
  buffer 128 frames, start IOProc. Else tear down (mic released → orange dot off).
- Sleep/wake, hot-plug, coreaudiod restart, rate change → full teardown + rebuild (simple, robust).
- Gain from Settings; CLI changes propagate via Darwin notification `com.snowballboost.settings`.

### Menu-bar app
- `SnowballBoost.app` (LSUIElement). Menu: Snowball connected ✓/✗ (name, rate, HW gain), engine state,
  gain picker (0/6/9/12/15/18), live in/out peak meters (dBFS, 10 Hz timer), limiter indicator (GR dB),
  "Open Audio MIDI Setup", Quit.
- Auto-load: `~/Library/LaunchAgents/com.snowballboost.agent.plist` → app executable, `RunAtLoad`,
  `KeepAlive {SuccessfulExit=false}` (crash → restart; Quit stays quit until next login),
  `ProcessType Interactive`, `AssociatedBundleIdentifiers = com.snowballboost.app` (so Login Items
  shows "Snowball Boost", not a bare path). macOS will post a one-time "Background item added" notice. Mic TCC attributed to the app bundle (NSMicrophoneUsageDescription);
  signed with Apple Development cert so the grant survives rebuilds.

### CLI `sbboost`
- `status` — Snowball present/UID/rate/format/HW gain; Boosted/Feed present; agent running (launchctl);
  gain setting.
- `gain <0|6|9|12|15|18>` — persist + notify.
- `diagnose [--seconds 5]` — opens raw Snowball and Snowball Boosted simultaneously (two IOProcs),
  reports per side: rate, format, HW gain (physical), gain applied, RMS dBFS, peak dBFS, clipped samples,
  limiter activity (from Boosted: samples ≥ −1.1 dBFS; plus measured gain delta raw→boosted).
- `bench [--seconds 10] [--out dir]` — records A (raw) and B (Boosted) *simultaneously from the same
  speech*, writes two WAVs, prints RMS, peak, clip count, noise floor (10th-percentile 50 ms window RMS),
  effective gain (dB), and B-vs-A latency via cross-correlation.

## Signing / security facts (for BUILD/INSTALL docs)
- Driver: ad-hoc or Apple Development signing loads in coreaudiod (to be confirmed by research + test);
  no entitlement; no Apple approval; SIP untouched; no kext. Install needs **sudo** (writes
  /Library/Audio/Plug-Ins/HAL, `killall coreaudiod`).
- App/CLI: Apple Development signing, hardened runtime + `com.apple.security.device.audio-input`
  entitlement (standard, self-granted). Developer ID only needed for distribution/notarization.
- AudioDriverKit approval: not needed (not used).

## Install / uninstall
- `make` → build all; `make test` → `swift test`.
- `make install` → `scripts/install.sh`: builds, signs, copies app to `/Applications/Snowball Boost.app`,
  `sudo` copies driver to `/Library/Audio/Plug-Ins/HAL/SnowballBoost.driver`, `sudo killall coreaudiod`,
  writes LaunchAgent plist, `launchctl bootstrap gui/$UID`, then runs `sbboost status`.
- `make uninstall` → bootout agent, remove plist, app, driver (sudo), restart coreaudiod, optionally
  `defaults delete com.snowballboost`. Touches nothing else.

## Execution steps (after approval)
1. Write ARCHITECTURE.md (decision record above, plus research citations).
2. Package.swift, DSP kernel + tests → `swift test` green.
3. Driver C + Info.plist + Makefile bundle target → builds, `codesign --verify`.
4. SnowballCore + CLI; `sbboost status` against real Snowball (no install needed).
5. Menu-bar app + LaunchAgent plist + install/uninstall scripts.
6. **Boundary: user runs `make install-driver`** (no `sudo` prefix — it prompts internally where
   needed) (or `make install`, same rule).
7. Verify `sbboost status` sees "Snowball Boosted" and hidden Feed; verify aggregate creation works
   (hidden-subdevice fallback if not).
8. **Boundary: first mic access → user clicks Allow** on TCC prompt (for app; and Terminal/Claude for CLI).
9. `sbboost diagnose` / `bench`; fix issues; test unplug/replug, rate 44.1↔48, `killall coreaudiod`,
   agent kill → restart. Sleep/wake documented as manual check.
10. Write README (Quick Start), BUILD, INSTALL, UNINSTALL, TROUBLESHOOTING (all 8 required topics).
    `git init` + initial commit only if user asks.

## Verification
- `swift test`: unity at 0 dB; +6/+12/+18 exact (within 1e-6 rel) below limiter threshold; silence→silence;
  ± symmetry; |out| ≤ ceiling for full-scale/over-range/impulse inputs; speech-like modulated signal
  (+12 dB lands below ceiling) → zero GR, no pumping; steady loud tone → GR ripple < 0.5 dB; NaN/Inf in →
  finite out; mono frame count/order preserved; gain ramp monotone.
- `system_profiler SPAudioDataType` + `sbboost status` list "Snowball Boosted" (1 in, 0 out).
- `sbboost diagnose`: Boosted RMS ≈ raw RMS + 12 dB (unless limited), peak ≤ −1 dBFS, 0 clips.
- `sbboost bench`: numbers for user's A/B comparison + measured latency; QuickTime/Voice Memos manual check.
- Only report as working what was actually executed; sudo/TCC/sleep steps flagged for the user.
