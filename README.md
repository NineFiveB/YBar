# ybar-win

**Top bar for Windows** — a GPU-rendered (D3D11 + DirectComposition),
scriptable status bar with first-class [komorebi](https://github.com/LGUG2Z/komorebi)
integration. A native C++ implementation of [YBar](https://github.com/NineFiveB/YBar)
that preserves its user contract: the sketchybar-style CLI/IPC grammar, the
embedded Lua 5.4 config runtime, themes, and the script/event environment.
Configs and themes written for YBar on macOS run here with only OS-inherent
edits.

> **Status: skeleton.** The wire format is implemented and tested; everything
> else is scaffolding. The authoritative design is
> [docs/WINDOWS-PORT.md](docs/WINDOWS-PORT.md) — read it first.

## Layout

| Path | Contents | Spec |
|---|---|---|
| `src/ipc/` | wire format (implemented), socket server/client, command parser/handler | §3.1–3.2, §5.1, §9 |
| `src/app/` | daemon lifecycle, message loop, config discovery/exec, hotload | §5 |
| `src/model/` | items, styles, components, layout, property setter, query serialization | §3.3, §8 |
| `src/anim/` | curves, scheduler (compositor-clock paced) | §3.8 |
| `src/render/` | D3D11 renderer, scene builder, glyph atlas, DirectWrite font cache | §7 |
| `src/win/` | bar/popup surfaces (HWND + DComp), displays, mouse, backdrops, appbar | §6 |
| `src/providers/` | audio, power, network, stats, media (GSMTC), workspace, **komorebi** | §10, §11 |
| `src/lua/` | vendored Lua 5.4 (C), bridge, prelude | §3.7, §12 |
| `shaders/ybar.hlsl` | the SDF/glyph pipeline, compiled at runtime with `D3DCompile` | §7.3 |
| `tests/` | Catch2 contract tests (ported from the Swift suite) | §14 |

## Building

Requires Visual Studio 2022 C++ tools, CMake ≥ 3.24, and
[vcpkg](https://github.com/microsoft/vcpkg) (`VCPKG_ROOT` set).

```powershell
cmake --preset default
cmake --build --preset default
ctest --preset default
```

## License

GPL-3.0-only, same as YBar. komorebi is a separate program under its own
license; ybar-win only communicates with it over its socket and neither links
nor redistributes any komorebi code.
