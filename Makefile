APP_NAME    := ClaudeMeter
CONFIG      := release
## Code signing identity. Ad-hoc (`-`) by default, which needs no setup and is enough to run.
##
## The cost of ad-hoc is a new code identity on every rebuild, so macOS treats each build as a
## different program and re-asks for Keychain access — every launch, in practice, since the item's
## ACL never matches the app that is asking. Any stable identity fixes that, because "Always Allow"
## then keeps applying:
##
##     security find-identity -v -p codesigning        # pick one
##     make install SIGN_ID="Apple Development: you@example.com (TEAMID)"
SIGN_ID     ?= -
DIST        := dist
APP         := $(DIST)/$(APP_NAME).app
CONTENTS    := $(APP)/Contents
BIN_PATH    := $(shell swift build -c $(CONFIG) --show-bin-path 2>/dev/null)

.PHONY: all build app run install test clean uninstall

all: app

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
app: build
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
	@# See `SIGN_ID` above for why the default costs a Keychain prompt per launch.
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
