# packaging

Manifests for the two package managers Windows users actually reach for. Both
ship the same portable zip the release workflow builds — there is no installer,
no service, and no elevation.

## Cutting a release

```powershell
git tag win-v0.1.0
git push origin win-v0.1.0
```

`.github/workflows/release.yml` builds, runs the tests, signs `ybar.exe`,
packages `ybar-win-<version>-x64.zip`, publishes it, and prints the SHA256 in
the release body. Signing happens before packaging, so that hash covers the
signed bits — the release body also states whether the build came out signed.

Then update the manifests below with that version and hash. The two
placeholder hashes (winget installer, scoop) are all-zero on purpose so a
stale manifest fails loudly instead of installing the wrong bits.

## winget

Three files under `winget/`, submitted to
[microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs) as
`manifests/n/NineFiveB/ybar-win/<version>/`:

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
scoop install https://raw.githubusercontent.com/NineFiveB/YBar/windows/packaging/scoop/ybar-win.json
```

`checkver`/`autoupdate` track `win-v*` tags, so scoop picks up new releases
without a manifest edit — only the version manifest hash needs regenerating,
which `scoop update` handles via `autoupdate`.

## Signing

Azure Trusted Signing, from CI, as a managed identity over OIDC — no
certificate file and no stored secret. `ci.yml` signs dev artifacts and
`release.yml` signs the release payload; both read the `AZURE_CLIENT_ID`,
`AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID` repo variables and skip
signing entirely while the first is empty, so forks still build.

This stopped being optional when Smart App Control (enforcing on stock
Windows 11) began blocking fresh unsigned builds outright rather than
merely warning about them. Enforcement is reputation-dependent, not a
hard unknown-hash wall — of two fresh unsigned CI builds on the reference
machine, one was blocked and one ran — which makes it worse to ship
against, not better: it fails for some users and not others. SmartScreen
additionally warns until the certificate accrues reputation. Neither package manager
requires a signature; winget and scoop pin the zip hash either way.

The alternative, for the record: a traditional OV certificate. Since the
2023-06 CA/B baseline its key must live on hardware, so signing could only
happen on the maintainer's machine, after the release — which is why the
hosted-CI route won.
