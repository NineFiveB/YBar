# Build artifacts live outside the repo: this project sits in ~/Documents, which
# iCloud syncs — the fileprovider daemon stamps xattrs onto freshly built
# bundles and codesign then rejects them as "detritus". A scratch path outside
# the synced tree sidesteps the race entirely. See docs/BUILDING.md.
SCRATCH := $(HOME)/.cache/ybar-build
BIN     := $(SCRATCH)/out/Products/Debug/ybar

.PHONY: build test run stop clean

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
