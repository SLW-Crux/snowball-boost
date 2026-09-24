#!/bin/bash
# Snowball Boost — read-only environment check. Changes nothing.
set -u
ok()   { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAILED=1; }
FAILED=0

echo "== macOS / hardware"
ver=$(sw_vers -productVersion); arch=$(uname -m)
[[ "${ver%%.*}" -ge 27 ]] && ok "macOS $ver" || warn "macOS $ver (plan targets 27)"
[[ "$arch" == arm64 ]] && ok "arch $arch" || fail "arch $arch (expected arm64)"
sip=$(csrutil status 2>/dev/null)
[[ "$sip" == *enabled* ]] && ok "SIP enabled (nothing here needs it changed)" || warn "SIP: $sip"

echo "== Xcode toolchain"
dev=$(xcode-select -p 2>/dev/null)
if [[ "$dev" == /Applications/Xcode*.app/Contents/Developer ]]; then ok "xcode-select -> $dev"
else fail "xcode-select -> '$dev'. Owner must run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"; fi
xv=$(xcodebuild -version 2>/dev/null | head -1) && ok "$xv" || fail "xcodebuild not usable (license not accepted? run: sudo xcodebuild -license accept)"
sv=$(swift --version 2>/dev/null | grep -o 'Swift version [0-9.]*') && ok "$sv" || fail "swift not found"
sdk=$(xcrun --show-sdk-path 2>/dev/null) && ok "SDK $(xcrun --show-sdk-version) at $sdk" || fail "macOS SDK not found"
[[ -f "$sdk/System/Library/Frameworks/CoreAudio.framework/Headers/AudioServerPlugIn.h" ]] \
  && ok "AudioServerPlugIn.h present" || fail "AudioServerPlugIn.h missing from SDK"
for t in clang codesign make plutil; do xcrun -f "$t" >/dev/null 2>&1 || command -v "$t" >/dev/null && ok "$t" || fail "$t missing"; done

echo "== Signing"
id=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development: [^"]*"' | head -1)
[[ -n "$id" ]] && ok "identity $id" || warn "no Apple Development identity — build will fall back to ad-hoc (mic permission may re-prompt after rebuilds)"

echo "== Blue Snowball"
system_profiler SPAudioDataType 2>/dev/null | grep -q "Blue Snowball:" \
  && ok "Core Audio lists 'Blue Snowball'" \
  || warn "Core Audio does not list 'Blue Snowball' — plug it in (build still works; device tests need it)"

echo "== Snowball Boost install state"
[[ -d /Library/Audio/Plug-Ins/HAL/SnowballBoost.driver ]] && ok "driver installed" || echo "  --    driver not installed yet"
[[ -d "/Applications/Snowball Boost.app" ]] && ok "app installed" || echo "  --    app not installed yet"
launchctl print "gui/$(id -u)/com.snowballboost.agent" >/dev/null 2>&1 && ok "LaunchAgent loaded" || echo "  --    LaunchAgent not loaded yet"
system_profiler SPAudioDataType 2>/dev/null | grep -q "Snowball Boosted:" && ok "'Snowball Boosted' visible" || echo "  --    'Snowball Boosted' not visible yet"

echo
[[ $FAILED -eq 0 ]] && echo "Preflight passed." || { echo "Preflight FAILED — fix the items above first."; exit 1; }
