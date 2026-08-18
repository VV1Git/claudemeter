APP_NAME    := ClaudeMeter
CONFIG      := release
## Code signing identity. There is no usable default, which is why `app` stops rather than
## guessing.
##
## Ad-hoc signing (`-`) needs no setup, and costs a new code identity on every rebuild: macOS
## treats each build as a different program, the credential item's ACL never matches the app that
## is asking, and every launch needs a fresh Keychain authorization that "Always Allow" cannot
## settle, because the next build is a different program again. (ClaudeMeter never raises that
## dialog by itself, so what you actually see is the panel asking to be authorized after every
## rebuild.) A stable identity fixes it outright:
##
##     security find-identity -v -p codesigning        # pick one
##     make install SIGN_ID="Apple Development: you@example.com (TEAMID)"
##
## `make app ALLOW_ADHOC=1` builds ad-hoc anyway, for a throwaway build that will not read the
## Keychain.
SIGN_ID     ?= -
DIST        := dist
APP         := $(DIST)/$(APP_NAME).app
CONTENTS    := $(APP)/Contents
BIN_PATH    := $(shell swift build -c $(CONFIG) --show-bin-path 2>/dev/null)

.PHONY: all build app run install test clean uninstall check-identity

all: app

## Refuses an accidental ad-hoc build. See `SIGN_ID` above for what it would cost.
check-identity:
	@if [ "$(SIGN_ID)" = "-" ] && [ -z "$(ALLOW_ADHOC)" ]; then \
		echo "SIGN_ID is ad-hoc (\"-\"), which gives this build a new code identity."; \
		echo "The Keychain will not recognise it, so ClaudeMeter will need authorizing"; \
		echo "after every rebuild and Always Allow will not stick."; \
		echo ""; \
		echo "  security find-identity -v -p codesigning"; \
		echo "  make $(MAKECMDGOALS) SIGN_ID=\"Apple Development: you@example.com (TEAMID)\""; \
		echo ""; \
		echo "Or ALLOW_ADHOC=1 to build ad-hoc anyway."; \
		exit 1; \
	fi

build:
	swift build -c $(CONFIG)

## `--no-parallel` is load-bearing, not caution. Several suites redirect the same
## process-global Paths.supportDirectoryOverride / claudeProjectsOverride, and
## swift-testing runs suites concurrently — so in parallel one suite's temp-tree
## cleanup can delete another's mid-test. Serial execution costs little here.
test:
	swift test --no-parallel

## Assemble a real .app bundle. SwiftPM only produces a bare executable, so the
## bundle structure, Info.plist (LSUIElement lives there) and signature are done here.
app: check-identity build
	rm -rf "$(APP)"
	mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	cp "$(BIN_PATH)/$(APP_NAME)" "$(CONTENTS)/MacOS/$(APP_NAME)"
	cp Packaging/Info.plist "$(CONTENTS)/Info.plist"
	printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@# SwiftPM emits resource bundles alongside the binary; the app needs them
	@# beside itself for Bundle.module to resolve.
	@for b in "$(BIN_PATH)"/*.bundle; do \
		[ -e "$$b" ] && cp -R "$$b" "$(CONTENTS)/Resources/" || true; \
	done
	@# `check-identity` has already refused an ad-hoc build unless ALLOW_ADHOC was set.
	codesign --force --sign "$(SIGN_ID)" --timestamp=none "$(APP)"
	@echo "Built $(APP)"

run: app
	@pkill -x $(APP_NAME) 2>/dev/null || true
	open "$(APP)"

install: app
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP)" /Applications/
	@echo "Installed to /Applications/$(APP_NAME).app"

uninstall:
	@pkill -x $(APP_NAME) 2>/dev/null || true
	rm -rf "/Applications/$(APP_NAME).app"

clean:
	swift package clean
	rm -rf "$(DIST)"
