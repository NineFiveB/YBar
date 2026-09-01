<#
.SYNOPSIS
    Installs ybar (GPU-rendered scriptable status bar for Windows) for the
    current user.

.DESCRIPTION
    Downloads the latest win-v* release zip into %LOCALAPPDATA%\Programs\ybar,
    verifies it against the SHA256 the release publishes (and the Authenticode
    signature on the exe), and puts the directory on the user PATH. No admin
    rights required and nothing is written outside the user profile.

    Run directly:
        irm https://raw.githubusercontent.com/NineFiveB/YBar/windows/scripts/install.ps1 | iex

    Options are read from environment variables, since a piped script takes no
    parameters:
        $env:YBAR_START     = 1        start the daemon when the install finishes
        $env:YBAR_AUTOSTART = 1        also register ybar to start at login
        $env:YBAR_VERSION   = 0.1.0    install a specific release (default: latest win-v*)
        $env:YBAR_UNINSTALL = 1        remove ybar instead of installing it
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Repo       = 'NineFiveB/YBar'
$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\ybar'
# The daemon's own state (IPC socket, logs) — separate from the binaries.
$StateDir   = Join-Path $env:LOCALAPPDATA 'ybar'
$ConfigDir  = Join-Path $env:USERPROFILE '.config\ybar'
$RunKey     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

function Write-Step($msg) { Write-Host "  $msg" }
function Write-Head($msg) { Write-Host ''; Write-Host $msg -ForegroundColor Cyan }

function Stop-YBar {
    $procs = @(Get-Process ybar -ErrorAction SilentlyContinue)
    if (-not $procs) { return $false }
    Write-Step 'stopping the running bar (its exe is locked while it runs)'
    # Graceful first: --exit over the IPC socket lets it release the work-area
    # reservation. It may have been installed by scoop or by hand, so any copy
    # of the CLI reaches the same daemon.
    $cli = Join-Path $InstallDir 'ybar.exe'
    if (-not (Test-Path $cli)) {
        $resolved = Get-Command ybar -ErrorAction SilentlyContinue
        $cli = if ($resolved) { $resolved.Source } else { $null }
    }
    if ($cli -and (Test-Path $cli)) {
        try { & $cli --exit 2>$null | Out-Null } catch {}
        for ($i = 0; $i -lt 40 -and @($procs | Where-Object { -not $_.HasExited }).Count; $i++) {
            Start-Sleep -Milliseconds 250
            foreach ($p in $procs) { $p.Refresh() }
        }
    }
    $alive = @($procs | Where-Object { -not $_.HasExited })
    if ($alive) {
        $alive | Stop-Process -Force -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 300
    }
    return $true
}

# scoop installs ybar too; a copy from each channel on PATH is a recipe for
# running a stale binary and thinking it's upgraded.
function Test-ScoopCopy {
    [bool](Get-Command ybar -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -like (Join-Path $env:USERPROFILE 'scoop\*') })
}

# The user PATH is usually REG_EXPAND_SZ; [Environment]::SetEnvironmentVariable
# reads it expanded and writes it back as REG_SZ, freezing entries other
# installers left as %JAVA_HOME%\bin etc. Go through the registry raw instead.
function Get-UserPathRaw {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
    if (-not $key) { return '' }
    try { return [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    finally { $key.Close() }
}

function Set-UserPathRaw($value) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try {
        $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
        if ($key.GetValueNames() -contains 'Path') { $kind = $key.GetValueKind('Path') }
        $key.SetValue('Path', $value, $kind)
    } finally { $key.Close() }
    # A raw registry write skips the WM_SETTINGCHANGE broadcast that
    # [Environment]::SetEnvironmentVariable does; without it Explorer never
    # rereads the key and new terminals keep the old PATH until relogin.
    if (-not ('YBar.Native' -as [type])) {
        Add-Type -Namespace YBar -Name Native -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    }
    $result = [UIntPtr]::Zero
    # HWND_BROADCAST, WM_SETTINGCHANGE, SMTO_ABORTIFHUNG
    [void][YBar.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
}

function Add-ToUserPath($dir) {
    $entries = @((Get-UserPathRaw) -split ';' | Where-Object { $_ })
    if ($entries -contains $dir) { Write-Step "PATH already contains $dir"; return }
    Set-UserPathRaw ((@($entries) + $dir) -join ';')
    Write-Step "added $dir to your user PATH"
    Write-Host '    (open a new terminal for this to take effect elsewhere)' -ForegroundColor DarkGray
}

function Remove-FromUserPath($dir) {
    $entries = @((Get-UserPathRaw) -split ';' | Where-Object { $_ })
    if ($entries -notcontains $dir) { return }
    Set-UserPathRaw (($entries | Where-Object { $_ -ne $dir }) -join ';')
    Write-Step "removed $dir from your user PATH"
}

# ---------------------------------------------------------------- uninstall --

if ($env:YBAR_UNINSTALL) {
    Write-Head 'Uninstalling ybar'
    [void](Stop-YBar)

    # `ybar autostart enable` writes an HKCU Run value named YBar.
    if (Get-ItemProperty -Path $RunKey -Name YBar -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $RunKey -Name YBar
        Write-Step 'removed the autostart entry'
    }
    Remove-FromUserPath $InstallDir
    foreach ($dir in @($InstallDir, $StateDir)) {
        if (Test-Path $dir) {
            # Non-fatal: a locked file must not abort the uninstall halfway,
            # after the Run key and PATH entry are already gone.
            try {
                Remove-Item $dir -Recurse -Force -Confirm:$false -ErrorAction Stop
                Write-Step "deleted $dir"
            } catch {
                Write-Host "  could not delete $dir - remove it by hand" -ForegroundColor Yellow
            }
        }
    }

    Write-Host ''
    Write-Host 'ybar removed.' -ForegroundColor Green
    if (Test-ScoopCopy) {
        Write-Host 'A scoop-installed copy of ybar is still present - remove it with: scoop uninstall ybar-win' -ForegroundColor Yellow
    }
    if (Test-Path $ConfigDir) {
        Write-Host "Your config was left alone at $ConfigDir - delete it by hand if you want it gone." -ForegroundColor DarkGray
    }
    # A lingering flag would turn the next install one-liner pasted into this
    # window into another uninstall.
    Remove-Item Env:YBAR_UNINSTALL -ErrorAction SilentlyContinue
    return
}

# ------------------------------------------------------------------ install --

Write-Head 'Installing ybar'

if ([Environment]::Is64BitOperatingSystem -eq $false) {
    throw 'ybar ships x64 binaries only.'
}

# Resolve the release to install. The repository also cuts macOS releases
# (plain v* tags), so "latest" means the newest win-v* one, not
# /releases/latest.
$headers = @{ 'User-Agent' = 'ybar-installer' }
$release = if ($env:YBAR_VERSION) {
    $tag = if ($env:YBAR_VERSION -like 'win-v*') { $env:YBAR_VERSION } else { "win-v$env:YBAR_VERSION" }
    Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/tags/$tag" -Headers $headers
} else {
    Write-Step 'looking up the latest win-v* release'
    $all = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases?per_page=30" -Headers $headers
    $all | Where-Object { $_.tag_name -like 'win-v*' -and -not $_.prerelease } | Select-Object -First 1
}
if (-not $release) { throw "No win-v* release found in $Repo." }
Write-Step "release $($release.tag_name)"

$asset = $release.assets | Where-Object { $_.name -like 'ybar-win-*-x64.zip' } | Select-Object -First 1
if (-not $asset) { throw "Release $($release.tag_name) has no ybar-win-*-x64.zip asset - it may still be uploading; retry in a minute." }

# The release body publishes the zip's SHA256; a release without one is
# incomplete, not verifiable.
$expected = $null
if ($release.body -match '([0-9a-fA-F]{64})') { $expected = $matches[1].ToLower() }
if (-not $expected) { throw "Release $($release.tag_name) publishes no SHA256 - refusing to install unverified." }

# Download and unpack to a temp dir first so a failed download cannot leave a
# half-installed directory behind.
$staging = Join-Path ([IO.Path]::GetTempPath()) ("ybar-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $staging | Out-Null
# Windows PowerShell 5.1 redraws the progress bar per buffer, slowing multi-MB
# downloads by an order of magnitude; iex shares the caller's scope, so save
# and restore instead of leaking the preference into their session.
$oldProgressPreference = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'
$wasRunning = $false
try {
    $zip = Join-Path $staging $asset.name
    Write-Step "downloading $($asset.name)"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing

    Write-Step 'verifying the checksum'
    $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected) {
        throw "Checksum mismatch for $($asset.name) - refusing to install. Expected $expected, got $actual."
    }

    $unpacked = Join-Path $staging 'unpacked'
    Expand-Archive -Path $zip -DestinationPath $unpacked
    if (-not (Test-Path (Join-Path $unpacked 'ybar.exe'))) {
        throw "The release zip has no ybar.exe at its top level - refusing to install."
    }

    # Release binaries are Authenticode-signed (Azure Trusted Signing). A
    # missing signature is only a warning - forks build unsigned - but a
    # BROKEN one means the zip's contents do not match what was signed.
    $sig = Get-AuthenticodeSignature (Join-Path $unpacked 'ybar.exe')
    switch ($sig.Status) {
        'Valid'     { Write-Step "signature OK ($($sig.SignerCertificate.Subject -replace '^CN=([^,]+).*','$1'))" }
        'NotSigned' { Write-Host '  note: this build is not code-signed (fork or pre-signing release)' -ForegroundColor Yellow }
        default     { throw "ybar.exe has a broken Authenticode signature ($($sig.Status)) - refusing to install." }
    }

    # An upgrade has to stop the daemon to overwrite its exe; remember to
    # bring it back afterwards, or the one-liner upgrade leaves the user
    # without their bar.
    $wasRunning = Stop-YBar

    # Replace the whole directory so files dropped from a release do not
    # linger. Config and state live elsewhere; retry briefly because process
    # teardown can hold the old exe's handle for a few seconds after exit.
    if (Test-Path $InstallDir) {
        for ($i = 0; $i -lt 20; $i++) {
            try { Remove-Item $InstallDir -Recurse -Force -Confirm:$false -ErrorAction Stop; break }
            catch { Start-Sleep -Milliseconds 500 }
        }
        if (Test-Path $InstallDir) { throw "Could not replace $InstallDir - a file in it is still in use." }
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $InstallDir) | Out-Null
    Move-Item $unpacked $InstallDir
    Write-Step "installed to $InstallDir"
} finally {
    $ProgressPreference = $oldProgressPreference
    Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue -Confirm:$false
}

Add-ToUserPath $InstallDir
# Make ybar usable in this session too, not just new terminals.
if (($env:PATH -split ';') -notcontains $InstallDir) { $env:PATH = "$InstallDir;$env:PATH" }

if (Test-ScoopCopy) {
    Write-Host ''
    Write-Host 'Note: a scoop-installed copy of ybar also exists. Whichever PATH entry was' -ForegroundColor Yellow
    Write-Host 'added first wins in new terminals, so `ybar` may keep running the scoop copy.' -ForegroundColor Yellow
    Write-Host 'Pick one channel: scoop uninstall ybar-win   (or uninstall this copy instead)' -ForegroundColor Yellow
}

if ($env:YBAR_AUTOSTART) {
    & (Join-Path $InstallDir 'ybar.exe') autostart enable
    if ($LASTEXITCODE) { throw "ybar autostart enable failed (exit $LASTEXITCODE)." }
}

if ($env:YBAR_START -or $wasRunning) {
    Write-Step 'starting the bar'
    # Console-subsystem exe: detach it so it does not tie up this terminal,
    # and give stderr a file - an unread pipe would eventually block it.
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    Start-Process (Join-Path $InstallDir 'ybar.exe') -WindowStyle Hidden `
        -RedirectStandardError (Join-Path $StateDir 'stderr.log')
}

Write-Host ''
Write-Host "ybar $($release.tag_name) installed." -ForegroundColor Green
Write-Host ''
Write-Host '  ybar                     start the bar (blocks the terminal; use autostart for login)'
Write-Host '  ybar theme list          shipped themes'
Write-Host '  ybar theme use <name>    switch the default config to a theme'
Write-Host '  ybar autostart enable    start it at every login'
Write-Host '  ybar --exit              stop the running bar'
Write-Host ''
Write-Host 'Configs live in ~/.config/ybar (ybarrc.lua, ybarrc, or *.jsonc).' -ForegroundColor DarkGray
Write-Host 'Uninstall: $env:YBAR_UNINSTALL=1; irm https://raw.githubusercontent.com/NineFiveB/YBar/windows/scripts/install.ps1 | iex' -ForegroundColor DarkGray
