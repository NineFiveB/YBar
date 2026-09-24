# Contributing

- Build (macOS): `make build` (Command Line Tools are enough; glass backdrops
  need the macOS 26 SDK — older toolchains build with the blur fallback).
- Tests: `make test` must pass. New engine features need tests. The
  text-metric goldens (`Tests/Fixtures/text-metrics.json`, measured with the
  vendored `Tests/Fixtures/YBarTestSans-Regular.ttf`) are regenerated with
  `YBAR_EXPORT_GOLDENS=1 make test`; that run fails by design so an export
  can never pass as green — re-run without the variable to check the new
  values in.
- The Windows port is a separate C++ engine on the orphan `windows` branch
  (CMake + vcpkg, its own `ctest` suite and docs). A change to the command
  grammar, the IPC wire format or the Lua API belongs on both branches. When a
  verb cannot land on both at once, record the gap and the contract in
  docs/WINDOWS-PORT.md so the other branch can follow.
- CI: every push and pull request to `main` runs `make build`, `make test`
  and `make app` on macOS 26 and macOS 15 (`.github/workflows/ci.yml`);
  the spec-copy diff against the `windows` branch is advisory only.
- Releases: bump the version in its three hand-edited places
  (`Version.current` in `Sources/YBarKit/IPC/SocketClient.swift`,
  `CFBundleShortVersionString` in `packaging/Info.plist`, `VERSION` in the
  `Makefile`; bump `CFBundleVersion` too — it is the build number a tag
  install reports), rename the `## [Unreleased]` section of `CHANGELOG.md`
  to `## [<x>] — <date>` (that section becomes the GitHub Release notes)
  and make sure `SECURITY.md` lists the `<major.minor>.x` series as
  supported, then `git tag v<x> && git push origin v<x>` to NineFiveB/YBar.
  `.github/workflows/release.yml` gates the tag against all five, runs the
  tests, pins the formula's url and sha256 from the tag's own tarball,
  proves it with a build-from-source install, commits the pin back to
  `main`, pushes the formula to the tap (needs the `HOMEBREW_TAP_TOKEN`
  secret) and publishes the GitHub Release; nothing in the formula's url or
  sha256 is edited by hand.
- README GIFs: `scripts/record-readme-gifs.sh` is the recipe behind
  `docs/media/ybar-demo.gif` and `ybar-popups.gif` — the maintainer's
  AeroSpace workspace and crop geometry are baked in, and it drives a running
  bar with ffmpeg and gifski on PATH.
- Helper binaries for the example configs: `make helpers`.
- Themes: see docs/THEMES.md. Ship a README crediting the palette/design
  origin, probe for optional binaries (aerospace, brew, gh) and hide
  modules when they are missing, and write Nerd Font glyphs as Lua
  `\u{...}` escapes.
- Keep configs portable: no absolute paths from your machine; derive
  paths from the config's own location.
- Commit messages: explain the why; no emojis in code or docs.
