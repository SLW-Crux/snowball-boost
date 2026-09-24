# Optional untracked file for your own local signing identity, e.g.:
#   SIGN_ID = Apple Development: Your Name (TEAMID1234)
-include Makefile.local

SIGN_ID ?= -
HAVE_SIGN_ID := $(shell [ "$(SIGN_ID)" = "-" ] && echo no || (security find-identity -v -p codesigning 2>/dev/null | grep -q "$(SIGN_ID)" && echo yes || echo no))
ifeq ($(HAVE_SIGN_ID),yes)
  EFFECTIVE_SIGN_ID := $(SIGN_ID)
else
  EFFECTIVE_SIGN_ID := -
endif

BUILD_DIR := build
DRIVER_BUNDLE := $(BUILD_DIR)/SnowballBoost.driver
DRIVER_CONTENTS := $(DRIVER_BUNDLE)/Contents
DRIVER_MACOS := $(DRIVER_CONTENTS)/MacOS

APP_BUNDLE := $(BUILD_DIR)/SnowballBoost.app
APP_CONTENTS := $(APP_BUNDLE)/Contents

CLI_BIN := .build/release/sbboost

.PHONY: all test driver app cli install install-driver uninstall clean

all: driver app cli
	swift build

test:
	swift test

driver: $(DRIVER_BUNDLE)

$(DRIVER_BUNDLE): Driver/SnowballBoostDriver.c Driver/Info.plist
	mkdir -p "$(DRIVER_MACOS)"
	clang -fPIC -bundle -arch arm64 -mmacosx-version-min=15.0 \
		-Wall -Wextra -Werror \
		-framework CoreAudio -framework CoreFoundation \
		-o "$(DRIVER_MACOS)/SnowballBoost" \
		Driver/SnowballBoostDriver.c
	cp Driver/Info.plist "$(DRIVER_CONTENTS)/Info.plist"
	plutil -lint "$(DRIVER_CONTENTS)/Info.plist"
	codesign --force --sign "$(EFFECTIVE_SIGN_ID)" "$(DRIVER_BUNDLE)"
	@echo "Signed $(DRIVER_BUNDLE) with: $(EFFECTIVE_SIGN_ID)"

# Build directory name has no space (Make target names with spaces are fragile); install.sh gives
# it its user-visible name ("Snowball Boost.app") when copying into /Applications.
app:
	swift build -c release --product SnowballBoostApp
	mkdir -p "$(APP_CONTENTS)/MacOS" "$(APP_CONTENTS)/Resources"
	cp .build/release/SnowballBoostApp "$(APP_CONTENTS)/MacOS/SnowballBoostApp"
	cp Resources/App-Info.plist "$(APP_CONTENTS)/Info.plist"
	plutil -lint "$(APP_CONTENTS)/Info.plist"
ifeq ($(HAVE_SIGN_ID),yes)
	codesign --force --sign "$(EFFECTIVE_SIGN_ID)" --options runtime --entitlements Resources/SnowballBoostApp.entitlements "$(APP_BUNDLE)"
else
	codesign --force --sign - "$(APP_BUNDLE)"
endif
	@echo "Signed $(APP_BUNDLE) with: $(EFFECTIVE_SIGN_ID)"

cli:
	swift build -c release --product sbboost
ifeq ($(HAVE_SIGN_ID),yes)
	codesign --force --sign "$(EFFECTIVE_SIGN_ID)" --options runtime --entitlements Resources/CLI.entitlements "$(CLI_BIN)"
else
	codesign --force --sign - "$(CLI_BIN)"
endif
	@echo "Signed $(CLI_BIN) with: $(EFFECTIVE_SIGN_ID)"

install: driver app cli
	@if [ "$$(id -u)" = "0" ]; then \
		echo "error: run 'make install' as yourself, not 'sudo make install' — codesign needs your" >&2; \
		echo "       login keychain, which root can't see. install.sh escalates internally, only" >&2; \
		echo "       for the driver copy and coreaudiod restart. Re-run: make install" >&2; \
		exit 1; \
	fi
	bash scripts/install.sh

install-driver: driver
	@if [ "$$(id -u)" = "0" ]; then \
		echo "error: run 'make install-driver' as yourself, not 'sudo make install-driver' —" >&2; \
		echo "       codesign needs your login keychain, which root can't see. install.sh" >&2; \
		echo "       escalates internally, only for the driver copy and coreaudiod restart." >&2; \
		echo "       Re-run: make install-driver" >&2; \
		exit 1; \
	fi
	bash scripts/install.sh --driver-only

uninstall:
	bash scripts/uninstall.sh

clean:
	rm -rf .build "$(BUILD_DIR)"
