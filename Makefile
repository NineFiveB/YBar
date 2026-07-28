# Build artifacts live outside the repo: this project sits in ~/Documents, which
# iCloud syncs — the fileprovider daemon stamps xattrs onto freshly built
# bundles and codesign then rejects them as "detritus". A scratch path outside
# the synced tree sidesteps the race entirely. See docs/BUILDING.md.
SCRATCH := $(HOME)/.cache/ybar-build
BIN     := $(SCRATCH)/out/Products/Debug/ybar

.PHONY: build test run stop clean

build:
	swift build --scratch-path $(SCRATCH)

test: build
	swift test --scratch-path $(SCRATCH)

run: build
	$(BIN)

stop:
	-$(BIN) --exit 2>/dev/null

clean:
	rm -rf $(SCRATCH)
