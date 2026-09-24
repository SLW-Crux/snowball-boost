# Snowball Boost — project rules for Claude Code

Read before doing anything: `docs/REQUIREMENTS.md` (owner's spec, authoritative) and
`docs/PLAN.md` (approved design). Execute the plan; do not redesign it. If something in the plan
proves impossible on this machine, stop, explain with evidence, propose the smallest change.

## Hard constraints
- Apple frameworks + code written in this repo ONLY. No third-party packages, no Homebrew tools,
  no XcodeGen, no CocoaPods, no downloaded binaries or scripts.
- BlackHole is GPL-3: may be read for understanding, NEVER copy code from it. Driver is written from
  Apple's `AudioServerPlugIn.h` contract / Apple sample structure.
- No network code, telemetry, analytics, crash upload. No `URLSession`, no sockets.
- No kext, no AudioDriverKit, no SIP changes, no `csrutil`.
- No noise suppression / AEC / EQ / AGC / voice processing. Gain + limiter only.
- Do NOT touch anything in `/Library/Audio/Plug-Ins/HAL/` except `SnowballBoost.driver`.
  Do not read, move, "clean up" or comment on other plug-ins there.
- Never modify Apple audio config, other devices' settings, or the Snowball's hardware gain
  (reading it for diagnostics is fine).
- Keep it small. V1 = Snowball → +12 dB → limiter → "Snowball Boosted".

## Toolchain (already present — do not install anything)
- Xcode 27.0 at `/Applications/Xcode.app`; `xcode-select -p` = `/Applications/Xcode.app/Contents/Developer`.
  Run `bash scripts/preflight.sh` first; if it reports Command Line Tools instead of Xcode, tell the
  owner to run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` and wait.
- Swift 6.4, macOS 27 SDK, arm64. Deployment target macOS 15.0+ is fine (needs `Synchronization`).
- Build system: SwiftPM (`Package.swift`) for DSP (C target), SnowballCore, app, CLI, tests;
  `Makefile` + `clang` for the `.driver` bundle and for assembling/signing `.app` bundles.
  No `.xcodeproj` (hand-written pbxproj is fragile). `xcodebuild` not required.
- Tests: `swift test` (Swift Testing or XCTest, both ship with Xcode).

## Signing
- Default identity: ad-hoc (`-`). Makefile variable `SIGN_ID` overrides it — set your own via an
  untracked `Makefile.local` (`SIGN_ID = Apple Development: Your Name (TEAMID)`) rather than
  editing the Makefile, so your identity never ends up in a commit.
- App: hardened runtime (`--options runtime`) + entitlement `com.apple.security.device.audio-input`,
  Info.plist `NSMicrophoneUsageDescription`, `LSUIElement=YES`, bundle id `com.snowballboost.app`.
  Without the entitlement TCC silently denies the mic under hardened runtime.
- CLI `sbboost`: embed Info.plist via `-Xlinker -sectcreate __TEXT __info_plist` with
  `NSMicrophoneUsageDescription`; same identity + entitlement.
- Driver: sign bundle (no entitlements). Export factory with `__attribute__((visibility("default")))`.

## Device match rule (generic — applies to any Blue Snowball iCE)
- ModelUID ends with `:0D8C:0005` (USB VID 0x0D8C, PID 0x0005 — the whole Snowball iCE product
  line, not one unit), transport `usb `. Multiple matches → sort by UID, first.
- Each physical unit's full device UID (`AppleUSBAudioEngine:...:<serial>:...`) is unique per Mac
  and per USB port history — don't hard-code one. Find yours with `sbboost status`.
- Typical stream format: Int16 mono 48 kHz (also 44.1/32/22.05/16/11.025/8 kHz supported).
  HW input gain range is roughly −8…+10 dB but varies slightly per unit — check with
  `sbboost status`, which reads it live.

## Boundaries the owner must handle (stop and ask with the exact command)
- Anything needing `sudo` (driver install into `/Library/Audio/Plug-Ins/HAL`, `sudo killall coreaudiod`,
  uninstall). You cannot type the password. Give the command in a ```bash block and wait.
- Microphone permission prompts (TCC "Allow") for the app and for the terminal/Claude host running `sbboost`.
- macOS "Background item added" notification for the LaunchAgent.
- Physical actions: unplug/replug Snowball, sleep/wake, speaking into the mic for benchmarks.

## Honesty rules
- Only claim something works if you ran it and saw the result. Quote real command output.
- Keep a running `docs/PROGRESS.md`: step, what was run, result, what's pending on the owner.
- If a step is skipped or untestable here, say so explicitly.
- Leave the repo buildable (`make`) and testable (`make test`) at the end of every work session.
- Do not `git init`/commit/push unless the owner asks.
