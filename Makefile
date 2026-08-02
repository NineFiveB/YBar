# Build artifacts live outside the repo: this project sits in ~/Documents, which
# iCloud syncs — the fileprovider daemon stamps xattrs onto freshly built
# bundles and codesign then rejects them as "detritus". A scratch path outside
# the synced tree sidesteps the race entirely. See docs/BUILDING.md.
SCRATCH := $(HOME)/.cache/ybar-build
BIN     := $(SCRATCH)/out/Products/Debug/ybar

.PHONY: build test run stop clean app

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
	cp -R $(SCRATCH)/out/Products/Debug/YBar_YBarKit.bundle $(APP_DIR)/Contents/Resources/
	codesign --force --sign "$(SIGN_ID)" --identifier com.ybar.YBar $(APP_DIR)

build:
	swift build --scratch-path $(SCRATCH)

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
