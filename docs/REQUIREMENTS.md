# Snowball Boost — Original Requirements (from the owner)

This is the authoritative spec. `docs/PLAN.md` is the approved design that satisfies it.
Where they conflict, this file wins; flag the conflict instead of guessing.

## Target machine
- Apple Silicon Mac, macOS 27
- Blue Snowball iCE USB microphone, model A00122
- Works correctly through Apple's built-in USB Audio / Core Audio driver
- Audio MIDI Setup shows the Snowball as: 1 input, 0 outputs, 48,000 Hz, 16-bit integer
- macOS exposes hardware input gain, but even near maximum the level is too low at a normal
  speaking distance of ~30 cm. Two separate A00122 units behave the same.

## Objective
Do NOT write a replacement USB driver. Keep Apple's USB audio driver and create a local virtual microphone:

```
Blue Snowball → Apple USB Audio / Core Audio → Snowball Boost → digital gain → limiter
  → virtual microphone visible to macOS/apps, named "Snowball Boosted"
```

Must be selectable in Voice Memos, QuickTime, Zoom, Teams, browsers, ChatGPT, and any other app
using normal Core Audio input devices.

## Architecture constraints
Simplest supported architecture that:
1. works on Apple Silicon;
2. works on macOS 27;
3. does not require disabling SIP for normal installation/use;
4. does not require a kernel extension;
5. processes all audio locally;
6. exposes a normal Core Audio input device to arbitrary applications;
7. automatically obtains audio from the physical Blue Snowball;
8. runs persistently without manual routing after every reboot.

Document the architecture decision before implementing. If a pure HAL plug-in cannot capture another
physical input device, do NOT invent a workaround inside the driver — use a minimal companion
process/LaunchAgent plus virtual device.

## Functional requirements
Input device:
- Automatically locate the Blue Snowball; prefer stable Core Audio/USB properties over display name.
- Do not interfere with the original Blue Snowball device.
- If more than one Snowball exists, deterministic selection.
- Owner clarification: this is ONLY for this recognised USB mic, and it must be auto-loaded.

Virtual device:
- Name "Snowball Boosted"; mono input; 48 kHz preferred, 44.1 kHz too if straightforward.
- Visible in Audio MIDI Setup and System Settings › Sound › Input; usable by normal Core Audio apps.

Processing chain:
```
input → convert to Float32 if necessary → adjustable digital gain → limiter → virtual mic output
```
- Gain settings: 0, +6, +9, +12, +15, +18 dB. Default +12 dB.
- multiplier = 10^(gainDB / 20). Do NOT multiply integer PCM without proper conversion/headroom.
- Simple, transparent peak limiter so loud speech never hard-clips.
- Do NOT add: noise suppression, echo cancellation, EQ, AGC, cloud processing, AI processing.

Latency: as low as reasonably possible for live speech/conferencing; no unnecessary buffering.

Device handling — recover automatically from: Snowball unplugged, plugged back in, sleep/wake,
sample-rate changes, audio device changes, application restarts, service restart, Snowball
unavailable at boot.

## Privacy
Absolutely no network access, telemetry, analytics, crash-report uploads, cloud services.
Audio never leaves the Mac. No third-party dependencies unless genuinely necessary.

## Control (V1, extremely simple)
Tiny native menu-bar app or a CLI. Must show: Snowball connected, Snowball Boost running, gain
selection, current input peak, current output peak, limiter activity. Persist gain across restarts.

## Installation
Proper installer/uninstaller: build components, install virtual audio component correctly,
install/start LaunchAgent/service, make "Snowball Boosted" appear, clean uninstall.
Do not modify or delete Apple's existing audio configuration. No manual copying into system dirs.

## Development / signing
Initially for the owner's own Mac; optimise for local dev/testing. Explain: what can run ad-hoc
signed, what needs Developer ID, whether any Apple entitlement is needed, whether AudioDriverKit
approval is needed, whether SIP must change. Avoid anything requiring SIP to be disabled.

## Testing
Automated DSP tests, at minimum:
1. 0 dB = unity gain
2. +6/+12/+18 dB mathematically correct
3. silence stays silence
4. positive/negative PCM symmetric
5. limiter prevents output exceeding full scale
6. sustained normal speech → no obvious pumping
7. no NaN/Inf propagation
8. mono stream integrity

Diagnostic tool reporting:
- Physical input: Blue Snowball, sample rate, format, current Core Audio gain, measured RMS, measured peak
- Virtual output: Snowball Boosted, gain applied, measured RMS, measured peak, limiter activity

Purpose: prove whether +12 dB actually solves the original problem.

## Benchmark
Instructions for recording the same speech through (A) raw "Blue Snowball" and (B) "Snowball Boosted"
at +12 dB, comparing RMS, peak, clipping, noise floor, latency.

## Deliverables
Complete working repository, not snippets: README.md (with a very short Quick Start),
ARCHITECTURE.md (why this architecture, why alternatives rejected), BUILD.md, INSTALL.md,
UNINSTALL.md, TROUBLESHOOTING.md, and all source/build/project files.

TROUBLESHOOTING.md must cover: Snowball detected but Snowball Boosted not visible; Boosted visible
but silent; very low level; clipping; sample-rate mismatch; device disappears after sleep;
microphone permissions; service/LaunchAgent problems.

## Working method
Do not stop after generating source code. Iterate:
1. research current macOS 27 APIs  2. write ARCHITECTURE.md  3. implement  4. build
5. fix compiler errors  6. run unit tests  7. install locally where permissions allow
8. verify Core Audio enumerates "Snowball Boosted"  9. verify the physical Snowball can be opened
10. run the diagnostic  11. fix issues  12. leave the repo buildable/testable.

Never claim something works unless it was actually tested. If macOS security blocks an
install/test, stop at that boundary, state exactly what command/action the owner must perform,
then continue once done.

**Do not over-engineer.** V1 is simply: Blue Snowball → +12 dB clean gain → Snowball Boosted.
