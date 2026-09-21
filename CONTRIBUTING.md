# Contributing

- Build (macOS): `make build` (Command Line Tools are enough; glass backdrops
  need the macOS 26 SDK — older toolchains build with the blur fallback).
- Tests: `make test` must pass. New engine features need tests.
- The Windows port is a separate C++ engine on the orphan `windows` branch
  (CMake + vcpkg, its own `ctest` suite and docs). A change to the command
  grammar, the IPC wire format or the Lua API belongs on both branches. When a
  verb cannot land on both at once, record the gap and the contract in
  docs/WINDOWS-PORT.md so the other branch can follow — that is how the
  `start`/`stop`/`restart`/`status` verbs and the 0/1/2 exit codes are tracked.
- Helper binaries for the example configs: `make helpers`.
- Themes: see docs/THEMES.md. Ship a README crediting the palette/design
  origin, probe for optional binaries (aerospace, brew, gh) and hide
  modules when they are missing, and write Nerd Font glyphs as Lua
  `\u{...}` escapes.
- Keep configs portable: no absolute paths from your machine; derive
  directories from the config's own location.
- Commit messages: explain the why; no emojis in code or docs.
