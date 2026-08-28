# packaging

Manifests for the two package managers Windows users actually reach for. Both
ship the same portable zip the release workflow builds — there is no installer,
no service, and no elevation.

## Cutting a release

```powershell
git tag win-v0.1.0
git push origin win-v0.1.0
```

`.github/workflows/release.yml` builds, runs the tests, packages
`ybar-win-<version>-x64.zip`, publishes it, and prints the SHA256 in the
release body.

Then update the manifests below with that version and hash. The two
placeholder hashes (winget installer, scoop) are all-zero on purpose so a
stale manifest fails loudly instead of installing the wrong bits.

## winget

Three files under `winget/`, submitted to
[microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs) as
`manifests/a/AegiosOT/ybar-win/<version>/`:

```powershell
winget validate --manifest packaging/winget
winget install --manifest packaging/winget   # local install test
```

`InstallerType: zip` + `NestedInstallerType: portable` is the same shape
komorebi uses: winget unpacks the zip and links `ybar.exe` onto `PATH` so
config scripts can call `ybar` back. Nothing is auto-started — that is what
`ybar autostart enable` is for.

`MinimumOSVersion` is 10.0.22000.0 (Windows 11) because the DWM system
backdrops behind `glass=on` do not exist before it. Everything else works on
Windows 10, so lower it if a Windows 10 build is ever supported explicitly.

## scoop

A single manifest under `scoop/`. Either submit it to a bucket or install it
directly:

```powershell
scoop install https://raw.githubusercontent.com/AegiosOT/YBar/windows/packaging/scoop/ybar-win.json
```

`checkver`/`autoupdate` track `win-v*` tags, so scoop picks up new releases
without a manifest edit — only the version manifest hash needs regenerating,
which `scoop update` handles via `autoupdate`.

## Signing

The binary is unsigned, so SmartScreen warns on first run. Signing is optional
future work: a code-signing certificate plus a `signtool` step in the release
workflow before packaging. Neither package manager requires it.
