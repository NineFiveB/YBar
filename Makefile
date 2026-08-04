# Build artifacts live outside the repo: this project sits in ~/Documents, which
# iCloud syncs — the fileprovider daemon stamps xattrs onto freshly built
# bundles and codesign then rejects them as "detritus". A scratch path outside
# the synced tree sidesteps the race entirely. See docs/BUILDING.md.
SCRATCH := $(HOME)/.cache/ybar-build
# debug/ is stable across SwiftPM build systems (a symlink on the
# swiftbuild layout, the real directory on classic).
BIN     := $(SCRATCH)/debug/ybar

.PHONY: build test run stop clean app helpers release

# App bundle: gives the daemon its own TCC identity so privacy prompts
# (Bluetooth, Calendar, Apple Events) are attributed to YBar and grants
# cover the daemon plus every helper it spawns. Launch with:
#   open -g ~/Applications/YBar.app --args -c <config.lua>
APP_DIR := $(HOME)/Applications/YBar.app
# Stable identity if present ("YBar Signing" self-signed cert), else ad-hoc.
# A stable signature keeps TCC grants (Accessibility, Screen Recording)
# valid across rebuilds; ad-hoc voids them every time.
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q "YBar Signing" && echo YBar Signing || echo -)

app: build
	rm -rf $(APP_DIR)
	mkdir -p $(APP_DIR)/Contents/MacOS $(APP_DIR)/Contents/Resources
	cp packaging/Info.plist $(APP_DIR)/Contents/Info.plist
	cp $(BIN) $(APP_DIR)/Contents/MacOS/ybar
	cp -R $(SCRATCH)/debug/YBar_YBarKit.bundle $(APP_DIR)/Contents/Resources/
	codesign --force --sign "$(SIGN_ID)" --identifier com.ybar.YBar $(APP_DIR)

build:
	swift build --scratch-path $(SCRATCH)

# Example-config helper binaries (gitignored; the sketchybar-port and glass
# themes need them for the app-menus row and the Background widget).
HELPERS := examples/sketchybar-port/helpers
helpers:
	mkdir -p $(HELPERS)/bin
	swiftc -O $(HELPERS)/statusitems.swift -o $(HELPERS)/bin/statusitems
	$(MAKE) -C $(HELPERS)/menus

# Distribution zip. Staged inside the scratch tree — never ~/Applications —
# because codesign must run outside the iCloud-synced repo (same xattr race
# as `build`). Note the resulting zip's signature is local-only: on any other
# machine the download fails Gatekeeper until re-signed (docs/INSTALL.md).
VERSION ?= 0.1.0
STAGE   := $(SCRATCH)/stage/YBar.app

release:
	swift build -c release --scratch-path $(SCRATCH)
	rm -rf $(SCRATCH)/stage
	mkdir -p $(STAGE)/Contents/MacOS $(STAGE)/Contents/Resources
	cp packaging/Info.plist $(STAGE)/Contents/Info.plist
	cp $(SCRATCH)/release/ybar $(STAGE)/Contents/MacOS/ybar
	cp -R $(SCRATCH)/release/YBar_YBarKit.bundle $(STAGE)/Contents/Resources/
	codesign --force --sign "$(SIGN_ID)" --identifier com.ybar.YBar $(STAGE)
	mkdir -p dist
	rm -f dist/YBar-$(VERSION).zip
	ditto -c -k --keepParent $(STAGE) dist/YBar-$(VERSION).zip
	shasum -a 256 dist/YBar-$(VERSION).zip

# -load-plugin-library: the CLT build planner intermittently misses the
# TestingMacros plugin in its testing/ subdirectory (docs/BUILDING.md).
TESTING_MACROS := /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib

test: build
	swift test --scratch-path $(SCRATCH) \
	  $(shell [ -f $(TESTING_MACROS) ] && echo -Xswiftc -load-plugin-library -Xswiftc $(TESTING_MACROS))

run: build
	$(BIN)

stop:
	-$(BIN) --exit 2>/dev/null

clean:
	rm -rf $(SCRATCH)
