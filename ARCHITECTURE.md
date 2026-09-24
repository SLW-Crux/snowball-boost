# Architecture

## Problem

Blue Snowball iCE (A00122) is too quiet at normal speaking distance (~30 cm) even near max
hardware input gain (measured: range −8…+10 dB, only ≤2 dB of headroom left at +8 dB). The fix
must be a clean digital gain + limiter stage, exposed as a normal Core Audio input device so any
app (Zoom, Teams, QuickTime, Voice Memos, browsers, ChatGPT) can select it like any other
microphone — without replacing Apple's own USB audio driver for the Snowball.

## Constraints that drove the design

1. Apple Silicon, macOS 27, SIP enabled and must stay enabled.
2. No kernel extension.
3. Audio processed 100% locally, no network code anywhere in the product.
4. Must expose a normal Core Audio input device (`kAudioDevicePropertyTransportType`-visible,
   enumerable via `system_profiler SPAudioDataType`, selectable in System Settings › Sound).
5. Must auto-locate and continue using the physical Snowball without user routing.
6. Must survive reboot, sleep/wake, unplug/replug, sample-rate changes, `coreaudiod` restarts.

## Decision

```
Blue Snowball (Apple USB Audio)
      │  HAL client IO — only a normal (non-sandboxed-in-that-sense) process may do this
      ▼
SnowballBoost.app  (LSUIElement menu-bar app, launched at login by a LaunchAgent)
  private aggregate device: [Snowball = clock main] + [SB Feed, drift-compensated]
  single IOProc: Float32 in → smoothed gain → lookahead peak limiter → Float32 out
      │
      ▼
SnowballBoost.driver  (AudioServerPlugIn in /Library/Audio/Plug-Ins/HAL, loaded by coreaudiod)
  device A "Snowball Boost Feed"  — hidden, 1 output stream
  device B "Snowball Boosted"     — visible, 1 input stream, mono Float32, 48k/44.1k
  A.output → shared in-plugin ring buffer → B.input; both share one host-time clock
      │
      ▼
Zoom / Teams / QuickTime / Voice Memos / browsers / ChatGPT / any Core Audio input consumer
```

Two cooperating components, both built from Apple frameworks only, nothing else:

- **A HAL plug-in (AudioServerPlugIn)** is the only SIP-compatible, kext-free way to publish an
  arbitrary virtual Core Audio device on macOS. It runs loaded inside `coreaudiod`'s plug-in host
  process.
- **A companion user process** (the menu-bar app) is required because `AudioServerPlugIn.h`
  (macOS 27 SDK, `/System/Library/Frameworks/CoreAudio.framework/Headers/AudioServerPlugIn.h`)
  states explicitly:

  > "An AudioServerPlugIn operates in its own process separate from the system daemon. First and
  > foremost, an AudioServerPlugIn may not make any calls to the client HAL API in the
  > CoreAudio.framework. This will result in undefined (but generally bad) behavior."

  A plug-in therefore cannot itself open and read the physical Snowball — it has to receive audio
  from somewhere. A normal process (the app) opens the Snowball via a private aggregate device,
  applies gain + limiting, and writes the result into a second, hidden device the driver exposes
  for exactly this purpose ("Snowball Boost Feed"). The driver copies Feed's output into Boosted's
  input through an in-process ring buffer. This matches the requirements doc's own fallback
  instruction: "If a pure HAL plug-in cannot capture another physical input device... use a
  minimal companion process/LaunchAgent plus virtual device."

### Why a hidden Feed device + a separate visible Boosted device, not one loopback device

A single bidirectional loopback device (BlackHole's approach) would show up in Zoom/System
Settings as a combined input **and** output, which is confusing (a "speaker" that's actually a
mic feed) and makes `kAudioDevicePropertyDeviceIsRunningSomewhere` ambiguous for on-demand
capture. Publishing two devices — a hidden 1-output Feed and a visible 1-input, 0-output Boosted —
keeps Boosted a pure microphone in every app's device list, and lets the engine only run its
IOProc while something is actually consuming Boosted (`DeviceIsRunningSomewhere`), which is
simpler and cheaper than tracking app state itself.

### Why a private aggregate device + HAL drift compensation, not a custom resampler

The Snowball has its own USB audio clock, independent of the Mac's host clock. Apple's aggregate
device machinery already solves this with `kAudioSubDeviceDriftCompensationKey = 1` set on the
Snowball sub-device, at zero extra code and one IOProc. Writing a custom resampler/clock-drift
corrector would be new DSP the plan explicitly avoids ("Do not add ... extra DSP").

### Why HAL IO to a hidden device, not shared memory / XPC between app and driver

An `AudioServerPlugIn_MachServices` + custom XPC channel would need extra Info.plist declarations,
custom IPC protocol, and more code on both sides. Normal Core Audio IO to a hidden device the
driver already publishes achieves the same transport with code we already have to write anyway
(the driver's ring buffer, the app's IOProc).

## Rejected alternatives

| Alternative | Why rejected |
|---|---|
| **AudioDriverKit (dext)** | AudioDriverKit targets *physical* hardware devices behind a DriverKit user-client; per Apple DTS (developer forums threads 775341, 682035) the entitlements needed for a *virtual* audio driver are not granted to third-party developers. It would also compete with/replace Apple's own USB Audio driver for the Snowball, which the requirements explicitly forbid. |
| **Kernel extension (kext)** | Deprecated, requires disabling SIP or entering reduced-security mode — explicitly disallowed by both CLAUDE.md and the requirements doc. |
| **Process-tap based capture** (`AudioHardwareCreateProcessTap` / macOS 14+ taps) | Process taps capture the *output* of another process (e.g. what an app is playing), not a way to publish a new *input* device that arbitrary apps can select as a microphone. Doesn't meet the "expose a normal Core Audio input device" requirement. |
| **A new macOS 26/27 user-space virtual-device creation API** | Searched the macOS 27 SDK headers and WWDC 25/26 session notes; no such API exists. Only additions found were process-tap related and `kAudioDevicePropertySuggestedReferenceDevice`. Confirms the HAL plug-in route is still the only option. |
| **Single loopback device (BlackHole-style)** | See above — rejected in favor of hidden Feed + visible Boosted for a cleaner device list and simpler on-demand-capture semantics. |
| **Custom resampler for clock drift** | Rejected in favor of Apple's private aggregate device + drift compensation (see above). |

## Third-party code — none used

- **BlackHole** (GPL-3) was read only for high-level structural understanding, per CLAUDE.md's
  explicit permission ("may be read for understanding, NEVER copy code from it"). No BlackHole
  source is copied, transcribed, or adapted anywhere in this repository. The driver is written
  fresh against Apple's own header contract.
- **Apple's historical "NullAudio" AudioServerPlugIn sample** was *not* used as a source, and no
  code from it appears anywhere in this repository. I attempted to re-verify its current license
  terms directly, per the owner's instruction, before deciding whether to rely on it at all:
  fetching `https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in`
  and the archived sample listing page both returned only the page's `<title>` element
  ("Creating an Audio Server Driver Plug-in | Apple Developer Documentation") with no body text —
  Apple's developer-documentation site is a JavaScript-rendered single-page app and the fetch
  tooling available in this session cannot execute that JavaScript, so the page's actual content
  (and any license/redistribution text on it) could not be confirmed. Rather than rely on memory
  of a retired sample's license, or risk copying anything under unclear terms, the driver in this
  repo is implemented **solely from `AudioServerPlugIn.h`**, the header shipped in the macOS 27
  SDK at `.../CoreAudio.framework/Headers/AudioServerPlugIn.h` (verified present by
  `scripts/preflight.sh`, header inspected directly on disk). That header states only:
  `Copyright: (c) 1985-2025 by Apple Inc., all rights reserved.` — it is a normal system header
  describing a public plug-in interface, used here the same way any Apple framework header is used
  by code that implements against it; it is not sample/example code and carries no separate
  redistribution license to evaluate. This satisfies CLAUDE.md's "Apple frameworks + code written
  in this repo ONLY" rule without any open question about sample-code licensing.

## Device visibility gating ("only for this recognised USB mic")

Per the owner's clarification, Boosted must be scoped to the specific recognised Snowball
(USB VID `0x0D8C` / PID `0x0005`) and auto-loaded — no device picker. The driver attempts to gate
Boosted's visibility on Snowball presence via IOKit matching notifications inside the plug-in
process. `AudioServerPlugIn.h` permits IOKit user-client access for standard IOKit objects without
extra Info.plist declarations. If IOKit notification setup fails in the plug-in's sandboxed
environment (to be confirmed empirically at build/verify time — see `docs/PROGRESS.md`), the
fallback is to leave Boosted always visible in the device list, but the app-side engine still only
builds the capture aggregate and runs the IOProc when the physical Snowball is actually present —
so no audio is ever produced from a device that isn't there, even if the empty device stays listed.

## Fallback: hidden device cannot be an aggregate sub-device

If verification (execution step 7) shows a hidden (`kAudioDevicePropertyIsHidden`) device cannot
be added as an aggregate sub-device, the plan's documented fallback is used: make Feed visible but
set `DeviceCanBeDefaultDevice` / `DeviceCanBeDefaultSystemDevice` to false, and rename it
"Snowball Boost (internal)" so it's clearly not meant to be selected directly.

## Signing / security summary (expanded in BUILD.md)

- Driver bundle: no entitlements (a HAL plug-in can't hold its own entitlements meaningfully; it
  runs inside `coreaudiod`'s process). Signed with the Apple Development identity, ad-hoc fallback.
  No SIP change. No kext. No AudioDriverKit approval needed (not used).
- App + CLI: Apple Development signing, hardened runtime, `com.apple.security.device.audio-input`
  entitlement (required — without it TCC silently denies mic access under hardened runtime),
  `NSMicrophoneUsageDescription` in Info.plist.
- Developer ID / notarization: only relevant for distributing outside this Mac; not required for
  local development/use, which is this project's only target per REQUIREMENTS.md.

## Non-goals (explicitly out of scope)

No noise suppression, echo cancellation, EQ, AGC, or any cloud/AI processing — gain + limiter
only. No network code (`URLSession`, sockets) anywhere. No device picker UI — the Snowball match
rule is hard-wired (transport `usb ` AND ModelUID ends with `:0D8C:0005`; multiple matches sorted
by UID, first one wins, deterministic).
