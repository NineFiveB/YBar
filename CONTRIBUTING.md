# Contributing

- Build: `make build` (Command Line Tools are enough; glass backdrops need
  the macOS 26 SDK — older toolchains build with the blur fallback).
- Tests: `make test` must pass. New engine features need tests.
- Helper binaries for the example configs: `make helpers`.
- Themes: see docs/THEMES.md. Ship a README crediting the palette/design
  origin, probe for optional binaries (aerospace, brew, gh) and hide
  modules when they are missing, and write Nerd Font glyphs as Lua
  `\u{...}` escapes.
- Keep configs portable: no absolute paths from your machine; derive
  directories from the config's own location.
- Commit messages: explain the why; no emojis in code or docs.
