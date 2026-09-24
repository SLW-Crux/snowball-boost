# Build

## Toolchain

Xcode 27, Swift 6.4, macOS 27 SDK, arm64. No `.xcodeproj` — everything builds via SwiftPM
(`Package.swift`) and `make`/`clang` for the parts SwiftPM can't produce (a `.driver` HAL plug-in
bundle, a signed `.app` bundle). Run `bash scripts/preflight.sh` first; it's read-only and checks
Xcode selection, SDK, signing identity, and that the Snowball is connected.

## Targets

```
make            # driver + app + cli + swift build; nothing installed
make test       # swift test (BoostDSPTests, SnowballCoreTests)
make driver     # build/SnowballBoost.driver — clang, signed
make app        # build/SnowballBoost.app — swift build -c release, signed with entitlements
make cli        # .build/release/sbboost — swift build -c release, signed with entitlements
make install    # driver + app + cli, then scripts/install.sh
make install-driver   # driver only, then scripts/install.sh --driver-only
make uninstall  # scripts/uninstall.sh
make clean      # rm -rf .build build
```

**Never prefix `make install` / `make install-driver` with `sudo`.** `codesign` needs your login
keychain (where the signing identity's private key lives), which a root process can't see —
running the whole `make` invocation as root fails signing with
`errSecInternalComponent: unable to build chain to self-signed root`. The scripts already escalate
internally, only for the driver copy into `/Library/Audio/Plug-Ins/HAL` and the `killall
coreaudiod` restart. The Makefile refuses to run `install`/`install-driver` as root and explains
this if you get it backwards.

## Signing identity

Everything is ad-hoc signed (`SIGN_ID = -`) by default — this works fine for building and running
on your own Mac. If you have your own Apple Development or Developer ID certificate and want a
signature that survives being copied/moved without re-signing (and avoids a re-prompt for
microphone access across rebuilds — see below), create an untracked `Makefile.local`:

```make
SIGN_ID = Apple Development: Your Name (TEAMID1234)
```

`Makefile.local` is git-ignored — your identity never ends up in a commit.

## What runs ad-hoc signed vs. what needs a real identity

- **Driver** (`SnowballBoost.driver`): signed with whatever `SIGN_ID` resolves to. No
  entitlements — a HAL plug-in runs inside a
  `coreaudiod`-managed helper process (`com.apple.audio.Core-Audio-Driver-Service.helper` on
  macOS 27) and doesn't hold entitlements of its own. Ad-hoc signing is sufficient to load; a real
  identity just means the signature survives being copied/moved without re-signing.
- **App** and **CLI**: signed with the same identity, **hardened runtime** (`--options runtime`),
  and the `com.apple.security.device.audio-input` entitlement. This combination is required —
  without the entitlement, TCC silently denies microphone access under hardened runtime (no error,
  just permanent silence). A stable signing identity across rebuilds also matters: if the identity
  changes, macOS treats the app as a different program and TCC's existing "Allow" grant doesn't
  carry over, so you'd be re-prompted.
- **Developer ID / notarization**: not used, not needed. Both only matter for distributing outside
  this Mac (Gatekeeper's first-launch check on a downloaded app). This project's only target is
  local use on the machine that builds it.

## Entitlements used

Only one, on the app and the CLI: `com.apple.security.device.audio-input`. Nothing else — no
sandbox, no network entitlements (there's no network code in this repo to entitle).

## Why AudioDriverKit approval isn't needed

AudioDriverKit targets physical hardware behind a DriverKit user client; per Apple DTS the
entitlements a *virtual* audio driver would need aren't granted to third-party developers, and
using it would mean writing a second driver that competes with Apple's own USB Audio driver for
the Snowball — which the owner's requirements explicitly rule out. This project doesn't use
AudioDriverKit at all: `SnowballBoost.driver` is a classic `AudioServerPlugIn`, loaded by
`coreaudiod` itself, not a DriverKit extension. See ARCHITECTURE.md for the full comparison.

## Why SIP is untouched

Nothing here needs SIP disabled or weakened. The driver installs into
`/Library/Audio/Plug-Ins/HAL/`, which is writable by an admin user with `sudo` — no
`csrutil` changes, no reduced security mode, no kext (kernel extensions are what typically force
SIP changes; this project has none). `scripts/preflight.sh` confirms SIP stays enabled and never
suggests changing it.

## The embedded Info.plist trick for the CLI

`sbboost` is a plain executable (no `.app` bundle), but TCC still needs an `Info.plist` with
`NSMicrophoneUsageDescription` to attribute a mic-access reason to it. `Package.swift` embeds
`Resources/CLI-Info.plist` into the binary via linker flags
(`-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Resources/CLI-Info.plist`)
— the standard way to give a bundle-less Mach-O binary an Info.plist. Verify it's present with
`otool -s __TEXT __info_plist .build/release/sbboost`.
