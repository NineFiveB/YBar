# Contributing

- Build: `make build` (Command Line Tools are enough; glass backdrops need
  the macOS 26 SDK — older toolchains build with the blur fallback).
- Tests: `make test` must pass. New engine features need tests. The
  text-metric goldens (`Tests/Fixtures/text-metrics.json`, measured with the
  vendored `Tests/Fixtures/YBarTestSans-Regular.ttf`) are regenerated with
  `YBAR_EXPORT_GOLDENS=1 make test`; that run fails by design so an export
  can never pass as green — re-run without the variable to check the new
  values in.
- CI: every push and pull request to `main` runs `make build`, `make test`
  and `make app` on macOS 26 and macOS 15 (`.github/workflows/ci.yml`);
  the spec-copy diff against the `windows` branch is advisory only.
- Releases: bump the version in its three hand-edited places
  (`Version.current` in `Sources/YBarKit/IPC/SocketClient.swift`,
  `CFBundleShortVersionString` in `packaging/Info.plist`, `VERSION` in the
  `Makefile`; bump `CFBundleVersion` too — it is the build number a tag
  install reports), then `git tag v<x> && git push origin v<x>` to
  NineFiveB/YBar. `.github/workflows/release.yml` gates the tag against
  those three, runs the tests, pins the formula's url and sha256 from the
  tag's own tarball, proves it with a build-from-source install, commits
  the pin back to `main`, pushes the formula to the tap (needs the
  `HOMEBREW_TAP_TOKEN` secret) and publishes the GitHub Release; nothing in
  the formula's url or sha256 is edited by hand.
- Helper binaries for the example configs: `make helpers`.
- Themes: see docs/THEMES.md. Ship a README crediting the palette/design
  origin, probe for optional binaries (aerospace, brew, gh) and hide
  modules when they are missing, and write Nerd Font glyphs as Lua
  `\u{...}` escapes.
- Keep configs portable: no absolute paths from your machine; derive
  directories from the config's own location.
- Commit messages: explain the why; no emojis in code or docs.
