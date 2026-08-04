# Building YBar

## Requirements

- macOS 14+ (the animation clock uses `NSView.displayLink`, macOS 14+)
- Swift 6 toolchain — **Command Line Tools are sufficient**; full Xcode is not required because shaders compile at runtime (`MTLDevice.makeLibrary(source:)`) instead of through the `metal` compiler at build time.

## The iCloud/xattr gotcha

If the repo lives under `~/Documents` or `~/Desktop` with iCloud sync enabled, plain `swift build` intermittently fails at the codesign step:

```
resource fork, Finder information, or similar detritus not allowed
```

The fileprovider daemon races the build and stamps `com.apple.FinderInfo` / `com.apple.fileprovider.fpfs#P` extended attributes onto the freshly assembled resource bundle; `codesign` refuses files carrying them. The fix is to keep build products outside the synced tree, which is exactly what the Makefile does:

```sh
make build     # = swift build --scratch-path ~/.cache/ybar-build
```

(The SIP-protected `com.apple.provenance` xattr is fine — codesign tolerates it.)

## Running tests with Command Line Tools only

`swift test` needs Swift Testing's runtime. The CLT ships `Testing.framework` at
`/Library/Developer/CommandLineTools/Library/Developer/Frameworks/`, but on some CLT builds two things are broken:

1. The test bundle's rpaths don't cover that directory, and the framework's own install-name-relative path to `lib_TestingInterop.dylib` is computed one directory short.
2. The fix is two symlinks inside the (stable) products directory:

```sh
SCRATCH=~/.cache/ybar-build/debug
mkdir -p $SCRATCH/YBarKitTests.xctest/Contents/Frameworks
ln -sfn /Library/Developer/CommandLineTools/Library/Developer/Frameworks/Testing.framework \
        $SCRATCH/YBarKitTests.xctest/Contents/Frameworks/Testing.framework
ln -sfn "/Library/Developer/CommandLineTools/Library/Developer/usr/lib/lib_TestingInterop.dylib" \
        $SCRATCH/lib_TestingInterop.dylib
```

`make test` works normally once these exist (they survive incremental builds). With full Xcode installed none of this is needed.

If macro-resolution errors appear (`plugin for module 'TestingMacros' not found`): the CLT build planner intermittently fails to resolve the macro plugin living in the `plugins/testing/` subdirectory. The reliable fix (baked into `make test`) is passing it explicitly:

```sh
swift test --scratch-path ~/.cache/ybar-build \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

## Verifying the power story

The renderer must do zero GPU work while the bar is static:

```sh
sudo powermetrics -s gpu_power -i 1000
```

GPU HW active residency should be ~0% between updates and only tick up during `--animate` windows.
