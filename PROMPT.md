# Prompt to paste into a new Claude Code session

Copy everything between the two lines below into a new Claude Code session opened on this folder.

---

You are building **Snowball Boost** in this repository: a macOS 27 virtual microphone that takes the
Blue Snowball (via Apple's own USB audio driver), applies clean digital gain (+12 dB default) and a
transparent peak limiter, and publishes the result as a Core Audio input device named
**"Snowball Boosted"**.

Before anything else, read these in full:
1. `CLAUDE.md`: project rules, toolchain, signing, constraints, and the boundaries where you must stop.
2. `docs/REQUIREMENTS.md`: the owner's spec. It is authoritative.
3. `docs/PLAN.md`: the approved architecture and design. Implement this design; do not redesign it.

Then run `bash scripts/preflight.sh` and fix nothing it reports without asking. It must show Xcode 27
selected, the macOS SDK present, the signing identity found, and the Blue Snowball connected.

Carry out `docs/PLAN.md` → "Execution steps" in order, working iteratively. Use a todo list.

1. **ARCHITECTURE.md first.** Write up the decision and the rejected alternatives, citing the research
   in PLAN.md. Before relying on the Apple sample's license, confirm it yourself by reading Apple's
   current page "Creating an Audio Server Driver Plug-in".
2. **DSP.** Write `Package.swift`, the C kernel `Sources/BoostDSP`, and the tests in `Tests/BoostDSPTests`
   covering every item in PLAN.md → Verification. Run `swift test` until it passes.
3. **Driver.** Write the `Driver/` C AudioServerPlugIn, its Info.plist, and the Makefile target that
   builds and signs `build/SnowballBoost.driver`. Build it and run `codesign --verify`. Check that the
   factory symbol is exported: `nm -gU` must show it.
4. **Core and CLI.** Write `Sources/SnowballCore` and the `sbboost` CLI. Run `sbboost status` against
   the real Snowball; this needs no install.
5. **App and install scripts.** Write the menu-bar app, the LaunchAgent plist, `scripts/install.sh`,
   `scripts/uninstall.sh`, and the Makefile targets `all`, `test`, `app`, `driver`, `cli`, `install`,
   `install-driver`, `uninstall` and `clean`.
6. **Stop: owner installs the driver.** Give the exact command in a ```bash block
   (e.g. `make install-driver` — no `sudo` prefix; it escalates internally only where needed).
   Wait for the owner to confirm before continuing.
7. **Check the devices.** Confirm Core Audio lists "Snowball Boosted" (1 in / 0 out) and that the
   hidden Feed device resolves by UID. Confirm the private aggregate (Snowball + Feed, with drift
   compensation) can be created. If a hidden device cannot be a subdevice, use the fallback written
   in PLAN.md.
8. **Stop: owner grants microphone access.** Tell the owner exactly which prompts to expect, then
   install and start the app/LaunchAgent via `make install`.
9. **Measure and harden.** Run `sbboost diagnose` and `sbboost bench` while the owner speaks at
   30 cm, and report the real numbers. Test unplug/replug, 44.1↔48 kHz, `sudo killall coreaudiod`
   (owner runs it), and killing the app (LaunchAgent must restart it). Sleep/wake is a manual check:
   ask the owner to do it.
10. **Documentation.** Write README.md (with a very short Quick Start), BUILD.md, INSTALL.md,
    UNINSTALL.md, and TROUBLESHOOTING.md covering all 8 topics required in REQUIREMENTS.md. BUILD.md
    must answer: what runs ad-hoc signed, what needs Developer ID, which entitlements are used, why
    AudioDriverKit approval is not needed, and why SIP is untouched.

Rules while working:
- After every step, build and test. Fix compiler errors and warnings before moving on.
- Keep `docs/PROGRESS.md` updated with what you ran, the real result, and anything waiting on the owner.
- Never claim something works unless you ran it. Quote the actual output.
- At any boundary you cannot pass (sudo, a TCC prompt, a physical action), stop and give the exact
  command or action, then wait.
- Do not add dependencies, network code, or extra DSP. Do not touch other HAL plug-ins or Apple audio
  settings. Do not over-engineer.
- Finish with the repo in a state where `make && make test` succeed, plus a short summary: what was
  verified, what is still unverified, and the measured before/after levels.

---
