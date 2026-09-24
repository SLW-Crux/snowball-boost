# How to run the build with Claude Code

## 1. Start the session
1. Open the Claude desktop app and go to the **Code** tab.
2. Start a new session with this folder (wherever you cloned it) as the working directory.
3. Claude Code loads `CLAUDE.md` and `.claude/settings.json` automatically.
4. Open `PROMPT.md`, copy the text between the two `---` lines, and paste it as your first message.

Xcode 27 is already installed and selected (`/Applications/Xcode.app`). Claude uses its compilers
through `swift`, `clang` and `make`. You don't need to open Xcode.

## 2. What Claude does on its own
- Runs `scripts/preflight.sh` (read-only checks).
- Writes ARCHITECTURE.md, the source code, tests, Makefile and scripts.
- Builds, runs the tests, and fixes compile errors in a loop.
- Records progress in `docs/PROGRESS.md`.

## 3. When Claude stops and waits for you
| When | What you do |
|---|---|
| Driver install | Run the `make install-driver` (or `make install`) command Claude gives you — **without** a `sudo` prefix, it prompts for your password internally only where needed — then tell Claude "done". |
| First mic access | macOS asks "Snowball Boost would like to access the microphone" → **Allow**. The terminal/Claude app may ask too → **Allow**. |
| LaunchAgent | macOS shows "Background item added: Snowball Boost". Leave it enabled. |
| Benchmark | Speak normally at ~30 cm for the number of seconds Claude asks. |
| Robustness tests | Unplug and replug the Snowball; put the Mac to sleep and wake it. |

## 4. Files in this folder
| Path | Purpose |
|---|---|
| `PROMPT.md` | The prompt to paste |
| `CLAUDE.md` | Rules Claude must follow (auto-loaded) |
| `docs/REQUIREMENTS.md` | Your original spec |
| `docs/PLAN.md` | The approved architecture and design |
| `scripts/preflight.sh` | Read-only environment check |
| `.claude/settings.json` | Pre-approved build/test commands so Claude asks you less often |
| `Driver/`, `Sources/`, `Tests/`, `Resources/` | Empty skeleton; Claude fills these in |
