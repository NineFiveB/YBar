# A formula, not a cask: YBar has no Developer ID, so a downloaded binary
# arrives quarantined with an untrusted signature and Gatekeeper refuses it.
# Building from source and signing ad-hoc on the installing machine sidesteps
# quarantine entirely. Command Line Tools are sufficient — shaders compile at
# runtime, so no Xcode dependency.
class Ybar < Formula
  desc "Metal-rendered, sketchybar-compatible macOS status bar"
  homepage "https://github.com/AltimG/YBar"
  url "https://github.com/AltimG/YBar/archive/refs/tags/v0.1.0.tar.gz"
  # SOURCE tarball hash (curl -L <url above> | shasum -a 256) - NOT the
  # app-zip hash that `make release` prints, which is a different,
  # machine-signed artifact. Regenerate on every new tag.
  sha256 "88bf58485b702f9d4f1db7d618728bd04457693594696ae0bc1e79fe9db9693c"
  license "GPL-3.0-only"
  head "https://github.com/AltimG/YBar.git", branch: "main"

  depends_on macos: :sonoma

  def install
    unless quiet_system("swift", "--version")
      odie "A Swift toolchain is required: xcode-select --install"
    end
    # SwiftPM's own sandbox cannot nest inside Homebrew's build sandbox.
    system "swift", "build", "-c", "release", "--disable-sandbox",
           "--scratch-path", ".scratch"

    # Mirrors the Makefile `app` target: the bundle gives the daemon its own
    # TCC identity (com.ybar.YBar), so privacy prompts are attributed to YBar
    # and grants cover the daemon plus every helper it spawns.
    app = prefix/"YBar.app"
    (app/"Contents/MacOS").mkpath
    (app/"Contents/Resources").mkpath
    cp "packaging/Info.plist", app/"Contents/Info.plist"
    cp ".scratch/release/ybar", app/"Contents/MacOS/ybar"
    cp_r ".scratch/release/YBar_YBarKit.bundle", app/"Contents/Resources"

    # Ad-hoc: installing machines lack the maintainer's "YBar Signing" cert,
    # and a fresh local signature passes Gatekeeper on locally built code.
    system "codesign", "--force", "--sign", "-",
           "--identifier", "com.ybar.YBar", app

    bin.install_symlink app/"Contents/MacOS/ybar"

    # Starter configs land in share/ybar/examples (docs/INSTALL.md points here).
    pkgshare.install "examples"
    pkgshare.install "themes"
    bin.install "scripts/ybar-theme"
  end

  def caveats
    <<~EOS
      YBar runs as an app bundle so macOS attributes privacy prompts
      (Bluetooth, Calendar, Apple Events) and manual grants (Accessibility,
      Screen Recording) to com.ybar.YBar. Start it with:

        open -g #{opt_prefix}/YBar.app --args -c ~/.config/ybar/ybarrc.lua

      The app is ad-hoc signed and every rebuild or upgrade produces a new
      signature, which voids previously granted TCC permissions. To keep
      grants across upgrades, create a self-signed code-signing certificate
      named "YBar Signing" in Keychain Access, then re-sign after upgrading:

        codesign --force --sign "YBar Signing" --identifier com.ybar.YBar \\
          #{opt_prefix}/YBar.app

      First-run permission walkthrough and autostart LaunchAgent:
      https://github.com/AltimG/YBar/blob/main/docs/INSTALL.md
    EOS
  end

  test do
    assert_match "ybar", shell_output("#{bin}/ybar --version")
  end
end
